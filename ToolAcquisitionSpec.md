# Tool Acquisition & Integration Standard

**Status:** Normative standard for DotForge tool onboarding.
**Applies to:** every CLI tool added to `Tools/*.json` (and its optional `.ps1` companion).

This document defines, unambiguously, how a tool becomes a first-class DotForge citizen: how we make
it XDG-compliant with the least possible environment pollution, how we *prove* our configuration is
actually honored, and how we layer required config, themes, completions, pickers, aliases, and
default-tool selection on top.

Requirement keywords — **MUST**, **MUST NOT**, **SHOULD**, **MAY** — carry their usual normative
force. Where a rule formalizes machinery that already exists, the implementing file is cited so the
rule and the code stay in sync.

---

## 1. Purpose & Scope

This standard governs **integration** of a single tool: XDG conformance, required configuration,
theming, completion, pickers, aliases, and default-tool selection. It is the procedure we follow,
together, each time we onboard a tool.

Out of scope — deferred to their own specs:

- **Package-manager metadata consolidation** (the "trifle"/package-universe effort): cataloguing,
  identity-linking, and mining metadata across scoop/winget/choco. See
  `docs/superpowers/specs/2026-07-06-trifle-tool-identity-guide-design.md` and the
  `2026-07-16-package-universe-*` specs. This standard treats package managers only as *tools to be
  integrated* (§11), not as a metadata pipeline.

---

## 2. Principles

1. **Minimum pollution.** Prefer the least intrusive mechanism that works (the ladder in §3). Set no
   environment variable, write no config file, and create no wrapper we can avoid. Every artifact we
   add MUST be justified by a conformance result (§4).
2. **Don't trust the documentation — verify.** A tool's docs are a *hypothesis*. We have already hit
   cases where documented behavior does not match reality. No configuration is considered "done"
   until a conformance probe (§4) shows the tool reads it *and honors its content*.
3. **Degrade silently, never fail.** DotForge is dot-sourced into a live profile. Any dependency on a
   tool's internals or optional behavior MUST degrade to a no-op or `Write-Warning`, never a
   terminating error. This is an existing house rule (`CLAUDE.md`, `docs/external-dependencies.md`);
   integration code MUST honor it.
4. **Idempotent.** Registering a tool twice in one session MUST be safe. Config files are written
   only when absent (never clobbering user edits); env vars and wrappers are set deterministically.
5. **XDG-first.** The home directory is not a dumping ground. State, data, cache, and config land
   under the XDG base dirs (`Initialize-DFEnvironment` seeds `XDG_CONFIG_HOME`, `XDG_DATA_HOME`,
   `XDG_STATE_HOME`, `XDG_CACHE_HOME`, and the non-spec `XDG_BIN_HOME`).

---

## 3. The XDG Integration Ladder

Every tool records `xdg.compliance` (`full | partial | none`, documentary) and `xdg.method`, the
dispatch key consumed by `Public/Register-DFTool.ps1`. Choose the **highest applicable rung**; drop
to the next only when a conformance probe (§4) shows the higher rung does not work.

| Rung | `xdg.method` | When | What DotForge does |
|------|--------------|------|--------------------|
| 1 | `default` | Tool is XDG-native and needs nothing. | No-op. Record `compliance: full`. |
| 2 | `env` | Tool honors an env var pointing at its config/state/data/cache. | Set each `xdg.vars` entry (values expanded via `Expand-DFXdgPath`); create each `xdg.dirs` path via `New-DFDirectory`. |
| 3 | `config` | Tool reads a config *file* and lets us set its state/data/cache paths inside that file. | Create the parent dir and write `config_path` from `config_content` **only when the file is absent**. Prefer this to rung 2 for state/data paths the tool supports in-file. |
| 4 | `wrapper` | Tool takes a `--config`/`-s`-style *flag* but no env var. | The companion `.ps1` defines a `function:global:<exe>` that injects the flag ahead of `@args`. `Register-DFTool`'s `wrapper` branch is a deliberate no-op; the sidecar owns it. |
| 5 | `manual` | Nothing DotForge can automate. | `Write-Warning` with `xdg.instructions`. Record the gap in the conformance ledger (§4). |

