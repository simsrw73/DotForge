# Tool selection, slice 1: plan

**Spec:** [2026-10-09-tool-selection-design.md](../specs/2026-10-09-tool-selection-design.md) (approved). This plan covers its slice 1:

- `Start-DFSession -Config`, a config snapshot, request resolution, groups
- the missing notice, `Get-DFToolStatus`
- removal of `-All`, `SkipTools`, `Initialize-DFEnvironment` and the global `$DFConfig`

Slices 2–4 (`after`/`requires` + setup, install, migration) are separate plans.

> **Update (2026-10-09):** `requires` (tools and `role:<name>`) landed early, after slice 1 went live: npm and inshellisense were reported missing because node is on PATH only after fnm's companion runs. They now `require role:js-runtime`, a category role fnm (priority 20) and mise (10) belong to. Slice 2 (`dependsOn` → `after`, and `setup.seed` folded into the one-time setup step) followed the same day.

**Rules:** TDD for each task. The full suite runs with every `XDG_*_HOME` pointed at an empty sentinel folder, before each commit. Startup is measured before and after the slice.

## Rollout (decided 2026-10-09)

The user's installed module (`OneDrive\Documents\PowerShell\Modules\DotForge`) is a **junction to this repo**, so `main` is live in every new shell. Slice 1 removes calls the profile makes, so:

- Slice 1 is built on branch **`feat/tool-selection`** in its own worktree (`.claude/worktrees/tool-selection`). `main` stays untouched.
- When it's ready, the profile change is prepared in the user's chezmoi source (`~/.local/share/chezmoi`) for the user to review.
- Then, in one step: merge the branch, and the user runs `chezmoi apply`.

## Facts this plan relies on (verified 2026-10-09)

- Every config read goes through `Get-DFConfig` (`Private/Get-DFConfiguredTheme.ps1:38`), which makes the only read of the global (`:60`).
- Tests set `$Global:DFConfig` in 94 lines across 21 files. `Register-DFTool -All` appears 6 times in tests.
- `Initialize-DFEnvironment` is mentioned in 46 files and `SkipTools` in 25, mostly docs, examples and tests.
- `Get-DFRegistrationSet`, `Get-DFRoleWinners` and `Invoke-DFToolRegistration` are in `Private/Register-DFToolSteps.ps1`. `Invoke-DFTopoSort` orders by `dependsOn`; slice 2 changes that to `after`/`requires`.

## Tasks

1. **Baseline.** Measure startup with the current profile shape (`Import-Module`; `Initialize-DFEnvironment`; `Register-DFTool -All` with the user's `SkipTools`). Save the numbers in this plan.
   - **Result (2026-10-09, 3 runs, `pwsh -NoProfile`, the user's `$DFConfig`):** import 0.69–0.72 s, `Initialize-DFEnvironment` 0.27–0.29 s, `Register-DFTool -All` 2.09–2.11 s. **Total 3.05–3.12 s.**
2. **Config snapshot.**
   - `Get-DFConfig` reads `$script:DFSessionConfig`, with no global fallback.
   - Add `Set-DFSessionConfig` (private): validate keys, warn with "did you mean" (`Get-DFFieldSuggestion`), store a copy.
   - Tests:
     - A helper `Set-DFTestConfig` in `tests/TestSupport.ps1` replaces the `$Global:DFConfig` assignments. This is a mechanical conversion of 21 files, scriptable.
     - An AST test asserts that nothing in `Private/`, `Public/` or `Tools/` reads `$DFConfig`.
3. **Groups.**
   - Create `data/groups.json` with the draft groups from the spec.
   - Add `Get-DFGroupDb` (private loader, cached) and `Get-DFToolGroup` (public).
   - Invariant tests: members exist; no group name equals a tool name; no nesting; descriptions present.
4. **`Resolve-DFRequestedTools`** (private, pure). Inputs: Tools, ExcludeTools, the group DB, and a record lookup.
   - Output: an ordered request set with `RequestedBy` and `Excluded` entries.
   - Warnings: unknown tool (did you mean), unknown group, and excluding something that wasn't requested.
   - **Deviation from the spec:** an unknown group **warns** instead of erroring, so a typo can't abort a profile that sets `$ErrorActionPreference = 'Stop'`.
   - In this slice it orders by the existing `dependsOn`. Requirements come in slice 2.
5. **Read only requested records.** `Import-DFToolDb` gains `-Name` and reads only those `Tools/<name>.json` files, plus their `dependsOn` closure for ordering. The whole-folder read stays for `Get-DFTool`/`Find-DFTool`.
6. **Roles over requested tools.**
   - Add a fallback detail to `Get-DFRoleWinners`.
   - A `Defaults` choice that isn't requested warns.
7. **`Start-DFSession -Config`** (public):
   - Snapshot the config, export XDG, resolve, check availability, pick role winners.
   - Activate, using today's per-tool registration and setup, with failure isolation.
   - Run the conflict check, record `$script:DFSessionStatus`, print the notice.
   - Calling it again only adds tools.
8. **`Get-DFToolStatus`** (public): `DotForge.ToolStatus` objects; `-Missing`/`-Failed`/`-Name`; behavior before a session exists.
9. **The missing notice:** three formats, with a threshold of 5.
10. **Removals:**
    - `Register-DFTool -All` and `SkipTools`. `Register-DFTool -Name` becomes "add to this session" and uses the session config.
    - `Initialize-DFEnvironment`: its XDG export moves into `Start-DFSession`, and package-manager detection is deferred to slice 3. `Install-DFTool` keeps detecting on its own until then.
    - The manifest export lists, `PublicSurface`, `docs/reference.md`.
11. **Docs and examples (mechanical; can be delegated with a tight brief):**
    - the guides, the README, `examples/*.ps1`
    - `CHANGELOG.md` (Added/Removed)
    - `CLAUDE.md` (profile shape, Testing section)
12. **Verify:**
   - **Result (2026-10-09, 3 runs each, `pwsh -NoProfile`, branch code):**
     - groups only (28 active): **2.28–2.45 s** (import ~0.72 s, `Start-DFSession` 1.57–1.72 s)
     - groups plus all 16 extras (44 active): 2.75–3.25 s
     - baseline (`-All`, 43 active): 3.05–3.12 s
     - So opt-in saves what you drop (~0.7 s for the 16 extras). The remaining ~2.3 s is import plus a handful of tools (module imports and init scripts): review candidates 1–3 (idle activation, module split, compiled registry) are where the rest is.
    - Run the full suite with the decoy folders.
    - Run a real shell with the new profile shape against a temp XDG: only requested tools are touched, and the notice is correct.
    - Measure startup after, compare with task 1, and record both.

## Out of this slice

- `after`/`requires` and the setup step (slice 2).
- Package-manager module, `Install-DFTool -Missing`/`-Setup` (slice 3).
- Migrating the user's chezmoi-managed profile (slice 4). Until then, the user's profile keeps working only if it's switched to `Start-DFSession`, so this slice's CHANGELOG and the final report must say so clearly.
