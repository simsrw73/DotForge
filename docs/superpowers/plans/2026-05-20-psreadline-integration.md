# PSReadLine Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add PSReadLine as a first-class DotForge tool with `dependsOn` ordering, a JSON settings block, a bundled+user theme system, and a live theme picker (`fprl`).

**Architecture:** Extract topological sort into `Private/Invoke-DFTopoSort.ps1`; wire it and a `$DFCurrentTool` injection point into `Register-DFTool`; add `psreadline.json` + `psreadline.ps1` sidecar that reads settings from the tool JSON, applies a hex-color theme, and registers `Select-PSReadLineTheme`/`fprl`. PSFzf declares `dependsOn: ["psreadline"]` so ordering is guaranteed.

**Tech Stack:** PowerShell 7+, Pester 5, PSReadLine (built-in to PS7+), fzf / Invoke-DFPicker.

**Spec:** `docs/superpowers/specs/2026-05-20-psreadline-integration-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `Private/Invoke-DFTopoSort.ps1` | Create | Kahn's topological sort over tool objects |
| `Public/Register-DFTool.ps1` | Modify | Call topo sort; inject `$DFCurrentTool` before dot-source |
| `Tools/PSFzf.json` | Modify | Add `dependsOn: ["psreadline"]` |
| `Tools/PSFzf.ps1` | Modify | Remove stale comment about key-handler removal |
| `Tools/psreadline.json` | Create | Tool entry with `settings` block |
| `Tools/psreadline/dark.json` | Create | Bundled dark theme |
| `Tools/psreadline/light.json` | Create | Bundled light theme |
| `Tools/psreadline/catppuccin-mocha.json` | Create | Bundled Catppuccin Mocha theme |
| `Tools/psreadline.ps1` | Create | Sidecar: apply settings, theme, register picker |
| `CLAUDE.md` | Modify | Document `dependsOn`, `$DFCurrentTool`, `$PSScriptRoot` conventions |
| `tests/Register-DFTool.Tests.ps1` | Modify | Add topo sort + `$DFCurrentTool` tests |
| `tests/psreadline.Tests.ps1` | Create | Settings, theme, and picker registration tests |

---

## Task 1: Private Invoke-DFTopoSort

**Files:**
- Create: `Private/Invoke-DFTopoSort.ps1`
- Modify: `tests/Register-DFTool.Tests.ps1` (add dot-source + Describe block)

- [ ] **Step 1.1: Add dot-source to BeforeAll and write failing tests**

Open `tests/Register-DFTool.Tests.ps1`. In the `BeforeAll` block (currently lines 1–11), add the new dot-source line:

```powershell
BeforeAll {
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/Invoke-DFFzf.ps1"
    . "$PSScriptRoot/../Public/Invoke-DFPicker.ps1"
    . "$PSScriptRoot/../Private/Test-DFToolSchema.ps1"
    . "$PSScriptRoot/../Private/Expand-DFXdgPath.ps1"
    . "$PSScriptRoot/../Private/Import-DFToolDb.ps1"
    . "$PSScriptRoot/../Private/Invoke-DFTopoSort.ps1"   # <-- add this line
    . "$PSScriptRoot/../Public/Get-DFTool.ps1"
    . "$PSScriptRoot/../Public/Find-DFTool.ps1"
    . "$PSScriptRoot/../Public/Register-DFTool.ps1"
}
```

Then append this new `Describe` block at the bottom of the file (after the closing `}` of the existing `Describe 'Register-DFTool'` block):

```powershell
Describe 'Invoke-DFTopoSort' {
    It 'returns tools unchanged when no dependsOn fields present' {
        $tools = @(
            [PSCustomObject]@{ name = 'zzz' },
            [PSCustomObject]@{ name = 'aaa' }
        )
        $result = Invoke-DFTopoSort -Tools $tools
        $result[0].name | Should -Be 'zzz'
        $result[1].name | Should -Be 'aaa'
    }

    It 'places dependency before dependent tool' {
        $tools = @(
            [PSCustomObject]@{ name = 'PSFzf';    dependsOn = @('psreadline') },
            [PSCustomObject]@{ name = 'psreadline'; dependsOn = @() }
        )
        $result = Invoke-DFTopoSort -Tools $tools
        $result[0].name | Should -Be 'psreadline'
        $result[1].name | Should -Be 'PSFzf'
    }

    It 'handles three-tool chain: a -> b -> c' {
        $tools = @(
            [PSCustomObject]@{ name = 'c'; dependsOn = @('b') },
            [PSCustomObject]@{ name = 'a'; dependsOn = @() },
            [PSCustomObject]@{ name = 'b'; dependsOn = @('a') }
        )
        $result = Invoke-DFTopoSort -Tools $tools
        $result[0].name | Should -Be 'a'
        $result[1].name | Should -Be 'b'
        $result[2].name | Should -Be 'c'
    }

    It 'ignores dep not present in the tool set (no error, tool still registered)' {
        $tools = @(
            [PSCustomObject]@{ name = 'PSFzf'; dependsOn = @('psreadline') }
        )
        { $result = Invoke-DFTopoSort -Tools $tools } | Should -Not -Throw
        $result = Invoke-DFTopoSort -Tools $tools
        $result | Should -HaveCount 1
        $result[0].name | Should -Be 'PSFzf'
    }

    It 'emits a warning and returns original order on cycle' {
        $tools = @(
            [PSCustomObject]@{ name = 'a'; dependsOn = @('b') },
            [PSCustomObject]@{ name = 'b'; dependsOn = @('a') }
        )
        $warns = $null
        $result = Invoke-DFTopoSort -Tools $tools -WarningVariable warns 3>$null
        $warns | Should -Not -BeNullOrEmpty
        $result | Should -HaveCount 2
    }

    It 'returns empty array for empty input' {
        $result = Invoke-DFTopoSort -Tools @()
        $result | Should -HaveCount 0
    }
}
```

- [ ] **Step 1.2: Run tests to confirm they fail**

```powershell
Invoke-Pester tests/Register-DFTool.Tests.ps1 -Output Detailed
```

Expected: all six new `Invoke-DFTopoSort` tests fail with "Invoke-DFTopoSort is not recognized" or similar. Existing tests still pass.

- [ ] **Step 1.3: Create Private/Invoke-DFTopoSort.ps1**

```powershell
#Requires -Version 7.0

