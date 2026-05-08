# General PowerShell Helpers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add 19 general-purpose PowerShell helper functions with short aliases to DotForge across 7 category files plus one new Layer 1 primitive.

**Architecture:** `Invoke-DFWithPager` is added to Layer 1, backed by a private `Invoke-DFPagerExe` stub (mirrors the `Invoke-DFFzf` pattern for testability). Six category files in `Public/` each contain 2–4 focused functions; all aliases are `Set-Alias -Scope Global -Force` at the bottom of each file. The module manifest is updated last.

**Tech Stack:** PowerShell 7+, Pester 5, `Invoke-DFPicker` (existing), `Ensure-DFDir` (existing)

---

## File Map

| Action | Path | Responsibility |
|---|---|---|
| Create | `Private/Invoke-DFPagerExe.ps1` | Pager exe invocation (mockable) |
| Create | `Public/DFHelpers.Pager.ps1` | `Invoke-DFWithPager` + `pg` alias |
| Create | `Public/DFHelpers.Help.ps1` | `Invoke-DFHelp`, `Select-DFCommand`, `Select-DFVerb`, `Select-DFModule` |
| Create | `Public/DFHelpers.Navigation.ps1` | `Set-DFLocationUp`, `New-DFDirectoryAndSet`, `Select-DFLocation` |
| Create | `Public/DFHelpers.FileSystem.ps1` | `New-DFFile`, `Get-DFWhich`, `Open-DFItem` |
| Create | `Public/DFHelpers.Process.ps1` | `Select-DFProcess`, `Get-DFTopProcess` |
| Create | `Public/DFHelpers.Environment.ps1` | `Get-DFPath`, `Select-DFEnvVar`, `Edit-DFProfile`, `Invoke-DFProfileReload` |
| Create | `Public/DFHelpers.Clipboard.ps1` | `Copy-DFToClipboard`, `Get-DFFromClipboard` |
| Create | `tests/DFHelpers.Pager.Tests.ps1` | Pager tests |
| Create | `tests/DFHelpers.Help.Tests.ps1` | Help tests |
| Create | `tests/DFHelpers.Navigation.Tests.ps1` | Navigation tests |
| Create | `tests/DFHelpers.FileSystem.Tests.ps1` | FileSystem tests |
| Create | `tests/DFHelpers.Process.Tests.ps1` | Process tests |
| Create | `tests/DFHelpers.Environment.Tests.ps1` | Environment tests |
| Create | `tests/DFHelpers.Clipboard.Tests.ps1` | Clipboard tests |
| Modify | `DotForge.psd1` | Export 19 new functions + 19 aliases |

---

## Task 1: Pager Primitive

**Files:**
- Create: `Private/Invoke-DFPagerExe.ps1`
- Create: `Public/DFHelpers.Pager.ps1`
- Create: `tests/DFHelpers.Pager.Tests.ps1`

- [ ] **Step 1: Create stub files**

```powershell
# Private/Invoke-DFPagerExe.ps1
#Requires -Version 7.0
```

```powershell
# Public/DFHelpers.Pager.ps1
#Requires -Version 7.0
```

- [ ] **Step 2: Write the failing tests**

```powershell
# tests/DFHelpers.Pager.Tests.ps1
BeforeAll {
    . "$PSScriptRoot/../Private/Invoke-DFPagerExe.ps1"
    . "$PSScriptRoot/../Public/DFHelpers.Pager.ps1"
}

Describe 'Invoke-DFWithPager' {
    BeforeEach {
        $script:SavedPager = $Env:Pager
        $Env:Pager = $null
    }
    AfterEach { $Env:Pager = $script:SavedPager }

    Context 'no pager set' {
        It 'passes pipeline input through to stdout' {
            $result = 'hello', 'world' | Invoke-DFWithPager
            $result | Should -Be @('hello', 'world')
        }

        It 'runs scriptblock and outputs result' {
            $result = Invoke-DFWithPager { 'from-block' }
            $result | Should -Be 'from-block'
        }

        It 'returns nothing for empty scriptblock' {
            $result = Invoke-DFWithPager { }
            $result | Should -BeNullOrEmpty
        }
    }

    Context 'pager set' {
        It 'invokes Invoke-DFPagerExe when $Env:Pager is set' {
            $Env:Pager = 'less'
            Mock Invoke-DFPagerExe { }
            'hello' | Invoke-DFWithPager
            Should -Invoke Invoke-DFPagerExe -Times 1
        }

        It 'passes the pager string to Invoke-DFPagerExe' {
            $Env:Pager = 'less -R'
            Mock Invoke-DFPagerExe { }
            'hello' | Invoke-DFWithPager
            Should -Invoke Invoke-DFPagerExe -ParameterFilter { $Pager -eq 'less -R' }
        }

        It 'does not invoke pager for empty input' {
            $Env:Pager = 'less'
            Mock Invoke-DFPagerExe { }
            Invoke-DFWithPager { }
            Should -Invoke Invoke-DFPagerExe -Times 0
        }
    }
}
```

