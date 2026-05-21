# New-DFShim Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `New-DFShim` — a Layer 3 Tool Operation that writes a `.cmd` shim forwarding invocations (with args) to a target executable, first `cd`-ing to the executable's own directory.

**Architecture:** Single public function `Public/New-DFShim.ps1` following the `Install-DFTool` pattern — `$DFConfig` for defaults, `Import-DFToolDb` for optional tool-name lookup, `New-DFDirectory` for dir creation, `SupportsShouldProcess` for `-WhatIf`. The shim itself is a 7-line `.cmd` generated as a here-string.

**Tech Stack:** PowerShell 7+, Pester 5, Windows `.cmd` batch files.

**Spec:** `docs/superpowers/specs/2026-05-20-new-dfshim-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `tests/New-DFShim.Tests.ps1` | Create | 12 Pester tests (TDD, written first) |
| `Public/New-DFShim.ps1` | Create | `New-DFShim` function |
| `DotForge.psd1` | Modify | Add `New-DFShim` to `FunctionsToExport` |
| `README.md` | Modify | Add row to Exported Cmdlets table |
| `CHANGELOG.md` | Modify | Add entry under `[Unreleased]` |

---

## Task 1: Write Failing Tests

**Files:**
- Create: `tests/New-DFShim.Tests.ps1`

- [ ] **Step 1.1: Create the test file**

Create `tests/New-DFShim.Tests.ps1` with the full content below. The `BeforeAll` dot-sources only what's needed — same pattern as other test files in this project.

```powershell
BeforeAll {
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/Expand-DFXdgPath.ps1"
    . "$PSScriptRoot/../Private/Import-DFToolDb.ps1"
    . "$PSScriptRoot/../Public/New-DFShim.ps1"
}