function Invoke-DFTopoSort {
    <#
    .SYNOPSIS
        Topological sort of tool objects using Kahn's algorithm.
        Tools whose dependsOn deps are not in the input set are processed normally.
        Cycles emit a warning and fall back to original order.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$Tools
    )

    if ($Tools.Count -eq 0) { return @() }

    $toolNames = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($t in $Tools) { [void]$toolNames.Add($t.name) }

    $inDegree   = @{}
    $successors = @{}
    foreach ($t in $Tools) {
        $inDegree[$t.name]   = 0
        $successors[$t.name] = [System.Collections.Generic.List[string]]::new()
    }

    foreach ($t in $Tools) {
        $deps = $t.PSObject.Properties['dependsOn']?.Value
        if (-not $deps) { continue }
        foreach ($dep in @($deps)) {
            if ($toolNames.Contains($dep)) {
                $successors[$dep].Add($t.name)
                $inDegree[$t.name]++
            }
        }
    }

    $queue = [System.Collections.Generic.Queue[string]]::new()
    foreach ($name in $inDegree.Keys | Where-Object { $inDegree[$_] -eq 0 }) {
        $queue.Enqueue($name)
    }

    $nameToTool = @{}
    foreach ($t in $Tools) { $nameToTool[$t.name] = $t }

    $sorted = [System.Collections.Generic.List[object]]::new()
    while ($queue.Count -gt 0) {
        $name = $queue.Dequeue()
        $sorted.Add($nameToTool[$name])
        foreach ($successor in $successors[$name]) {
            $inDegree[$successor]--
            if ($inDegree[$successor] -eq 0) { $queue.Enqueue($successor) }
        }
    }

    if ($sorted.Count -ne $Tools.Count) {
        Write-Warning 'DotForge: circular dependency detected in tool dependsOn — falling back to original order'
        return $Tools
    }

    return $sorted.ToArray()
}
```

- [ ] **Step 1.4: Run tests to confirm they pass**

```powershell
Invoke-Pester tests/Register-DFTool.Tests.ps1 -Output Detailed
```

Expected: all 6 new tests + all existing tests pass.

- [ ] **Step 1.5: Commit**

```powershell
git add Private/Invoke-DFTopoSort.ps1 tests/Register-DFTool.Tests.ps1
git commit -m "feat: add Invoke-DFTopoSort private helper with tests"
```

---

## Task 2: Wire Topo Sort + $DFCurrentTool into Register-DFTool

**Files:**
- Modify: `Public/Register-DFTool.ps1`
- Modify: `tests/Register-DFTool.Tests.ps1` (new It blocks in existing Describe)

- [ ] **Step 2.1: Write failing tests for dependsOn ordering and $DFCurrentTool**

Append these `It` blocks inside the existing `Describe 'Register-DFTool'` block in `tests/Register-DFTool.Tests.ps1`, before its closing `}`:

```powershell
    It 'registers psreadline before PSFzf when PSFzf has dependsOn = ["psreadline"]' {
        $order = [System.Collections.Generic.List[string]]::new()

        @'
{ "name": "psreadline", "type": "module", "executable": "PSReadLine", "dependsOn": [] }
'@ | Set-Content (Join-Path $script:TmpTools 'psreadline.json')

        @'
{ "name": "PSFzf", "type": "module", "executable": "PSFzf", "dependsOn": ["psreadline"] }
'@ | Set-Content (Join-Path $script:TmpTools 'PSFzf.json')

        # Record registration order via sentinels
        "`$global:RegOrder.Add('psreadline')" |
            Set-Content (Join-Path $script:TmpTools 'psreadline.ps1')
        "`$global:RegOrder.Add('PSFzf')" |
            Set-Content (Join-Path $script:TmpTools 'PSFzf.ps1')

        $Global:RegOrder = [System.Collections.Generic.List[string]]::new()
        Mock Get-Module { [PSCustomObject]@{ Name = $Name } }
        Register-DFTool -All -ToolsPath $script:TmpTools

        $Global:RegOrder[0] | Should -Be 'psreadline'
        $Global:RegOrder[1] | Should -Be 'PSFzf'

        Remove-Variable RegOrder -Scope Global -ErrorAction Ignore
        Remove-Item (Join-Path $script:TmpTools 'psreadline.json') -ErrorAction Ignore
        Remove-Item (Join-Path $script:TmpTools 'PSFzf.json')      -ErrorAction Ignore
        Remove-Item (Join-Path $script:TmpTools 'psreadline.ps1')  -ErrorAction Ignore
        Remove-Item (Join-Path $script:TmpTools 'PSFzf.ps1')       -ErrorAction Ignore
        $script:DFToolDb = $null
    }

    It 'injects $DFCurrentTool before dot-sourcing companion' {
        Mock Get-Command { [PSCustomObject]@{ Path = 'C:\fake\testtool.exe' } }
        '$global:CapturedTool = $DFCurrentTool' |
            Set-Content (Join-Path $script:TmpTools 'testtool.ps1')

        Register-DFTool -Name 'testtool' -ToolsPath $script:TmpTools
        $Global:CapturedTool | Should -Not -BeNullOrEmpty
        $Global:CapturedTool.name | Should -Be 'testtool'

        Remove-Variable CapturedTool -Scope Global -ErrorAction Ignore
        Remove-Item (Join-Path $script:TmpTools 'testtool.ps1') -ErrorAction Ignore
    }