- [ ] **Step 3: Run tests to confirm they fail**

```powershell
Invoke-Pester tests/DFHelpers.Pager.Tests.ps1 -Output Detailed
```

Expected: all tests fail with "The term 'Invoke-DFWithPager' is not recognized"

- [ ] **Step 4: Implement `Invoke-DFPagerExe`**

```powershell
# Private/Invoke-DFPagerExe.ps1
#Requires -Version 7.0

function Invoke-DFPagerExe {
    param(
        [Parameter(Mandatory)][string[]]$Lines,
        [Parameter(Mandatory)][string]$Pager
    )
    $parts    = $Pager -split '\s+', 2
    $pagerArgs = if ($parts.Count -gt 1) { $parts[1] -split '\s+' } else { @() }
    $Lines | & $parts[0] @pagerArgs
}
```

- [ ] **Step 5: Implement `Invoke-DFWithPager`**

```powershell
# Public/DFHelpers.Pager.ps1
#Requires -Version 7.0

function Invoke-DFWithPager {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline)]
        [string]$InputObject,

        [Parameter(Position = 0)]
        [scriptblock]$Command
    )
    begin   { $lines = [System.Collections.Generic.List[string]]@() }
    process { if ($null -ne $InputObject) { $lines.Add($InputObject) } }
    end {
        if ($Command) { $lines = & $Command | ForEach-Object { "$_" } }
        if ($Env:Pager -and $lines.Count -gt 0) {
            Invoke-DFPagerExe -Lines $lines -Pager $Env:Pager
        } else {
            $lines
        }
    }
}
Set-Alias -Name pg -Value Invoke-DFWithPager -Scope Global -Force
```

- [ ] **Step 6: Run tests to confirm they pass**

```powershell
Invoke-Pester tests/DFHelpers.Pager.Tests.ps1 -Output Detailed
```

Expected: `Tests: 6 Passed, 0 Failed`

- [ ] **Step 7: Commit**

```powershell
git add Private/Invoke-DFPagerExe.ps1 Public/DFHelpers.Pager.ps1 tests/DFHelpers.Pager.Tests.ps1
git commit -m "feat: add Invoke-DFWithPager Layer 1 primitive (pg)"
```

---

## Task 2: Help & Discovery

**Files:**
- Create: `Public/DFHelpers.Help.ps1`
- Create: `tests/DFHelpers.Help.Tests.ps1`

- [ ] **Step 1: Create stub**

```powershell
# Public/DFHelpers.Help.ps1
#Requires -Version 7.0
```

- [ ] **Step 2: Write the failing tests**

```powershell
# tests/DFHelpers.Help.Tests.ps1
BeforeAll {
    # Stub Invoke-DFWithPager — avoids sourcing the full pager stack in these tests
    function Invoke-DFWithPager {
        [CmdletBinding()]
        param(
            [Parameter(ValueFromPipeline)][string]$InputObject,
            [scriptblock]$Command
        )
        process { $InputObject }
        end { if ($Command) { & $Command } }
    }
    . "$PSScriptRoot/../Private/Invoke-DFFzf.ps1"
    . "$PSScriptRoot/../Public/Invoke-DFPicker.ps1"
    . "$PSScriptRoot/../Public/DFHelpers.Help.ps1"
}

Describe 'Invoke-DFHelp' {
    BeforeEach {
        $script:SavedNoColor = $Env:NO_COLOR
        $Env:NO_COLOR = $null
    }
    AfterEach { $Env:NO_COLOR = $script:SavedNoColor }

    It 'calls Get-Help with the supplied name' {
        Mock Get-Help { 'help text' | Out-String }
        Mock Invoke-DFWithPager { }
        Invoke-DFHelp 'Get-Process'
        Should -Invoke Get-Help -ParameterFilter { $Name -eq 'Get-Process' }
    }

    It 'emits no ANSI codes when $Env:NO_COLOR is set' {
        $Env:NO_COLOR = '1'
        Mock Get-Help { "SYNOPSIS`nsome text" | Out-String }
        $result = Invoke-DFHelp 'Get-Process'
        ($result -join '') | Should -Not -Match "`e\["
    }

    It 'colorizes SYNOPSIS header when $Env:NO_COLOR is not set and VT is supported' {
        Mock Get-Help { "SYNOPSIS`nsome text" | Out-String }
        # Force SupportsVirtualTerminal = true by patching; if the host doesn't support it
        # this test is skipped rather than failed
        if (-not $Host.UI.SupportsVirtualTerminal) {
            Set-ItResult -Skipped -Because 'terminal does not support VT sequences'
            return
        }
        $result = Invoke-DFHelp 'Get-Process'
        ($result -join '') | Should -Match "`e\["
    }
}

