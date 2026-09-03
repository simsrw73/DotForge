# vivid LS_COLORS Theming Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `vivid` tool plugin that resolves DotForge's shared theme (default `catppuccin-mocha`) to a cached `LS_COLORS` value, applied to the session env var, with a live fzf picker (`fls`) for switching themes interactively.

**Architecture:** A new `Tools/vivid.json` + `Tools/vivid.ps1` pair, following the exact plugin pattern already used by `mdcat`/`mdv`/`glow`/`delta`/`psreadline` — no core file changes. Theme resolution uses the existing `Get-DFConfiguredTheme` (chain) + `Resolve-DFThemeName` (translate) private functions. Caching mirrors `Private/Get-DFHelpTopicList.ps1`'s file-plus-fingerprint pattern under `$XDG_CACHE_HOME/dotforge`.

**Tech Stack:** PowerShell 7+, Pester 5/6, `vivid` CLI (external, optional — `Register-DFTool` already skips unavailable tools).

## Global Constraints

- No `$ErrorActionPreference = 'Stop'` in module files (inherited from caller).
- All directory creation goes through `New-DFDirectory`, never raw `New-Item`.
- Tool JSON schema: `name`, `executable` required; `xdg.method` one of `default|env|config|wrapper|manual`.
- No central theme registry — theme mapping lives in each tool's own optional `themeMap` (not needed here: vivid's native theme names equal the canonical names).
- Every public function needs complete comment-based help — **not applicable here**: `Invoke-DFApplyLSColorsTheme` and `Select-LSColorsTheme` are sidecar-registered globals (like `Invoke-DFApplyPSReadLineTheme`/`Select-PSReadLineTheme`), not `Public/` module exports, so this rule (which governs `DotForge.psd1`'s `FunctionsToExport`) does not apply to them — matching existing precedent.
- Tests: suite must pass under both Pester 5.8.0 and 6.0.1.
- Before committing: update README.md and CHANGELOG.md `[Unreleased]` for any user-visible change (project convention, enforced by a pre-commit hook reminder).
- Full design context: `docs/superpowers/specs/2026-09-03-vivid-ls-colors-design.md`.

---

### Task 1: `Tools/vivid.json` + core theming/caching in `Tools/vivid.ps1`

**Files:**
- Create: `Tools/vivid.json`
- Create: `Tools/vivid.ps1`
- Modify: `build/categories/dotforge-curated.jsonc` (adds a `vivid` entry)
- Modify: `data/tool-categories.json` (regenerated via `build/Build-DFCategoryDb.ps1`, not hand-edited)
- Modify: `data/tool-identities.json` (regenerated via `build/Build-DFToolIdentities.ps1`, not hand-edited)
- Test: `tests/vivid.Tests.ps1`

**Interfaces:**
- Consumes: `Get-DFConfiguredTheme -ToolKey <string> -Default <string>` (existing, `Private/Get-DFConfiguredTheme.ps1`), `Resolve-DFThemeName -Name <string> -ThemeMap <pscustomobject>` (existing, `Private/Resolve-DFThemeName.ps1`), `New-DFDirectory <path>` (existing, `Public/New-DFDirectory.ps1`), `$DFCurrentTool` (set by `Register-DFTool` before dot-sourcing the sidecar).
- Produces: global function `Invoke-DFApplyLSColorsTheme -Name <string>` (no return value; side effect: sets `$Env:LS_COLORS` via `[System.Environment]::SetEnvironmentVariable`) — consumed by Task 2's picker.

- [ ] **Step 1: Write the failing schema + sidecar tests**

Create `tests/vivid.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/Invoke-DFFzf.ps1"
    . "$PSScriptRoot/../Public/Invoke-DFPicker.ps1"
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

Describe 'Tools/vivid.json' {
    BeforeAll {
        $script:VividJson = Get-Content "$PSScriptRoot/../Tools/vivid.json" -Raw | ConvertFrom-Json
    }

    It 'declares the default XDG method' {
        $script:VividJson.xdg.method | Should -Be 'default'
    }

    It 'declares scoop and winget package ids, and no choco' {
        $script:VividJson.packages.scoop  | Should -Be 'vivid'
        $script:VividJson.packages.winget | Should -Be 'sharkdp.vivid'
        $script:VividJson.packages.PSObject.Properties.Name | Should -Not -Contain 'choco'
    }

    It 'defaults the theme setting to catppuccin-mocha' {
        $script:VividJson.settings.theme | Should -Be 'catppuccin-mocha'
    }

    It 'declares no picker yet (Task 2 adds the fls picker)' {
        $script:VividJson.picker | Should -Be $null
    }
}

Describe 'vivid tool sidecar' -Skip:(-not (Get-Command vivid.exe -ErrorAction Ignore)) {
    BeforeEach {
        $script:DFToolDb       = $null
        $script:SavedConfigHome = $Env:XDG_CONFIG_HOME
        $script:SavedCacheHome  = $Env:XDG_CACHE_HOME
        $Env:XDG_CONFIG_HOME    = Join-Path $TestDrive 'config'
        $Env:XDG_CACHE_HOME     = Join-Path $TestDrive 'cache'
        Remove-Item $Env:XDG_CACHE_HOME -Recurse -Force -ErrorAction Ignore

        $script:RealTools = Join-Path $PSScriptRoot '../Tools'
    }

    AfterEach {
        $Env:XDG_CONFIG_HOME = $script:SavedConfigHome
        $Env:XDG_CACHE_HOME  = $script:SavedCacheHome
        $script:DFToolDb     = $null

        [System.Environment]::SetEnvironmentVariable('LS_COLORS', $null, 'Process')
        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
        Remove-Item 'function:global:Invoke-DFApplyLSColorsTheme' -ErrorAction Ignore
    }

    It 'sets LS_COLORS to vivid catppuccin-mocha output by default' {
        Register-DFTool -Name 'vivid' -ToolsPath $script:RealTools
        $Env:LS_COLORS | Should -Not -BeNullOrEmpty
        $Env:LS_COLORS | Should -Match 'di=0;38;2;137;180;250'
    }

    It 'registers Invoke-DFApplyLSColorsTheme as a global function' {
        Register-DFTool -Name 'vivid' -ToolsPath $script:RealTools
        Test-Path 'function:global:Invoke-DFApplyLSColorsTheme' | Should -BeTrue
    }

    It 'caches the generated value and reuses it for a matching theme name' {
        Register-DFTool -Name 'vivid' -ToolsPath $script:RealTools
        $cacheFile = Join-Path $Env:XDG_CACHE_HOME 'dotforge' 'ls-colors.txt'
        Set-Content -Path $cacheFile -Value 'SENTINEL-CACHED-VALUE' -Encoding UTF8

        Invoke-DFApplyLSColorsTheme -Name 'catppuccin-mocha'

        $Env:LS_COLORS | Should -Be 'SENTINEL-CACHED-VALUE'
    }

    It 'regenerates when the theme name differs from the cached key' {
        Register-DFTool -Name 'vivid' -ToolsPath $script:RealTools
        $cacheFile = Join-Path $Env:XDG_CACHE_HOME 'dotforge' 'ls-colors.txt'
        Set-Content -Path $cacheFile -Value 'SENTINEL-CACHED-VALUE' -Encoding UTF8

        Invoke-DFApplyLSColorsTheme -Name 'catppuccin-latte'

        $Env:LS_COLORS | Should -Not -Be 'SENTINEL-CACHED-VALUE'
        $Env:LS_COLORS | Should -Not -BeNullOrEmpty
    }

    It 'warns and leaves LS_COLORS unchanged for an unrecognized theme name' {
        Register-DFTool -Name 'vivid' -ToolsPath $script:RealTools
        [System.Environment]::SetEnvironmentVariable('LS_COLORS', 'PRE-EXISTING', 'Process')

        $warnings = Invoke-DFApplyLSColorsTheme -Name 'not-a-real-theme' 3>&1 |
            Where-Object { $_ -is [System.Management.Automation.WarningRecord] }

        $warnings | Where-Object { $_ -match "theme 'not-a-real-theme'" } | Should -Not -BeNullOrEmpty
        $Env:LS_COLORS | Should -Be 'PRE-EXISTING'
    }

    It 'follows the shared $DFConfig[Theme] key' {
        $Global:DFConfig = @{ Theme = 'catppuccin-latte' }
        Register-DFTool -Name 'vivid' -ToolsPath $script:RealTools
        $keyFile = Join-Path $Env:XDG_CACHE_HOME 'dotforge' 'ls-colors.key'
        (Get-Content $keyFile -Raw).Trim() | Should -Be 'catppuccin-latte'
    }

    It 'lets VividTheme override the shared Theme key' {
        $Global:DFConfig = @{ Theme = 'catppuccin-latte'; VividTheme = 'catppuccin-mocha' }
        Register-DFTool -Name 'vivid' -ToolsPath $script:RealTools
        $keyFile = Join-Path $Env:XDG_CACHE_HOME 'dotforge' 'ls-colors.key'
        (Get-Content $keyFile -Raw).Trim() | Should -Be 'catppuccin-mocha'
    }

    It 'warns and no-ops when $Env:XDG_CACHE_HOME is not set' {
        $Env:XDG_CACHE_HOME = $null
        $warnings = Register-DFTool -Name 'vivid' -ToolsPath $script:RealTools 3>&1 |
            Where-Object { $_ -is [System.Management.Automation.WarningRecord] }
        $warnings | Where-Object { $_ -match 'XDG_CACHE_HOME' } | Should -Not -BeNullOrEmpty
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/vivid.Tests.ps1 -Output Detailed"`

Expected: FAIL — `Tools/vivid.json` does not exist yet, so the `Describe 'Tools/vivid.json'` block errors on `Get-Content` in `BeforeAll`, and the sidecar `Describe` block's tests fail because `Register-DFTool -Name 'vivid'` finds no matching tool record (no `LS_COLORS` gets set, `Invoke-DFApplyLSColorsTheme` is never defined).

- [ ] **Step 3: Create `Tools/vivid.json`**

```json
{
  "name": "vivid",
  "description": "Themeable LS_COLORS generator",
  "tags": ["color", "theme", "listing"],
  "executable": "vivid.exe",
  "packages": {
    "scoop": "vivid",
    "winget": "sharkdp.vivid"
  },
  "xdg": { "compliance": "none", "method": "default" },
  "settings": { "theme": "catppuccin-mocha" },
  "aliases": {},
  "picker": null
}
```

`picker` is `null`, not `"custom"`, because Task 1's sidecar doesn't build a picker yet — `tests/Tools.PickerDeclaration.Tests.ps1` enforces that `"custom"` is only declared once a sidecar actually calls `Invoke-DFPicker` (Task 2 flips this to `"custom"` when it adds the picker).

- [ ] **Step 3b: Register vivid in the generated category/identity data files**

Adding a curated tool with a `packages` block trips two existing consistency tests that check the shipped, generated data files against `Tools/*.json`:
- `the shipped data/tool-categories.json.contains every tool curated in Tools/*.json`
- `the shipped data/tool-identities.json.contains every tool that has a packages block in Tools/*.json`

Add an entry to `build/categories/dotforge-curated.jsonc` (alphabetically, between `uv` and `wget`):

```jsonc
  "vivid": {
    "function": ["shell-enhancement"], "worksWith": ["filesystem"], "interface": "cli",
    "ids": { "scoop": "vivid", "winget": "sharkdp.vivid" },
    "relatedTo": ["eza", "lsd"], "popularity": 1
  },
```

(`shell-enhancement` matches `Terminal-Icons`'s categorization — the closest existing analog: both add visual richness to directory listings rather than managing files themselves. `"function"`/`"worksWith"` values must come from the closed vocabulary in `build/categories/taxonomy.jsonc`.)

Then regenerate both generated files:

```powershell
./build/Build-DFCategoryDb.ps1
./build/Build-DFToolIdentities.ps1
```

The second command does live network resolution for any tool not already cached (only `vivid` here) to verify its `packages` ids against its real repository — expect it to resolve `vivid` to `https://github.com/sharkdp/vivid` (`"linkedVia": "repo"`). Confirm both diffs are small and targeted (just the `"updated"` date bump plus the new `vivid` entry) before moving on — a much larger diff means something matched or regenerated unexpectedly.

- [ ] **Step 4: Create `Tools/vivid.ps1`**

```powershell
# Companion for vivid — resolve the configured theme, generate (or reuse a
# cached) LS_COLORS value, and apply it to the session. Caching mirrors
# Private/Get-DFHelpTopicList.ps1's file-plus-fingerprint pattern: the
# fingerprint is just the resolved theme name, so a theme change invalidates
# the cache and a stable theme reuses it without spawning vivid again
# (~42ms measured locally — worth avoiding on every shell startup).

Set-Item -Path 'function:global:Invoke-DFApplyLSColorsTheme' -Value ({
    <#
    .SYNOPSIS
        Resolves and applies an LS_COLORS value for the named vivid theme.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    if (-not $Env:XDG_CACHE_HOME) {
        Write-Warning 'DotForge: $Env:XDG_CACHE_HOME is not set. Call Initialize-DFEnvironment first.'
        return
    }

    $cacheDir  = Join-Path $Env:XDG_CACHE_HOME 'dotforge'
    $cacheFile = Join-Path $cacheDir 'ls-colors.txt'
    $keyFile   = Join-Path $cacheDir 'ls-colors.key'

    $cacheValid = (Test-Path $cacheFile) -and (Test-Path $keyFile) -and
                  ((Get-Content $keyFile -Raw).Trim() -eq $Name)

    if ($cacheValid) {
        $value = (Get-Content $cacheFile -Raw).Trim()
    } else {
        $raw = & vivid generate $Name 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "DotForge: vivid theme '$Name' failed — $($raw.Trim())"
            return
        }
        $value = $raw.Trim()

        New-DFDirectory $cacheDir
        Set-Content -Path $keyFile   -Value $Name  -Encoding UTF8
        Set-Content -Path $cacheFile -Value $value -Encoding UTF8
    }

    [System.Environment]::SetEnvironmentVariable('LS_COLORS', $value, 'Process')
}.GetNewClosure())

# Resolve: per-tool VividTheme -> shared Theme -> tool JSON default.
$_settings = $DFCurrentTool.PSObject.Properties['settings']?.Value
$_default  = $_settings.PSObject.Properties['theme']?.Value ?? 'catppuccin-mocha'
$_theme    = Get-DFConfiguredTheme -ToolKey 'VividTheme' -Default $_default
$_theme    = Resolve-DFThemeName -Name $_theme -ThemeMap ($DFCurrentTool.PSObject.Properties['themeMap']?.Value)

Invoke-DFApplyLSColorsTheme -Name $_theme
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/vivid.Tests.ps1 -Output Detailed"`

Expected: PASS — all `Describe 'Tools/vivid.json'` and `Describe 'vivid tool sidecar'` tests green (the sidecar `Describe` runs for real since `vivid.exe` is installed in this dev environment; it auto-skips on a machine without it).

- [ ] **Step 6: Run the full suite to check for regressions**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/ -Output None"`

Expected: all tests pass (previous count plus the new `vivid.Tests.ps1` tests), 0 failed.

- [ ] **Step 7: Commit**

```bash
git add Tools/vivid.json Tools/vivid.ps1 tests/vivid.Tests.ps1
git commit -m "feat(vivid): add LS_COLORS theming plugin

Resolves the shared theme (default catppuccin-mocha) via the existing
Get-DFConfiguredTheme/Resolve-DFThemeName chain, generates LS_COLORS
via vivid, and caches it under \$XDG_CACHE_HOME/dotforge so a stable
theme doesn't re-spawn vivid (~42ms) every session.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KjTXV8CBbqnMmRTZspmhfs"
```

---

### Task 2: Live picker — `Select-LSColorsTheme` / `fls`

**Files:**
- Modify: `Tools/vivid.json` (flips `"picker"` from `null` to `"custom"` — Task 1 shipped `null` since no sidecar picker existed yet; `tests/Tools.PickerDeclaration.Tests.ps1` requires the JSON and the sidecar to agree)
- Modify: `Tools/vivid.ps1`
- Test: `tests/vivid.Tests.ps1`

**Interfaces:**
- Consumes: `Invoke-DFApplyLSColorsTheme -Name <string>` (Task 1), `Invoke-DFPicker -List <scriptblock> -Header <string> -Preview <string> -Ansi -Action <scriptblock>` (existing, `Public/Invoke-DFPicker.ps1`).
- Produces: global function `Select-LSColorsTheme` and global alias `fls`.

- [ ] **Step 1: Write the failing picker tests**

Add to the `Describe 'vivid tool sidecar'` block in `tests/vivid.Tests.ps1` (after the existing `It` blocks, before the closing brace), and add the two new cleanup lines to `AfterEach`:

```powershell
    AfterEach {
        $Env:XDG_CONFIG_HOME = $script:SavedConfigHome
        $Env:XDG_CACHE_HOME  = $script:SavedCacheHome
        $script:DFToolDb     = $null

        [System.Environment]::SetEnvironmentVariable('LS_COLORS', $null, 'Process')
        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
        Remove-Item 'function:global:Invoke-DFApplyLSColorsTheme' -ErrorAction Ignore
        Remove-Item 'function:global:Select-LSColorsTheme' -ErrorAction Ignore
        Remove-Alias fls -Scope Global -Force -ErrorAction Ignore
    }

    It 'registers Select-LSColorsTheme as a global function' {
        Register-DFTool -Name 'vivid' -ToolsPath $script:RealTools
        Test-Path 'function:global:Select-LSColorsTheme' | Should -BeTrue
    }

    It 'registers fls as an alias for Select-LSColorsTheme' {
        Register-DFTool -Name 'vivid' -ToolsPath $script:RealTools
        Get-Alias fls -ErrorAction Ignore | Should -Not -BeNullOrEmpty
    }
```

(This replaces the existing `AfterEach` block from Task 1 with the version above — the only change is the two added `Remove-Item`/`Remove-Alias` lines.)

Also update the `Describe 'Tools/vivid.json'` block's picker test (Task 1 asserted `$null`; it's `"custom"` from this task on):

```powershell
    It 'declares a custom picker' {
        $script:VividJson.picker | Should -Be 'custom'
    }
```

(Replaces Task 1's `'declares no picker yet (Task 2 adds the fls picker)'` test.)

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/vivid.Tests.ps1 -Output Detailed"`

Expected: FAIL on three tests — the picker test (JSON still says `null`), and `Select-LSColorsTheme`/`fls` don't exist yet.

- [ ] **Step 3: Flip `Tools/vivid.json`'s picker field, and add the picker to `Tools/vivid.ps1`**

In `Tools/vivid.json`, change `"picker": null` to `"picker": "custom"`.

Append to the end of `Tools/vivid.ps1` (after the `Invoke-DFApplyLSColorsTheme -Name $_theme` line from Task 1):

```powershell
# Live picker: list vivid's own themes, preview each via `vivid preview`,
# apply the chosen one immediately (same cache/apply path as registration).
Set-Item -Path 'function:global:Select-LSColorsTheme' -Value ({
    [CmdletBinding()]
    param()

    Invoke-DFPicker `
        -List    { vivid themes } `
        -Header  'Select LS_COLORS theme  [Enter to apply for this session]' `
        -Preview 'vivid preview {}' `
        -Ansi `
        -Action  {
            param($n)
            Invoke-DFApplyLSColorsTheme -Name $n
            Write-Host "Theme applied: $n  (to persist: set `$Global:DFConfig['VividTheme'] = '$n')" -ForegroundColor Green
        }
}.GetNewClosure())
Set-Alias -Name fls -Value Select-LSColorsTheme -Scope Global -Force
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/vivid.Tests.ps1 -Output Detailed"`

