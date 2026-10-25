# Manager Choice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `InstallAlways` (one source for every tool a system manager carries, else skip) and a record field `install.avoid` (source → reason: ranked last, warned about when used).

**Architecture:** Records gain `install.avoid`, normalized and schema-checked beside `install.prefer`. `Shared/DFInstallSource.ps1` owns the order: one helper decides whether `InstallAlways` covers a tool; `Get-DFInstallSourceOrder` applies it and moves avoided sources last; `Resolve-DFInstallSource` reports the skip as a Gap and returns the avoid reason. The plan carries the reason to its printout and the result Detail.

**Tech Stack:** PowerShell 7.2+, Pester 6.

**Spec:** `docs/superpowers/specs/2026-10-25-manager-choice-design.md`

## Global Constraints

- Order: `-Via`, `InstallVia`, `InstallAlways`, `install.prefer`, `InstallOrder`, DotForge's order; avoided sources last unless named by `-Via`, `InstallVia` or `InstallAlways`.
- `InstallAlways` covers a tool only when the tool has a package in some system manager's source (members of the `package-manager` role: scoop, winget, choco). Covered and no package in the named source → skipped as a Gap: `InstallAlways is <source>, which has no package for it`.
- `InstallVia`/`-Via` beat `InstallAlways`. `InstallAlways` beats `ExcludeSources`, with a warning. An unknown `InstallAlways` source warns (through `Write-DFInstallWarning`) and is ignored.
- `install.avoid`: object, source → one-sentence reason; always present after normalization (empty object). Schema errors: not an object, a non-string reason, a source the tool has no package for, a source also in `prefer`.
- No core code names a tool or manager (plugin rule); rustup and pnpm get `"install": { "avoid": { "scoop": "..." } }` in their JSON only.
- Work in worktree `../DotForge-manager-choice` on branch `manager-choice`; the spec and this plan are uncommitted in the main checkout: move them in first. All commits signed, batched in Task 4.

## Review Focus