Describe 'Select-DFVerb' {
    It 'outputs the verb name from the selected line' {
        Mock Invoke-DFFzf { 'Lifecycle            Start' }
        $result = Select-DFVerb
        $result | Should -Be 'Start'
    }

    It 'returns nothing when user cancels' {
        Mock Invoke-DFFzf { $null }
        Select-DFVerb | Should -BeNullOrEmpty
    }
}

Describe 'Select-DFModule' {
    It 'outputs the module name from the selected line' {
        Mock Invoke-DFFzf { 'PSReadLine                               2.3.4      Cmdlets for great...' }
        $result = Select-DFModule
        $result | Should -Be 'PSReadLine'
    }

    It 'returns nothing when user cancels' {
        Mock Invoke-DFFzf { $null }
        Select-DFModule | Should -BeNullOrEmpty
    }
}

Describe 'Select-DFCommand' {
    It 'outputs the command name from the selected line' {
        Mock Invoke-DFFzf { 'Get-Process                                        Cmdlet          Microsoft.PowerShell.Management' }
        $result = Select-DFCommand
        $result | Should -Be 'Get-Process'
    }

    It 'returns nothing when user cancels' {
        Mock Invoke-DFFzf { $null }
        Select-DFCommand | Should -BeNullOrEmpty
    }
}
```

- [ ] **Step 3: Run tests to confirm they fail**

```powershell
Invoke-Pester tests/DFHelpers.Help.Tests.ps1 -Output Detailed
```

Expected: all tests fail — functions not defined

- [ ] **Step 4: Implement**

```powershell
# Public/DFHelpers.Help.ps1
#Requires -Version 7.0

function Invoke-DFHelp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Name
    )
    $helpText = Get-Help $Name -Full | Out-String

    $useColor = (-not $Env:NO_COLOR) -and $Host.UI.SupportsVirtualTerminal
    if ($useColor) {
        $yellow = "`e[1;33m"
        $reset  = "`e[0m"
        foreach ($h in 'SYNOPSIS','DESCRIPTION','PARAMETERS','EXAMPLES','NOTES','RELATED LINKS') {
            $helpText = $helpText -replace "(?m)^($h)", "$yellow`$1$reset"
        }
    }

    $helpText | Invoke-DFWithPager
}
Set-Alias -Name hm -Value Invoke-DFHelp -Scope Global -Force

function Select-DFCommand {
    [CmdletBinding()]
    param(
        [string]$Module = ''
    )
    $gcParams = @{}
    if ($Module) { $gcParams.Module = $Module }

    Invoke-DFPicker `
        -List    { Get-Command @gcParams |
                   ForEach-Object { '{0,-50} {1,-15} {2}' -f $_.Name, $_.CommandType, $_.Source } } `
        -Header  'Select command  [Enter to output name]' `
        -Preview 'pwsh -NoProfile -NonInteractive -Command "Get-Help {1} -ErrorAction SilentlyContinue | Out-String" 2>nul' `
        -Parse   { ($_ -split '\s+')[0] }
}
Set-Alias -Name fcmd -Value Select-DFCommand -Scope Global -Force

function Select-DFVerb {
    [CmdletBinding()]
    param()
    Invoke-DFPicker `
        -List   { Get-Verb | ForEach-Object { '{0,-20} {1}' -f $_.Group, $_.Verb } } `
        -Header 'Select verb  [Enter to output]' `
        -Parse  { ($_ -split '\s+')[1] }
}
Set-Alias -Name fverb -Value Select-DFVerb -Scope Global -Force

function Select-DFModule {
    [CmdletBinding()]
    param()
    Invoke-DFPicker `
        -List   { Get-Module -ListAvailable |
                  ForEach-Object { '{0,-40} {1,-10} {2}' -f $_.Name, $_.Version, $_.Description } } `
        -Header 'Select module  [Enter to output name]' `
        -Parse  { ($_ -split '\s+')[0] }
}
Set-Alias -Name fmod -Value Select-DFModule -Scope Global -Force
```

- [ ] **Step 5: Run tests to confirm they pass**

```powershell
Invoke-Pester tests/DFHelpers.Help.Tests.ps1 -Output Detailed
```

Expected: all tests pass (VT test may be skipped depending on terminal)

- [ ] **Step 6: Commit**

```powershell
git add Public/DFHelpers.Help.ps1 tests/DFHelpers.Help.Tests.ps1
git commit -m "feat: add Help helpers — Invoke-DFHelp (hm), Select-DFCommand/Verb/Module (fcmd/fverb/fmod)"
```

---

## Task 3: Navigation

**Files:**
- Create: `Public/DFHelpers.Navigation.ps1`
- Create: `tests/DFHelpers.Navigation.Tests.ps1`

- [ ] **Step 1: Create stub**

```powershell
# Public/DFHelpers.Navigation.ps1
#Requires -Version 7.0
```

- [ ] **Step 2: Write the failing tests**

```powershell
# tests/DFHelpers.Navigation.Tests.ps1
BeforeAll {
    . "$PSScriptRoot/../Public/Ensure-DFDir.ps1"
    . "$PSScriptRoot/../Private/Invoke-DFFzf.ps1"
    . "$PSScriptRoot/../Public/Invoke-DFPicker.ps1"
    . "$PSScriptRoot/../Public/DFHelpers.Navigation.ps1"
}