Expected: PASS — all tests in the file green.

- [ ] **Step 5: Run the full suite to check for regressions**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/ -Output None"`

Expected: all tests pass, 0 failed.

- [ ] **Step 6: Commit**

```bash
git add Tools/vivid.ps1 tests/vivid.Tests.ps1
git commit -m "feat(vivid): add fls live theme picker

Mirrors psreadline's fprl/Select-PSReadLineTheme: fzf-list vivid's
own themes, preview each via 'vivid preview {}', apply on Enter
through the same cache/apply path Task 1 already established.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KjTXV8CBbqnMmRTZspmhfs"
```

---

### Task 3: Documentation

**Files:**
- Modify: `README.md`
- Modify: `ToolAcquisitionSpec.md`
- Modify: `CHANGELOG.md`

**Interfaces:** None (docs only; no code).

- [ ] **Step 1: Update `README.md`'s Included Tools table**

In `README.md`, find:

```markdown
## Included Tools (35)

| Group            | Tools                                              |
| ---------------- | -------------------------------------------------- |
| Completion       | carapace, inshellisense                            |
| File/dir         | bat, eza, lsd, fd, ripgrep, broot                  |
```

Replace with:

```markdown
## Included Tools (36)

| Group            | Tools                                              |
| ---------------- | -------------------------------------------------- |
| Completion       | carapace, inshellisense                            |
| File/dir         | bat, eza, lsd, fd, ripgrep, broot, vivid           |
```

