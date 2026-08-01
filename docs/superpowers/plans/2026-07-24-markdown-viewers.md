# Markdown Viewers (mdv + mdcat) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `mdv` and `mdcat` (Rust terminal markdown viewers) to DotForge with catppuccin theming, a shared `$DFConfig['Theme']` key, native/carapace completions, and cargo installability.

**Architecture:** A new private helper `Get-DFConfiguredTheme` centralizes the theme-name fallback chain (per-tool key → shared `Theme` → default). `mdcat` is configured by the `MDCAT_THEME` env var + a sidecar that also registers its native completions; `mdv` gets `MDV_CONFIG_PATH` + a sidecar that seeds `config.yaml` when absent + a bundled carapace spec. `Install-DFTool` gains a `cargo` arm reached as a per-tool last resort. `glow` and `psreadline` are re-routed through the shared helper.

**Tech Stack:** PowerShell 7+, Pester 5, carapace, cargo. Design: `docs/superpowers/specs/2026-07-24-markdown-viewers-design.md`.

## Global Constraints

- **PowerShell 7+.** No `$ErrorActionPreference = 'Stop'` in module files (inherited from caller).
- **All directory creation goes through `New-DFDirectory`**, never raw `New-Item`.
- **Public `DF` prefix; private helpers also `DF`-prefixed, in `Private/`, `function script:Name`.** Private `*.ps1` auto-load via `DotForge.psm1` and are visible to dot-sourced sidecars.
- **Null-safe `$DFConfig`:** always test `$null -ne $Global:DFConfig` (the value), never `Get-Variable -Name DFConfig`. `$DFConfig = $null` leaves the variable defined; indexing a null throws.
- **Sidecar contract:** `Register-DFTool` sets `$DFCurrentTool` before dot-sourcing `Tools/<name>.ps1`; sidecars may read `$DFCurrentTool.settings` and `$DFCurrentTool.xdg`. `$PSScriptRoot` resolves to `Tools/` at dot-source time.
- **Tool JSON schema:** `name` + `executable` required; `xdg.method` ∈ `default|env|config|wrapper|manual`.
- **Verified theme vocabularies (do not invent names):**
  - mdcat `--theme`: `auto, dark, light, catppuccin-mocha, catppuccin-latte, gruvbox-dark, gruvbox-light, dracula, nord, solarized-dark, solarized-light`
  - mdv `config.yaml` `theme:`: `terminal, solarized-dark, nord, tokyonight, kanagawa, gruvbox, monokai, material-ocean, catppuccin`
- **Family mapping is per-tool:** glow/psreadline/mdcat map bare `catppuccin` → `catppuccin-mocha`; mdv maps `catppuccin-mocha`/`catppuccin-latte` → `catppuccin`.
- **Run tests from `pwsh -NoProfile`** to avoid profile interference. Commit after each task.

---

## File Structure

**New:**
- `Private/Get-DFConfiguredTheme.ps1` — theme-name fallback resolver (shared).
- `Tools/mdcat.json`, `Tools/mdcat.ps1` — mdcat tool + sidecar (MDCAT_THEME + completions).
- `Tools/mdv.json`, `Tools/mdv.ps1` — mdv tool + sidecar (MDV_CONFIG_PATH + seed config.yaml).
- `Tools/carapace/specs/mdv.yaml` — carapace completion spec for mdv.
- `tests/Get-DFConfiguredTheme.Tests.ps1`, `tests/mdcat.Tests.ps1`, `tests/mdv.Tests.ps1`.

**Modified:**
- `Public/Install-DFTool.ps1` — cargo install arm + per-tool cargo append.
- `Tools/glow.ps1`, `Tools/psreadline.ps1` — route theme through `Get-DFConfiguredTheme` + catppuccin alias.
- `tests/Install-DFTool.Tests.ps1` — cargo case.
- `README.md`, `CHANGELOG.md`, `docs/external-dependencies.md`, `examples/02-standard.ps1` — docs.

---

## Task 1: `Get-DFConfiguredTheme` shared resolver

**Files:**
- Create: `Private/Get-DFConfiguredTheme.ps1`
- Test: `tests/Get-DFConfiguredTheme.Tests.ps1`

**Interfaces:**
- Produces: `Get-DFConfiguredTheme -ToolKey <string> [-Default <string>]` → `[string]` (or `$null`). Returns `$Global:DFConfig[$ToolKey]` if truthy, else `$Global:DFConfig['Theme']` if truthy, else `$Default` (which defaults to `$null`). Null-safe when `$Global:DFConfig` is `$null`.

- [ ] **Step 1: Write the failing test**

Create `tests/Get-DFConfiguredTheme.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/../Private/Get-DFConfiguredTheme.ps1"
}

Describe 'Get-DFConfiguredTheme' {
    AfterEach { Remove-Variable DFConfig -Scope Global -ErrorAction Ignore }

    It 'returns the per-tool key when set' {
        $Global:DFConfig = @{ MdvTheme = 'nord'; Theme = 'catppuccin' }
        Get-DFConfiguredTheme -ToolKey 'MdvTheme' -Default 'catppuccin' | Should -Be 'nord'
    }

    It 'falls back to the shared Theme key' {
        $Global:DFConfig = @{ Theme = 'catppuccin' }
        Get-DFConfiguredTheme -ToolKey 'MdvTheme' -Default 'terminal' | Should -Be 'catppuccin'
    }

    It 'falls back to the default when neither key is set' {
        $Global:DFConfig = @{ SkipTools = @('lsd') }
        Get-DFConfiguredTheme -ToolKey 'MdvTheme' -Default 'catppuccin' | Should -Be 'catppuccin'
    }

    It 'returns the default when $DFConfig is not defined' {
        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
        Get-DFConfiguredTheme -ToolKey 'MdvTheme' -Default 'catppuccin' | Should -Be 'catppuccin'
    }

    It 'tolerates $DFConfig being set to $null' {
        $Global:DFConfig = $null
        Get-DFConfiguredTheme -ToolKey 'MdvTheme' -Default 'catppuccin' | Should -Be 'catppuccin'
    }

    It 'returns $null when nothing is set and no default is given' {
        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
        Get-DFConfiguredTheme -ToolKey 'MdvTheme' | Should -BeNullOrEmpty
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Get-DFConfiguredTheme.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Get-DFConfiguredTheme` not recognized / file not found.