```

- [ ] **Step 2.2: Run tests to confirm new tests fail**

```powershell
Invoke-Pester tests/Register-DFTool.Tests.ps1 -Output Detailed
```

Expected: the two new tests fail (ordering wrong or `$DFCurrentTool` is null). All other tests still pass.

- [ ] **Step 2.3: Modify Register-DFTool.ps1**

Two targeted changes:

**Change A** — after line 49 (after `$tools = if ($All) { ... } else { ... }`), add:

```powershell
    # Topological sort respects dependsOn declarations
    $tools = Invoke-DFTopoSort -Tools @($tools)
```

**Change B** — replace the companion dot-source block (currently lines 196–199):

```powershell
        # ── Companion .ps1 ──────────────────────────────────────────────────
        $companion = Join-Path $resolvedToolsPath "$($tool.name).ps1"
        if (Test-Path $companion -PathType Leaf) {
            . ($companion)
        }
```

With:

```powershell
        # ── Companion .ps1 ──────────────────────────────────────────────────
        $companion = Join-Path $resolvedToolsPath "$($tool.name).ps1"
        if (Test-Path $companion -PathType Leaf) {
            $DFCurrentTool = $tool
            . ($companion)
            Remove-Variable -Name DFCurrentTool -ErrorAction Ignore
        }