Describe 'Set-DFLocationUp' {
    BeforeEach { $script:SavedLocation = Get-Location }
    AfterEach  { Set-Location $script:SavedLocation }

    It 'moves up one level by default' {
        $deep = Join-Path $TestDrive 'a'
        New-Item -ItemType Directory -Path $deep -Force | Out-Null
        Set-Location $deep
        up
        (Get-Location).Path | Should -Be $TestDrive
    }

    It 'moves up N levels' {
        $deep = Join-Path $TestDrive 'a' 'b' 'c'
        New-Item -ItemType Directory -Path $deep -Force | Out-Null
        Set-Location $deep
        up 3
        (Get-Location).Path | Should -Be $TestDrive
    }
}

Describe 'New-DFDirectoryAndSet' {
    BeforeEach { $script:SavedLocation = Get-Location }
    AfterEach  { Set-Location $script:SavedLocation }

    It 'creates the directory and sets location to it' {
        $newDir = Join-Path $TestDrive 'newdir'
        mkcd $newDir
        Test-Path $newDir -PathType Container | Should -BeTrue
        (Get-Location).Path | Should -Be $newDir
    }
}

Describe 'Select-DFLocation' {
    BeforeEach { $script:SavedLocation = Get-Location }
    AfterEach  { Set-Location $script:SavedLocation }

    It 'changes to the selected directory' {
        $target = Join-Path $TestDrive 'target'
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        Mock Invoke-DFFzf { $target }
        fcd
        (Get-Location).Path | Should -Be $target
    }

    It 'does nothing when user cancels' {
        $before = (Get-Location).Path
        Mock Invoke-DFFzf { $null }
        fcd
        (Get-Location).Path | Should -Be $before
    }
}
```

- [ ] **Step 3: Run tests to confirm they fail**

```powershell
Invoke-Pester tests/DFHelpers.Navigation.Tests.ps1 -Output Detailed
```

Expected: all tests fail — functions not defined

- [ ] **Step 4: Implement**

```powershell
# Public/DFHelpers.Navigation.ps1
#Requires -Version 7.0

function Set-DFLocationUp {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [ValidateRange(1, 99)]
        [int]$Levels = 1
    )
    $path = ('../' * $Levels).TrimEnd('/')
    Set-Location $path
}
Set-Alias -Name up -Value Set-DFLocationUp -Scope Global -Force

function New-DFDirectoryAndSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Path
    )
    Ensure-DFDir $Path
    Set-Location $Path
}
Set-Alias -Name mkcd -Value New-DFDirectoryAndSet -Scope Global -Force