1. `Find-DFToolSource` uses `Get-DFInstallSourceOrder` to find where an installed tool came from: with `InstallAlways` the order may be empty or only one source, but it still asks every source the tool has (it appends `$have`). Test in Task 2 that a winget-installed tool is still found under `InstallAlways = 'scoop'`.
2. `InstallAlways` set and the tool has no system-manager package but is pinned by `InstallVia` to a registry: InstallVia wins, no Gap. Test in Task 2.
3. Interactive re-planning (Install-DFTool's question loop) must not repeat the unknown-source or excluded-source warning: use `Write-DFInstallWarning`. Test in Task 2 by calling the order twice inside one warned set.
4. A record with `install` absent: `install.avoid` must still read as empty (StrictMode-safe) everywhere it's read. Test in Task 1.
5. A tool whose only non-avoided source has no available manager: the avoided source still installs it (it's ranked last, not removed). Test in Task 2.

---

### Task 1: `install.avoid` in records

**Files:**
- Modify: `Shared/Import-DFToolDb.ps1` (`ConvertTo-DFInstallBlock`, ~line 478; and the record normalization so `install` is never `$null`, if it is today)
- Modify: `Shared/Test-DFToolSchema.ps1` (allowed keys `install = 'prefer'` → add `'avoid'`, ~line 449; checks beside `install.prefer`, ~line 322)
- Modify: `Tools/rustup.json`, `Tools/pnpm.json`; regenerate `data/tool-registry.json`
- Test: `tests/Installs.Schema.Tests.ps1`, `tests/Test-DFToolSchema.Tests.ps1`, `tests/ToolLocations.Tests.ps1`

**Interfaces:**
- Produces: `$tool.install.avoid` — a `[pscustomobject]` (source → reason string) on every normalized record, empty when undeclared. Read a reason with `$tool.install.avoid.PSObject.Properties[$source]?.Value`.

- [ ] **Step 1: Failing tests.**
  - Normalization: a record without `install` → `@($tool.install.avoid.PSObject.Properties).Count -eq 0` (no throw under `Set-StrictMode -Version Latest`); with `"install": { "avoid": { "scoop": "why" } }` → `$tool.install.avoid.scoop -eq 'why'`.
  - Schema: `avoid` as a string → error matching `*install.avoid must be an object*`; a reason that isn't a string → `*install.avoid.scoop must be a reason (text)*`; avoiding a source with no package → `*install.avoid names sources the tool has no package for: choco*`; `prefer` and `avoid` both naming scoop → `*install.prefer and install.avoid both name: scoop*`; a valid one → no errors.
  - Records (`ToolLocations.Tests.ps1`): `rustup` and `pnpm` avoid `scoop` with a non-empty reason.
- [ ] **Step 2: Run** `./build/Test-DFFull.ps1 -Path tests/Installs.Schema.Tests.ps1, tests/Test-DFToolSchema.Tests.ps1, tests/ToolLocations.Tests.ps1`. Expected: the new tests FAIL.
- [ ] **Step 3: Implement.** Normalize `avoid` to a pscustomobject; schema checks with the messages above. Reasons for the records:
  - rustup: `scoop's installer sets CARGO_HOME and RUSTUP_HOME to its own folder before rustup-init runs, so toolchains never land in the XDG folders.`
  - pnpm: `scoop's post-install saves its own store, cache and state folders in pnpm's config, so PNPM_HOME alone doesn't move them.`
  Then `./build/Build-DFToolRegistry.ps1`.
- [ ] **Step 4: Run** the same command plus `tests/ToolRegistry.Tests.ps1`. Expected: PASS.

### Task 2: The source order

**Files:**
- Modify: `Shared/DFInstallSource.ps1` (`Get-DFInstallSourceOrder`, `Resolve-DFInstallSource`; new helper)
- Modify: `Private/DFSessionConfig.ps1` (`$script:DFConfigKeys`: `InstallAlways = 'One source for every tool a system manager carries; a tool it lacks is skipped'`; update the `InstallVia` description to "beats InstallAlways and ExcludeSources")
- Test: `tests/DFInstallSource.Tests.ps1`, `tests/Find-DFToolSource.Tests.ps1`

**Interfaces:**
- Consumes: Task 1's `$tool.install.avoid`.
- Produces:
  - `Get-DFInstallAlways -Tool <pscustomobject> -ToolDb <hashtable> [-Via <hashtable>]` → `[string]` the source `InstallAlways` imposes on this tool, or `$null` (unset, unknown source, tool not covered, or pinned by `-Via`/`InstallVia`).
  - `Resolve-DFInstallSource` result gains `AvoidReason` (`[string]`, `$null` unless the chosen source is one the record avoids).

- [ ] **Step 1: Failing tests** in `DFInstallSource.Tests.ps1` (test Db from `New-Db`; add to it a psresource-only module record `{ "name": "mod", "packages": { "psgallery": "Mod" } }` with a `psresource` manager `installs.from = psgallery`, and give `glow` `"install": { "prefer": ["winget"], "avoid": { "choco": "choco is bad here" } }`):
  - `InstallAlways beats install.prefer and InstallOrder` — `InstallAlways = 'scoop'` → glow's order `@('scoop')`.
  - `skips a tool the InstallAlways source has no package for` — a tool with only `winget` → order empty; `Resolve-DFInstallSource` Gap `'InstallAlways is scoop, which has no package for it'`.
  - `leaves a tool no system manager carries alone` — `mod` under `InstallAlways = 'scoop'` → order `@('psgallery')`.
  - `lets InstallVia and -Via beat InstallAlways` — `InstallVia = @{ glow = 'winget' }` → order starts with `winget`; `-Via @{ glow = 'choco' }` → starts with `choco`.
  - `InstallAlways wins over ExcludeSources, with a warning` — `ExcludeSources = @('scoop')` → order `@('scoop')`, warning `*InstallAlways*ExcludeSources*`.
  - `warns about an unknown InstallAlways source, once, and ignores it` — `InstallAlways = 'nope'` → normal order; inside one `$script:DFInstallWarned = [System.Collections.Generic.HashSet[string]]::new()` two calls give one warning.
  - `ranks an avoided source last` — `InstallOrder = @('choco', 'scoop')` → glow's order `@('winget', 'scoop', 'choco')`.
  - `keeps an avoided source first when the user names it` — `-Via @{ glow = 'choco' }`, `InstallVia`, and `InstallAlways = 'choco'` each → first is `choco`.
  - `still installs from an avoided source when nothing else is available` — `IsAvailable` true only for choco → Source `choco`, `AvoidReason` `'choco is bad here'`.
  - `has no AvoidReason for an ordinary source` — default → `AvoidReason` `$null`.
  - In `Find-DFToolSource.Tests.ps1`: `still finds a tool installed through another source under InstallAlways` — `InstallAlways = 'scoop'`, the tool listed by winget's mocked list → Manager `winget`.
- [ ] **Step 2: Run** `./build/Test-DFFull.ps1 -Path tests/DFInstallSource.Tests.ps1, tests/Find-DFToolSource.Tests.ps1, tests/DFSessionConfig.Tests.ps1`. Expected: new tests FAIL.
- [ ] **Step 3: Implement.** `Get-DFInstallAlways`: the system sources are `installs.from` of `Get-DFRoleMember -Role 'package-manager'` over the managers in `-ToolDb`; known sources are `Get-DFBuiltInSourceOrder`. In `Get-DFInstallSourceOrder`: after `$pinned`, `$always = Get-DFInstallAlways ...`; when `$always` is set (and nothing pinned) the order is `@($always)` filtered by `$have` (no ExcludeSources filter; warn if excluded); otherwise today's list, then move sources in `install.avoid` to the end unless equal to `$pinned`. `Resolve-DFInstallSource`: when the order is empty and `Get-DFInstallAlways` is set, the Gap is the InstallAlways text; set `AvoidReason` from the chosen source. Update both functions' help (DESCRIPTION order line) and `Find-DFToolSource`'s help line naming the order.
- [ ] **Step 4: Run** the same command. Expected: PASS.

### Task 3: The plan shows the reason

**Files:**
- Modify: `Private/New-DFInstallPlan.ps1` (item gains `AvoidReason`), `Private/Write-DFInstallPlan.ps1`, `Private/Invoke-DFInstallPlan.ps1` (Detail)
- Test: `tests/New-DFInstallPlan.Tests.ps1`, `tests/Invoke-DFInstallPlan.Tests.ps1`

**Interfaces:**
- Consumes: Task 2's `AvoidReason`.
- Produces: plan item property `AvoidReason`.

- [ ] **Step 1: Failing tests.** A tool installed from a source its record avoids: `New-DFInstallPlan` item `.AvoidReason` equals the reason; `Write-DFInstallPlan` (mock `Write-Host`) prints a line matching `*<tool> from <source>: <reason>*`; `Invoke-DFInstallPlan` result Detail is `via <manager> (<reason>)`. A tool from an ordinary source: Detail stays `via <manager>`.
- [ ] **Step 2: Run** `./build/Test-DFFull.ps1 -Path tests/New-DFInstallPlan.Tests.ps1, tests/Invoke-DFInstallPlan.Tests.ps1`. Expected: new tests FAIL.
- [ ] **Step 3: Implement.** Copy `AvoidReason` onto the item; in `Write-DFInstallPlan` print `  note: <tool> from <source>: <reason>` (Yellow) after the stages; in `Invoke-DFInstallPlan` append ` (<reason>)` to the Installed Detail.
- [ ] **Step 4: Run** the same command. Expected: PASS.

### Task 4: Docs, generated files, gate, review, merge

**Files:**
- Modify: `docs/guide/configuration.md` (settings table row for `InstallAlways` after `InstallVia`; the precedence list ~line 365), `docs/guide/writing-a-tool.md` (`install.avoid` beside `install.prefer`), `docs/guide/troubleshooting.md` (row for the new Gap: fix with `InstallVia = @{ <tool> = '<source>' }` or a different `InstallAlways`), `CLAUDE.md` (Tool JSON Schema: `install.avoid`), `CHANGELOG.md` (`### Added`), `TODO.md` (T-83: add "warn at first run about a tool already installed from a source its record avoids"), the restore notes (piece 5 done)
- Regenerate: `Bundle/DotForge.Core.ps1`, `docs/reference.md`

- [ ] **Step 1:** Docs as listed. A doc code block that sets config only is unmarked; nothing here installs.
- [ ] **Step 2:** `./build/Build-DFCoreBundle.ps1`, `./build/Build-DFReferenceDocs.ps1`.
- [ ] **Step 3:** `./build/Test-DFFull.ps1`. Expected: 0 failed.
- [ ] **Step 4:** Commit (signed), including the spec and this plan: `feat: InstallAlways, and records can avoid a source`.
- [ ] **Step 5:** Final review, fixes, then fast-forward `main`, push, remove the worktree (leave it first).