```

- [ ] **Step 2.4: Run tests to confirm all pass**

```powershell
Invoke-Pester tests/Register-DFTool.Tests.ps1 -Output Detailed
```

Expected: all tests pass, including the two new ones.

- [ ] **Step 2.5: Commit**

```powershell
git add Public/Register-DFTool.ps1 tests/Register-DFTool.Tests.ps1
git commit -m "feat: wire dependsOn topo sort and DFCurrentTool into Register-DFTool"
```

---

## Task 3: PSFzf.json + PSFzf.ps1 Minor Changes

**Files:**
- Modify: `Tools/PSFzf.json`
- Modify: `Tools/PSFzf.ps1`

- [ ] **Step 3.1: Add dependsOn to PSFzf.json**

Open `Tools/PSFzf.json`. Add `"dependsOn": ["psreadline"]` after the `"executable"` line:

```json
{
  "name": "PSFzf",
  "type": "module",
  "description": "PowerShell wrapper around fzf with PSReadLine key handler integration",
  "tags": [
    "fuzzy",
    "picker",
    "module"
  ],
  "executable": "PSFzf",
  "dependsOn": ["psreadline"],
  "packages": {
    "psresource": "PSFzf",
    "scoop": "psfzf"
  },
  "xdg": {
    "compliance": "none",
    "method": "default"
  },
  "aliases": {},
  "picker": null
}
```

- [ ] **Step 3.2: Remove stale comment from PSFzf.ps1**

Open `Tools/PSFzf.ps1`. Replace lines 1–2:

```powershell
# Companion for PSFzf — import module and configure PSReadLine key bindings
# PSReadline.ps1 must have already removed the default Ctrl+T/R handlers before this runs.
```

With:

```powershell
# Companion for PSFzf — import module and configure PSReadLine key bindings
```

- [ ] **Step 3.3: Run full test suite to confirm no regressions**

```powershell
Invoke-Pester tests/ -Output Detailed
```

Expected: all tests pass.

- [ ] **Step 3.4: Commit**

```powershell
git add Tools/PSFzf.json Tools/PSFzf.ps1
git commit -m "feat: add dependsOn to PSFzf and remove stale comment"
```

---

## Task 4: psreadline.json + Bundled Themes

**Files:**
- Create: `Tools/psreadline.json`
- Create: `Tools/psreadline/dark.json`
- Create: `Tools/psreadline/light.json`
- Create: `Tools/psreadline/catppuccin-mocha.json`

- [ ] **Step 4.1: Create Tools/psreadline.json**

```json
{
  "name": "psreadline",
  "type": "module",
  "description": "Enhanced command-line editing and syntax highlighting for PowerShell",
  "tags": ["readline", "completion", "theme", "module"],
  "executable": "PSReadLine",
  "dependsOn": [],
  "xdg": { "compliance": "none", "method": "default" },
  "settings": {
    "editMode":            "Windows",
    "predictionSource":    "HistoryAndPlugin",
    "predictionViewStyle": "InlineView",
    "bellStyle":           "None",
    "historyNoDuplicates": true,
    "historySaveStyle":    "SaveIncrementally"
  },
  "aliases": {},
  "picker": null
}
```

- [ ] **Step 4.2: Create Tools/psreadline/ directory and dark.json**

```json
{
  "name": "dark",
  "colors": {
    "Command":          "#569cd6",
    "Parameter":        "#9cdcfe",
    "String":           "#ce9178",
    "Operator":         "#d4d4d4",
    "Variable":         "#9cdcfe",
    "Comment":          "#6a9955",
    "Keyword":          "#c586c0",
    "Error":            "#f44747",
    "InlinePrediction": "#4a4a4a",
    "ListPrediction":   "#3794ff"
  }
}
```

- [ ] **Step 4.3: Create Tools/psreadline/light.json**

```json
{
  "name": "light",
  "colors": {
    "Command":          "#0000ff",
    "Parameter":        "#001080",
    "String":           "#a31515",
    "Operator":         "#000000",
    "Variable":         "#001080",
    "Comment":          "#008000",
    "Keyword":          "#0000ff",
    "Error":            "#cd3131",
    "InlinePrediction": "#aaaaaa",
    "ListPrediction":   "#0066bf"
  }
}
```

- [ ] **Step 4.4: Create Tools/psreadline/catppuccin-mocha.json**

```json
{
  "name": "catppuccin-mocha",
  "colors": {
    "Command":          "#cba6f7",
    "Parameter":        "#89dceb",
    "String":           "#a6e3a1",
    "Operator":         "#cdd6f4",
    "Variable":         "#cdd6f4",
    "Comment":          "#585b70",
    "Keyword":          "#f38ba8",
    "Error":            "#f38ba8",
    "InlinePrediction": "#585b70",
    "ListPrediction":   "#89b4fa"
  }
}
```

- [ ] **Step 4.5: Run tests to confirm module still loads cleanly**

```powershell
Invoke-Pester tests/ -Output Detailed
```

Expected: all tests pass.

- [ ] **Step 4.6: Commit**

```powershell
git add Tools/psreadline.json Tools/psreadline/
git commit -m "feat: add psreadline tool entry and bundled themes"
```

---

## Task 5: psreadline.ps1 Sidecar (TDD)

**Files:**
- Create: `tests/psreadline.Tests.ps1`
- Create: `Tools/psreadline.ps1`

- [ ] **Step 5.1: Write failing tests**

Create `tests/psreadline.Tests.ps1`:

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
    . "$PSScriptRoot/../Public/Register-DFTool.ps1"
}

Describe 'psreadline tool sidecar' {
    BeforeEach {
        $script:DFToolDb = $null
        $script:SavedConfigHome = $Env:XDG_CONFIG_HOME
        $Env:XDG_CONFIG_HOME    = Join-Path $TestDrive 'config'

        # Point at the real Tools directory
        $script:RealTools = Join-Path $PSScriptRoot '../Tools'
    }

    AfterEach {
        $Env:XDG_CONFIG_HOME = $script:SavedConfigHome
        $script:DFToolDb     = $null

        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
        Remove-Item 'function:global:Select-PSReadLineTheme'    -ErrorAction Ignore
        Remove-Item 'function:global:Invoke-DFApplyPSReadLineTheme' -ErrorAction Ignore
        Remove-Alias fprl -Scope Global -Force -ErrorAction Ignore
    }

    It 'registers Select-PSReadLineTheme as a global function' {
        Register-DFTool -Name 'psreadline' -ToolsPath $script:RealTools
        Test-Path 'function:global:Select-PSReadLineTheme' | Should -BeTrue
    }

    It 'registers fprl as an alias for Select-PSReadLineTheme' {
        Register-DFTool -Name 'psreadline' -ToolsPath $script:RealTools
        Get-Alias fprl -ErrorAction Ignore | Should -Not -BeNullOrEmpty
    }

    It 'registers Invoke-DFApplyPSReadLineTheme as a global function' {
        Register-DFTool -Name 'psreadline' -ToolsPath $script:RealTools
        Test-Path 'function:global:Invoke-DFApplyPSReadLineTheme' | Should -BeTrue
    }

    It 'applies PSReadLine settings from tool JSON' {
        Register-DFTool -Name 'psreadline' -ToolsPath $script:RealTools
        (Get-PSReadLineOption).BellStyle        | Should -Be 'None'
        (Get-PSReadLineOption).HistoryNoDuplicates | Should -BeTrue
    }

    It 'applies the dark theme by default (Colors.Command is non-null)' {
        Register-DFTool -Name 'psreadline' -ToolsPath $script:RealTools
        (Get-PSReadLineOption).Colors.Command | Should -Not -BeNullOrEmpty
    }

    It 'applies the theme named in $DFConfig[PSReadLineTheme]' {
        $Global:DFConfig = @{ PSReadLineTheme = 'light' }
        Register-DFTool -Name 'psreadline' -ToolsPath $script:RealTools
        # Light theme Command color is #0000ff — VT sequence contains "0;0;255"
        (Get-PSReadLineOption).Colors.Command | Should -Match '0;0;255'
    }

    It 'applies a theme from XDG user dir, overriding bundled name' {
        $userDir = Join-Path $Env:XDG_CONFIG_HOME 'psreadline' 'themes'
        New-Item -ItemType Directory -Force -Path $userDir | Out-Null
        @'
{
  "name": "dark",
  "colors": {
    "Command": "#ff0000",
    "Parameter": "#00ff00",
    "String": "#0000ff",
    "Operator": "#ffffff",
    "Variable": "#00ff00",
    "Comment": "#888888",
    "Keyword": "#ff00ff",
    "Error": "#ff0000",
    "InlinePrediction": "#444444",
    "ListPrediction": "#00ffff"
  }
}
'@ | Set-Content (Join-Path $userDir 'dark.json')

        Register-DFTool -Name 'psreadline' -ToolsPath $script:RealTools
        # User dark overrides bundled: Command = #ff0000 → VT contains "255;0;0"
        (Get-PSReadLineOption).Colors.Command | Should -Match '255;0;0'
    }

    It 'warns and continues when an invalid hex color is in the theme' {
        $Global:DFConfig = @{ PSReadLineTheme = 'badcolors' }
        $userDir = Join-Path $Env:XDG_CONFIG_HOME 'psreadline' 'themes'
        New-Item -ItemType Directory -Force -Path $userDir | Out-Null
        @'
{
  "name": "badcolors",
  "colors": {
    "Command": "notahex",
    "Parameter": "#9cdcfe"
  }
}
'@ | Set-Content (Join-Path $userDir 'badcolors.json')

        { Register-DFTool -Name 'psreadline' -ToolsPath $script:RealTools `
            -WarningVariable w 3>$null } | Should -Not -Throw
    }

    It 'warns when named theme is not found' {
        $Global:DFConfig = @{ PSReadLineTheme = 'nonexistent-theme' }
        Register-DFTool -Name 'psreadline' -ToolsPath $script:RealTools `
            -WarningVariable w 3>$null
        $w | Should -Not -BeNullOrEmpty
    }
}
```

- [ ] **Step 5.2: Run tests to confirm they fail**

```powershell
Invoke-Pester tests/psreadline.Tests.ps1 -Output Detailed
```

Expected: all tests fail (psreadline.ps1 does not exist yet).

- [ ] **Step 5.3: Create Tools/psreadline.ps1**

```powershell
# Companion for psreadline — apply settings, theme, and register theme picker (fprl)

# 1. Apply settings from tool JSON
$_settings = $DFCurrentTool.PSObject.Properties['settings']?.Value
if ($_settings) {
    $_settingsMap = @{
        editMode            = 'EditMode'
        predictionSource    = 'PredictionSource'
        predictionViewStyle = 'PredictionViewStyle'
        bellStyle           = 'BellStyle'
        historyNoDuplicates = 'HistoryNoDuplicates'
        historySaveStyle    = 'HistorySaveStyle'
    }
    $_optionArgs = @{}
    $_settings.PSObject.Properties | ForEach-Object {
        $_param = $_settingsMap[$_.Name]
        if ($_param) {
            $_optionArgs[$_param] = $_.Value
        } else {
            Write-Warning "DotForge: unknown PSReadLine setting '$($_.Name)' — skipping"
        }
    }
    if ($_optionArgs.Count -gt 0) {
        Set-PSReadLineOption @_optionArgs
    }
}

# 2. Register Invoke-DFApplyPSReadLineTheme (captures $PSScriptRoot via closure)
$_bundledDir = Join-Path $PSScriptRoot 'psreadline'

Set-Item -Path 'function:global:Invoke-DFApplyPSReadLineTheme' -Value ({
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    # Resolve path: absolute path passthrough, XDG user dir, then bundled
    $path = $null
    if ([System.IO.Path]::IsPathRooted($Name)) {
        $path = $Name
    } else {
        if ($Env:XDG_CONFIG_HOME) {
            $p = Join-Path $Env:XDG_CONFIG_HOME 'psreadline' 'themes' "$Name.json"
            if (Test-Path $p) { $path = $p }
        }
        if (-not $path) {
            $p = Join-Path $_bundledDir "$Name.json"
            if (Test-Path $p) { $path = $p }
        }
    }
    if (-not $path) {
        Write-Warning "DotForge: PSReadLine theme '$Name' not found"
        return
    }

    $theme  = Get-Content $path -Raw | ConvertFrom-Json
    $colors = @{}
    $theme.colors.PSObject.Properties | ForEach-Object {
        $hex = $_.Value
        if ($hex -match '^#[0-9A-Fa-f]{6}$') {
            $r = [Convert]::ToInt32($hex.Substring(1, 2), 16)
            $g = [Convert]::ToInt32($hex.Substring(3, 2), 16)
            $b = [Convert]::ToInt32($hex.Substring(5, 2), 16)
            $colors[$_.Name] = "`e[38;2;${r};${g};${b}m"
        } else {
            Write-Warning "DotForge: invalid color '$hex' for token '$($_.Name)' — skipping"
        }
    }
    if ($colors.Count -gt 0) {
        Set-PSReadLineOption -Colors $colors
    }
}.GetNewClosure())

