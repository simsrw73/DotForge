# Theming Batch 1 (psreadline default + bat) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close two low-effort items from the theming backlog (`TODO.md`'s "Coverage audit" list): make `psreadline` default to catppuccin-mocha like `mdcat`/`mdv`/`glow` already do, and wire `bat` into the same theme system (a tool with zero DotForge theme integration today, despite already shipping a native `Catppuccin Mocha` theme).

**Architecture:** Task 1 is a one-line default-value change plus a stale test-name fix — no new files. Task 2 follows the exact `mdcat.ps1`/`mdcat.json` pattern (JSON ships a static native-name default in `env`; a new sidecar overrides it only when `$DFConfig` specifies a different theme, translating the canonical name via a new `themeMap`). No core changes in either task.

**Tech Stack:** PowerShell 7+, Pester 5/6.

## Global Constraints

- No `$ErrorActionPreference = 'Stop'` in any module file.
- `xdg.vars` is `${XDG_*}` path templates only; non-path values (theme names, flag strings) go in the top-level `env` block instead — CLAUDE.md's Tool JSON Schema section, already followed by `bat.json`'s existing `BAT_CONFIG_PATH` entry.
- Theme resolution: `Get-DFConfiguredTheme -ToolKey '<Tool>Theme'` (chain: per-tool key → shared `$DFConfig.Theme` → the value passed as `-Default`, or `$null` if omitted) then `Resolve-DFThemeName -Name ... -ThemeMap ($DFCurrentTool.themeMap)` (canonical → native, pass-through otherwise) — per `ToolAcquisitionSpec.md` §6.1/§6.2. Shared `Theme` is canonical-only (`catppuccin-mocha`); a per-tool override accepts canonical or that tool's own native names.
- Verified facts (do not re-derive): `bat --version` here is 0.26.1; `bat --list-themes` includes the literal native name `Catppuccin Mocha` (mixed case, space-separated — this is bat's *display* name, not a slug); `BAT_THEME="Catppuccin Mocha"` measurably changes bat's syntax-highlighting ANSI codes (tested directly); `BAT_THEME` set to an unrecognized name makes bat print `[bat warning]: Unknown theme '...', using default.` to stderr and exit 0 — bat degrades on its own, no DotForge-side validation/whitelist needed (unlike `mdcat`, which needs one because `MDCAT_THEME` fails silently on a bad value).
- Full suite must show no new failures beyond the 10 pre-existing, already-tracked `Get-DFCategoryDb`/`Get-DFCategoryList` failures (unrelated, see `TODO.md`).
- Before committing: update `README.md` and `CHANGELOG.md` `[Unreleased]` for any user-visible change (project convention).

---

### Task 1: `psreadline` defaults to catppuccin-mocha

**Files:**
- Modify: `Tools/psreadline.ps1:106`
- Modify: `tests/psreadline.Tests.ps1` (rename one stale test)

**Interfaces:** None new — this only changes the `-Default` argument already passed to the existing `Get-DFConfiguredTheme` call.

- [ ] **Step 1: Write the failing test**

In `tests/psreadline.Tests.ps1`, find:

```powershell
    It 'applies the dark theme by default (Colors.Command is non-null)' {
        # NOTE: Get-PSReadLineOption.Colors returns $null when output is redirected
        # (PSReadLine disables color support without VT). The sidecar also stores the
        # applied colors in $global:DFPSReadLineColors for testability.
        Register-DFTool -Name 'psreadline' -ToolsPath $script:RealTools
        $colors = (Get-PSReadLineOption).Colors
        $commandColor = if ($colors) { $colors.Command } else { $global:DFPSReadLineColors['Command'] }
        $commandColor | Should -Not -BeNullOrEmpty
    }
```

Replace with (renamed to match the new default, and asserting the actual color rather than just non-null, so a regression back to `dark` would be caught):

```powershell
    It 'applies the catppuccin-mocha theme by default' {
        # NOTE: Get-PSReadLineOption.Colors returns $null when output is redirected
        # (PSReadLine disables color support without VT). The sidecar also stores the
        # applied colors in $global:DFPSReadLineColors for testability.
        Register-DFTool -Name 'psreadline' -ToolsPath $script:RealTools
        $colors = (Get-PSReadLineOption).Colors
        $commandColor = if ($colors) { $colors.Command } else { $global:DFPSReadLineColors['Command'] }
        # catppuccin-mocha Command color is #cba6f7 -> VT contains "203;166;247"
        $commandColor | Should -Match '203;166;247'
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/psreadline.Tests.ps1 -Output Detailed"`

Expected: FAIL on this one renamed test — the current default is `dark`, whose `Command` color doesn't match `203;166;247`. All other tests in the file still pass.

- [ ] **Step 3: Change the default**

In `Tools/psreadline.ps1`, find:

```powershell
$_themeSetting = Get-DFConfiguredTheme -ToolKey 'PSReadLineTheme' -Default 'dark'
```

Replace with:

```powershell
$_themeSetting = Get-DFConfiguredTheme -ToolKey 'PSReadLineTheme' -Default 'catppuccin-mocha'
```

(`Tools/psreadline/catppuccin-mocha.json` already exists and ships with the module — this is a default-value change only, no new theme file needed.)

- [ ] **Step 4: Run the test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/psreadline.Tests.ps1 -Output Detailed"`

Expected: PASS — all tests in the file green.

- [ ] **Step 5: Run the full suite to check for regressions**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/ -Output None"`

Expected: no new failures beyond the 10 pre-existing unrelated ones.

- [ ] **Step 6: Update README and CHANGELOG**

In `README.md`, find (the psreadline Tool-Specific Helpers subsection):

```markdown
**psreadline** (`Tools/psreadline.ps1`)

| Function / Alias                              | Purpose                                          |
```

Replace with:

```markdown
**psreadline** (`Tools/psreadline.ps1`)

Defaults to catppuccin-mocha (matching `mdcat`/`mdv`/`glow`) — previously this
was the only themed tool in this list that shipped with a neutral `dark`
default instead. Set `$DFConfig['PSReadLineTheme']` to override.

| Function / Alias                              | Purpose                                          |
```

In `CHANGELOG.md`, find:

```markdown
## [Unreleased]

### Added
```

Replace with:

```markdown
## [Unreleased]

### Changed

- **`psreadline` now defaults to `catppuccin-mocha`**, matching `mdcat`/`mdv`/`glow`.
  Previously its built-in default was `dark` — the only themed tool in this
  codebase that didn't ship catppuccin out of the box. `Tools/psreadline/catppuccin-mocha.json`
  already existed; this was a one-line default-value change
  (`Tools/psreadline.ps1`'s `Get-DFConfiguredTheme -Default` argument).

### Added
```

- [ ] **Step 7: Commit**

```bash
git add Tools/psreadline.ps1 tests/psreadline.Tests.ps1 README.md CHANGELOG.md
git commit -m "fix(psreadline): default to catppuccin-mocha, not dark

Matches mdcat/mdv/glow, which already ship catppuccin-mocha as their
built-in default with zero config. psreadline was the outlier --
identified during the vivid LS_COLORS work's coverage audit
(TODO.md). Tools/psreadline/catppuccin-mocha.json already existed;
this is a one-line default-value change.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KjTXV8CBbqnMmRTZspmhfs"
```

---

### Task 2: `bat` theming via `BAT_THEME`

**Files:**
- Modify: `Tools/bat.json`
- Create: `Tools/bat.ps1`
- Modify: `tests/bat.Tests.ps1` if it exists, else Create it (check first — see Step 1)
- Modify: `examples/02-standard.ps1` (add `BatTheme` to the Theme-key comment block)

**Interfaces:** None new — mirrors `mdcat.ps1`'s existing pattern exactly (no new shared function).

- [ ] **Step 1: Check for an existing `tests/bat.Tests.ps1`**

Run: `ls tests/bat.Tests.ps1 2>&1 || echo "does not exist"`

If it exists, read it fully before proceeding — the steps below assume it does not, and give complete new-file content; if one exists, adapt by adding the same `Describe`/`It` blocks into it instead of overwriting, preserving whatever it already covers.

- [ ] **Step 2: Write the failing tests**

Create `tests/bat.Tests.ps1` (or add this content to the existing one — see Step 1):

```powershell
BeforeAll {
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/Test-DFToolSchema.ps1"
    . "$PSScriptRoot/../Private/ConvertTo-DFPath.ps1"
    . "$PSScriptRoot/../Private/Expand-DFXdgPath.ps1"
    . "$PSScriptRoot/../Private/Import-DFToolDb.ps1"
    . "$PSScriptRoot/../Private/Invoke-DFTopoSort.ps1"
    . "$PSScriptRoot/../Public/Get-DFTool.ps1"
    . "$PSScriptRoot/../Public/Find-DFTool.ps1"
    . "$PSScriptRoot/../Private/Get-DFCoreutilsShadowSet.ps1"
    . "$PSScriptRoot/../Public/Get-DFCommandConflict.ps1"
    . "$PSScriptRoot/../Private/Initialize-DFCompletionStack.ps1"
    . "$PSScriptRoot/../Private/Get-DFConfiguredTheme.ps1"
    . "$PSScriptRoot/../Private/Resolve-DFThemeName.ps1"
    . "$PSScriptRoot/../Public/Register-DFTool.ps1"
}

Describe 'Tools/bat.json' {
    BeforeAll {
        $script:BatJson = Get-Content "$PSScriptRoot/../Tools/bat.json" -Raw | ConvertFrom-Json
    }

    It 'defaults BAT_THEME to the native Catppuccin Mocha name' {
        $script:BatJson.env.BAT_THEME | Should -Be 'Catppuccin Mocha'
    }

    It 'declares a themeMap from canonical catppuccin-mocha to the native name' {
        $script:BatJson.themeMap.'catppuccin-mocha' | Should -Be 'Catppuccin Mocha'
    }
}

Describe 'bat tool sidecar' -Skip:(-not (Get-Command bat.exe -ErrorAction Ignore)) {
    BeforeEach {
        $script:DFToolDb       = $null
        $script:SavedConfigHome = $Env:XDG_CONFIG_HOME
        $Env:XDG_CONFIG_HOME    = Join-Path $TestDrive 'config'
        $script:RealTools       = Join-Path $PSScriptRoot '../Tools'
    }

    AfterEach {
        $Env:XDG_CONFIG_HOME = $script:SavedConfigHome
        $script:DFToolDb     = $null
        [System.Environment]::SetEnvironmentVariable('BAT_THEME', $null, 'Process')
        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
    }

    It 'sets BAT_THEME to Catppuccin Mocha by default' {
        Register-DFTool -Name 'bat' -ToolsPath $script:RealTools
        $Env:BAT_THEME | Should -Be 'Catppuccin Mocha'
    }

    It 'follows the shared $DFConfig[Theme] key, translating to the native name' {
        $Global:DFConfig = @{ Theme = 'catppuccin-mocha' }
        Register-DFTool -Name 'bat' -ToolsPath $script:RealTools
        $Env:BAT_THEME | Should -Be 'Catppuccin Mocha'
    }

    It 'lets BatTheme override with a non-canonical native bat theme name' {
        $Global:DFConfig = @{ BatTheme = 'Dracula' }
        Register-DFTool -Name 'bat' -ToolsPath $script:RealTools
        $Env:BAT_THEME | Should -Be 'Dracula'
    }

    It 'lets BatTheme override the shared Theme key' {
        $Global:DFConfig = @{ Theme = 'catppuccin-mocha'; BatTheme = 'Dracula' }
        Register-DFTool -Name 'bat' -ToolsPath $script:RealTools
        $Env:BAT_THEME | Should -Be 'Dracula'
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/bat.Tests.ps1 -Output Detailed"`

Expected: FAIL — `Tools/bat.json` has no `env.BAT_THEME`/`themeMap` yet, and `Tools/bat.ps1` doesn't exist, so `Register-DFTool -Name 'bat'` never sets `$Env:BAT_THEME`.

- [ ] **Step 4: Update `Tools/bat.json`**

Find:

```json
  "xdg": {
    "compliance": "partial",
    "method": "env",
    "vars": {
      "BAT_CONFIG_PATH": "${XDG_CONFIG_HOME}/bat/bat.conf"
    },
    "dirs": []
  },
  "aliases": {
```

Replace with:

```json
  "xdg": {
    "compliance": "partial",
    "method": "env",
    "vars": {
      "BAT_CONFIG_PATH": "${XDG_CONFIG_HOME}/bat/bat.conf"
    },
    "dirs": []
  },
  "env": {
    "BAT_THEME": "Catppuccin Mocha"
  },
  "themeMap": {
    "catppuccin-mocha": "Catppuccin Mocha"
  },
  "aliases": {
```

- [ ] **Step 5: Create `Tools/bat.ps1`**

```powershell
# Companion for bat — override BAT_THEME only when $DFConfig specifies a
# theme different from the JSON default. bat validates BAT_THEME itself
# (an unrecognized name warns to stderr and falls back to its own default,
# exit 0 — verified against bat 0.26.1), so no DotForge-side whitelist is
# needed here, unlike mdcat.

$_name = Get-DFConfiguredTheme -ToolKey 'BatTheme'
if ($_name) {
    $_name = Resolve-DFThemeName -Name $_name -ThemeMap ($DFCurrentTool.PSObject.Properties['themeMap']?.Value)
    [System.Environment]::SetEnvironmentVariable('BAT_THEME', $_name, 'Process')
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/bat.Tests.ps1 -Output Detailed"`

Expected: PASS — all tests green (the sidecar `Describe` runs for real since `bat.exe` is installed in this dev environment).

- [ ] **Step 7: Run the full suite to check for regressions**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/ -Output None"`

Expected: no new failures beyond the 10 pre-existing unrelated ones.

- [ ] **Step 8: Update README, ToolAcquisitionSpec.md, and CHANGELOG**

In `README.md`, find the `$DFConfig` example block (note: this worktree branched from `origin/main`, which doesn't yet have the `vivid` branch's `VividTheme` line — that exists only on local `main` post-merge, not yet pushed; anchoring on `DeltaTheme`, the actual last line here, avoids a repeat of that mismatch):

```markdown
    DeltaTheme          = 'catppuccin-mocha'    # delta features string (overrides Theme)
```

Replace with:

```markdown
    DeltaTheme          = 'catppuccin-mocha'    # delta features string (overrides Theme)
    BatTheme            = 'catppuccin-mocha'    # bat syntax theme (canonical or bat's own native name)
```

In `README.md`'s Tool-Specific Helpers section, find the boundary between `bitwarden`/`chezmoi` alphabetically — actually there is currently no `bat` subsection there since `bat.ps1` didn't exist. Find:

```markdown
**delta** (`Tools/delta.ps1`)
```

Replace with:

```markdown
**bat** (`Tools/bat.ps1`)

bat ships a native `Catppuccin Mocha` theme, so `Tools/bat.json` sets
`BAT_THEME` to that name directly (no translation needed for the default).
Theme comes from `$DFConfig['BatTheme']`, then the shared `$DFConfig['Theme']`
(translated via `themeMap`), then the JSON default. bat validates `BAT_THEME`
itself — an unrecognized name warns and falls back to bat's own default
rather than erroring, so no DotForge-side whitelist is needed.

**delta** (`Tools/delta.ps1`)
```

In `ToolAcquisitionSpec.md` §6.1, find:

```markdown
Theme resolution is `Private/Get-DFConfiguredTheme.ps1`: per-tool key (`GlowTheme`, `MdcatTheme`,
`MdvTheme`, `PSReadLineTheme`, …) → shared `$DFConfig.Theme` → the tool's built-in default. Setting
```

Replace with:

```markdown
Theme resolution is `Private/Get-DFConfiguredTheme.ps1`: per-tool key (`GlowTheme`, `MdcatTheme`,
`MdvTheme`, `PSReadLineTheme`, `BatTheme`, …) → shared `$DFConfig.Theme` → the tool's built-in default. Setting
```

(Note: this worktree branched from `origin/main`, which doesn't yet have the `vivid` branch's `DeltaTheme`/`VividTheme` additions to this same list — those exist only on local `main` post-merge, not yet pushed. Adding just `BatTheme` here keeps this anchor valid against what's actually in this worktree; merging both branches later will combine all three additions correctly since they're on the same line without conflicting edits to each other's exact tokens.)

In `examples/02-standard.ps1`, find:

```powershell
    #   DeltaTheme      = 'catppuccin-mocha'    # override just delta (a delta
    #                                           #   config must define the feature)
```

Replace with:

```powershell
    #   DeltaTheme      = 'catppuccin-mocha'    # override just delta (a delta
    #                                           #   config must define the feature)
    #   BatTheme        = 'catppuccin-mocha'    # override just bat
```

In `CHANGELOG.md`, find:

```markdown
## [Unreleased]

### Added
```

Replace with:

```markdown
## [Unreleased]

### Added

- **`bat` theming via `BAT_THEME`.** `Tools/bat.json` now ships bat's native
  `Catppuccin Mocha` theme as the default (bat already had this theme built
  in — no external config needed, unlike `delta`). A new `Tools/bat.ps1`
  overrides it from `$DFConfig['BatTheme']`/`$DFConfig['Theme']` via the
  standard `Get-DFConfiguredTheme`/`Resolve-DFThemeName` chain, same pattern
  as `mdcat`. bat validates the theme name itself and degrades gracefully on
  an unrecognized one, so no DotForge-side whitelist is needed.
```

- [ ] **Step 9: Run the full suite one more time**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/ -Output None"`

Expected: no new failures beyond the 10 pre-existing unrelated ones (docs-only edits since Step 7, shouldn't change anything, but confirms no accidental breakage).

- [ ] **Step 10: Commit**

```bash
git add Tools/bat.json Tools/bat.ps1 tests/bat.Tests.ps1 README.md ToolAcquisitionSpec.md CHANGELOG.md examples/02-standard.ps1
git commit -m "feat(bat): theme via BAT_THEME, defaulting to Catppuccin Mocha

bat already ships a native Catppuccin Mocha theme (verified: bat
--list-themes, bat 0.26.1) -- no external config authoring needed,
unlike delta. Tools/bat.json sets BAT_THEME directly; a new
Tools/bat.ps1 overrides it from \$DFConfig via the standard
Get-DFConfiguredTheme/Resolve-DFThemeName chain, mirroring mdcat.ps1.
bat validates BAT_THEME itself (warns + falls back to its own default
on an unrecognized name, exit 0), so no DotForge-side whitelist is
needed. Identified as the cheapest remaining gap during the vivid
LS_COLORS work's coverage audit (TODO.md).

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KjTXV8CBbqnMmRTZspmhfs"
```

---

## Self-Review Notes

- **Spec coverage:** Task 1 covers the psreadline default gap; Task 2 covers the full bat theming gap identified in the coverage audit. Both TODO.md items this plan addresses can be marked done in a follow-up commit (not part of either task's file list — left to the controller after both land, matching how the vivid plan handled its own TODO.md entry).
- **Placeholder scan:** none found — every step has complete, runnable code, including the conditional existing-file check in Task 2 Step 1.
- **Type consistency:** `Tools/bat.ps1` uses `Get-DFConfiguredTheme`/`Resolve-DFThemeName` with the exact same parameter names and call shape as `Tools/mdcat.ps1`, `Tools/glow.ps1`, `Tools/delta.ps1`, and `Tools/vivid.ps1` already do.