Path templating: `xdg.vars`/`xdg.dirs`/`config_path` values MAY use the tokens `${XDG_CONFIG_HOME}`,
`${XDG_DATA_HOME}`, `${XDG_STATE_HOME}`, `${XDG_CACHE_HOME}`, expanded by
`Private/Expand-DFXdgPath.ps1` (case-sensitive `-creplace`; exact `${…}` form only). `XDG_BIN_HOME` is
**not** a supported token. **`xdg.vars` values are `${XDG_*}` path templates only.** Non-path
environment variables (flag strings, tool options, `GIT_PAGER`, theme names, …) belong in the
tool's top-level **`env`** block, applied unconditionally by `Register-DFTool` (also via
`Expand-DFXdgPath`, so an `env` value that references `${XDG_*}` still expands).

**Rung-preference rule.** When a tool supports *both* an env var and an in-config path for the same
state/data/cache location, put the path **in the config file** (rung 3) and reserve env vars for
config-file *location* only. This keeps the environment minimal (Principle 1).

---

## 4. Conformance Protocol

Conformance is an **author-time / build-time** activity. It **MUST NOT** run in the user's live
shell or ship as a runtime cost. It is the work you and I do together when adding a tool: decide
whether the tool behaves in a standard way, or whether we must write an adapter around a deficiency —
and record the evidence either way.

### 4.1 Claims

For each tool we assert a set of **claims**, each independently probed:

- `honors-xdg` — respects XDG base dirs unaided.
- `honors-env:<VAR>` — reads config/state from env var `<VAR>`.
- `honors-config-read` — reads the config file at the expected path.
- `honors-config-content:<key>` — honors a *specific setting* inside that file (not merely that the
  file is read).
- `honors-flag:<flag>` — honors a command-line flag (e.g. `--config`).

A claim's verdict is `pass`, `fail`, or `manual` (verified by a human because it cannot be asserted
programmatically — e.g. a theme's visual effect).

### 4.2 Probing

The probe harness lives at `build/Test-DFToolConformance.ps1` (author-side; never loaded by the
module). Each automatable probe MUST:

1. Establish a clean, isolated environment (a `$TestDrive`-style scratch dir; only the env var/config
   under test set).
2. **Set the thing** (env var, or write a config with a sentinel setting).
3. **Spawn the real tool** and capture behavior that is dispositive of honoring — e.g. output that
   only appears if the sentinel setting took effect. Merely observing that the process opened the
   file is insufficient for `honors-config-content` claims.
4. Emit `pass`/`fail` with the captured evidence.

Where honoring cannot be asserted from tool output, the claim is `manual`: the ledger records a
human verdict plus **re-test instructions** so it can be re-checked on a future tool version.

Harness design MUST follow existing test conventions: `Set-StrictMode -Version Latest`, injectable
seams (a canned resolver scriptblock in place of live spawning, as `Build-DFToolIdentities.ps1` does
with `-ResolveLinkage`), and no reliance on ambient machine state.

### 4.3 The conformance ledger