- [ ] **Step 3: Write the implementation**

Create `Private/Get-DFConfiguredTheme.ps1`:

```powershell
#Requires -Version 7.0

function script:Get-DFConfiguredTheme {
    <#
    .SYNOPSIS
        Resolves a tool's theme name from $DFConfig, honoring a per-tool key,
        then a shared 'Theme' key, then a caller default.
    .DESCRIPTION
        The fallback chain shared by every themed DotForge tool:
          1. $Global:DFConfig[$ToolKey]   (e.g. 'GlowTheme', 'MdvTheme')
          2. $Global:DFConfig['Theme']    (the cross-tool key)
          3. $Default                     (the tool's built-in default; may be $null)
        Family-name -> tool-dialect mapping (e.g. 'catppuccin' -> 'catppuccin-mocha')
        is deliberately NOT done here — it differs per tool and stays in each sidecar.
        Tests the VALUE of $DFConfig, not the variable's existence: `$DFConfig = $null`
        leaves the variable defined and indexing into it throws.
    .PARAMETER ToolKey
        The per-tool $DFConfig key to check first (e.g. 'MdcatTheme').
    .PARAMETER Default
        Value returned when neither the per-tool key nor 'Theme' is set. Defaults to $null.
    .OUTPUTS
        [string] the resolved theme name, or $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$ToolKey,
        [string]$Default
    )

    if ($null -ne $Global:DFConfig) {
        $perTool = $Global:DFConfig[$ToolKey]
        if ($perTool) { return $perTool }
        $shared = $Global:DFConfig['Theme']
        if ($shared) { return $shared }
    }
    $Default
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Get-DFConfiguredTheme.Tests.ps1 -Output Detailed"`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Private/Get-DFConfiguredTheme.ps1 tests/Get-DFConfiguredTheme.Tests.ps1
git commit -m "feat: add Get-DFConfiguredTheme shared theme resolver"
```

---

## Task 2: cargo package-manager arm in `Install-DFTool`

**Files:**
- Modify: `Public/Install-DFTool.ps1` (package-order build ~line 45-52; install switch ~line 64-95)
- Test: `tests/Install-DFTool.Tests.ps1`

**Interfaces:**
- Consumes: nothing new.
- Produces: `Install-DFTool -Name <cargo-only tool>` resolves to `cargo install <pkgId>` when the tool declares `packages.cargo` and `cargo` is on PATH, tried AFTER scoop/winget/choco.

**Context:** `Install-DFTool` iterates `$pmOrder` (from `Resolve-DFPackageManager`, default `scoop, winget, choco`) and looks up `packages.<pm>`. cargo is in no order list, so a cargo-only tool currently warns "Could not install". Fix: append `cargo` per-tool when declared + add the install arm.

- [ ] **Step 1: Write the failing tests**

Add to `tests/Install-DFTool.Tests.ps1`, inside `Describe 'Install-DFTool'`, after the existing `'uses $DFConfig.PackageManagerOrder when set'` test (before `'does not throw when -WhatIf is specified'`):

```powershell
    It 'installs a cargo-only tool via cargo when scoop/winget/choco lack it' {
        @'
{ "name": "cargotool", "executable": "cargotool.exe", "packages": { "cargo": "cargotool" } }
'@ | Set-Content (Join-Path $script:TmpTools 'cargotool.json')
        $script:DFToolDb = $null

        $script:CargoArgs = $null
        function script:cargo { $script:CargoArgs = $args; $global:LASTEXITCODE = 0 }
        # cargo present; the default managers are not
        Mock Get-Command { if ($Name -eq 'cargo') { [PSCustomObject]@{ Name = 'cargo' } } else { $null } }

        Install-DFTool -Name 'cargotool' -ToolsPath $script:TmpTools
        ($script:CargoArgs -join ' ') | Should -Match 'install\s+cargotool'
    }

    It 'prefers scoop over cargo when both are declared and available' {
        @'
{ "name": "dualtool", "executable": "dualtool.exe", "packages": { "scoop": "dualtool", "cargo": "dualtool" } }
'@ | Set-Content (Join-Path $script:TmpTools 'dualtool.json')
        $script:DFToolDb = $null

        $script:ScoopHit = $false; $script:CargoHit = $false
        function script:scoop { $script:ScoopHit = $true; $global:LASTEXITCODE = 0 }
        function script:cargo { $script:CargoHit = $true; $global:LASTEXITCODE = 0 }
        Mock Get-Command { [PSCustomObject]@{ Name = $Name } }   # everything available

        Install-DFTool -Name 'dualtool' -ToolsPath $script:TmpTools
        $script:ScoopHit | Should -BeTrue
        $script:CargoHit | Should -BeFalse
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Install-DFTool.Tests.ps1 -Output Detailed"`
Expected: the two new tests FAIL — `cargotool` warns "Could not install" (cargo never tried); `CargoArgs` stays `$null`.

- [ ] **Step 3: Implement — append cargo and add the switch arm**

In `Public/Install-DFTool.ps1`, the current package-order block is:

```powershell
    $dfConfigVar = Get-Variable -Name DFConfig -Scope Global -ErrorAction Ignore
    $pmOrder = if ($PackageManager) {
        @($PackageManager)
    } elseif ($null -ne $dfConfigVar -and $dfConfigVar.Value['PackageManagerOrder']) {
        @($dfConfigVar.Value['PackageManagerOrder'])
    } else {
        Resolve-DFPackageManager
    }
```

Leave that as-is. Then, INSIDE the `foreach ($toolName in $Name)` loop, immediately after `$installedVia = $null` (currently ~line 63), insert a per-tool order that appends cargo when this tool declares it and no explicit `-PackageManager` was pinned:

```powershell
        # cargo is not in the auto-detect priority; append it as a last resort when
        # this tool declares a cargo package (skipped when -PackageManager pins one).
        $toolPmOrder = @($pmOrder)
        if (-not $PackageManager -and
            $null -ne $packages -and
            $packages.PSObject.Properties['cargo'] -and
            $toolPmOrder -notcontains 'cargo') {
            $toolPmOrder += 'cargo'
        }
```

Change the loop header from `foreach ($pm in $pmOrder) {` to `foreach ($pm in $toolPmOrder) {`.

Add a `cargo` arm to the install `switch ($pm)` (after the `'choco'` arm):

```powershell
                    'cargo'      { cargo install $pkgId 2>&1 }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Install-DFTool.Tests.ps1 -Output Detailed"`
Expected: PASS (all, including the two new).

- [ ] **Step 5: Commit**

```bash
git add Public/Install-DFTool.ps1 tests/Install-DFTool.Tests.ps1
git commit -m "feat: install cargo-only tools via cargo as last resort"
```

---

## Task 3: mdcat tool + sidecar (theme env + native completions)

**Files:**
- Create: `Tools/mdcat.json`, `Tools/mdcat.ps1`
- Test: `tests/mdcat.Tests.ps1`

**Interfaces:**
- Consumes: `Get-DFConfiguredTheme` (Task 1); `Register-DFTool` (existing).
- Produces: registering `mdcat` sets `$Env:MDCAT_THEME` to the resolved theme and registers mdcat's native completions. `$DFConfig['MdcatTheme']` / `$DFConfig['Theme']` override the theme.

- [ ] **Step 1: Write the failing tests**

Create `tests/mdcat.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/Invoke-DFFzf.ps1"
    . "$PSScriptRoot/../Public/Invoke-DFPicker.ps1"
    . "$PSScriptRoot/../Private/Test-DFToolSchema.ps1"
    . "$PSScriptRoot/../Private/Expand-DFXdgPath.ps1"
    . "$PSScriptRoot/../Private/Import-DFToolDb.ps1"
    . "$PSScriptRoot/../Private/Invoke-DFTopoSort.ps1"
    . "$PSScriptRoot/../Public/Get-DFTool.ps1"
    . "$PSScriptRoot/../Public/Find-DFTool.ps1"
    . "$PSScriptRoot/../Private/Get-DFCoreutilsShadowSet.ps1"
    . "$PSScriptRoot/../Public/Get-DFCommandConflict.ps1"
    . "$PSScriptRoot/../Private/Initialize-DFCompletionStack.ps1"
    . "$PSScriptRoot/../Private/Get-DFConfiguredTheme.ps1"
    . "$PSScriptRoot/../Public/Register-DFTool.ps1"

    $script:McatJson = Get-Content "$PSScriptRoot/../Tools/mdcat.json" -Raw | ConvertFrom-Json
}

Describe 'Tools/mdcat.json' {
    It 'declares the env XDG method' {
        $script:McatJson.xdg.method | Should -Be 'env'
    }
    It 'sets a catppuccin MDCAT_THEME default' {
        $script:McatJson.xdg.vars.MDCAT_THEME | Should -Be 'catppuccin-mocha'
    }
    It 'declares scoop and cargo packages' {
        $script:McatJson.packages.scoop | Should -Be 'mdcat'
        $script:McatJson.packages.cargo | Should -Be 'mdcat'
    }
}

Describe 'mdcat tool sidecar' -Skip:(-not (Get-Command mdcat.exe -ErrorAction Ignore)) {
    BeforeEach {
        $script:DFToolDb     = $null
        $script:SavedTheme   = $Env:MDCAT_THEME
        $Env:MDCAT_THEME     = $null
        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
        $script:RealTools = Join-Path $PSScriptRoot '../Tools'
    }
    AfterEach {
        $Env:MDCAT_THEME = $script:SavedTheme
        $script:DFToolDb = $null
        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
    }

    It 'sets MDCAT_THEME to the JSON default when no $DFConfig theme is set' {
        Register-DFTool -Name 'mdcat' -ToolsPath $script:RealTools
        $Env:MDCAT_THEME | Should -Be 'catppuccin-mocha'
    }

    It 'lets $DFConfig[MdcatTheme] override the theme' {
        $Global:DFConfig = @{ MdcatTheme = 'dracula' }
        Register-DFTool -Name 'mdcat' -ToolsPath $script:RealTools
        $Env:MDCAT_THEME | Should -Be 'dracula'
    }

    It 'maps the shared catppuccin family to catppuccin-mocha' {
        $Global:DFConfig = @{ Theme = 'catppuccin' }
        Register-DFTool -Name 'mdcat' -ToolsPath $script:RealTools
        $Env:MDCAT_THEME | Should -Be 'catppuccin-mocha'
    }

    It 'falls back to auto for an unsupported theme name' {
        $Global:DFConfig = @{ MdcatTheme = 'no-such-theme' }
        Register-DFTool -Name 'mdcat' -ToolsPath $script:RealTools -WarningAction SilentlyContinue
        $Env:MDCAT_THEME | Should -Be 'auto'
    }

    It 'tolerates $DFConfig being set to $null' {
        $Global:DFConfig = $null
        { Register-DFTool -Name 'mdcat' -ToolsPath $script:RealTools } | Should -Not -Throw
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/mdcat.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Tools/mdcat.json` not found.

- [ ] **Step 3: Create `Tools/mdcat.json`**

```json
{
  "name": "mdcat",
  "description": "cat for markdown — render CommonMark in the terminal",
  "tags": [
    "markdown",
    "viewer",
    "text"
  ],
  "executable": "mdcat.exe",
  "packages": {
    "scoop": "mdcat",
    "cargo": "mdcat"
  },
  "xdg": {
    "compliance": "full",
    "method": "env",
    "vars": {
      "MDCAT_THEME": "catppuccin-mocha"
    }
  },
  "aliases": {},
  "picker": null
}
```

- [ ] **Step 4: Create `Tools/mdcat.ps1`**

```powershell
# Companion for mdcat — refine the theme from $DFConfig and register completions.
#
# mdcat is XDG-native and its MDCAT_THEME env var works from any shell (verified
# against mdcat 2.13.0). Tools/mdcat.json sets a static catppuccin-mocha default;
# this sidecar overrides it only when $DFConfig asks for a different theme, then
# registers mdcat's own PowerShell completions.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingInvokeExpression', '')]
param()

# 1. Theme: override the JSON default only when $DFConfig specifies one.
$_name = Get-DFConfiguredTheme -ToolKey 'MdcatTheme'
if ($_name) {
    # Family alias: bare 'catppuccin' -> mdcat's default flavour.
    if ($_name -eq 'catppuccin') { $_name = 'catppuccin-mocha' }

    $_builtin = @(
        'auto', 'dark', 'light',
        'catppuccin-mocha', 'catppuccin-latte',
        'gruvbox-dark', 'gruvbox-light',
        'dracula', 'nord',
        'solarized-dark', 'solarized-light'
    )
    if ($_name -notin $_builtin) {
        Write-Warning "DotForge: mdcat theme '$_name' not recognized — falling back to 'auto'"
        $_name = 'auto'
    }
    [System.Environment]::SetEnvironmentVariable('MDCAT_THEME', $_name, 'Process')
}

# 2. Native completions. mdcat emits a single Register-ArgumentCompleter -Native
#    call; carapace ships no mdcat spec, so there is no conflict, and it composes
#    with PSFzf's Tab (which routes through TabExpansion2). Invoke-Expression is
#    mdcat's documented init pattern. See docs/external-dependencies.md.
$_completions = mdcat --completions powershell | Out-String
if ($_completions) { Invoke-Expression $_completions }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/mdcat.Tests.ps1 -Output Detailed"`
Expected: PASS (json tests always; sidecar tests when `mdcat.exe` is present).

- [ ] **Step 6: Commit**

```bash
git add Tools/mdcat.json Tools/mdcat.ps1 tests/mdcat.Tests.ps1
git commit -m "feat: add mdcat markdown viewer with catppuccin theme + completions"
```

---

## Task 4: mdv tool + sidecar (config path + seeded config.yaml)

**Files:**
- Create: `Tools/mdv.json`, `Tools/mdv.ps1`
- Test: `tests/mdv.Tests.ps1`

**Interfaces:**
- Consumes: `Get-DFConfiguredTheme` (Task 1); `Register-DFTool`, `New-DFDirectory`, `Expand-DFXdgPath` (existing).
- Produces: registering `mdv` sets `$Env:MDV_CONFIG_PATH` to `$XDG_CONFIG_HOME/mdv`, creates that dir, and writes `config.yaml` (`theme: "<resolved>"`) **only when absent**. `$DFConfig['MdvTheme']`/`['Theme']` select the seeded theme.

**Context:** mdv has no config auto-discovery and no theme env var (verified). Theme lives only in `config.yaml` found via `MDV_CONFIG_PATH`. Seed-when-absent mirrors `Register-DFTool`'s `config` method — never clobbers a user-edited file. `Register-DFTool`'s `env` method sets the var and creates `dirs` before the sidecar runs.

- [ ] **Step 1: Write the failing tests**

Create `tests/mdv.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/Invoke-DFFzf.ps1"
    . "$PSScriptRoot/../Public/Invoke-DFPicker.ps1"
    . "$PSScriptRoot/../Private/Test-DFToolSchema.ps1"
    . "$PSScriptRoot/../Private/Expand-DFXdgPath.ps1"
    . "$PSScriptRoot/../Private/Import-DFToolDb.ps1"
    . "$PSScriptRoot/../Private/Invoke-DFTopoSort.ps1"
    . "$PSScriptRoot/../Public/Get-DFTool.ps1"
    . "$PSScriptRoot/../Public/Find-DFTool.ps1"
    . "$PSScriptRoot/../Private/Get-DFCoreutilsShadowSet.ps1"
    . "$PSScriptRoot/../Public/Get-DFCommandConflict.ps1"
    . "$PSScriptRoot/../Private/Initialize-DFCompletionStack.ps1"
    . "$PSScriptRoot/../Private/Get-DFConfiguredTheme.ps1"
    . "$PSScriptRoot/../Public/Register-DFTool.ps1"

    $script:MdvJson = Get-Content "$PSScriptRoot/../Tools/mdv.json" -Raw | ConvertFrom-Json
}

Describe 'Tools/mdv.json' {
    It 'declares the env XDG method' {
        $script:MdvJson.xdg.method | Should -Be 'env'
    }
    It 'points MDV_CONFIG_PATH at the XDG mdv dir' {
        $script:MdvJson.xdg.vars.MDV_CONFIG_PATH | Should -Be '${XDG_CONFIG_HOME}/mdv'
    }
    It 'names catppuccin as the seed theme' {
        $script:MdvJson.settings.theme | Should -Be 'catppuccin'
    }
    It 'declares a cargo package' {
        $script:MdvJson.packages.cargo | Should -Be 'mdv'
    }
}

Describe 'mdv tool sidecar' -Skip:(-not (Get-Command mdv.exe -ErrorAction Ignore)) {
    BeforeEach {
        $script:DFToolDb        = $null
        $script:SavedConfigHome = $Env:XDG_CONFIG_HOME
        $script:SavedConfigPath = $Env:MDV_CONFIG_PATH
        $Env:XDG_CONFIG_HOME    = Join-Path $TestDrive 'config'
        $Env:MDV_CONFIG_PATH    = $null
        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
        $script:RealTools = Join-Path $PSScriptRoot '../Tools'
    }
    AfterEach {
        $Env:XDG_CONFIG_HOME = $script:SavedConfigHome
        $Env:MDV_CONFIG_PATH = $script:SavedConfigPath
        $script:DFToolDb     = $null
        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
    }

    It 'sets MDV_CONFIG_PATH and creates the dir' {
        Register-DFTool -Name 'mdv' -ToolsPath $script:RealTools
        $Env:MDV_CONFIG_PATH | Should -Be (Join-Path $Env:XDG_CONFIG_HOME 'mdv')
        Test-Path $Env:MDV_CONFIG_PATH | Should -BeTrue
    }

    It 'seeds config.yaml with the catppuccin theme when absent' {
        Register-DFTool -Name 'mdv' -ToolsPath $script:RealTools
        $cfg = Join-Path $Env:XDG_CONFIG_HOME 'mdv' 'config.yaml'
        Test-Path $cfg | Should -BeTrue
        (Get-Content $cfg -Raw) | Should -Match 'theme:\s*"catppuccin"'
    }

    It 'does not overwrite an existing config.yaml' {
        $dir = Join-Path $Env:XDG_CONFIG_HOME 'mdv'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $cfg = Join-Path $dir 'config.yaml'
        'theme: "nord"   # user edit' | Set-Content $cfg
        Register-DFTool -Name 'mdv' -ToolsPath $script:RealTools
        (Get-Content $cfg -Raw) | Should -Match 'user edit'
    }

    It 'maps the catppuccin family down to mdv''s catppuccin theme' {
        $Global:DFConfig = @{ Theme = 'catppuccin-mocha' }
        Register-DFTool -Name 'mdv' -ToolsPath $script:RealTools
        $cfg = Join-Path $Env:XDG_CONFIG_HOME 'mdv' 'config.yaml'
        (Get-Content $cfg -Raw) | Should -Match 'theme:\s*"catppuccin"'
    }

    It 'tolerates $DFConfig being set to $null' {
        $Global:DFConfig = $null
        { Register-DFTool -Name 'mdv' -ToolsPath $script:RealTools } | Should -Not -Throw
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/mdv.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Tools/mdv.json` not found.

- [ ] **Step 3: Create `Tools/mdv.json`**

```json
{
  "name": "mdv",
  "description": "Terminal markdown viewer with themes and syntax highlighting",
  "tags": [
    "markdown",
    "viewer",
    "text"
  ],
  "executable": "mdv.exe",
  "packages": {
    "cargo": "mdv"
  },
  "xdg": {
    "compliance": "partial",
    "method": "env",
    "vars": {
      "MDV_CONFIG_PATH": "${XDG_CONFIG_HOME}/mdv"
    },
    "dirs": [
      "${XDG_CONFIG_HOME}/mdv"
    ]
  },
  "settings": {
    "theme": "catppuccin"
  },
  "aliases": {},
  "picker": null
}
```

- [ ] **Step 4: Create `Tools/mdv.ps1`**

```powershell
# Companion for mdv — seed a themed config.yaml, since mdv has no config
# auto-discovery and no theme env var (verified against mdv 4.2.1). Its config
# is found only via MDV_CONFIG_PATH (set by Tools/mdv.json's env method) pointing
# at a dir holding config.yaml. We write that file only when it is absent, so a
# user-edited config is never clobbered — the same restraint as Register-DFTool's
# 'config' method. See docs/external-dependencies.md.

# 1. Theme: per-tool key -> shared Theme -> JSON default 'catppuccin'.
$_settings = $DFCurrentTool.PSObject.Properties['settings']?.Value
$_default  = $_settings.PSObject.Properties['theme']?.Value ?? 'catppuccin'
$_name     = Get-DFConfiguredTheme -ToolKey 'MdvTheme' -Default $_default

# Family alias: mdv ships one catppuccin flavour, so any catppuccin-* -> catppuccin.
if ($_name -like 'catppuccin-*') { $_name = 'catppuccin' }

$_valid = @(
    'terminal', 'solarized-dark', 'nord', 'tokyonight',
    'kanagawa', 'gruvbox', 'monokai', 'material-ocean', 'catppuccin'
)
if ($_name -notin $_valid) {
    Write-Warning "DotForge: mdv theme '$_name' not recognized — falling back to 'terminal'"
    $_name = 'terminal'
}

# 2. Seed config.yaml when absent. MDV_CONFIG_PATH was set by the env method; fall
#    back to the XDG path if it is somehow empty.
$_cfgDir = if ($Env:MDV_CONFIG_PATH) { $Env:MDV_CONFIG_PATH }
           else { Expand-DFXdgPath '${XDG_CONFIG_HOME}/mdv' }
New-DFDirectory $_cfgDir | Out-Null

$_cfgFile = Join-Path $_cfgDir 'config.yaml'
if (-not (Test-Path $_cfgFile -PathType Leaf)) {
    Set-Content -Path $_cfgFile -Value "theme: `"$_name`"" -Encoding UTF8
    Write-Verbose "DotForge: seeded mdv config at $_cfgFile (theme: $_name)"
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/mdv.Tests.ps1 -Output Detailed"`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Tools/mdv.json Tools/mdv.ps1 tests/mdv.Tests.ps1
git commit -m "feat: add mdv markdown viewer with seeded catppuccin config"
```

---

## Task 5: carapace completion spec for mdv

**Files:**
- Create: `Tools/carapace/specs/mdv.yaml`
- Test: extend `tests/mdv.Tests.ps1` (parse + shape assertions; no binary needed)

**Interfaces:**
- Consumes: nothing. Deployed to `$XDG_CONFIG_HOME/carapace/specs/` by the existing `Tools/carapace.ps1` logic (which copies `Tools/carapace/specs/*.yaml`), exactly like `scoop.yaml`.
- Produces: `mdv <Tab>` completes flags once carapace is registered.

**Context:** mdv has no completion generator and carapace ships no spec (verified: `carapace mdv export` → 0 bytes). Hand-authored, so it can drift; catalogued in external-dependencies. Flag-key syntax is short-first with `=` marking value-taking flags, matching `scoop.yaml`.

- [ ] **Step 1: Write the failing test**

Add a new `Describe` block to `tests/mdv.Tests.ps1` (after the existing blocks). It parses the YAML as text (no YAML module dependency — assert on content):

```powershell
Describe 'Tools/carapace/specs/mdv.yaml' {
    BeforeAll {
        $script:SpecPath = "$PSScriptRoot/../Tools/carapace/specs/mdv.yaml"
        $script:Spec     = Get-Content $script:SpecPath -Raw
    }
    It 'exists and names the mdv command' {
        Test-Path $script:SpecPath | Should -BeTrue
        $script:Spec | Should -Match '(?m)^name:\s*mdv\b'
    }
    It 'declares the theme flag with catppuccin among its values' {
        $script:Spec | Should -Match '--theme'
        $script:Spec | Should -Match 'catppuccin'
    }
    It 'declares the config-file and pager flags' {
        $script:Spec | Should -Match '--config-file'
        $script:Spec | Should -Match '--pager'
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/mdv.Tests.ps1 -Output Detailed"`
Expected: the new block FAILS — `mdv.yaml` not found.

- [ ] **Step 3: Create `Tools/carapace/specs/mdv.yaml`**

```yaml
# Carapace spec for mdv (WhoSowSee/mdv terminal markdown viewer).
#
# mdv has no completion generator of its own and carapace ships no mdv spec, so
# without this file `mdv <TAB>` falls through to filesystem completion. DotForge
# deploys this to $XDG_CONFIG_HOME/carapace/specs/ (Tools/carapace.ps1), where
# carapace loads it automatically. See `carapace --help` ("Specs are loaded from ...").
#
# Hand-authored, so it can drift from the installed binary — catalogued in
# docs/external-dependencies.md. Flag-key syntax is short-first (`-t, --theme`);
# a trailing `=` marks a flag that takes a value.
name: mdv
description: Terminal markdown viewer
flags:
  -h, --help: Show help
  -V, --version: Show version
  -F, --config-file=: Directory containing config.yaml
  -n, --no-config: Skip loading configuration files
  -G, --init-config=: Create the default configuration file
  -A, --no-colors: Strip all ANSI colors
  -C, --hide-comments: Hide Markdown comments
  -E, --render-html: Render raw HTML fragments
  -H, --html: Print HTML instead of terminal formatting
  -p, --pager: Show output in the built-in pager
  -t, --theme=: Set the UI theme
  -T, --code-theme=: Set the code-block highlight theme
  -L, --no-code-language: Hide the language label above code blocks
  -e, --show-empty-elements: Show empty Markdown elements
  -g, --no-code-guessing: Disable heuristic language detection
  -s, --code-block-style=: Visual style for code blocks
  -O, --callout-style=: Visual style for callouts
  -D, --pretty-list: Render list markers as Nerd Font icons
completion:
  flag:
    theme:
      - terminal
      - solarized-dark
      - nord
      - tokyonight
      - kanagawa
      - gruvbox
      - monokai
      - material-ocean
      - catppuccin
    code-theme:
      - terminal
      - solarized-dark
      - nord
      - tokyonight
      - kanagawa
      - gruvbox
      - monokai
      - material-ocean
      - catppuccin
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/mdv.Tests.ps1 -Output Detailed"`
Expected: PASS (all mdv blocks).

- [ ] **Step 5: Verify carapace loads the spec (if carapace present)**

Run:
```
pwsh -NoProfile -Command "Copy-Item Tools/carapace/specs/mdv.yaml \"$Env:XDG_CONFIG_HOME/carapace/specs/mdv.yaml\" -Force; (carapace mdv export mdv '' 2>&1 | Out-String).Length"
```
Expected: a non-zero length (carapace now parses the spec). If carapace is absent, skip.

- [ ] **Step 6: Commit**

```bash
git add Tools/carapace/specs/mdv.yaml tests/mdv.Tests.ps1
git commit -m "feat: bundle carapace completion spec for mdv"
```

---

## Task 6: Route glow + psreadline through the shared resolver

**Files:**
- Modify: `Tools/glow.ps1` (theme resolution ~line 14-25; `Resolve-DFGlowStyle` body ~line 40-54)
- Modify: `Tools/psreadline.ps1` (`Invoke-DFApplyPSReadLineTheme` body ~line 65; initial-theme block ~line 105-110)
- Test: extend `tests/glow.Tests.ps1` and `tests/psreadline.Tests.ps1`

**Interfaces:**
- Consumes: `Get-DFConfiguredTheme` (Task 1). Both test files already dot-source the same helper chain; add `. "$PSScriptRoot/../Private/Get-DFConfiguredTheme.ps1"` to each `BeforeAll` (before `Register-DFTool.ps1`).
- Produces: `$DFConfig['Theme'] = 'catppuccin'` themes glow (→ bundled `catppuccin-mocha.json`) and psreadline (→ bundled `catppuccin-mocha.json`); per-tool `GlowTheme`/`PSReadLineTheme` still win. psreadline default stays `dark`.

- [ ] **Step 1: Write the failing tests**

In `tests/glow.Tests.ps1`, add the helper dot-source to `BeforeAll` (after the `Initialize-DFCompletionStack.ps1` line):

```powershell
    . "$PSScriptRoot/../Private/Get-DFConfiguredTheme.ps1"
```

Then add inside `Describe 'glow tool sidecar'` (after the existing `'passes a glow built-in style name through unchanged'` test):

```powershell
    It 'follows the shared $DFConfig[Theme] key (catppuccin -> bundled mocha)' {
        $Global:DFConfig = @{ Theme = 'catppuccin' }
        Register-DFTool -Name 'glow' -ToolsPath $script:RealTools
        $expected = (Resolve-Path (Join-Path $script:RealTools 'glow' 'catppuccin-mocha.json')).Path
        $global:DFGlowStyle | Should -Be $expected
    }

    It 'lets GlowTheme override the shared Theme key' {
        $Global:DFConfig = @{ Theme = 'catppuccin'; GlowTheme = 'dracula' }
        Register-DFTool -Name 'glow' -ToolsPath $script:RealTools
        $global:DFGlowStyle | Should -Be 'dracula'
    }
```

In `tests/psreadline.Tests.ps1`, add the helper dot-source to `BeforeAll` similarly, then add (after the existing `'applies the theme named in $DFConfig[PSReadLineTheme]'` test):

```powershell
    It 'follows the shared $DFConfig[Theme] key (catppuccin -> mocha)' {
        # Same VT/redirect limitation — fall back to $global:DFPSReadLineColors.
        $Global:DFConfig = @{ Theme = 'catppuccin' }
        Register-DFTool -Name 'psreadline' -ToolsPath $script:RealTools
        $colors = (Get-PSReadLineOption).Colors
        $commandColor = if ($colors) { $colors.Command } else { $global:DFPSReadLineColors['Command'] }
        # catppuccin-mocha Command color is #cba6f7 -> VT contains "203;166;247"
        $commandColor | Should -Match '203;166;247'
    }

    It 'lets PSReadLineTheme override the shared Theme key' {
        $Global:DFConfig = @{ Theme = 'catppuccin'; PSReadLineTheme = 'light' }
        Register-DFTool -Name 'psreadline' -ToolsPath $script:RealTools
        $colors = (Get-PSReadLineOption).Colors
        $commandColor = if ($colors) { $colors.Command } else { $global:DFPSReadLineColors['Command'] }
        # light theme Command color is #0000ff -> VT contains "0;0;255"
        $commandColor | Should -Match '0;0;255'
    }
```

**Note:** the catppuccin-mocha `colors.Command` is `#cba6f7` → decimal RGB `203;166;247` (already used above). If you change the bundled theme, recompute.

- [ ] **Step 2: Run tests to verify they fail**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/glow.Tests.ps1,tests/psreadline.Tests.ps1 -Output Detailed"`
Expected: the four new tests FAIL — glow: `Theme` ignored (only `GlowTheme` read), so it falls back to bundled default and the `Theme=catppuccin` + `GlowTheme=dracula` case may pass by luck but the shared-key case resolves to the JSON default, not via `Theme`; psreadline: `Theme` ignored, default `dark` used, wrong Command color.

- [ ] **Step 3: Edit `Tools/glow.ps1`**

Replace the theme-resolution block (currently lines 14-25):

```powershell
# 1. Settings from tool JSON, with $DFConfig override for the theme name
$_settings = $DFCurrentTool.PSObject.Properties['settings']?.Value
$_theme    = $_settings.PSObject.Properties['theme']?.Value ?? 'catppuccin-mocha'
$_cfgRaw   = $_settings.PSObject.Properties['configFile']?.Value ?? '${XDG_CONFIG_HOME}/glow/glow.yml'
$_cfg      = Expand-DFXdgPath $_cfgRaw

# Test the value, not the variable's existence: `$DFConfig = $null` leaves the
# variable defined, and indexing into it throws.
if ($null -ne $Global:DFConfig) {
    $_override = $Global:DFConfig['GlowTheme']
    if ($_override) { $_theme = $_override }
}
```

with:

```powershell
# 1. Settings from tool JSON. Theme: per-tool GlowTheme -> shared Theme -> JSON default.
$_settings = $DFCurrentTool.PSObject.Properties['settings']?.Value
$_default  = $_settings.PSObject.Properties['theme']?.Value ?? 'catppuccin-mocha'
$_theme    = Get-DFConfiguredTheme -ToolKey 'GlowTheme' -Default $_default
$_cfgRaw   = $_settings.PSObject.Properties['configFile']?.Value ?? '${XDG_CONFIG_HOME}/glow/glow.yml'
$_cfg      = Expand-DFXdgPath $_cfgRaw
```

Add the catppuccin family alias inside `Resolve-DFGlowStyle`, immediately after the `param(...)` line (before the `$builtin = @(...)` line):

```powershell
    # Family alias: the shared 'catppuccin' key means glow's bundled mocha flavour.
    if ($Name -eq 'catppuccin') { $Name = 'catppuccin-mocha' }
```

- [ ] **Step 4: Edit `Tools/psreadline.ps1`**

Add the catppuccin alias inside `Invoke-DFApplyPSReadLineTheme`, immediately after its `param([Parameter(Mandatory)][string]$Name)` line (before `# Resolve path:`):

```powershell
    # Family alias: the shared 'catppuccin' key means the bundled mocha flavour.
    if ($Name -eq 'catppuccin') { $Name = 'catppuccin-mocha' }
```

Replace the initial-theme block (currently lines 105-110):

```powershell
# 3. Apply initial theme
$_themeSetting = $null
if ($null -ne $Global:DFConfig) {
    $_themeSetting = $Global:DFConfig['PSReadLineTheme']
}
Invoke-DFApplyPSReadLineTheme -Name ($_themeSetting ?? 'dark')
```

with:

```powershell
# 3. Apply initial theme: per-tool PSReadLineTheme -> shared Theme -> 'dark'.
$_themeSetting = Get-DFConfiguredTheme -ToolKey 'PSReadLineTheme' -Default 'dark'
Invoke-DFApplyPSReadLineTheme -Name $_themeSetting
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/glow.Tests.ps1,tests/psreadline.Tests.ps1 -Output Detailed"`
Expected: PASS (all, including the four new).

- [ ] **Step 6: Commit**

```bash
git add Tools/glow.ps1 Tools/psreadline.ps1 tests/glow.Tests.ps1 tests/psreadline.Tests.ps1
git commit -m "feat: route glow and psreadline through shared Theme key"
```

---

## Task 7: Documentation

**Files:**
- Modify: `README.md`, `CHANGELOG.md`, `docs/external-dependencies.md`, `examples/02-standard.ps1`

**Interfaces:** none (docs only). No test cycle; the deliverable is accurate docs.

- [ ] **Step 1: Full suite green before documenting**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/ -Output Normal"`
Expected: PASS, 0 failed. (Everything from Tasks 1-6 integrated.)

- [ ] **Step 2: README — shared theme + the two viewers**

In the `$DFConfig` block (near `GlowTheme`), add:

```powershell
    Theme               = 'catppuccin'         # shared theme for all viewers (per-tool keys override)
    MdcatTheme          = 'catppuccin-mocha'    # mdcat theme (overrides Theme)
    MdvTheme            = 'catppuccin'          # mdv theme (overrides Theme)
```

In *Tool-Specific Helpers*, after the **glow** entry, add:

```markdown
**mdcat** (`Tools/mdcat.ps1`)

mdcat is XDG-native and its `MDCAT_THEME` env var works from any shell, so DotForge
sets the theme via that variable (no wrapper) and registers mdcat's own
`--completions powershell`. Theme comes from `$DFConfig['MdcatTheme']`, then the
shared `$DFConfig['Theme']`, then `catppuccin-mocha`. Built-ins: `catppuccin-mocha`,
`catppuccin-latte`, `dracula`, `nord`, `gruvbox-dark/-light`, `solarized-dark/-light`,
`auto`, `dark`, `light`.

**mdv** (`Tools/mdv.ps1`)

mdv has no config auto-discovery and no theme env var, so DotForge points
`MDV_CONFIG_PATH` at `$XDG_CONFIG_HOME/mdv` and seeds `config.yaml` with the resolved
theme **only when the file is absent** — your edits are never overwritten. Theme comes
from `$DFConfig['MdvTheme']`, then `$DFConfig['Theme']`, then `catppuccin`. Because the
seed is write-when-absent, **changing the theme after first run means editing or
deleting `config.yaml`** and re-registering. Completion is provided by a bundled
carapace spec (`Tools/carapace/specs/mdv.yaml`).
```

In the *Included Tools* table (`Text/data` row), change `jq, glow` to `jq, glow, mdcat, mdv`.

- [ ] **Step 3: CHANGELOG — under `[Unreleased]`**

Add an `### Added` entry (create the heading if absent):

```markdown
- **Two markdown viewers — `mdcat` and `mdv`:** both catppuccin by default. `mdcat`
  is themed via `MDCAT_THEME` with native `--completions`; `mdv` is themed by a seeded
  `config.yaml` (written only when absent) plus a bundled carapace spec. A shared
  `$DFConfig['Theme']` key now drives `glow`, `mdcat`, `mdv`, and `psreadline`, with
  per-tool keys (`GlowTheme`, `MdcatTheme`, `MdvTheme`, `PSReadLineTheme`) overriding it.
  `Install-DFTool` gained a `cargo` arm (last-resort) so cargo-only tools install.
```

- [ ] **Step 4: external-dependencies.md — new entries**

In the *Documented but load-bearing* table, add rows:

```markdown
| mdcat's `MDCAT_THEME` env var and `--completions powershell` | `Tools/mdcat.ps1`, `Tools/mdcat.json` | Both documented (mdcat 2.13.0). Env var honored from any shell; `--completions` emits one `-Native` completer. carapace ships no mdcat spec, so no conflict. An unrecognized theme falls back to `auto`. |
| mdv's config path (`MDV_CONFIG_PATH`) and `config.yaml` theme key | `Tools/mdv.ps1`, `Tools/mdv.json` | mdv 4.2.1 has **no config auto-discovery** (redirecting HOME/APPDATA/XDG_CONFIG_HOME loads nothing) and **no theme env var**; theme lives only in `config.yaml` found via `MDV_CONFIG_PATH`. DotForge seeds that file when absent, never clobbering user edits — so a theme change after first run needs a manual edit/delete. |
| carapace loads `Tools/carapace/specs/mdv.yaml` | `Tools/carapace.ps1`, `Tools/carapace/specs/mdv.yaml` | mdv has no completion generator and carapace ships no spec (`carapace mdv export` → 0 bytes). Hand-authored spec, deployed like `scoop.yaml`; can drift from the binary. |
```

- [ ] **Step 5: examples/02-standard.ps1 — shared Theme key**

In the `$DFConfig` theme comment block added earlier, replace the theme lines with:

```powershell
    # One shared theme for every viewer; per-tool keys override it:
    #   Theme           = 'catppuccin'         # glow, mdcat, mdv, psreadline
    #   MdcatTheme      = 'dracula'             # override just mdcat
    #   MdvTheme        = 'nord'                # override just mdv
    #   GlowTheme       = 'catppuccin-mocha'    # override just glow
    #   PSReadLineTheme = 'catppuccin-mocha'    # override just psreadline
```

- [ ] **Step 6: Commit**

```bash
git add README.md CHANGELOG.md docs/external-dependencies.md examples/02-standard.ps1
git commit -m "docs: document mdv, mdcat, and the shared Theme key"
```

---

## Final Verification

- [ ] **Full suite from a clean shell**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/ -Output Normal"`
Expected: 0 failed.

- [ ] **Live end-to-end** (binaries present)

```powershell
Import-Module ./DotForge.psd1 -Force
$DFConfig = @{ Theme = 'catppuccin' }
Register-DFTool -Name mdcat, mdv, glow, psreadline
$Env:MDCAT_THEME                                              # catppuccin-mocha
mdcat README.md | Select-Object -First 3                      # catppuccin-colored
Get-Content (Join-Path $Env:XDG_CONFIG_HOME 'mdv/config.yaml')# theme: "catppuccin"
mdv README.md | Select-Object -First 3                        # catppuccin
$global:DFGlowStyle                                           # ...\Tools\glow\catppuccin-mocha.json
Install-DFTool -Name mdv -WhatIf                              # "via cargo (mdv)"
```

- [ ] **PSScriptAnalyzer parity** (new/edited files match the existing sidecar baseline — global-var + positional-Join-Path warnings only)

```powershell
foreach ($f in 'Tools/mdcat.ps1','Tools/mdv.ps1','Private/Get-DFConfiguredTheme.ps1','Public/Install-DFTool.ps1') {
    "--- $f"; Invoke-ScriptAnalyzer -Path $f | Format-Table Severity, Line, RuleName -AutoSize
}
```