function Select-DFLocation {
    [CmdletBinding()]
    param()
    Invoke-DFPicker `
        -List   {
            if (Get-Command fd -ErrorAction Ignore) {
                fd --type d 2>$null
            } else {
                Get-ChildItem -Recurse -Directory -ErrorAction Ignore |
                    Select-Object -ExpandProperty FullName
            }
        } `
        -Header 'Select directory  [Enter to cd]' `
        -Action { param($dir) Set-Location $dir }
}
Set-Alias -Name fcd -Value Select-DFLocation -Scope Global -Force
```

- [ ] **Step 5: Run tests to confirm they pass**

```powershell
Invoke-Pester tests/DFHelpers.Navigation.Tests.ps1 -Output Detailed
```

Expected: `Tests: 5 Passed, 0 Failed`

- [ ] **Step 6: Commit**

```powershell
git add Public/DFHelpers.Navigation.ps1 tests/DFHelpers.Navigation.Tests.ps1
git commit -m "feat: add Navigation helpers — Set-DFLocationUp (up), New-DFDirectoryAndSet (mkcd), Select-DFLocation (fcd)"
```

---

## Task 4: File System

**Files:**
- Create: `Public/DFHelpers.FileSystem.ps1`
- Create: `tests/DFHelpers.FileSystem.Tests.ps1`

- [ ] **Step 1: Create stub**

```powershell
# Public/DFHelpers.FileSystem.ps1
#Requires -Version 7.0
```

- [ ] **Step 2: Write the failing tests**

```powershell
# tests/DFHelpers.FileSystem.Tests.ps1
BeforeAll {
    . "$PSScriptRoot/../Public/DFHelpers.FileSystem.ps1"
}

Describe 'New-DFFile' {
    It 'creates a new empty file when path does not exist' {
        $path = Join-Path $TestDrive 'newfile.txt'
        touch $path
        Test-Path $path | Should -BeTrue
        (Get-Item $path).Length | Should -Be 0
    }

    It 'updates LastWriteTime when file already exists' {
        $path = Join-Path $TestDrive 'existing.txt'
        New-Item -ItemType File -Path $path | Out-Null
        $oldTime = (Get-Item $path).LastWriteTime
        Start-Sleep -Milliseconds 100
        touch $path
        (Get-Item $path).LastWriteTime | Should -BeGreaterThan $oldTime
    }

    It 'accepts multiple paths' {
        $a = Join-Path $TestDrive 'a.txt'
        $b = Join-Path $TestDrive 'b.txt'
        touch $a $b
        Test-Path $a | Should -BeTrue
        Test-Path $b | Should -BeTrue
    }
}

Describe 'Get-DFWhich' {
    It 'returns the full path of a known executable' {
        $result = which pwsh
        $result | Should -Not -BeNullOrEmpty
        $result | Should -Match '(?i)\.exe$'
    }

    It 'returns nothing silently for an unknown command' {
        $result = which nonexistent-command-xyz-df
        $result | Should -BeNullOrEmpty
    }

    It '-All does not throw' {
        { which pwsh -All } | Should -Not -Throw
    }

    It '-All returns all matches when multiple exist' {
        $results = which pwsh -All
        $results | Should -Not -BeNullOrEmpty
    }
}

Describe 'Open-DFItem' {
    It 'calls Invoke-Item for a single path' {
        Mock Invoke-Item { }
        open 'somefile.txt'
        Should -Invoke Invoke-Item -Times 1 -ParameterFilter { $Path -eq 'somefile.txt' }
    }

    It 'calls Invoke-Item once per path for multiple paths' {
        Mock Invoke-Item { }
        open 'a.txt' 'b.txt'
        Should -Invoke Invoke-Item -Times 2
    }
}
```

- [ ] **Step 3: Run tests to confirm they fail**

```powershell
Invoke-Pester tests/DFHelpers.FileSystem.Tests.ps1 -Output Detailed
```

Expected: all tests fail — functions not defined

- [ ] **Step 4: Implement**

```powershell
# Public/DFHelpers.FileSystem.ps1
#Requires -Version 7.0

function New-DFFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromRemainingArguments)]
        [string[]]$Path
    )
    process {
        foreach ($p in $Path) {
            if (Test-Path $p) {
                (Get-Item $p).LastWriteTime = Get-Date
            } else {
                New-Item -ItemType File -Path $p | Out-Null
            }
        }
    }
}
Set-Alias -Name touch -Value New-DFFile -Scope Global -Force

function Get-DFWhich {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
        [string]$Name,
        [switch]$All
    )
    process {
        $params = @{ Name = $Name; CommandType = 'Application'; ErrorAction = 'Ignore' }
        if ($All) { $params.All = $true }
        Get-Command @params | Select-Object -ExpandProperty Source
    }
}
Set-Alias -Name which -Value Get-DFWhich -Scope Global -Force

function Open-DFItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromRemainingArguments)]
        [string[]]$Path
    )
    process {
        foreach ($p in $Path) { Invoke-Item $p }
    }
}
Set-Alias -Name open -Value Open-DFItem -Scope Global -Force
```

- [ ] **Step 5: Run tests to confirm they pass**

```powershell
Invoke-Pester tests/DFHelpers.FileSystem.Tests.ps1 -Output Detailed
```

Expected: `Tests: 7 Passed, 0 Failed`

- [ ] **Step 6: Commit**

```powershell
git add Public/DFHelpers.FileSystem.ps1 tests/DFHelpers.FileSystem.Tests.ps1
git commit -m "feat: add FileSystem helpers — New-DFFile (touch), Get-DFWhich (which), Open-DFItem (open)"
```

---

## Task 5: Process Management

**Files:**
- Create: `Public/DFHelpers.Process.ps1`
- Create: `tests/DFHelpers.Process.Tests.ps1`

- [ ] **Step 1: Create stub**

```powershell
# Public/DFHelpers.Process.ps1
#Requires -Version 7.0
```

- [ ] **Step 2: Write the failing tests**

```powershell
# tests/DFHelpers.Process.Tests.ps1
BeforeAll {
    . "$PSScriptRoot/../Private/Invoke-DFFzf.ps1"
    . "$PSScriptRoot/../Public/Invoke-DFPicker.ps1"
    . "$PSScriptRoot/../Public/DFHelpers.Process.ps1"
}

Describe 'Select-DFProcess' {
    It 'returns a Process object for the selected process' {
        $proc = Get-Process -Id $PID
        $line = '{0,-35} {1,7} {2,8:F1} {3,10}' -f $proc.Name, $proc.Id, $proc.CPU, [math]::Round($proc.WorkingSet / 1MB)
        Mock Invoke-DFFzf { $line }
        $result = fps
        $result | Should -BeOfType [System.Diagnostics.Process]
        $result.Id | Should -Be $PID
    }

    It 'returns nothing when user cancels' {
        Mock Invoke-DFFzf { $null }
        fps | Should -BeNullOrEmpty
    }
}

Describe 'Get-DFTopProcess' {
    It 'does not throw with default parameters' {
        { top } | Should -Not -Throw
    }

    It 'does not throw with -By Memory' {
        { top -By Memory } | Should -Not -Throw
    }

    It 'does not throw with -Count 5' {
        { top -Count 5 } | Should -Not -Throw
    }
}
```

- [ ] **Step 3: Run tests to confirm they fail**

```powershell
Invoke-Pester tests/DFHelpers.Process.Tests.ps1 -Output Detailed
```

Expected: all tests fail — functions not defined

- [ ] **Step 4: Implement**

```powershell
# Public/DFHelpers.Process.ps1
#Requires -Version 7.0

function Select-DFProcess {
    [CmdletBinding()]
    param(
        [switch]$Multi
    )
    Invoke-DFPicker `
        -List    { Get-Process | Sort-Object CPU -Descending |
                   ForEach-Object { '{0,-35} {1,7} {2,8:F1} {3,10}' -f $_.Name, $_.Id, $_.CPU, [math]::Round($_.WorkingSet / 1MB) } } `
        -Header  'Select process  [Enter to output object]' `
        -Preview 'pwsh -NoProfile -NonInteractive -Command "Get-Process -Id {2} | Format-List *" 2>nul' `
        -Multi:$Multi `
        -Parse   {
            $parts = ($_ -split '\s+').Where({ $_ })
            Get-Process -Id ([int]$parts[1]) -ErrorAction Ignore
        }
}
Set-Alias -Name fps -Value Select-DFProcess -Scope Global -Force