Results are recorded in a machine-readable ledger, `data/tool-conformance.json`, keyed by
**tool + version tested**. It is a machine-readable *superset* of the prose in
`docs/external-dependencies.md`; that file remains the human narrative ("what breaks, how it
degrades"), and each of its entries SHOULD cross-reference a ledger claim ID.

Ledger record shape (per tool):

```jsonc
{
  "bat": {
    "versionTested": "0.24.0",
    "claims": [
      { "id": "bat/honors-env:BAT_CONFIG_PATH", "verdict": "pass",
        "evidence": "custom --theme in config changed rendered output",
        "probe": "automated" },
      { "id": "bat/honors-config-content:theme", "verdict": "manual",
        "evidence": "confirmed visually 2026-07-24",
        "retest": "set theme=ansi in bat.conf; run `bat --config-file` then a sample file" }
    ]
  }
}
```

The committed ledger MUST be tested against its schema and against the shipped `Tools/*.json` set (the
same "generator → shipped data → test-the-data" pattern as
`tests/Build-DFToolIdentities.Tests.ps1`), so drift between claims and reality is caught in CI.

### 4.4 Adapters link to failures

When a claim `fail`s and we work around it in a sidecar (an **adapter**), the adapter code MUST carry
a comment referencing the failing claim ID (e.g. `# adapter for glow/honors-env:GLOW_CONFIG_DIR`).
Consequences:

- **Issue reports are generated, not hand-written.** `build/Test-DFToolConformance.ps1` emits a
  report artifact (e.g. `reports/tool-conformance-issues.md`) from all `fail` verdicts — the tool,
  the claim, how we tested it, and the observed vs expected behavior — ready to file upstream.
- **Adapter removal is mechanical.** When an upstream fix ships and a re-probe flips the claim to
  `pass`, the harness flags every adapter still referencing that claim ID as **dead code to remove**.
  This closes the loop: file the issue → wait → re-test → delete the adapter.

### 4.5 Rule

No configuration is "done" until its governing claim is `pass` or `manual` in the ledger. A `fail`
that we cannot adapt around MUST be recorded and surfaced in the issue report, and the tool
integrated at the best rung that *does* pass.

---

## 5. Required Configuration

Some configuration is required or strongly recommended regardless of XDG: **pagers, viewers,
editors**.

- Most tools honor the conventional `PAGER`, `EDITOR`, `VISUAL` env vars. We MUST verify this per §4
  (`honors-env:PAGER`, etc.) rather than assume it.
- Where a tool honors them, DotForge relies on them and adds nothing.
- Where a tool does not, configure the behavior per the §3 ladder and record the adapter.
- DotForge MAY set sensible defaults for `PAGER`/`EDITOR`/`VISUAL` **only when unset**, and MUST NOT
  clobber a value the user already set.

Implementation note / cleanup: the pager helper reads `$Env:Pager` (`Public/DFHelpers.Pager.ps1`,
`Private/Invoke-DFPagerExe.ps1`) while the README documents `$Env:PAGER`. Windows env vars are
case-insensitive so both work, but the standard name is `PAGER`; align docs and code on it.

---

## 6. Theme

DotForge has **one system-wide default theme**, set once, applied to every themed tool, with
per-tool overrides.

### 6.1 Resolution chain

Theme resolution is `Private/Get-DFConfiguredTheme.ps1`: per-tool key (`GlowTheme`, `MdcatTheme`,
`MdvTheme`, `PSReadLineTheme`, …) → shared `$DFConfig.Theme` → the tool's built-in default. Setting
`$DFConfig.Theme = 'catppuccin-mocha'` MUST theme every honoring tool; a per-tool key overrides just
that tool.

### 6.2 Per-tool translation (governed by `docs/plugin-architecture.md`)

Tools name the same theme family differently (e.g. glow/mdcat/psreadline/delta call it
`catppuccin-mocha`; mdv calls it `catppuccin`). Per the plugin invariant, this mapping MUST NOT
live in a central registry keyed by tool — that would require editing core data to add a themed
tool. Instead, **each tool optionally declares its own `themeMap`** (canonical family → its
dialect) in its own JSON:

```jsonc
// Tools/mdv.json — only needed when the tool's native name differs from the canonical
"themeMap": { "catppuccin-mocha": "catppuccin" }
```

A tool whose native dialect equals the canonical (glow, mdcat, psreadline, delta) needs no
`themeMap` at all.

**Configuration vocabulary (collision-free):**

- The shared `$DFConfig.Theme` accepts the **canonical family name only**.
- A per-tool override (`$DFConfig.<Tool>Theme`) accepts the canonical name **or** a name that
  tool alone natively understands.
- **The canonical name is the only value that triggers translation.** A per-tool override that
  is not a canonical key in that tool's map passes through unchanged to the tool's own built-in
  validation (which falls back to a safe default if unrecognized). There are no aliases and no
  cross-tool matching — this is what prevents one tool's dialect (e.g. mdv's `catppuccin`) from
  being mistaken for another tool's input.

`Private/Resolve-DFThemeName.ps1` implements the translation: given a name and a tool's own
`themeMap` (or `$null`), it returns the mapped dialect on a canonical match, else the name
unchanged. It is a pure function — no file I/O, no module state, no validation, no fallback;
those remain the sidecar's job.

- Sidecars call `Get-DFConfiguredTheme` (the chain) then `Resolve-DFThemeName` (reading their own
  `$DFCurrentTool.themeMap`), then validate the result against their own built-in theme list and
  apply it via the §3 ladder. They no longer hardcode any family→dialect mapping.

### 6.3 Acquiring/creating the theme

If a themed tool does not ship the system default theme, acquire or author it (e.g. a bundled
`Tools/<tool>/catppuccin-mocha.json`, as glow and psreadline already do) and install it via the §3
ladder. Whether the tool honors the applied theme is a `honors-config-content:theme` claim (§4),
typically `manual`.