Describe 'New-DFShim' {
    BeforeEach {
        $script:DFToolDb = $null
        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore

        # Set up a fake app directory and executable
        $script:AppDir  = Join-Path $TestDrive 'myapp'
        $script:FakeExe = Join-Path $script:AppDir 'myapp.exe'
        New-Item -ItemType Directory -Force -Path $script:AppDir  | Out-Null
        New-Item -ItemType File      -Force -Path $script:FakeExe | Out-Null

        # Dedicated shims dir for most tests
        $script:ShimsDir = Join-Path $TestDrive 'shims'

        # Save PATH so we can restore it
        $script:SavedPath = $Env:PATH
    }

    AfterEach {
        $Env:PATH = $script:SavedPath
        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
        $script:DFToolDb = $null
    }

    It 'creates a .cmd file in the specified shims dir' {
        New-DFShim -Name 'myapp' -Target $script:FakeExe -ShimsPath $script:ShimsDir
        Test-Path (Join-Path $script:ShimsDir 'myapp.cmd') | Should -BeTrue
    }

    It 'generated .cmd contains the correct target path' {
        New-DFShim -Name 'myapp' -Target $script:FakeExe -ShimsPath $script:ShimsDir
        $content = Get-Content (Join-Path $script:ShimsDir 'myapp.cmd') -Raw
        $content | Should -Match ([regex]::Escape("`"$($script:FakeExe)`" %*"))
    }

    It 'generated .cmd contains cd /d to the app directory' {
        New-DFShim -Name 'myapp' -Target $script:FakeExe -ShimsPath $script:ShimsDir
        $content = Get-Content (Join-Path $script:ShimsDir 'myapp.cmd') -Raw
        $content | Should -Match ([regex]::Escape("cd /d `"$($script:AppDir)`""))
    }

    It 'uses ShimsPath from $DFConfig when -ShimsPath is not specified' {
        $configDir = Join-Path $TestDrive 'config-shims'
        $Global:DFConfig = @{ ShimsPath = $configDir }
        New-DFShim -Name 'myapp' -Target $script:FakeExe
        Test-Path (Join-Path $configDir 'myapp.cmd') | Should -BeTrue
    }

    It 'falls back to $HOME\.local\bin when no $DFConfig ShimsPath is set' {
        $defaultDir = Join-Path $HOME '.local' 'bin'
        try {
            New-DFShim -Name 'dfshimtest' -Target $script:FakeExe 3>$null
            Test-Path (Join-Path $defaultDir 'dfshimtest.cmd') | Should -BeTrue
        } finally {
            Remove-Item (Join-Path $defaultDir 'dfshimtest.cmd') -ErrorAction Ignore
        }
    }

    It 'warns when shims dir is not on $PATH' {
        # $script:ShimsDir is a fresh TestDrive path — not on PATH
        $warns = New-DFShim -Name 'myapp' -Target $script:FakeExe `
            -ShimsPath $script:ShimsDir 3>&1 |
            Where-Object { $_ -is [System.Management.Automation.WarningRecord] }
        $warns | Should -Not -BeNullOrEmpty
    }

    It 'does not warn when shims dir is already on $PATH' {
        $Env:PATH = $script:ShimsDir + [IO.Path]::PathSeparator + $Env:PATH
        $warns = New-DFShim -Name 'myapp' -Target $script:FakeExe `
            -ShimsPath $script:ShimsDir 3>&1 |
            Where-Object { $_ -is [System.Management.Automation.WarningRecord] }
        $warns | Should -BeNullOrEmpty
    }

    It 'resolves target from tool DB when -Target is omitted' {
        $toolsDir = Join-Path $TestDrive 'tools'
        New-Item -ItemType Directory -Force -Path $toolsDir | Out-Null
        @'
{ "name": "myapp", "executable": "myapp.exe" }
'@ | Set-Content (Join-Path $toolsDir 'myapp.json')

        Mock Get-Command {
            [PSCustomObject]@{ Source = $script:FakeExe }
        } -ParameterFilter { $Name -eq 'myapp.exe' }

        New-DFShim -Name 'myapp' -ShimsPath $script:ShimsDir -ToolsPath $toolsDir
        $content = Get-Content (Join-Path $script:ShimsDir 'myapp.cmd') -Raw
        $content | Should -Match ([regex]::Escape($script:FakeExe))

        Remove-Item $toolsDir -Recurse -Force -ErrorAction Ignore
        $script:DFToolDb = $null
    }

    It '-Target bypasses the tool DB entirely' {
        # No ToolsPath provided and no real DB — should still work with -Target
        $toolsDir = Join-Path $TestDrive 'emptytools'
        New-Item -ItemType Directory -Force -Path $toolsDir | Out-Null

        New-DFShim -Name 'directapp' -Target $script:FakeExe -ShimsPath $script:ShimsDir `
            -ToolsPath $toolsDir
        Test-Path (Join-Path $script:ShimsDir 'directapp.cmd') | Should -BeTrue

        Remove-Item $toolsDir -Recurse -Force -ErrorAction Ignore
        $script:DFToolDb = $null
    }

    It 'errors when -Target file does not exist' {
        { New-DFShim -Name 'ghost' -Target 'C:\nonexistent\ghost.exe' `
            -ShimsPath $script:ShimsDir -ErrorAction Stop } |
            Should -Throw
    }

    It 'errors when tool name is not in DB and -Target is omitted' {
        $emptyDir = Join-Path $TestDrive 'emptytools2'
        New-Item -ItemType Directory -Force -Path $emptyDir | Out-Null
        { New-DFShim -Name 'notregistered' -ShimsPath $script:ShimsDir `
            -ToolsPath $emptyDir -ErrorAction Stop } |
            Should -Throw
        $script:DFToolDb = $null
    }

    It '-Force overwrites an existing shim' {
        New-DFShim -Name 'myapp' -Target $script:FakeExe -ShimsPath $script:ShimsDir

        $newExe = Join-Path $script:AppDir 'myapp2.exe'
        New-Item -ItemType File -Force -Path $newExe | Out-Null
        New-DFShim -Name 'myapp' -Target $newExe -ShimsPath $script:ShimsDir -Force

        $content = Get-Content (Join-Path $script:ShimsDir 'myapp.cmd') -Raw
        $content | Should -Match ([regex]::Escape($newExe))
    }

    It 'errors without -Force when shim already exists' {
        New-DFShim -Name 'myapp' -Target $script:FakeExe -ShimsPath $script:ShimsDir
        { New-DFShim -Name 'myapp' -Target $script:FakeExe `
            -ShimsPath $script:ShimsDir -ErrorAction Stop } |
            Should -Throw
    }

    It '-WhatIf does not create the shim file' {
        New-DFShim -Name 'myapp' -Target $script:FakeExe `
            -ShimsPath $script:ShimsDir -WhatIf
        Test-Path (Join-Path $script:ShimsDir 'myapp.cmd') | Should -BeFalse
    }
}
```

- [ ] **Step 1.2: Run tests to confirm they all fail**

```powershell
Invoke-Pester tests/New-DFShim.Tests.ps1 -Output Detailed
```

Expected: all 12 tests fail — `New-DFShim` function not found.

- [ ] **Step 1.3: Commit the failing tests**

```powershell
git add tests/New-DFShim.Tests.ps1
git commit -m "test: add New-DFShim failing tests (TDD)"
```

---

## Task 2: Implement New-DFShim

**Files:**
- Create: `Public/New-DFShim.ps1`

- [ ] **Step 2.1: Create Public/New-DFShim.ps1**

```powershell
#Requires -Version 7.0

function New-DFShim {
    <#
    .SYNOPSIS
        Creates a .cmd shim that forwards invocations to a target executable,
        first changing the working directory to the executable's own directory.
    .PARAMETER Name
        Shim filename (without .cmd extension). When -Target is omitted, also
        used as the DotForge tool name to look up the executable path in the registry.
    .PARAMETER Target
        Explicit path to the target executable. Bypasses tool DB lookup.
    .PARAMETER ShimsPath
        Directory where the shim is written. Defaults to $DFConfig['ShimsPath'],
        then $HOME\.local\bin.
    .PARAMETER Force
        Overwrite an existing shim without error.
    .PARAMETER ToolsPath
        Override the tools directory (used in tests).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Name,

        [string]$Target,

        [string]$ShimsPath,

        [switch]$Force,

        [string]$ToolsPath
    )

    # 1. Resolve shims directory
    $shimsDir = if ($ShimsPath) {
        $ShimsPath
    } elseif ($null -ne (Get-Variable -Name DFConfig -Scope Global -ErrorAction Ignore) -and
              $Global:DFConfig['ShimsPath']) {
        $Global:DFConfig['ShimsPath']
    } else {
        Join-Path $HOME '.local' 'bin'
    }

    # 2. Create directory (idempotent)
    New-DFDirectory $shimsDir

    # 3. PATH check
    $normalizedShims = [IO.Path]::GetFullPath($shimsDir)
    $onPath = $Env:PATH -split [IO.Path]::PathSeparator |
        Where-Object { $_ } |
        Where-Object { [IO.Path]::GetFullPath($_) -eq $normalizedShims }
    if (-not $onPath) {
        Write-Warning "DotForge: '$shimsDir' is not on PATH — shims won't be invocable until it is added"
    }

    # 4. Resolve target executable
    $resolvedTarget = $null
    if ($Target) {
        if (-not (Test-Path $Target -PathType Leaf)) {
            Write-Error "DotForge: Target '$Target' does not exist or is not a file"
            return
        }
        $resolvedTarget = $Target
    } else {
        $dbArgs = if ($ToolsPath) { @{ ToolsPath = $ToolsPath } } else { @{} }
        $db = Import-DFToolDb @dbArgs
        if (-not $db.ContainsKey($Name)) {
            Write-Error "DotForge: Tool '$Name' not found in registry. Use -Target to specify the executable path."
            return
        }
        $executable = $db[$Name].executable
        $found = Get-Command $executable -ErrorAction Ignore
        if (-not $found) {
            Write-Error "DotForge: Tool '$Name' executable '$executable' not found on PATH. Is the tool installed?"
            return
        }
        $resolvedTarget = $found.Source
    }

    # 5. App directory (working dir for the shim)
    $appDir = Split-Path -Parent $resolvedTarget

    # 6. Shim existence check
    $shimPath = Join-Path $shimsDir "$Name.cmd"
    if ((Test-Path $shimPath) -and -not $Force) {
        Write-Error "DotForge: Shim '$shimPath' already exists. Use -Force to overwrite."
        return
    }

    # 7. Write shim
    if ($PSCmdlet.ShouldProcess($shimPath, 'Create shim')) {
        $lines = @(
            '@echo off'
            'setlocal'
            "cd /d `"$appDir`""
            "`"$resolvedTarget`" %*"
            'set "_exit=%ERRORLEVEL%"'
            'endlocal'
            'exit /b %_exit%'
        )
        Set-Content -Path $shimPath -Value ($lines -join "`r`n") -Encoding ASCII -NoNewline
        Write-Verbose "DotForge: shim created → $shimPath"
    }
}
```

- [ ] **Step 2.2: Run tests to confirm all 12 pass**

```powershell
Invoke-Pester tests/New-DFShim.Tests.ps1 -Output Detailed
```

Expected: all 12 tests pass.

- [ ] **Step 2.3: Run full test suite to confirm no regressions**

```powershell
Invoke-Pester tests/ -Output Detailed
```

Expected: all pre-existing tests still pass.

- [ ] **Step 2.4: Commit**

```powershell
git add Public/New-DFShim.ps1
git commit -m "feat: add New-DFShim — generate .cmd shims for off-PATH executables"
```

---

## Task 3: Wire into DotForge.psd1 + Update Docs

**Files:**
- Modify: `DotForge.psd1` lines 10–49 (`FunctionsToExport`)
- Modify: `README.md`
- Modify: `CHANGELOG.md`

- [ ] **Step 3.1: Add New-DFShim to DotForge.psd1**

In `DotForge.psd1`, find the `# Layer 3 — Tool Operations` section:

```powershell
        # Layer 3 — Tool Operations
        'Initialize-DFEnvironment',
        'Install-DFTool',
```

Replace with:

```powershell
        # Layer 3 — Tool Operations
        'Initialize-DFEnvironment',
        'Install-DFTool',
        'New-DFShim',
```

- [ ] **Step 3.2: Add New-DFShim to README.md Exported Cmdlets table**

In `README.md`, find the Core (Layer 1–3) table. Add a new row after the `Install-DFTool` row:

```markdown
| `New-DFShim [-Name] [-Target] [-Force]` |       | Create a `.cmd` shim forwarding to an executable |
```

Also add a `ShimsPath` key to the `$DFConfig` table entry that's already documented (it was added in the spec but ensure it's in the main table, not just the code block):

In the **User Configuration** section, update the `$DFConfig` code block to include:
```powershell
$DFConfig = @{
    PackageManagerOrder = @('scoop', 'winget')  # PM preference for Install-DFTool
    SkipTools           = @('lsd')              # excluded from Register-DFTool -All
    PSReadLineTheme     = 'catppuccin-mocha'    # PSReadLine color theme (name or path)
    ShimsPath           = "$HOME\.local\bin"    # shim output dir for New-DFShim
}
```

- [ ] **Step 3.3: Add CHANGELOG entry**

In `CHANGELOG.md`, under `### Added` in `[Unreleased]`:

```markdown
- `New-DFShim [-Name] [-Target] [-ShimsPath] [-Force]` — creates a `.cmd` shim in `$HOME\.local\bin` (or `$DFConfig['ShimsPath']`) that forwards invocations to a target executable, first `cd`-ing to the executable's own directory. Accepts a tool name (DB lookup) or explicit `-Target` path. Warns if the shims directory is not on `$PATH`.
```

- [ ] **Step 3.4: Run full test suite one final time**

```powershell
Invoke-Pester tests/ -Output Detailed
```

Expected: all tests pass.

- [ ] **Step 3.5: Verify module exports New-DFShim**

```powershell
Import-Module ./DotForge.psd1 -Force
Get-Command -Module DotForge | Where-Object Name -eq 'New-DFShim'
```

Expected: `New-DFShim` listed as a `Function`.

- [ ] **Step 3.6: Smoke-test manually**

```powershell
Import-Module ./DotForge.psd1 -Force

# By explicit target path (use any real .exe on your system)
$testExe = (Get-Command pwsh.exe).Source
New-DFShim -Name 'mypwsh' -Target $testExe -ShimsPath "$env:TEMP\shims" -Verbose

# Verify the .cmd content
Get-Content "$env:TEMP\shims\mypwsh.cmd"
# Expected output:
# @echo off
# setlocal
# cd /d "C:\Program Files\PowerShell\7"
# "C:\Program Files\PowerShell\7\pwsh.exe" %*
# set "_exit=%ERRORLEVEL%"
# endlocal
# exit /b %_exit%

# -WhatIf — should print what it would do, create nothing
New-DFShim -Name 'mypwsh2' -Target $testExe -ShimsPath "$env:TEMP\shims" -WhatIf
Test-Path "$env:TEMP\shims\mypwsh2.cmd"   # → False
```

- [ ] **Step 3.7: Commit**

```powershell
git add DotForge.psd1 README.md CHANGELOG.md
git commit -m "feat: export New-DFShim; update README and CHANGELOG"
```