function Get-DFTopProcess {
    [CmdletBinding()]
    param(
        [ValidateSet('CPU', 'Memory')]
        [string]$By = 'CPU',
        [int]$Count = 20
    )
    $sortProp = if ($By -eq 'Memory') { 'WorkingSet' } else { 'CPU' }
    Get-Process |
        Sort-Object $sortProp -Descending |
        Select-Object -First $Count -Property Name, Id,
            @{N = 'CPU(s)';  E = { [math]::Round($_.CPU, 2) }},
            @{N = 'Mem(MB)'; E = { [math]::Round($_.WorkingSet / 1MB) }} |
        Format-Table -AutoSize
}
Set-Alias -Name top -Value Get-DFTopProcess -Scope Global -Force
```

- [ ] **Step 5: Run tests to confirm they pass**

```powershell
Invoke-Pester tests/DFHelpers.Process.Tests.ps1 -Output Detailed
```

Expected: `Tests: 5 Passed, 0 Failed`

- [ ] **Step 6: Commit**

```powershell
git add Public/DFHelpers.Process.ps1 tests/DFHelpers.Process.Tests.ps1
git commit -m "feat: add Process helpers — Select-DFProcess (fps), Get-DFTopProcess (top)"
```

---

## Task 6: Environment & Profile

**Files:**
- Create: `Public/DFHelpers.Environment.ps1`
- Create: `tests/DFHelpers.Environment.Tests.ps1`

- [ ] **Step 1: Create stub**

```powershell
# Public/DFHelpers.Environment.ps1
#Requires -Version 7.0
```

- [ ] **Step 2: Write the failing tests**

```powershell
# tests/DFHelpers.Environment.Tests.ps1
BeforeAll {
    . "$PSScriptRoot/../Private/Invoke-DFFzf.ps1"
    . "$PSScriptRoot/../Public/Invoke-DFPicker.ps1"
    . "$PSScriptRoot/../Public/DFHelpers.Environment.ps1"
}

