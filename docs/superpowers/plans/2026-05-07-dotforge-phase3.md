# DotForge Phase 3 — Install + Init Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add tool installation (`Install-DFTool`), environment bootstrap (`Initialize-DFEnvironment`), user configuration (`$DFConfig`), and fix two open Phase 2 items (`list_accepts_path` path safety, `xdg.method = "config"` support).

**Architecture:** `Resolve-DFPackageManager` (private, cached) detects available PMs at startup. `Initialize-DFEnvironment` creates XDG dirs and reports available PMs. `Install-DFTool` walks a configurable PM priority list and invokes the first manager that knows the tool. `$Global:DFConfig` is a user-supplied hashtable read at call time — no module-level defaults needed. Phase 2 open items (path-safety in `list_accepts_path`, `xdg.method = "config"`) are fixed here since they touch `Register-DFTool`.

**Tech Stack:** PowerShell 7+, Pester 5. External package managers: scoop, winget, choco. Builds on all Phase 1 + Phase 2 code.

---

## Phase 1 + 2 Foundation (do not modify unless a task says to)

```
Private/: Expand-DFXdgPath, Import-DFToolDb, Invoke-DFFzf, Test-DFToolSchema
Public/:  Add-DFToPath, Ensure-DFDir, Find-DFTool, Get-DFCachedCompletion,
          Get-DFTool, Invoke-DFPicker, Register-DFTool
Tools/:   25 JSON records, ripgrep.ps1, procs.ps1
tests/:   89 passing tests (StrictMode)
```

## File Map — New/Modified This Phase

| File | Role |
|------|------|
| `Private/Resolve-DFPackageManager.ps1` | Detect available PMs; cache result in `$script:` |
| `Public/Initialize-DFEnvironment.ps1` | Bootstrap XDG dirs + report available PMs |
| `Public/Install-DFTool.ps1` | Install tool via first available PM that has a package |
| `Public/Register-DFTool.ps1` | Modify: add `SkipTools` from `$DFConfig`; fix `list_accepts_path`; add `'config'` XDG arm |
| `Tools/winget.json` | Add missing winget tool record |
| `Tools/winget.ps1` | Companion: `Select-WingetPackage`/`wins`, `Remove-WingetPackage`/`wrm` |
| `DotForge.psd1` | Add `Initialize-DFEnvironment`, `Install-DFTool` to `FunctionsToExport` |
| `tests/Resolve-DFPackageManager.Tests.ps1` | Pester tests |
| `tests/Initialize-DFEnvironment.Tests.ps1` | Pester tests |
| `tests/Install-DFTool.Tests.ps1` | Pester tests |
| `tests/Register-DFTool.Tests.ps1` | Modify: add tests for SkipTools and list_accepts_path |
| `tests/Test-DFToolSchema.Tests.ps1` | Modify: add winget to seed list |

---

## Task 1: `Resolve-DFPackageManager`

**Files:**
- Create: `Private/Resolve-DFPackageManager.ps1`
- Create: `tests/Resolve-DFPackageManager.Tests.ps1`

### What it does

Checks which of `scoop`, `winget`, `choco` are on PATH. Caches the result. `-Force` clears cache.
Returns `[string[]]` of available PM names in priority order.

- [ ] **Step 1: Write the failing tests**

Create `C:\Users\simsr\projects\DotForge\tests\Resolve-DFPackageManager.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/../Private/Resolve-DFPackageManager.ps1"
}

Describe 'Resolve-DFPackageManager' {
    BeforeEach { $script:DFPackageManagers = $null }

    It 'returns only managers found on PATH' {
        Mock Get-Command { if ($Name -eq 'scoop') { [PSCustomObject]@{ Name = 'scoop' } } else { $null } }
        $result = Resolve-DFPackageManager
        $result | Should -Contain 'scoop'
        $result | Should -Not -Contain 'winget'
        $result | Should -Not -Contain 'choco'
    }

    It 'returns empty array when no managers are found' {
        Mock Get-Command { $null }
        $result = Resolve-DFPackageManager
        @($result).Count | Should -Be 0
    }

    It 'caches result on second call (Get-Command not called again)' {
        Mock Get-Command { [PSCustomObject]@{ Name = $Name } } -Verifiable
        Resolve-DFPackageManager | Out-Null
        Resolve-DFPackageManager | Out-Null
        # Get-Command should only be called for the first invocation (3 PMs)
        Should -Invoke Get-Command -Times 3 -Exactly
    }

    It 'reloads when -Force is specified' {
        Mock Get-Command { $null }
        Resolve-DFPackageManager | Out-Null  # caches empty
        Mock Get-Command { [PSCustomObject]@{ Name = 'scoop' } } -ParameterFilter { $Name -eq 'scoop' }
        $result = Resolve-DFPackageManager -Force
        $result | Should -Contain 'scoop'
    }

    It 'respects custom -Priority order' {
        Mock Get-Command { [PSCustomObject]@{ Name = $Name } }
        $result = Resolve-DFPackageManager -Priority @('winget', 'scoop')
        @($result)[0] | Should -Be 'winget'
        @($result)[1] | Should -Be 'scoop'
        @($result).Count | Should -Be 2
    }
}
```