# 3. Apply initial theme
$_themeSetting = $null
if ($null -ne (Get-Variable -Name DFConfig -Scope Global -ErrorAction Ignore)) {
    $_themeSetting = $Global:DFConfig['PSReadLineTheme']
}
Invoke-DFApplyPSReadLineTheme -Name ($_themeSetting ?? 'dark')

# 4. Register theme picker
Set-Item -Path 'function:global:Select-PSReadLineTheme' -Value ({
    [CmdletBinding()]
    param()

    $themes = [System.Collections.Generic.List[string]]::new()
    $seen   = [System.Collections.Generic.HashSet[string]]::new(
                  [System.StringComparer]::OrdinalIgnoreCase)

    if ($Env:XDG_CONFIG_HOME) {
        $userDir = Join-Path $Env:XDG_CONFIG_HOME 'psreadline' 'themes'
        if (Test-Path $userDir) {
            Get-ChildItem $userDir -Filter '*.json' | Sort-Object Name | ForEach-Object {
                if ($seen.Add($_.BaseName)) { $themes.Add($_.BaseName) }
            }
        }
    }
    if (Test-Path $_bundledDir) {
        Get-ChildItem $_bundledDir -Filter '*.json' | Sort-Object Name | ForEach-Object {
            if ($seen.Add($_.BaseName)) { $themes.Add($_.BaseName) }
        }
    }
    if ($themes.Count -eq 0) {
        Write-Warning 'DotForge: no PSReadLine themes found'
        return
    }

    Invoke-DFPicker `
        -List   { $themes }.GetNewClosure() `
        -Header 'Select PSReadLine theme  [Enter to apply for this session]' `
        -Action {
            param($n)
            Invoke-DFApplyPSReadLineTheme -Name $n
            Write-Host "Theme applied: $n  (to persist: set `$Global:DFConfig['PSReadLineTheme'] = '$n')" -ForegroundColor Green
        }
}.GetNewClosure())
Set-Alias -Name fprl -Value Select-PSReadLineTheme -Scope Global -Force
```

- [ ] **Step 5.4: Run tests to confirm they pass**

```powershell
Invoke-Pester tests/psreadline.Tests.ps1 -Output Detailed
```

Expected: all 8 tests pass.

- [ ] **Step 5.5: Run full test suite to check for regressions**

```powershell
Invoke-Pester tests/ -Output Detailed
```

Expected: all tests pass.

- [ ] **Step 5.6: Commit**

```powershell
git add Tools/psreadline.ps1 tests/psreadline.Tests.ps1
git commit -m "feat: add psreadline sidecar with settings, theme, and fprl picker"
```

---

## Task 6: CLAUDE.md + Final Verification

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 6.1: Add three entries to Key Design Decisions in CLAUDE.md**

In `CLAUDE.md`, at the end of the `## Key Design Decisions` section, append:

```markdown
- **`dependsOn` ordering**: Any tool JSON may declare `"dependsOn": ["othertool"]`. `Register-DFTool` calls `Invoke-DFTopoSort` (private, `Private/Invoke-DFTopoSort.ps1`) to sort the registration list using Kahn's algorithm before iterating. Dependencies outside the current registration set are skipped silently. Cycles emit `Write-Warning` and fall back to original order.
- **`$DFCurrentTool` sidecar contract**: `Register-DFTool` sets `$DFCurrentTool = $tool` immediately before dot-sourcing a companion `.ps1` and clears it after. Sidecars may read `$DFCurrentTool.settings` and other fields. Existing sidecars that do not reference `$DFCurrentTool` are unaffected.
- **PSReadLine + PSFzf ordering**: PSFzf declares `"dependsOn": ["psreadline"]`. `psreadline.ps1` runs first and applies `Set-PSReadLineOption` settings + theme. PSFzf then overlays its key bindings via `Set-PsFzfOption`. Each tool owns only what it touches — psreadline.ps1 does NOT remove PSFzf's key handlers. Sidecar companions that need their own subdirectory (e.g., bundled themes in `Tools/psreadline/`) use `$PSScriptRoot`, which resolves to `Tools/` at dot-source time.
```

- [ ] **Step 6.2: Run full test suite one final time**

