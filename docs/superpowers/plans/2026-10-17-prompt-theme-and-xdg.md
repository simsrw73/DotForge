# Prompt themes and runtime XDG paths Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** starship and oh-my-posh follow `Theme` (live through `Set-DFToolTheme`), and bun, pnpm, python, pip and pipx keep their files under the XDG folders.

**Architecture:**
- **Core:** a theme block gains an optional `apply` field, a global function a companion defines, taking `-Name <native>`. `Set-DFToolTheme` calls it.
- **starship:** its companion writes a cached copy of the user's `starship.toml` with only the `palette` line changed (and a missing palette table added), then points `STARSHIP_CONFIG` at it.
- **oh-my-posh:** its companion picks a bundled catppuccin theme when the user has no config.
- **The five runtime tools:** they get `xdg` blocks only.

**Tech Stack:** PowerShell 7.2+, Pester 6, starship 1.26, oh-my-posh, bun 1.3, pnpm, Python 3.14, pip 26, pipx 1.18.

**Spec:** `docs/superpowers/specs/2026-10-17-prompt-theme-and-xdg-design.md`

## Global Constraints

- **No tool names in core.** No file in `Private/`, `Public/` or `Shared/` names starship, oh-my-posh or the runtime tools; `apply` is generic.
- **The user's `starship.toml` is never written.** The copy lives at `$XDG_CACHE_HOME\dotforge\starship\starship.toml`.
- **Copy rule:** use the source as is when its palette already matches or it has no `palette` line; otherwise write the copy.
- **Live edits:** a source newer than the copy refreshes it at shell start.
- **Values the user set are kept** (`Set-DFEnv`), except that a `STARSHIP_CONFIG` or `POSH_THEME` pointing into DotForge's own files (the cache copy, `Tools\oh-my-posh\`) isn't the user's.
- **An explicit `Set-DFToolTheme` beats a user config** for the rest of the session.
- **Old homes never block a tool:** they're declared `{ paths, move: false, guide }`, never as a normal conflict. That covers `${HOME}/.bun`, `${LOCALAPPDATA}/pnpm`, `${HOME}/pipx`, `${LOCALAPPDATA}/pipx`, `${HOME}/.python_history`, and the pip and bun caches.
- **No `PYTHONPYCACHEPREFIX`. No new pickers. No seeded starship layout.**
- **The five existing `command` themes** (fzf, gum, psreadline, skim, vivid) are unchanged.
- **Rebuild after changes:** bundle, registry and reference docs. A new config key goes in `$script:DFConfigKeys`. Gate: `build/Test-DFFull.ps1`.
- **Real binaries:** don't run real oh-my-posh, bun, pip or pipx in tests. Probes run read-only, or with variables pointing at scratch folders; note the known folders before and after each probe.

## Review Focus

1. A `starship.toml` whose `palette` line has spaces, a comment after it, or sits inside a table gets only the top-level `palette` line changed. Everything else is byte-identical (Task 3).
2. A user `STARSHIP_CONFIG` that points at a missing file gives no copy and no error; starship shows its defaults (Task 3).
3. A nested shell inherits `STARSHIP_CONFIG` or `POSH_THEME` pointing at DotForge's copy or bundled theme, and still follows `Theme` rather than freezing on the parent's choice (Tasks 3 and 4).
4. `Set-DFToolTheme starship <name>` with an unknown name falls back with a warning and leaves the prompt working (Task 2).
5. A user's existing `~/.bun`, `%LOCALAPPDATA%\pnpm` or `~/.python_history` never makes bun, pnpm, python or pip Conflict or Blocked (Task 5).

---

### Task 1: Probes

**Files:**
- Modify: the spec (add a "Probe results" section)