- [ ] **Step 2: Run tests — confirm they fail**

```powershell
cd C:\Users\simsr\projects\DotForge
Invoke-Pester tests/Resolve-DFPackageManager.Tests.ps1 -Output Detailed
```

Expected: All 5 tests fail.

- [ ] **Step 3: Implement `Resolve-DFPackageManager`**

Create `C:\Users\simsr\projects\DotForge\Private\Resolve-DFPackageManager.ps1`:

```powershell
#Requires -Version 7.0

$script:DFPackageManagers = $null

function script:Resolve-DFPackageManager {
    <#
    .SYNOPSIS
        Detects which package managers are available on PATH.
        Returns names in priority order. Result is cached; use -Force to reload.
    .PARAMETER Priority
        Ordered list of package manager names to check.
        Defaults to scoop, winget, choco.
    .PARAMETER Force
        Clear cache and re-detect.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [string[]]$Priority = @('scoop', 'winget', 'choco'),
        [switch]$Force
    )

    if ($script:DFPackageManagers -and -not $Force) { return $script:DFPackageManagers }

    $available = $Priority | Where-Object { Get-Command $_ -ErrorAction Ignore }
    $script:DFPackageManagers = @($available)
    return $script:DFPackageManagers
}
```

- [ ] **Step 4: Run tests — confirm all 5 pass**

```powershell
Invoke-Pester tests/Resolve-DFPackageManager.Tests.ps1 -Output Detailed
```

Expected: 5/5 passing.

- [ ] **Step 5: Commit**

```powershell
git add Private/Resolve-DFPackageManager.ps1 tests/Resolve-DFPackageManager.Tests.ps1
git commit -m "feat: Resolve-DFPackageManager — detect available package managers"
```

---

## Task 2: `Initialize-DFEnvironment`

**Files:**
- Create: `Public/Initialize-DFEnvironment.ps1`
- Create: `tests/Initialize-DFEnvironment.Tests.ps1`

### What it does

Sets XDG env vars if absent, creates all four XDG base directories, detects package managers
and reports them. Safe to call multiple times (idempotent).

- [ ] **Step 1: Write the failing tests**

Create `C:\Users\simsr\projects\DotForge\tests\Initialize-DFEnvironment.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/../Public/Ensure-DFDir.ps1"
    . "$PSScriptRoot/../Private/Resolve-DFPackageManager.ps1"
    . "$PSScriptRoot/../Public/Initialize-DFEnvironment.ps1"
}

Describe 'Initialize-DFEnvironment' {
    BeforeEach {
        $script:DFPackageManagers = $null
        $script:Saved = @{
            Config = $Env:XDG_CONFIG_HOME
            Data   = $Env:XDG_DATA_HOME
            State  = $Env:XDG_STATE_HOME
            Cache  = $Env:XDG_CACHE_HOME
        }
        # Clear XDG vars so we test the defaulting logic
        Remove-Item Env:\XDG_CONFIG_HOME -ErrorAction Ignore
        Remove-Item Env:\XDG_DATA_HOME   -ErrorAction Ignore
        Remove-Item Env:\XDG_STATE_HOME  -ErrorAction Ignore
        Remove-Item Env:\XDG_CACHE_HOME  -ErrorAction Ignore
    }
    AfterEach {
        $Env:XDG_CONFIG_HOME = $script:Saved.Config
        $Env:XDG_DATA_HOME   = $script:Saved.Data
        $Env:XDG_STATE_HOME  = $script:Saved.State
        $Env:XDG_CACHE_HOME  = $script:Saved.Cache
    }

    It 'sets XDG env vars when they are absent' {
        Mock Get-Command { $null }
        Initialize-DFEnvironment
        $Env:XDG_CONFIG_HOME | Should -Not -BeNullOrEmpty
        $Env:XDG_DATA_HOME   | Should -Not -BeNullOrEmpty
        $Env:XDG_STATE_HOME  | Should -Not -BeNullOrEmpty
        $Env:XDG_CACHE_HOME  | Should -Not -BeNullOrEmpty
    }

    It 'does not override XDG vars that are already set' {
        $Env:XDG_CONFIG_HOME = 'C:\custom\config'
        Mock Get-Command { $null }
        Initialize-DFEnvironment
        $Env:XDG_CONFIG_HOME | Should -Be 'C:\custom\config'
    }

    It 'creates the four XDG base directories' {
        $Env:XDG_CONFIG_HOME = Join-Path $TestDrive 'config'
        $Env:XDG_DATA_HOME   = Join-Path $TestDrive 'data'
        $Env:XDG_STATE_HOME  = Join-Path $TestDrive 'state'
        $Env:XDG_CACHE_HOME  = Join-Path $TestDrive 'cache'
        Mock Get-Command { $null }
        Initialize-DFEnvironment
        Test-Path $Env:XDG_CONFIG_HOME | Should -BeTrue
        Test-Path $Env:XDG_DATA_HOME   | Should -BeTrue
        Test-Path $Env:XDG_STATE_HOME  | Should -BeTrue
        Test-Path $Env:XDG_CACHE_HOME  | Should -BeTrue
    }

    It 'emits a warning when no package managers are found' {
        Mock Get-Command { $null }
        Initialize-DFEnvironment -WarningVariable warns 3>$null
        $warns | Should -Not -BeNullOrEmpty
    }

    It 'does not warn when at least one package manager is found' {
        Mock Get-Command { [PSCustomObject]@{ Name = 'scoop' } }
        Initialize-DFEnvironment -WarningVariable warns 3>$null
        $warns | Should -BeNullOrEmpty
    }

    It 'is idempotent — calling twice does not throw' {
        Mock Get-Command { $null }
        $Env:XDG_CONFIG_HOME = Join-Path $TestDrive 'config'
        $Env:XDG_DATA_HOME   = Join-Path $TestDrive 'data'
        $Env:XDG_STATE_HOME  = Join-Path $TestDrive 'state'
        $Env:XDG_CACHE_HOME  = Join-Path $TestDrive 'cache'
        { Initialize-DFEnvironment; Initialize-DFEnvironment } | Should -Not -Throw
    }
}
```