---

## 7. Completion

Order of preference:

1. **Nothing to do** if carapace **and** inshellisense already provide completion for the tool.
   Completion is orchestrated by `Private/Initialize-DFCompletionStack.ps1` (mode `Native` =
   carapace + PSFzf; mode `Inshellisense`).
2. **Tool-provided** completion if the tool ships its own and it does **not** conflict with the
   active completer stack.
3. **Bundled carapace spec** otherwise: author a `*.yaml` spec under `Tools/carapace/specs/`
   (deployed to `$XDG_CONFIG_HOME/carapace/specs` by `Tools/carapace.ps1`). Only `mdv` and `scoop`
   exist today; this is the extension point for new tools.

A tool MUST NOT register a completer that shadows or double-binds the active Tab handler.

---

## 8. Pickers

Pickers/previewers are added **case-by-case**, only where genuinely useful. Two forms:

- **Declarative** `picker` object in the tool JSON (keys: `alias`, `function`, `list`, `preview`,
  `preview_window`, `action`, …), auto-built into an `Invoke-DFPicker` wrapper by
  `Register-DFTool`. Use for straightforward list→preview→act flows (see `eza`, `zoxide`).
- **`"custom"`** sentinel when the picker needs bespoke logic in the companion `.ps1` (see the
  package-manager pickers, `ripgrep`).

When onboarding, note explicitly whether a previewer adds real value (e.g. syntax-highlighted file
preview, package `info` on hover) and justify it; default to **no picker**.

---

## 9. Aliases

Aliases are declared in the tool JSON `aliases` map (`{ "<alias>": { "command": "<exe>",
"args": [...] } }`) and built by `Register-DFTool` (args-less → `Set-Alias`; with args → a global
wrapper function that first removes any colliding built-in alias). Guidance:

- A tool that can produce a lot of output SHOULD get a **paging** alias.
- Pickers get **short** aliases (`ff`, `sins`).
- Very common usage patterns get an alias (`ll`).
- Well-known conventional aliases SHOULD be provided (`cat`→`bat -pp`).
- **Standard, contested aliases** (`ls`, `ll`, `tree`, `cat`) belong to the **default-tool winner**
  (§10), not to every tool that could claim them.

Every new alias MUST also be added to `AliasesToExport` in `DotForge.psd1` (existing house rule).

---

## 10. Default Tool Selection

When several tools do the same job (eza vs lsd; multiple pagers; multiple markdown viewers), the user
picks a **winner**, and the winner receives the standard aliases for that role.

### 10.1 Mechanism — declarative

Selection is declared in `$DFConfig.Defaults`, a role→tool map the user sets in their profile before
`Import-Module DotForge`:

```powershell
$DFConfig = @{
    Defaults = @{ listing = 'eza'; pager = 'bat'; 'markdown-renderer' = 'glow' }
}
```

- **Roles are equivalence groups** drawn from the category taxonomy's `function` field
  (`data/tool-categories.json`, built by `build/Build-DFCategoryDb.ps1`). Tools sharing a `function`
  value form a group.
- The **winner** for a role receives that role's **standard aliases** (e.g. `listing`'s winner gets
  `ls`, `ll`, `tree`).
- **Contested aliases are computed, not declared.** A role's winner's own `aliases` block IS
  the set of aliases it claims. A **loser** (a tool sharing the same `role` but not named as the
  winner) has ONLY the alias keys it shares with the winner suppressed — every other alias it
  declares, its XDG config, picker, and companion `.ps1` still apply. This is computed live from
  each tool's own declared `aliases`; there is no separate contested-alias list.
- No startup prompt. Selection is purely declarative (consistent with `$DFConfig` being a plain
  user-authored hashtable read defensively).

### 10.1a The `role` field

A tool optionally declares a top-level `role` string in its own JSON (e.g. `"role": "listing"`) to
say "I compete in this equivalence group." Per `docs/plugin-architecture.md`, this is NOT a central
registry — a role name is just a string a tool declares and the user references as a key in
`$DFConfig.Defaults`. `Register-DFTool` resolves the named winner for each `Defaults` entry,
validating that the winner exists, declares that same role, and is actually available/registering
this call before recording its alias keys; any of those checks failing degrades to no suppression
for that role, never a thrown error.

### 10.2 Interaction with conflict detection