- [ ] **Step 1: Answer spec probes 1–6.**
  - pnpm: from pnpm's docs or source.
  - bun: `BUN_INSTALL` and `BUN_INSTALL_CACHE_DIR` pointed at scratch folders, then `bun pm cache` and `bun pm bin -g`.
  - pipx: `pipx environment` with `PIPX_HOME` unset in a child process.
  - Python: `python -c "import sys; print(sys.version)"`, plus the docs for `PYTHON_HISTORY` on Windows.
  - oh-my-posh: the theme file names from its GitHub repo, `themes/catppuccin_*.omp.json`.
  - starship: is `STARSHIP_CONFIG` read on every render? From the docs, or `starship prompt` run twice with a different `STARSHIP_CONFIG`.
- [ ] **Step 2: Fetch the four oh-my-posh catppuccin themes and the license.** Save them to `Tools/oh-my-posh/` as `catppuccin_mocha.omp.json`, `catppuccin_macchiato.omp.json`, `catppuccin_frappe.omp.json`, `catppuccin_latte.omp.json` and `LICENSE` (from oh-my-posh's repo, MIT). Record the source commit in the probe results.
- [ ] **Step 3: Commit.** `docs: prompt theme and XDG probe results; bundle oh-my-posh catppuccin themes`

### Task 2: The theme `apply` field

**Files:**
- Modify:
  - `Shared/Test-DFToolSchema.ps1`: add `apply` to the known `theme` fields and to the `'default', 'files', 'fallback', 'command'` string check;
  - `Shared/Import-DFToolDb.ps1`: theme normalization gains `apply`;
  - `Public/Set-DFToolTheme.ps1`;
  - `Private/Get-DFToolTheme.ps1` (`Test-DFThemeSwitchable`).
- Test: `tests/Set-DFToolTheme.Tests.ps1`, `tests/Test-DFToolSchema.Tests.ps1`

**Interfaces:**
- Produces: theme block field `apply` (string, a global function name). `Set-DFToolTheme -Name <tool> -Theme <name>` resolves the theme as today, records it (`Set-DFSessionTheme`), then calls `& $apply -Name $resolved.Native`. It returns the resolved theme. `Test-DFThemeSwitchable` is true when `apply` is set.

- [ ] **Step 1: Failing tests.**
  - A fixture tool with `theme.apply = 'Invoke-TestApply'` (a stub recording `$Name`). `Set-DFToolTheme fixture catppuccin-latte` calls it once with the mapped native name.
  - An unknown theme falls back to the default with a warning, and `apply` still runs with the fallback.
  - A tool with only `command` is still refused, with today's message.
  - Schema: `apply` must be a non-empty string.
  - Normalization: a record without `apply` gets `$null`.
- [ ] **Step 2: Run them.** `./build/Test-DFFull.ps1 -Path tests/Set-DFToolTheme.Tests.ps1, tests/Test-DFToolSchema.Tests.ps1` → FAIL.
- [ ] **Step 3: Implement.** Rebuild the bundle.
- [ ] **Step 4: Run them again** → PASS.
- [ ] **Step 5: Commit.** `feat: a theme can name an apply function that Set-DFToolTheme calls`

### Task 3: starship follows Theme

**Files:**
- Modify:
  - `Tools/starship.json`: theme block `{ key: "StarshipTheme", default: "catppuccin-mocha", map: { catppuccin-mocha: "catppuccin_mocha", catppuccin-macchiato: "catppuccin_macchiato", catppuccin-frappe: "catppuccin_frappe", catppuccin-latte: "catppuccin_latte" }, apply: "Invoke-DFApplyStarshipTheme" }`, plus a `setup.notes` entry (below);
  - `Tools/starship.ps1`;
  - `build/New-DFCatppuccinThemes.ps1`;
  - `Private/DFSessionConfig.ps1` (`StarshipTheme`).
- Create: `Tools/starship/catppuccin-palettes.toml` (generated: four `[palettes.catppuccin_<flavor>]` tables with catppuccin's 26 names, in the format catppuccin's starship preset uses).
- Test: `tests/starship.Tests.ps1`, `tests/CatppuccinThemes.Tests.ps1`

**Interfaces:**
- Consumes: `apply` (Task 2).
- Produces: `global:Invoke-DFApplyStarshipTheme -Name <native>`, with full help.
  - **Source:** the companion captures it once as `$Env:STARSHIP_CONFIG`, unless that points into `$XDG_CACHE_HOME\dotforge\starship`, in which case it uses the record's XDG path.
  - **No source file:** nothing happens.
  - **Copy rule:** `palette = "<x>"` at top level (before the first `[table]`) is compared with `-Name`.
    - Equal, or no such line: `STARSHIP_CONFIG` is set to the source.
    - Otherwise: the copy is written with only that line changed. The `[palettes.<Name>]` table is appended from `Tools/starship/catppuccin-palettes.toml` when the source lacks it. Then `STARSHIP_CONFIG` is set to the copy.
  - **Setting the variable:** through `Set-DFEnv` with `-ExplicitReason`, so the switch wins over the session value.
  - **At load:** the companion calls it with `(Get-DFToolTheme -Tool $DFCurrentTool).Native`. A copy older than its source is rewritten.
- `setup.notes`: `{ text: "your starship.toml sets no palette, so Theme can't change its colors; add palette = \"catppuccin_mocha\" (and its [palettes.*] table) to use it", unlessFile: … }`. A plain note can't test the file's content, so the companion adds it once with `Add-DFToolSetupNote` during setup. Builder's choice: a setup script, or a note the companion adds; it must show only once.

- [ ] **Step 1: Failing tests** (fixture `starship.toml` in `$TestDrive`, `XDG_*` isolated):
  - `palette = "catppuccin_mocha"` with all four tables, Theme latte: the copy differs from the source only on that line, and `STARSHIP_CONFIG` is the copy.
  - Theme mocha: no copy; `STARSHIP_CONFIG` is the source.
  - No `palette` line: no copy.
  - Palette set but `[palettes.catppuccin_latte]` missing: the copy ends with that table (`base = "#eff1f5"`).
  - A `palette = "x"  # comment` line, and a `palette` key inside `[palettes.foo]`: only the top-level line changes.
  - `STARSHIP_CONFIG` = a missing file: no copy, no error.
  - Inherited `STARSHIP_CONFIG` pointing at the cache copy: the record's XDG source is used.
  - Source newer than the copy: the copy is rewritten.
  - `Set-DFToolTheme starship catppuccin-frappe` switches `STARSHIP_CONFIG` to a copy with `catppuccin_frappe`.
  - `CatppuccinThemes.Tests.ps1`: the palettes file is generated, and has latte's base `#eff1f5`.
- [ ] **Step 2: Run them.** `./build/Test-DFFull.ps1 -Path tests/starship.Tests.ps1, tests/CatppuccinThemes.Tests.ps1` → FAIL.
- [ ] **Step 3: Implement.** Run the generator, then rebuild the registry and the bundle.
- [ ] **Step 4: Run them again** → PASS.
- [ ] **Step 5: Real check.** `starship prompt` with `STARSHIP_CONFIG` set to a latte copy of the user's file gives latte colors. Use a copy in scratch; never write the user's file.
- [ ] **Step 6: Commit.** `feat: starship follows Theme through a palette-swapped copy of your config`

### Task 4: oh-my-posh follows Theme

**Files:**
- Modify:
  - `Tools/oh-my-posh.json`: theme block `{ key: "OhMyPoshTheme", default: "catppuccin-mocha", map: { catppuccin-mocha: "catppuccin_mocha", … }, apply: "Invoke-DFApplyOhMyPoshTheme" }`;
  - `Tools/oh-my-posh.ps1`;
  - `Private/DFSessionConfig.ps1` (`OhMyPoshTheme`).
- Test: `tests/oh-my-posh.Tests.ps1` (new, or extend an existing prompt test)

**Interfaces:**
- Consumes: `apply` (Task 2); the bundled files (Task 1).
- Produces:
  - `Resolve-DFOhMyPoshConfig -Native <string>` (sidecar), returning the config path or `$null` in this order:
    1. `$Env:POSH_THEME`, when it exists and isn't under `Tools\oh-my-posh`;
    2. the single user `*.omp.*` in `$XDG_CONFIG_HOME\oh-my-posh` (today's warning when there are several);
    3. `$Env:POSH_THEMES_PATH\<native>.omp.json`;
    4. `Tools\oh-my-posh\<native>.omp.json`.
  - `global:Invoke-DFApplyOhMyPoshTheme -Name <native>` (full help): uses step 3 or 4's file directly, skipping 1 and 2, because an explicit switch wins. It re-inits like `Select-PoshTheme` does.

- [ ] **Step 1: Failing tests** (fake files; `oh-my-posh` stubbed as a global function that records `--config`):
  - The order above.
  - `POSH_THEME` pointing into `Tools\oh-my-posh` is ignored.
  - With no user config, the bundled latte theme is used when Theme is latte.
  - `Set-DFToolTheme oh-my-posh catppuccin-frappe` re-inits with the frappe file, even when a user config exists.
- [ ] **Step 2: Run them** → FAIL.
- [ ] **Step 3: Implement.** Rebuild the registry and the bundle.
- [ ] **Step 4: Run them again** → PASS.
- [ ] **Step 5: Commit.** `feat: oh-my-posh follows Theme with bundled catppuccin themes`

### Task 5: XDG paths for bun, pnpm, python, pip, pipx

**Files:**
- Modify: `Tools/bun.json`, `Tools/pnpm.json`, `Tools/python.json`, `Tools/pip.json`, `Tools/pipx.json`.
- Create: `Tools/bun.ps1` and `Tools/pnpm.ps1`, which put their bin folders on PATH with `Add-DFToPath`, like `Tools/rustup.ps1`.
- Test: `tests/RuntimeXdg.Tests.ps1` (new), `tests/ToolNative.Coverage.Tests.ps1`

**Interfaces:** the variables and native locations from the spec's XDG table, as corrected by Task 1's probe results. Every native is `{ paths, move: false, guide }`, and each guide says what lives there and how to move it.

- [ ] **Step 1: Failing tests:**
  - Each tool, activated in a test session, sets its variables to the XDG paths.
  - bun's and pnpm's bin folders are on PATH.
  - A pre-existing `~/.bun` (and `~/.python_history`) under a test `HOME` leaves bun (and python and pip) Active, not Conflict or Blocked.
  - A variable the user already set is kept.
- [ ] **Step 2: Run them.** `./build/Test-DFFull.ps1 -Path tests/RuntimeXdg.Tests.ps1, tests/ToolNative.Coverage.Tests.ps1` → FAIL.
- [ ] **Step 3: Implement.** Rebuild the registry and the bundle.
- [ ] **Step 4: Run them again** → PASS.
- [ ] **Step 5: Commit.** `feat: bun, pnpm, python, pip and pipx keep their files under XDG`

### Task 6: Docs, backlog, gate

- [ ] **Step 1: Docs:**
  - `docs/guide/tools.md`: starship and oh-my-posh theming, including the copy rule and the "edits show from the next shell" limit; the five tools' folders.
  - `docs/guide/configuration.md`: `StarshipTheme`, `OhMyPoshTheme`, theme table rows.
  - `docs/guide/writing-a-tool.md`: the theme `apply` field.
  - `CLAUDE.md`: the theme bullet gains `apply`.
  - `docs/external-dependencies.md`: starship's `palette` key and `STARSHIP_CONFIG` read per render; oh-my-posh's bundled themes; bun's, pnpm's and pipx's variables.
  - `CHANGELOG.md`.
  - `TODO-Tools.md`: close prompt, js-runtime and python-runtime, and close python-package-manager and js-package-manager when nothing is left; record that pickers are covered by `Select-NpmScript`.
- [ ] **Step 2: Regenerate** the bundle, registry and reference docs, and categories/identities if the suite asks for them.
- [ ] **Step 3: Full gate.** `./build/Test-DFFull.ps1` → `Failed 0 … FailedContainers 0 SentinelFiles 0 StrayFolders 0`.
- [ ] **Step 4: Commit.** `docs: prompt themes and runtime XDG paths`