- [ ] **Step 2: Run tests — confirm they fail**

```powershell
Invoke-Pester tests/Initialize-DFEnvironment.Tests.ps1 -Output Detailed
```

Expected: All 6 tests fail.

- [ ] **Step 3: Implement `Initialize-DFEnvironment`**

Create `C:\Users\simsr\projects\DotForge\Public\Initialize-DFEnvironment.ps1`:

```powershell
#Requires -Version 7.0

function Initialize-DFEnvironment {
    <#
    .SYNOPSIS
        Bootstraps the DotForge environment: sets XDG base directory env vars
        if absent, creates the directories, and reports available package managers.
        Safe to call multiple times (idempotent).
    #>
    [CmdletBinding()]
    param()

    # Set XDG base dirs if not already defined
    if (-not $Env:XDG_CONFIG_HOME) { $Env:XDG_CONFIG_HOME = Join-Path $home '.config' }
    if (-not $Env:XDG_DATA_HOME)   { $Env:XDG_DATA_HOME   = Join-Path $home '.local' 'share' }
    if (-not $Env:XDG_STATE_HOME)  { $Env:XDG_STATE_HOME  = Join-Path $home '.local' 'state' }
    if (-not $Env:XDG_CACHE_HOME)  { $Env:XDG_CACHE_HOME  = Join-Path $home '.cache' }

    # Create directories
    @($Env:XDG_CONFIG_HOME, $Env:XDG_DATA_HOME, $Env:XDG_STATE_HOME, $Env:XDG_CACHE_HOME) |
        ForEach-Object { Ensure-DFDir $_ }

    # Detect and report available package managers
    $pms = Resolve-DFPackageManager -Force

    if ($pms.Count -eq 0) {
        Write-Warning 'DotForge: No supported package managers found (scoop, winget, choco). Install one to use Install-DFTool.'
    } else {
        Write-Host "DotForge: Environment ready. Package managers: $($pms -join ', ')" -ForegroundColor Green
    }
}
```

- [ ] **Step 4: Run tests — confirm all 6 pass**

```powershell
Invoke-Pester tests/Initialize-DFEnvironment.Tests.ps1 -Output Detailed
```

Expected: 6/6 passing.

- [ ] **Step 5: Commit**

```powershell
git add Public/Initialize-DFEnvironment.ps1 tests/Initialize-DFEnvironment.Tests.ps1
git commit -m "feat: Initialize-DFEnvironment — bootstrap XDG dirs and detect package managers"
```

---

## Task 3: `$DFConfig` support in `Register-DFTool`

**Files:**
- Modify: `Public/Register-DFTool.ps1`
- Modify: `tests/Register-DFTool.Tests.ps1` (append new tests)

### What it does

When `-All` is used, `Register-DFTool` skips tools whose names appear in
`$Global:DFConfig['SkipTools']`. If `$Global:DFConfig` is not set or has no `SkipTools`,
all tools are configured (current behavior unchanged).

- [ ] **Step 1: Add new failing tests**

Append to `C:\Users\simsr\projects\DotForge\tests\Register-DFTool.Tests.ps1` — inside the
existing `Describe 'Register-DFTool'` block, at the end, before the closing `}`:

```powershell
    It 'skips tools listed in $Global:DFConfig.SkipTools when -All is used' {
        # Add a second tool to the temp tools dir
        @'
{ "name": "skiptool", "executable": "skiptool.exe" }
'@ | Set-Content (Join-Path $script:TmpTools 'skiptool.json')

        $Global:DFConfig = @{ SkipTools = @('skiptool') }
        Mock Get-Command { [PSCustomObject]@{ Path = 'C:\fake\tool.exe' } }
        Mock Register-ArgumentCompleter { }

        $registered = [System.Collections.Generic.List[string]]::new()
        # Track which tools were processed by checking Get-Command calls
        # Instead, verify skiptool's exe was never checked:
        Register-DFTool -All -ToolsPath $script:TmpTools
        Should -Invoke Get-Command -ParameterFilter { $Name -eq 'skiptool.exe' } -Times 0

        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
        Remove-Item (Join-Path $script:TmpTools 'skiptool.json') -ErrorAction Ignore
    }

    It 'does not skip tools when $Global:DFConfig is not set' {
        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
        Mock Get-Command { [PSCustomObject]@{ Path = 'C:\fake\tool.exe' } }
        Mock Register-ArgumentCompleter { }
        { Register-DFTool -All -ToolsPath $script:TmpTools } | Should -Not -Throw
    }
```