- [ ] **Step 2: Update `README.md`'s `$DFConfig` example block**

Find:

```markdown
    PSReadLineEditMode  = 'Windows'             # Windows or Emacs editing keys
    PSReadLineTheme     = 'catppuccin-mocha'    # PSReadLine color theme (name or path)
    Theme               = 'catppuccin-mocha'    # shared theme for all viewers (canonical name only; per-tool keys override)
```

Replace with:

```markdown
    PSReadLineEditMode  = 'Windows'             # Windows or Emacs editing keys
    PSReadLineTheme     = 'catppuccin-mocha'    # PSReadLine color theme (name or path)
    VividTheme          = 'catppuccin-mocha'    # LS_COLORS theme (overrides Theme)
    Theme               = 'catppuccin-mocha'    # shared theme for all viewers (canonical name only; per-tool keys override)
```

- [ ] **Step 3: Add the `vivid` Tool-Specific Helpers subsection**

In `README.md`, find the boundary between the `psreadline` subsection and the `winget` header:

```markdown
`Tools/psreadline.json`'s `keyHandlers` array declares extra `Set-PSReadLineKeyHandler`
bindings applied on top of the `editMode` default. Out of the box this adds
home-row selection chords that Emacs mode doesn't bind by default — `Ctrl+Shift+F`/`B`
(select char forward/backward) and `Ctrl+Shift+E`/`A` (select to end/start of line),
mirroring the existing `Ctrl+F`/`B`/`E`/`A` movement chords the way `Alt+Shift+F`
already mirrors `Alt+F` for word selection. Each entry is `{ "chord": "...", "function": "..." }`;
an unresolvable `chord`/`function` pair warns and is skipped rather than failing registration.

**winget** (`Tools/winget.ps1`)
```