```powershell
Invoke-Pester tests/ -Output Detailed
```

Expected: all tests pass.

- [ ] **Step 6.3: Smoke-test manually in a real shell**

```powershell
# From a pwsh -NoProfile session:
Import-Module ./DotForge.psd1 -Force

# Register psreadline then PSFzf
Register-DFTool -Name psreadline, PSFzf -Verbose

# Verify PSReadLine settings
(Get-PSReadLineOption).EditMode              # → Windows
(Get-PSReadLineOption).PredictionSource      # → HistoryAndPlugin
(Get-PSReadLineOption).BellStyle             # → None
(Get-PSReadLineOption).HistoryNoDuplicates   # → True

# Verify default theme applied
(Get-PSReadLineOption).Colors.Command        # → non-null VT string

# Verify picker
Get-Command Select-PSReadLineTheme           # → GlobalFunction
Get-Alias fprl                               # → Select-PSReadLineTheme
Get-Command Invoke-DFApplyPSReadLineTheme    # → GlobalFunction

# Test catppuccin-mocha via $DFConfig
$Global:DFConfig = @{ PSReadLineTheme = 'catppuccin-mocha' }
Register-DFTool -Name psreadline -Verbose
(Get-PSReadLineOption).Colors.Command        # → VT string containing catppuccin purple

# Test -All respects ordering (psreadline before PSFzf in verbose output)
Register-DFTool -All -Verbose 2>&1 | Select-String 'registered'
```

- [ ] **Step 6.4: Update README.md**

Add `PSReadLine` to the Included Tools table in `README.md` and note the `dependsOn` schema field in the Tool JSON Schema section.

- [ ] **Step 6.5: Commit**

```powershell
git add CLAUDE.md README.md
git commit -m "docs: document dependsOn, DFCurrentTool, and PSReadLine integration"
```