Describe 'Get-DFPath' {
    It 'returns one entry per PATH segment' {
        $saved = $Env:PATH
        $Env:PATH = 'C:\foo;C:\bar;C:\baz'
        $result = path
        $Env:PATH = $saved
        $result | Should -Be @('C:\foo', 'C:\bar', 'C:\baz')
    }
}

Describe 'Select-DFEnvVar' {
    It 'outputs the value of the selected env var' {
        $Env:DF_TEST_VAR = 'test-value-123'
        Mock Invoke-DFFzf { "DF_TEST_VAR`ttest-value-123" }
        $result = fenv
        Remove-Item Env:DF_TEST_VAR -ErrorAction Ignore
        $result | Should -Be 'test-value-123'
    }

    It 'returns nothing when user cancels' {
        Mock Invoke-DFFzf { $null }
        fenv | Should -BeNullOrEmpty
    }
}

Describe 'Edit-DFProfile' {
    BeforeEach { $script:SavedEditor = $Env:EDITOR }
    AfterEach  { $Env:EDITOR = $script:SavedEditor }

    It 'emits a warning when $Env:EDITOR is not set' {
        $Env:EDITOR = $null
        ep -WarningVariable warns 3>$null
        $warns | Should -Not -BeNullOrEmpty
    }

    It 'does not emit a warning when $Env:EDITOR is set' {
        $Env:EDITOR = 'pwsh'
        try { ep -WarningVariable warns 3>$null } catch { }
        $warns | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-DFProfileReload' {
    It 'does not throw even when $PROFILE does not exist' {
        { reload } | Should -Not -Throw
    }
}
```

- [ ] **Step 3: Run tests to confirm they fail**

```powershell
Invoke-Pester tests/DFHelpers.Environment.Tests.ps1 -Output Detailed
```

Expected: all tests fail — functions not defined

- [ ] **Step 4: Implement**

```powershell
# Public/DFHelpers.Environment.ps1
#Requires -Version 7.0

function Get-DFPath {
    [CmdletBinding()]
    param()
    $Env:PATH -split [IO.Path]::PathSeparator
}
Set-Alias -Name path -Value Get-DFPath -Scope Global -Force

function Select-DFEnvVar {
    [CmdletBinding()]
    param()
    Invoke-DFPicker `
        -List      { Get-ChildItem Env: | Sort-Object Name |
                     ForEach-Object { "$($_.Name)`t$($_.Value)" } } `
        -Delimiter "`t" `
        -Header    'Select env var  [Enter to output value]' `
        -Parse     { ($_ -split "`t", 2)[1] }
}
Set-Alias -Name fenv -Value Select-DFEnvVar -Scope Global -Force

function Edit-DFProfile {
    [CmdletBinding()]
    param()
    if (-not $Env:EDITOR) {
        Write-Warning 'DotForge: $Env:EDITOR is not set'
        return
    }
    & $Env:EDITOR $PROFILE
}
Set-Alias -Name ep -Value Edit-DFProfile -Scope Global -Force

function Invoke-DFProfileReload {
    [CmdletBinding()]
    param()
    if (Test-Path $PROFILE) {
        . $PROFILE
    } else {
        Write-Warning "DotForge: `$PROFILE not found at $PROFILE"
    }
}
Set-Alias -Name reload -Value Invoke-DFProfileReload -Scope Global -Force
```

- [ ] **Step 5: Run tests to confirm they pass**

```powershell
Invoke-Pester tests/DFHelpers.Environment.Tests.ps1 -Output Detailed
```

Expected: `Tests: 5 Passed, 0 Failed`

- [ ] **Step 6: Commit**

```powershell
git add Public/DFHelpers.Environment.ps1 tests/DFHelpers.Environment.Tests.ps1
git commit -m "feat: add Environment helpers — Get-DFPath (path), Select-DFEnvVar (fenv), Edit-DFProfile (ep), Invoke-DFProfileReload (reload)"
```

---

## Task 7: Clipboard

**Files:**
- Create: `Public/DFHelpers.Clipboard.ps1`
- Create: `tests/DFHelpers.Clipboard.Tests.ps1`

> **Note:** These tests interact with the real system clipboard — they may behave unexpectedly if the clipboard is locked or unavailable (e.g., headless CI). Run them on a developer machine.

- [ ] **Step 1: Create stub**

```powershell
# Public/DFHelpers.Clipboard.ps1
#Requires -Version 7.0
```

- [ ] **Step 2: Write the failing tests**

```powershell
# tests/DFHelpers.Clipboard.Tests.ps1
BeforeAll {
    . "$PSScriptRoot/../Public/DFHelpers.Clipboard.ps1"
}

Describe 'Copy-DFToClipboard' {
    It 'sets clipboard from a positional argument' {
        copy 'direct text'
        Get-Clipboard | Should -Be 'direct text'
    }

    It 'sets clipboard from pipeline input' {
        'hello world' | copy
        Get-Clipboard | Should -Be 'hello world'
    }

    It 'joins multiple pipeline items with newlines' {
        'line1', 'line2', 'line3' | copy
        Get-Clipboard | Should -Be "line1`nline2`nline3"
    }
}

Describe 'Get-DFFromClipboard' {
    It 'returns clipboard contents' {
        Set-Clipboard 'test clipboard content'
        paste | Should -Be 'test clipboard content'
    }
}
```

- [ ] **Step 3: Run tests to confirm they fail**

```powershell
Invoke-Pester tests/DFHelpers.Clipboard.Tests.ps1 -Output Detailed
```

Expected: all tests fail — functions not defined

- [ ] **Step 4: Implement**

```powershell
# Public/DFHelpers.Clipboard.ps1
#Requires -Version 7.0

function Copy-DFToClipboard {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromPipeline)]
        [string]$InputObject
    )
    begin   { $lines = [System.Collections.Generic.List[string]]@() }
    process { if ($null -ne $InputObject) { $lines.Add($InputObject) } }
    end     { Set-Clipboard -Value ($lines -join "`n") }
}
Set-Alias -Name copy -Value Copy-DFToClipboard -Scope Global -Force