Insert a new subsection between them, so the result reads:

```markdown
`Tools/psreadline.json`'s `keyHandlers` array declares extra `Set-PSReadLineKeyHandler`
bindings applied on top of the `editMode` default. Out of the box this adds
home-row selection chords that Emacs mode doesn't bind by default — `Ctrl+Shift+F`/`B`
(select char forward/backward) and `Ctrl+Shift+E`/`A` (select to end/start of line),
mirroring the existing `Ctrl+F`/`B`/`E`/`A` movement chords the way `Alt+Shift+F`
already mirrors `Alt+F` for word selection. Each entry is `{ "chord": "...", "function": "..." }`;
an unresolvable `chord`/`function` pair warns and is skipped rather than failing registration.

**vivid** (`Tools/vivid.ps1`)

vivid is a suggested, not required, tool — `Register-DFTool` already skips any
tool whose executable isn't on PATH, so installing `vivid` is what turns this
feature on. Theme comes from `$DFConfig['VividTheme']`, then the shared
`$DFConfig['Theme']`, then `catppuccin-mocha`; no `themeMap` is needed since
vivid's own theme names already match the canonical family names. The
generated `LS_COLORS` value is cached under `$XDG_CACHE_HOME/dotforge/` and
only regenerated when the resolved theme name changes (`vivid generate` takes
~40ms — not free on every shell startup). `eza` (this repo's `listing`-role
default) reads `LS_COLORS` directly, so this changes its output once applied.

| Function / Alias                          | Purpose                                            |
| ------------------------------------------ | --------------------------------------------------- |
| `Select-LSColorsTheme` / `fls`             | Live fzf theme picker for LS_COLORS, with a `vivid preview` swatch per theme |
| `Invoke-DFApplyLSColorsTheme -Name <theme>` | Resolve/cache/apply LS_COLORS for a named vivid theme |

**winget** (`Tools/winget.ps1`)
```