The winner's standard aliases may collide with Windows coreutils shims. The existing detector
(`Public/Get-DFCommandConflict.ps1` + `Private/Get-DFCoreutilsShadowSet.ps1`) reports these; its
remediation guidance MUST reflect the *winner's* aliases, and `$DFConfig.IgnoreConflicts` /
`SkipConflictCheck` continue to govern whether the shadow is surfaced.

---

## 11. Package Managers

Package managers are integrated as **ordinary tools** (a minimal `Tools/<pm>.json` plus a rich
`.ps1` companion), configured via the same §3 ladder, with these standing conventions:

- `packages: {}` — a package manager cannot install itself via the others.
- `picker: "custom"` — the search/install/upgrade fuzzy pickers live in the companion `.ps1`.
- **Object data sources over table scraping** (existing decision): winget via the
  `Microsoft.WinGet.Client` module; scoop via the `Scoop` module (+ `scoop-search`); choco via CLI
  machine mode `-r`/`--limit-output`. Elevation for choco routes through gsudo when available.
- Install ordering comes from `Private/Resolve-DFPackageManager.ps1` (default `scoop, winget, choco`),
  overridable via `$DFConfig.PackageManagerOrder` or `Install-DFTool -PackageManager`; `cargo`/`npm`
  are per-tool install backends, not pickers.

Their **metadata** (identity linking, category mining, cross-catalog consolidation) is out of scope
here — see the trifle/package-universe specs referenced in §1.

---

## 12. Onboarding Checklist

The followable procedure to add one tool end-to-end. Perform in order; each step references the
governing section.

1. **Install arm.** Add `packages` (`scoop`/`winget`/`choco`, or `cargo`/`npm` backend) so
   `Install-DFTool` can fetch it.
2. **Probe conformance (§4).** Run `build/Test-DFToolConformance.ps1` for the tool. Establish which
   claims pass, fail, or are manual. Do not trust the docs.
3. **Pick the ladder rung (§3).** Choose the highest `xdg.method` whose claim passes. Prefer
   in-config paths over env vars. Record `xdg.compliance`.
4. **Write `Tools/<tool>.json`.** `name` + `executable` (required), `type` if a module, `xdg`
   (`method`, `vars`/`dirs`/`config_*`), `tags`, `dependsOn`, `packages`, and `settings` as needed.
5. **Companion `.ps1` (only if needed).** For `wrapper` rung, `"custom"` pickers, or `settings`-driven
   behavior. Read `$DFCurrentTool.settings` defensively; expose prompt-level functions/aliases via
   `function:global:` / `Set-Alias -Scope Global`. Adapter code MUST reference its conformance
   failure ID (§4.4).
6. **Theme (§6)** if the tool renders styled output: declare an optional `themeMap` (canonical →
   this tool's dialect) in the tool's own JSON, only if its native name differs from the canonical
   (§6.2); have the sidecar resolve via `Resolve-DFThemeName`, validate + apply; bundle the default
   theme if the tool lacks it.
7. **Completion (§7):** nothing if carapace/inshellisense cover it; else tool-provided if
   non-conflicting; else a bundled `Tools/carapace/specs/<tool>.yaml`.
8. **Pickers & aliases (§8, §9):** add a picker only if genuinely useful; add paging/short/well-known
   aliases; register in `DotForge.psd1`.
9. **Default-tool group (§10):** if the tool shares a `function` with others, add it to the category
   taxonomy and confirm the `$DFConfig.Defaults` winner logic covers contested aliases.
10. **Tests.** Pester 5 unit tests (mocked fzf/PMs) plus environment-conditional
    (`-Skip:(-not (Get-Command …))`) integration tests for the real binary.
11. **Ledger & docs.** Commit the conformance record to `data/tool-conformance.json`; add a prose
    entry to `docs/external-dependencies.md` for any dependency on the tool's internals; update
    `README.md` and `examples/` per the house pre-commit rules.

---

## 13. Invariants (reaffirmed)

- **Author-time, not runtime.** Conformance probing and issue-report generation never run in the live
  shell.
- **Degrade silently, never fail** (Principle 3). Undocumented dependencies MUST no-op or warn.
- **Strict mode** in all author-side harness/build code (`Set-StrictMode -Version Latest`); tests
  assert hard invariants, not just happy paths.
- **Verify before claiming done** (Principle 2). Every applied configuration is backed by a ledger
  verdict.