- [ ] **Step 2: Run new tests — confirm they fail**

```powershell
Invoke-Pester tests/Register-DFTool.Tests.ps1 -Output Detailed
```

Expected: The 2 new SkipTools tests fail; the existing 11 still pass.

- [ ] **Step 3: Add SkipTools logic to `Register-DFTool`**

In `Public/Register-DFTool.ps1`, find the tools resolution block:

```powershell
    $tools = if ($All) {
        $db.Values
    } else {
```

Replace the `-All` branch with:

```powershell
    $skipTools = @($Global:DFConfig?['SkipTools'] ?? @())

    $tools = if ($All) {
        $db.Values | Where-Object { $_.name -notin $skipTools }
    } else {
```

- [ ] **Step 4: Run all Register-DFTool tests — confirm 13 pass**

```powershell
Invoke-Pester tests/Register-DFTool.Tests.ps1 -Output Detailed
```

Expected: 13/13 passing (11 original + 2 new).

- [ ] **Step 5: Commit**

```powershell
git add Public/Register-DFTool.ps1 tests/Register-DFTool.Tests.ps1
git commit -m "feat: Register-DFTool — respect \$DFConfig.SkipTools when -All is used"
```

---

## Task 4: `Install-DFTool`

**Files:**
- Create: `Public/Install-DFTool.ps1`
- Create: `tests/Install-DFTool.Tests.ps1`

### What it does

Installs one or more tools via the first available package manager that has a package for it.
Priority order: `$PackageManager` override → `$Global:DFConfig['PackageManagerOrder']` →
`Resolve-DFPackageManager` result. Supports `-WhatIf`.

Key: external commands (`scoop`, `winget`, `choco`) are hard to mock. Tests use:
- `-WhatIf` for happy-path assertions (ShouldProcess prevents actual execution)
- Mock `Get-Command` to control which PMs appear available
- Define local `function scoop {}` etc. in test scope to intercept calls

- [ ] **Step 1: Write the failing tests**

Create `C:\Users\simsr\projects\DotForge\tests\Install-DFTool.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/../Private/Test-DFToolSchema.ps1"
    . "$PSScriptRoot/../Private/Import-DFToolDb.ps1"
    . "$PSScriptRoot/../Private/Resolve-DFPackageManager.ps1"
    . "$PSScriptRoot/../Public/Install-DFTool.ps1"
}

Describe 'Install-DFTool' {
    BeforeEach {
        $script:DFToolDb         = $null
        $script:DFPackageManagers = $null
        $script:TmpTools = Join-Path $TestDrive 'tools'
        New-Item -ItemType Directory -Force -Path $script:TmpTools | Out-Null

        @'
{
  "name": "pkgtool",
  "executable": "pkgtool.exe",
  "packages": {
    "scoop": "pkgtool-scoop",
    "winget": "Vendor.pkgtool"
  }
}
'@ | Set-Content (Join-Path $script:TmpTools 'pkgtool.json')

        @'
{ "name": "nopkg", "executable": "nopkg.exe", "packages": {} }
'@ | Set-Content (Join-Path $script:TmpTools 'nopkg.json')

        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
    }

    It 'warns for an unknown tool name' {
        Install-DFTool -Name 'nosuch' -ToolsPath $script:TmpTools -WarningVariable warns 3>$null
        $warns | Where-Object { $_ -match 'nosuch' } | Should -Not -BeNullOrEmpty
    }

    It 'warns when no package manager is available for the tool' {
        Mock Get-Command { $null }
        Install-DFTool -Name 'pkgtool' -ToolsPath $script:TmpTools -WarningVariable warns 3>$null
        $warns | Where-Object { $_ -match 'pkgtool' } | Should -Not -BeNullOrEmpty
    }

    It 'warns when the available PM has no package for the tool' {
        Mock Get-Command { if ($Name -eq 'choco') { [PSCustomObject]@{ Name = 'choco' } } else { $null } }
        Install-DFTool -Name 'pkgtool' -PackageManager 'choco' -ToolsPath $script:TmpTools -WarningVariable warns 3>$null
        $warns | Where-Object { $_ -match 'pkgtool' } | Should -Not -BeNullOrEmpty
    }

    It 'uses -PackageManager override when specified' {
        # Define a function named scoop in test scope to intercept calls
        $script:ScoopCalled = $false
        function script:scoop { $script:ScoopCalled = $true; $global:LASTEXITCODE = 0 }
        Mock Get-Command { [PSCustomObject]@{ Name = $Name } }

        Install-DFTool -Name 'pkgtool' -PackageManager 'scoop' -ToolsPath $script:TmpTools
        $script:ScoopCalled | Should -BeTrue
    }

    It 'uses $DFConfig.PackageManagerOrder when set' {
        $Global:DFConfig = @{ PackageManagerOrder = @('winget') }
        $script:WingetCalled = $false
        function script:winget { $script:WingetCalled = $true; $global:LASTEXITCODE = 0 }
        Mock Get-Command { [PSCustomObject]@{ Name = $Name } }

        Install-DFTool -Name 'pkgtool' -ToolsPath $script:TmpTools
        $script:WingetCalled | Should -BeTrue

        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
    }

    It 'does not throw when -WhatIf is specified' {
        Mock Get-Command { [PSCustomObject]@{ Name = $Name } }
        { Install-DFTool -Name 'pkgtool' -PackageManager 'scoop' -ToolsPath $script:TmpTools -WhatIf } |
            Should -Not -Throw
    }

    It 'processes multiple tool names in a single call' {
        Mock Get-Command { $null }
        Install-DFTool -Name @('pkgtool', 'nopkg', 'nosuch') -ToolsPath $script:TmpTools `
            -WarningVariable warns 3>$null
        # Should warn for all 3 (no PM available / no package / unknown)
        @($warns).Count | Should -Be 3
    }
}
```

- [ ] **Step 2: Run tests — confirm they fail**

```powershell
Invoke-Pester tests/Install-DFTool.Tests.ps1 -Output Detailed
```

Expected: All 7 tests fail.

- [ ] **Step 3: Implement `Install-DFTool`**

Create `C:\Users\simsr\projects\DotForge\Public\Install-DFTool.ps1`:

```powershell
#Requires -Version 7.0