- [ ] **Step 4: Update `ToolAcquisitionSpec.md` §6.1**

Find:

```markdown
Theme resolution is `Private/Get-DFConfiguredTheme.ps1`: per-tool key (`GlowTheme`, `MdcatTheme`,
`MdvTheme`, `PSReadLineTheme`, …) → shared `$DFConfig.Theme` → the tool's built-in default. Setting
```

Replace with:

```markdown
Theme resolution is `Private/Get-DFConfiguredTheme.ps1`: per-tool key (`GlowTheme`, `MdcatTheme`,
`MdvTheme`, `PSReadLineTheme`, `DeltaTheme`, `VividTheme`, …) → shared `$DFConfig.Theme` → the tool's
built-in default. Setting
```

(This also fixes a pre-existing gap: `DeltaTheme` was already implemented in `Tools/delta.ps1` per the theme-centralization spec but was never added to this list.)

- [ ] **Step 5: Update `CHANGELOG.md`**

In `CHANGELOG.md`, find:

```markdown
## [Unreleased]

### Added

- **`Tools/psreadline.json` declarative `keyHandlers`.**
```

Replace with:

```markdown
## [Unreleased]

### Added

- **`vivid` LS_COLORS theming.** New `Tools/vivid.json`/`.ps1` plugin resolves
  the shared theme (default `catppuccin-mocha`) via the existing
  `Get-DFConfiguredTheme`/`Resolve-DFThemeName` chain and applies it as
  `LS_COLORS`, cached under `$XDG_CACHE_HOME/dotforge` and regenerated only on
  a theme change (`vivid generate` costs ~40ms). `eza` (this repo's
  `listing`-role default) reads `LS_COLORS` directly, so this changes its
  output once `vivid` is installed — it's a suggested, not required, tool.
  Ships a live picker, `Select-LSColorsTheme` / `fls`, mirroring psreadline's
  `fprl`, with a `vivid preview {}` swatch per theme in the fzf preview pane.

- **`Tools/psreadline.json` declarative `keyHandlers`.**
```