function Get-DFFromClipboard {
    [CmdletBinding()]
    param()
    Get-Clipboard
}
Set-Alias -Name paste -Value Get-DFFromClipboard -Scope Global -Force
```

- [ ] **Step 5: Run tests to confirm they pass**

```powershell
Invoke-Pester tests/DFHelpers.Clipboard.Tests.ps1 -Output Detailed
```

Expected: `Tests: 4 Passed, 0 Failed`

- [ ] **Step 6: Commit**

```powershell
git add Public/DFHelpers.Clipboard.ps1 tests/DFHelpers.Clipboard.Tests.ps1
git commit -m "feat: add Clipboard helpers — Copy-DFToClipboard (copy), Get-DFFromClipboard (paste)"
```

---

## Task 8: Module Manifest Update

**Files:**
- Modify: `DotForge.psd1`

- [ ] **Step 1: Run full test suite to confirm all tasks passed**

```powershell
Invoke-Pester tests/ -Output Detailed
```

Expected: all existing + new tests pass, 0 failures

- [ ] **Step 2: Update `DotForge.psd1`**

Replace the `FunctionsToExport` and `AliasesToExport` arrays:

```powershell
FunctionsToExport = @(
    # Layer 1 — Core Primitives
    'Add-DFToPath',
    'Ensure-DFDir',
    'Invoke-DFPicker',
    'Get-DFCachedCompletion',
    'Invoke-DFWithPager',
    # Layer 2 — Tool Registry
    'Get-DFTool',
    'Find-DFTool',
    'Register-DFTool',
    # Layer 3 — Tool Operations
    'Initialize-DFEnvironment',
    'Install-DFTool',
    'Update-DFCompletions',
    # General Helpers — Pager (already in Layer 1 above)
    # General Helpers — Help & Discovery
    'Invoke-DFHelp',
    'Select-DFCommand',
    'Select-DFVerb',
    'Select-DFModule',
    # General Helpers — Navigation
    'Set-DFLocationUp',
    'New-DFDirectoryAndSet',
    'Select-DFLocation',
    # General Helpers — File System
    'New-DFFile',
    'Get-DFWhich',
    'Open-DFItem',
    # General Helpers — Process
    'Select-DFProcess',
    'Get-DFTopProcess',
    # General Helpers — Environment & Profile
    'Get-DFPath',
    'Select-DFEnvVar',
    'Edit-DFProfile',
    'Invoke-DFProfileReload',
    # General Helpers — Clipboard
    'Copy-DFToClipboard',
    'Get-DFFromClipboard'
)
AliasesToExport   = @(
    'pg',
    'hm', 'fcmd', 'fverb', 'fmod',
    'up', 'mkcd', 'fcd',
    'touch', 'which', 'open',
    'fps', 'top',
    'path', 'fenv', 'ep', 'reload',
    'copy', 'paste'
)
```

- [ ] **Step 3: Run full test suite again**

```powershell
Invoke-Pester tests/ -Output Detailed
```

Expected: all tests still pass

- [ ] **Step 4: Smoke-test module import**

```powershell
Import-Module ./DotForge.psd1 -Force
Get-Command -Module DotForge | Sort-Object Name | Format-Table Name, CommandType
```

Expected: all 29 functions listed

- [ ] **Step 5: Commit**

```powershell
git add DotForge.psd1
git commit -m "feat: export 19 new General Helper functions and 19 aliases in module manifest"
```