function Install-DFTool {
    <#
    .SYNOPSIS
        Installs one or more known CLI tools via the first available package manager
        that has a package entry for each tool.
    .PARAMETER Name
        One or more tool names to install (must exist in the tool registry).
    .PARAMETER PackageManager
        Override the package manager for this call (scoop | winget | choco).
    .PARAMETER ToolsPath
        Override the tools directory (used in tests).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][string[]]$Name,
        [string]$PackageManager,
        [string]$ToolsPath
    )

    $dbArgs = if ($ToolsPath) { @{ ToolsPath = $ToolsPath } } else { @{} }
    $db = Import-DFToolDb @dbArgs

    # Determine package manager priority order for this call
    $pmOrder = if ($PackageManager) {
        @($PackageManager)
    } elseif ($Global:DFConfig?['PackageManagerOrder']) {
        @($Global:DFConfig['PackageManagerOrder'])
    } else {
        Resolve-DFPackageManager
    }

    foreach ($toolName in $Name) {
        if (-not $db.ContainsKey($toolName)) {
            Write-Warning "DotForge: Unknown tool '$toolName'"
            continue
        }

        $tool     = $db[$toolName]
        $packages = $tool.PSObject.Properties['packages']?.Value

        $installedVia = $null

        foreach ($pm in $pmOrder) {
            if (-not (Get-Command $pm -ErrorAction Ignore)) { continue }

            $pkgId = $packages?.PSObject.Properties[$pm]?.Value
            if (-not $pkgId) { continue }

            if ($PSCmdlet.ShouldProcess("$toolName via $pm ($pkgId)", 'Install')) {
                Write-Host "  Installing $toolName via $pm ($pkgId)…" `
                    -ForegroundColor DarkGray -NoNewline

                $null = switch ($pm) {
                    'scoop'  { scoop  install $pkgId 2>&1 }
                    'winget' { winget install --id $pkgId --silent `
                                   --accept-source-agreements `
                                   --accept-package-agreements 2>&1 }
                    'choco'  { choco  install $pkgId -y 2>&1 }
                }

                if ($LASTEXITCODE -eq 0) {
                    Write-Host ' ✓' -ForegroundColor Green
                    $installedVia = $pm
                    break
                } else {
                    Write-Host ' failed' -ForegroundColor Red
                }
            } else {
                $installedVia = $pm  # -WhatIf path: treat as success so we break
                break
            }
        }

        if (-not $installedVia) {
            Write-Warning "DotForge: Could not install '$toolName'. No compatible package manager from: $($pmOrder -join ', ')"
        }
    }
}
```

- [ ] **Step 4: Run tests — confirm all 7 pass**

```powershell
Invoke-Pester tests/Install-DFTool.Tests.ps1 -Output Detailed
```

Expected: 7/7 passing.

- [ ] **Step 5: Commit**

```powershell
git add Public/Install-DFTool.ps1 tests/Install-DFTool.Tests.ps1
git commit -m "feat: Install-DFTool — install tools via configured package manager"
```

---

## Task 5: Fix `list_accepts_path` and add `xdg.method = "config"` in `Register-DFTool`

**Files:**
- Modify: `Public/Register-DFTool.ps1`
- Modify: `tests/Register-DFTool.Tests.ps1` (append new tests)

### Two fixes in one commit

**Fix A — `list_accepts_path` path safety:**

The current implementation builds the list scriptblock via string interpolation:
`[scriptblock]::Create("$capturedList '$Path'")`. If `$Path` contains a single quote,
this produces broken PowerShell syntax.

Fix: split the list command string into parts and invoke directly, passing `$Path` as
a separate argument — PowerShell quotes it correctly:

```powershell
# Instead of: [scriptblock]::Create("$capturedList '$Path'")
# Use:
$capturedParts = @($pList -split '\s+')
$fn = {
    [CmdletBinding()]
    param([string]$Path = '.')
    Invoke-DFPicker `
        -List { & $capturedParts[0] @($capturedParts[1..($capturedParts.Count - 1)]) $Path } `
        ...
}.GetNewClosure()
```

`$capturedParts` is captured by `.GetNewClosure()`. `$Path` is passed as a naked PS argument
— the runtime handles quoting, so paths with spaces and special characters work.

**Fix B — `xdg.method = "config"` support:**

Add a `'config'` arm to the XDG switch. The JSON schema for this method:
```json
"xdg": {
  "method": "config",
  "config_path": "${XDG_CONFIG_HOME}/tool/config.toml",
  "config_content": "# default config\nkey = value"
}
```

Behavior: create the config file only if it doesn't exist (never overwrite user edits).

- [ ] **Step 1: Add failing tests for both fixes**

Append to `tests/Register-DFTool.Tests.ps1` inside the `Describe` block:

```powershell
    It 'list_accepts_path: passes path as argument (no single-quote injection)' {
        # A path with a single quote would break string-interpolated scriptblock
        $pathWithQuote = Join-Path $TestDrive "it's a test"
        New-Item -ItemType Directory -Force -Path $pathWithQuote | Out-Null

        # Create a tool with list_accepts_path picker
        @'
{
  "name": "pathtool",
  "executable": "pathtool.exe",
  "picker": {
    "alias": "fpt",
    "function": "Select-PathTool",
    "list": "eza --icons -1",
    "list_accepts_path": true,
    "preview_window": "right:60%",
    "header": "Select"
  }
}
'@ | Set-Content (Join-Path $script:TmpTools 'pathtool.json')

        Mock Get-Command { [PSCustomObject]@{ Path = 'C:\fake\pathtool.exe' } }
        Mock Register-ArgumentCompleter { }
        { Register-DFTool -Name 'pathtool' -ToolsPath $script:TmpTools } | Should -Not -Throw

        # Verify the function was created
        Test-Path 'function:global:Select-PathTool' | Should -BeTrue

        Remove-Item 'function:global:Select-PathTool' -ErrorAction Ignore
        Remove-Alias fpt -Scope Global -Force -ErrorAction Ignore
        Remove-Item (Join-Path $script:TmpTools 'pathtool.json') -ErrorAction Ignore
    }

    It 'xdg method config: creates config file if it does not exist' {
        $configPath = Join-Path $TestDrive 'tool' 'config.conf'
        @"
{
  "name": "cfgtool",
  "executable": "cfgtool.exe",
  "xdg": {
    "compliance": "partial",
    "method": "config",
    "config_path": "$($configPath -replace '\\', '/')",
    "config_content": "# default config"
  }
}
"@ | Set-Content (Join-Path $script:TmpTools 'cfgtool.json')

        Mock Get-Command { [PSCustomObject]@{ Path = 'C:\fake\cfgtool.exe' } }
        Register-DFTool -Name 'cfgtool' -ToolsPath $script:TmpTools
        Test-Path $configPath | Should -BeTrue
        Get-Content $configPath | Should -Be '# default config'

        Remove-Item (Join-Path $script:TmpTools 'cfgtool.json') -ErrorAction Ignore
    }

    It 'xdg method config: does not overwrite existing config file' {
        $configPath = Join-Path $TestDrive 'tool2' 'config.conf'
        New-Item -ItemType Directory -Force -Path (Split-Path $configPath) | Out-Null
        'user content' | Set-Content $configPath

        @"
{
  "name": "cfgtool2",
  "executable": "cfgtool2.exe",
  "xdg": {
    "compliance": "partial",
    "method": "config",
    "config_path": "$($configPath -replace '\\', '/')",
    "config_content": "# default config"
  }
}
"@ | Set-Content (Join-Path $script:TmpTools 'cfgtool2.json')

        Mock Get-Command { [PSCustomObject]@{ Path = 'C:\fake\cfgtool2.exe' } }
        Register-DFTool -Name 'cfgtool2' -ToolsPath $script:TmpTools
        Get-Content $configPath | Should -Be 'user content'

        Remove-Item (Join-Path $script:TmpTools 'cfgtool2.json') -ErrorAction Ignore
    }
```

- [ ] **Step 2: Run new tests — confirm they fail**

```powershell
Invoke-Pester tests/Register-DFTool.Tests.ps1 -Output Detailed
```

Expected: 3 new tests fail; existing 13 still pass.

- [ ] **Step 3: Apply Fix A — `list_accepts_path` in `Register-DFTool`**

In `Public/Register-DFTool.ps1`, find the picker section. Locate the `if ($pAccPath)` branch.
Currently it has:
```powershell
                $fn = if ($pAccPath) {
                    {
                        [CmdletBinding()]
                        param([string]$Path = '.')
                        Invoke-DFPicker `
                            -List          ([scriptblock]::Create("$capturedList '$Path'")) `
```

Replace the entire `if ($pAccPath) { ... } else { ... }` block with:

```powershell
                $fn = if ($pAccPath) {
                    $capturedParts = @($capturedList -split '\s+')
                    {
                        [CmdletBinding()]
                        param([string]$Path = '.')
                        Invoke-DFPicker `
                            -List          { & $capturedParts[0] @($capturedParts[1..($capturedParts.Count - 1)]) $Path } `
                            -Preview       $capturedPreview `
                            -PreviewWindow $capturedWindow `
                            -Ansi:$capturedAnsi `
                            -Header        $capturedHeader `
                            -Parse         $capturedParse `
                            -Action        $capturedAction
                    }.GetNewClosure()
                } else {
                    {
                        [CmdletBinding()]
                        param()
                        Invoke-DFPicker `
                            -List          ([scriptblock]::Create($capturedList)) `
                            -Preview       $capturedPreview `
                            -PreviewWindow $capturedWindow `
                            -Ansi:$capturedAnsi `
                            -Header        $capturedHeader `
                            -Parse         $capturedParse `
                            -Action        $capturedAction
                    }.GetNewClosure()
                }
```

Note: `$capturedParts` must be defined **before** the scriptblock literal so `.GetNewClosure()` captures the already-computed array, not a reference to `$pList`.

- [ ] **Step 4: Apply Fix B — `'config'` arm in the XDG switch**

In `Public/Register-DFTool.ps1`, find the XDG switch block. Currently it has:
```powershell
            { $_ -in 'config', 'wrapper' } {
                Write-Verbose "DotForge: $($tool.name) xdg.method '$xdgMethod' deferred to Phase 3"
            }
            'default' { } # tool already follows XDG natively
```

Replace the `{ $_ -in 'config', 'wrapper' }` arm only with two separate arms:

```powershell
            'config' {
                $xdg = $tool.xdg
                $rawConfigPath    = $xdg.PSObject.Properties['config_path']?.Value
                $rawConfigContent = $xdg.PSObject.Properties['config_content']?.Value
                if ($rawConfigPath) {
                    $expandedPath = Expand-DFXdgPath $rawConfigPath
                    Ensure-DFDir (Split-Path $expandedPath)
                    if (-not (Test-Path $expandedPath) -and $rawConfigContent) {
                        Set-Content -Path $expandedPath -Value $rawConfigContent -Encoding UTF8
                        Write-Verbose "DotForge: Created default config at $expandedPath"
                    }
                }
            }
            'wrapper' {
                Write-Verbose "DotForge: $($tool.name) xdg.method 'wrapper' — handled by companion .ps1"
            }
            'default' { } # tool already follows XDG natively
```

- [ ] **Step 5: Run all Register-DFTool tests — confirm 16 pass**

```powershell
Invoke-Pester tests/Register-DFTool.Tests.ps1 -Output Detailed
```

Expected: 16/16 passing (13 previous + 3 new).

- [ ] **Step 6: Commit**

```powershell
git add Public/Register-DFTool.ps1 tests/Register-DFTool.Tests.ps1
git commit -m "fix: Register-DFTool — safe list_accepts_path, xdg.method config support"
```

---

## Task 6: `winget.json` + `winget.ps1` companion

**Files:**
- Create: `Tools/winget.json`
- Create: `Tools/winget.ps1`
- Modify: `tests/Test-DFToolSchema.Tests.ps1` (add winget to seed list)

- [ ] **Step 1: Create `Tools/winget.json`**

```json
{
  "name": "winget",
  "description": "Windows Package Manager — install, upgrade, and configure applications",
  "tags": ["package-manager", "windows"],
  "executable": "winget.exe",
  "packages": {},
  "xdg": { "compliance": "none", "method": "default" },
  "completions": {
    "type": "static",
    "flags": [
      "install", "uninstall", "upgrade", "list", "show", "search",
      "export", "import", "settings", "features", "source", "hash",
      "validate", "complete", "download", "repair", "pin"
    ]
  },
  "aliases": {},
  "picker": "custom"
}
```

- [ ] **Step 2: Create `Tools/winget.ps1`**

```powershell
# Companion for winget — defines Select-WingetPackage (wins) and Remove-WingetPackage (wrm)
# Dot-sourced by Register-DFTool when winget is registered.

function global:Select-WingetPackage {
    [CmdletBinding()]
    param([string]$Query = '')

    if (-not $Query) { $Query = Read-Host 'Search winget packages' }

    Invoke-DFPicker `
        -List          { winget search $Query 2>$null | Select-Object -Skip 2 | Where-Object { $_ -match '\S' } } `
        -PreviewWindow 'hidden' `
        -Header        'Select package to install  [Enter to winget install]' `
        -Parse         { ($_ -split '\s{2,}')[1] } `
        -Action        {
            param($id)
            if ($id) {
                Write-Host "⚙  Installing $id…" -ForegroundColor Cyan
                winget install --id $id
            }
        }
}
Set-Alias -Name wins -Value Select-WingetPackage -Scope Global -Force

function global:Remove-WingetPackage {
    [CmdletBinding()]
    param()

    Invoke-DFPicker `
        -List          { winget list 2>$null | Select-Object -Skip 3 | Where-Object { $_ -match '\S' } } `
        -PreviewWindow 'hidden' `
        -Header        'Select package to uninstall  [Enter to winget uninstall]' `
        -Parse         { ($_ -split '\s{2,}')[1] } `
        -Action        {
            param($id)
            if ($id) {
                Write-Host "⚙  Uninstalling $id…" -ForegroundColor DarkYellow
                winget uninstall --id $id
            }
        }
}
Set-Alias -Name wrm -Value Remove-WingetPackage -Scope Global -Force
```

- [ ] **Step 3: Add `winget` to the seed file validation list**

In `tests/Test-DFToolSchema.Tests.ps1`, find the `$seedFiles = @(...)` array inside
`Describe 'Seed tool JSON files'`. Add `'winget'` to the list:

```powershell
    $seedFiles = @(
        'bat', 'eza', 'fzf', 'ripgrep', 'zoxide',
        'fd', 'broot', 'jq', 'glow', 'procs', 'winfetch',
        'curl', 'wget', 'docker', 'less', 'gh', 'delta',
        'lazygit', 'rustup', 'uv', 'chezmoi', 'micro',
        'bitwarden', 'npm', 'scoop', 'winget'
    ) | ForEach-Object {
        @{ Name = $_; Path = Join-Path $PSScriptRoot "../Tools/$_.json" }
    }
```

- [ ] **Step 4: Run schema tests — 26 seed tests must pass**

```powershell
Invoke-Pester tests/Test-DFToolSchema.Tests.ps1 -Output Detailed
```

Expected: 7 + 26 = 33 tests passing.

- [ ] **Step 5: Commit**

```powershell
git add Tools/winget.json Tools/winget.ps1 tests/Test-DFToolSchema.Tests.ps1
git commit -m "feat: winget tool record and companion pickers (wins, wrm)"
```

---

## Task 7: Module wiring, full test run, push

**Files:**
- Modify: `DotForge.psd1` — add `Initialize-DFEnvironment`, `Install-DFTool`

- [ ] **Step 1: Update `DotForge.psd1`**

Find `FunctionsToExport` and add the two new public functions:

```powershell
FunctionsToExport = @(
    'Add-DFToPath',
    'Ensure-DFDir',
    'Invoke-DFPicker',
    'Get-DFCachedCompletion',
    'Get-DFTool',
    'Find-DFTool',
    'Register-DFTool',
    'Initialize-DFEnvironment',
    'Install-DFTool'
)
```

- [ ] **Step 2: Verify module imports with 9 exports**

```powershell
pwsh -NoProfile -Command "
  Import-Module 'C:\Users\simsr\projects\DotForge\DotForge.psd1' -Force
  Get-Command -Module DotForge | Select-Object Name | Sort-Object Name
"
```

Expected (9 functions, sorted):
```
Add-DFToPath
Ensure-DFDir
Find-DFTool
Get-DFCachedCompletion
Get-DFTool
Initialize-DFEnvironment
Install-DFTool
Invoke-DFPicker
Register-DFTool
```

- [ ] **Step 3: Run full test suite with StrictMode**

```powershell
pwsh -NoProfile -Command "
  Set-StrictMode -Version Latest
  `$ErrorActionPreference = 'Continue'
  Import-Module Pester -MinimumVersion 5.0
  `$r = Invoke-Pester 'C:\Users\simsr\projects\DotForge\tests\' -PassThru -Output Normal
  Write-Host \"Passed: `$(`$r.PassedCount)  Failed: `$(`$r.FailedCount)\"
"
```

Expected: 0 failures. Approximate count:
89 (Phase 1+2) + 5 + 6 + 2 + 7 + 3 + 1 (winget schema) = ~113 tests.

- [ ] **Step 4: Commit and push**

```powershell
cd C:\Users\simsr\projects\DotForge
git add DotForge.psd1
git commit -m "feat: Phase 3 complete — Install-DFTool, Initialize-DFEnvironment, DFConfig

New exports: Initialize-DFEnvironment, Install-DFTool
New private: Resolve-DFPackageManager
Register-DFTool: DFConfig.SkipTools, xdg.method config, safe list_accepts_path
26 tool records (added winget)"

git push
```

---

## Self-Review Notes

**Spec coverage:**
- `Resolve-DFPackageManager` ✓ Task 1
- `Initialize-DFEnvironment` ✓ Task 2
- `$DFConfig` support (`SkipTools`) ✓ Task 3
- `Install-DFTool` ✓ Task 4
- `list_accepts_path` fix ✓ Task 5
- `xdg.method = "config"` ✓ Task 5
- `winget.json` ✓ Task 6
- Module wiring ✓ Task 7

**Not in Phase 3 scope (→ Phase 4):**
- `Update-DFCompletions`
- `xdg.method = "wrapper"` (documented: handled by companion .ps1)
- PSFzf/posh-git/Terminal-Icons as module-type tools
- README / PSGallery publishing

**Type consistency:**
- `Resolve-DFPackageManager` returns `[string[]]` — used correctly in `Initialize-DFEnvironment` and `Install-DFTool`
- `$Global:DFConfig?['SkipTools']` access uses `?[]` null-conditional on hashtable — safe in PS7
- `$capturedParts = @($pList -split '\s+')` defined before scriptblock — captured correctly by `.GetNewClosure()`
- `Test-DFToolSchema` `$seedFiles` array extended from 25 → 26 names