- [ ] **Step 6: Run the full suite one more time**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/ -Output None"`

Expected: all tests pass, 0 failed (docs-only changes shouldn't affect any test, but this confirms nothing was accidentally broken while editing).

- [ ] **Step 7: Commit**

```bash
git add README.md ToolAcquisitionSpec.md CHANGELOG.md
git commit -m "docs(vivid): document LS_COLORS theming plugin

Tool table, \$DFConfig.VividTheme key, Tool-Specific Helpers
subsection, ToolAcquisitionSpec.md §6.1 per-tool-key list (also
adds the already-shipped DeltaTheme, which the list had omitted),
and CHANGELOG.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KjTXV8CBbqnMmRTZspmhfs"
```

---

## Self-Review Notes

- **Spec coverage:** Section 1 (JSON) → Task 1 Step 3. Section 2 (resolution/caching) → Task 1 Step 4. Section 3 (picker) → Task 2. Section 4 (testing) → Task 1/2 test steps, using the `mdcat`-precedent `-Skip` pattern the spec settled on during self-review. Section 5 (docs) → Task 3. All acceptance criteria map to a concrete step above.
- **Placeholder scan:** none found — every step has complete, runnable code.
- **Type consistency:** `Invoke-DFApplyLSColorsTheme -Name <string>` is defined once in Task 1 Step 4 and consumed identically (same name, same single positional-by-name `-Name` parameter) in Task 2 Step 3's picker `-Action` block and in Task 1's own registration-time call.
