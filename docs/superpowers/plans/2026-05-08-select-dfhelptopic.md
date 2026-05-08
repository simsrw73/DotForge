# Select-DFHelpTopic Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `Select-DFHelpTopic` (`fh`) — an fzf-based help browser backed by a module-fingerprint-invalidated cache — and replace the hardcoded header list in `Invoke-DFHelp` with a dynamic regex.

**Architecture:** A new private `Get-DFHelpTopicList` helper owns all cache logic (mirrors the `Invoke-DFFzf`/`Invoke-DFPagerExe` pattern). `Select-DFHelpTopic` delegates to it entirely and uses `.GetNewClosure()` on the `-List` scriptblock to safely capture the local `$topics` variable across function boundaries. The regex change to `Invoke-DFHelp` is a one-line replacement of the `foreach` loop.

**Tech Stack:** PowerShell 7+, Pester 5, `Invoke-DFPicker` (existing), `Invoke-DFHelp` (existing), `Ensure-DFDir` (existing), `$XDG_CACHE_HOME`

---

## File Map

| Action | Path | Responsibility |
|---|---|---|
| Create | `Private/Get-DFHelpTopicList.ps1` | Cache read/write/invalidation, returns `Name\tCategory` lines |
| Create | `tests/Get-DFHelpTopicList.Tests.ps1` | Cache hit/miss/force tests |
| Modify | `Public/DFHelpers.Help.ps1` | Add `Select-DFHelpTopic` + `fh`; replace foreach with regex |
| Modify | `tests/DFHelpers.Help.Tests.ps1` | Add `Select-DFHelpTopic` tests; add regex tests |
| Modify | `DotForge.psd1` | Export `Select-DFHelpTopic` + `fh` |

---

## Task 1: `Get-DFHelpTopicList` Private Helper

**Files:**
- Create: `Private/Get-DFHelpTopicList.ps1`
- Create: `tests/Get-DFHelpTopicList.Tests.ps1`

- [ ] **Step 1: Create stub**

```powershell
# Private/Get-DFHelpTopicList.ps1
#Requires -Version 7.0
```

- [ ] **Step 2: Write the failing tests**

```powershell
# tests/Get-DFHelpTopicList.Tests.ps1
BeforeAll {
    . "$PSScriptRoot/../Public/Ensure-DFDir.ps1"
    . "$PSScriptRoot/../Private/Get-DFHelpTopicList.ps1"
}

Describe 'Get-DFHelpTopicList' {
    BeforeEach {
        $script:SavedXdg = $Env:XDG_CACHE_HOME
        $Env:XDG_CACHE_HOME = $TestDrive
    }
    AfterEach { $Env:XDG_CACHE_HOME = $script:SavedXdg }

    It 'returns topics as Name<TAB>Category lines' {
        Mock Get-Help {
            @(
                [PSCustomObject]@{ Name = 'Get-Process';    Category = 'Cmdlet'   },
                [PSCustomObject]@{ Name = 'about_Parsing';  Category = 'HelpFile' }
            )
        }
        Mock Get-Module { @() }
        $result = Get-DFHelpTopicList
        $result | Should -Contain "Get-Process`tCmdlet"
        $result | Should -Contain "about_Parsing`tHelpFile"
    }

    It 'writes help-topics.txt and help-topics.key on first run' {
        Mock Get-Help { @([PSCustomObject]@{ Name = 'Get-Item'; Category = 'Cmdlet' }) }
        Mock Get-Module { @() }
        Get-DFHelpTopicList
        Test-Path (Join-Path $TestDrive 'dotforge' 'help-topics.txt') | Should -BeTrue
        Test-Path (Join-Path $TestDrive 'dotforge' 'help-topics.key') | Should -BeTrue
    }

    It 'returns cached list without calling Get-Help when fingerprint matches' {
        $cacheDir = Join-Path $TestDrive 'dotforge'
        New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
        Set-Content (Join-Path $cacheDir 'help-topics.key')  ''              -Encoding UTF8
        Set-Content (Join-Path $cacheDir 'help-topics.txt') "Get-Item`tCmdlet" -Encoding UTF8
        Mock Get-Module { @() }
        Mock Get-Help { throw 'Should not be called on cache hit' }
        $result = Get-DFHelpTopicList
        $result | Should -Contain "Get-Item`tCmdlet"
    }

    It 'regenerates cache when fingerprint changes' {
        $cacheDir = Join-Path $TestDrive 'dotforge'
        New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
        Set-Content (Join-Path $cacheDir 'help-topics.key')  'OldMod:1.0'     -Encoding UTF8
        Set-Content (Join-Path $cacheDir 'help-topics.txt') "OldTopic`tCmdlet" -Encoding UTF8
        Mock Get-Module {
            @([PSCustomObject]@{ Name = 'NewMod'; Version = [version]'2.0' })
        }
        Mock Get-Help { @([PSCustomObject]@{ Name = 'New-Topic'; Category = 'Cmdlet' }) }
        $result = Get-DFHelpTopicList
        $result | Should -Contain     "New-Topic`tCmdlet"
        $result | Should -Not -Contain "OldTopic`tCmdlet"
    }

    It '-Force regenerates cache even when fingerprint matches' {
        $cacheDir = Join-Path $TestDrive 'dotforge'
        New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
        Set-Content (Join-Path $cacheDir 'help-topics.key')  ''                 -Encoding UTF8
        Set-Content (Join-Path $cacheDir 'help-topics.txt') "OldTopic`tCmdlet"  -Encoding UTF8
        Mock Get-Module { @() }
        Mock Get-Help { @([PSCustomObject]@{ Name = 'Fresh-Topic'; Category = 'Cmdlet' }) }
        $result = Get-DFHelpTopicList -Force
        $result | Should -Contain     "Fresh-Topic`tCmdlet"
        $result | Should -Not -Contain "OldTopic`tCmdlet"
    }
}
```

- [ ] **Step 3: Run tests to confirm they fail**

```powershell
Invoke-Pester tests/Get-DFHelpTopicList.Tests.ps1 -Output Detailed
```

Expected: all tests fail — function not defined

- [ ] **Step 4: Implement `Get-DFHelpTopicList`**

```powershell
# Private/Get-DFHelpTopicList.ps1
#Requires -Version 7.0

function Get-DFHelpTopicList {
    <#
    .SYNOPSIS
        Returns all available PS help topics as Name<TAB>Category lines.
        Caches to XDG_CACHE_HOME/dotforge and invalidates when the installed module set changes.
    .PARAMETER Force
        Bypass the cache and regenerate from Get-Help *.
    #>
    [CmdletBinding()]
    param(
        [switch]$Force
    )

    $cacheDir    = Join-Path $Env:XDG_CACHE_HOME 'dotforge'
    $cacheFile   = Join-Path $cacheDir 'help-topics.txt'
    $keyFile     = Join-Path $cacheDir 'help-topics.key'

    $fingerprint = Get-Module -ListAvailable |
                   Sort-Object Name, Version |
                   ForEach-Object { "$($_.Name):$($_.Version)" } |
                   Join-String -Separator ','

    $cacheValid  = -not $Force -and
                   (Test-Path $cacheFile) -and
                   (Test-Path $keyFile)   -and
                   ((Get-Content $keyFile -Raw).Trim() -eq $fingerprint)

    if ($cacheValid) {
        return Get-Content $cacheFile
    }

    $topics = Get-Help * -ErrorAction SilentlyContinue |
              Where-Object { $_.Name } |
              Sort-Object Name |
              ForEach-Object { "$($_.Name)`t$($_.Category)" }

    Ensure-DFDir $cacheDir
    Set-Content -Path $keyFile   -Value $fingerprint -Encoding UTF8
    Set-Content -Path $cacheFile -Value $topics      -Encoding UTF8

    $topics
}
```

- [ ] **Step 5: Run tests to confirm they pass**

```powershell
Invoke-Pester tests/Get-DFHelpTopicList.Tests.ps1 -Output Detailed
```

Expected: `Tests: 5 Passed, 0 Failed`

- [ ] **Step 6: Run full suite to check for regressions**

```powershell
Invoke-Pester tests/ -Output Detailed
```

Expected: all existing tests still pass

- [ ] **Step 7: Commit**

```powershell
git add Private/Get-DFHelpTopicList.ps1 tests/Get-DFHelpTopicList.Tests.ps1
git commit -m "feat: add Get-DFHelpTopicList private cache helper"
```

---

## Task 2: `Select-DFHelpTopic` + `Invoke-DFHelp` Regex Update

**Files:**
- Modify: `Public/DFHelpers.Help.ps1`
- Modify: `tests/DFHelpers.Help.Tests.ps1`

**Background on `.GetNewClosure()`:** PowerShell scriptblocks passed across function boundaries do not automatically capture local variables from the defining scope. `.GetNewClosure()` creates a copy of the scriptblock that binds current variable values, ensuring `$topics` is visible when `Invoke-DFPicker` calls `& $List` internally.

- [ ] **Step 1: Write the failing tests**

Add the following to `tests/DFHelpers.Help.Tests.ps1`. The `BeforeAll` block needs one new line to source `Get-DFHelpTopicList` before `DFHelpers.Help.ps1`:

```powershell
# tests/DFHelpers.Help.Tests.ps1 — replace the entire BeforeAll block
BeforeAll {
    function Invoke-DFWithPager {
        [CmdletBinding()]
        param(
            [Parameter(ValueFromPipeline)][string]$InputObject,
            [scriptblock]$Command
        )
        process { $InputObject }
        end { if ($Command) { & $Command } }
    }
    . "$PSScriptRoot/../Public/Ensure-DFDir.ps1"
    . "$PSScriptRoot/../Private/Invoke-DFFzf.ps1"
    . "$PSScriptRoot/../Private/Get-DFHelpTopicList.ps1"
    . "$PSScriptRoot/../Public/Invoke-DFPicker.ps1"
    . "$PSScriptRoot/../Public/DFHelpers.Help.ps1"
}
```

Then add these new Describe blocks at the end of the file:

```powershell
Describe 'Invoke-DFHelp regex' {
    BeforeEach {
        $script:SavedNoColor = $Env:NO_COLOR
        $Env:NO_COLOR = $null
    }
    AfterEach { $Env:NO_COLOR = $script:SavedNoColor }

    It 'colorizes any all-caps header, not just hardcoded ones' {
        Mock Get-Help { "CUSTOMHEADER`nsome content" | Out-String }
        Mock Invoke-DFWithPager { }
        if (-not $Host.UI.SupportsVirtualTerminal) {
            Set-ItResult -Skipped -Because 'terminal does not support VT sequences'
            return
        }
        $result = Invoke-DFHelp 'anything'
        ($result -join '') | Should -Match "`e\[.*CUSTOMHEADER"
    }

    It 'does not colorize indented content lines' {
        Mock Get-Help { "SYNOPSIS`n    indented content line" | Out-String }
        Mock Invoke-DFWithPager { }
        if (-not $Host.UI.SupportsVirtualTerminal) {
            Set-ItResult -Skipped -Because 'terminal does not support VT sequences'
            return
        }
        $result = Invoke-DFHelp 'anything'
        ($result -join '') | Should -Not -Match "`e\[.*indented"
    }
}

Describe 'Select-DFHelpTopic' {
    BeforeEach {
        $script:SavedXdg = $Env:XDG_CACHE_HOME
        $Env:XDG_CACHE_HOME = $TestDrive
    }
    AfterEach { $Env:XDG_CACHE_HOME = $script:SavedXdg }

    It 'calls Invoke-DFHelp with the selected topic name' {
        Mock Get-DFHelpTopicList { @("Get-Process`tCmdlet", "about_Parsing`tHelpFile") }
        Mock Invoke-DFFzf { "Get-Process`tCmdlet" }
        Mock Invoke-DFHelp { }
        fh
        Should -Invoke Invoke-DFHelp -ParameterFilter { $Name -eq 'Get-Process' }
    }

    It 'does not call Invoke-DFHelp when user cancels' {
        Mock Get-DFHelpTopicList { @("Get-Process`tCmdlet") }
        Mock Invoke-DFFzf { $null }
        Mock Invoke-DFHelp { }
        fh
        Should -Invoke Invoke-DFHelp -Times 0
    }

    It '-Category filters to matching topics only' {
        Mock Get-DFHelpTopicList {
            @("Get-Process`tCmdlet", "about_Parsing`tHelpFile", "Get-Item`tCmdlet")
        }
        Mock Invoke-DFFzf { $null }
        fh -Category HelpFile
        Should -Invoke Invoke-DFFzf -ParameterFilter {
            $InputItems.Count -eq 1 -and $InputItems[0] -like 'about_Parsing*'
        }
    }

    It '-Force is passed through to Get-DFHelpTopicList' {
        Mock Get-DFHelpTopicList { @() }
        Mock Invoke-DFFzf { $null }
        fh -Force
        Should -Invoke Get-DFHelpTopicList -ParameterFilter { $Force }
    }
}
```

- [ ] **Step 2: Run tests to confirm they fail**

```powershell
Invoke-Pester tests/DFHelpers.Help.Tests.ps1 -Output Detailed
```

Expected: the 6 new tests fail — `Select-DFHelpTopic` and `fh` not defined; regex tests may vary

- [ ] **Step 3: Implement `Select-DFHelpTopic` in `Public/DFHelpers.Help.ps1`**

Add this block at the end of `Public/DFHelpers.Help.ps1` (before the final blank line):

```powershell
function Select-DFHelpTopic {
    <#
    .SYNOPSIS
        Fuzzy-searches all available PS help topics and opens the selected topic in Invoke-DFHelp.
    .PARAMETER Category
        Optional. Filters topics by Get-Help category (Cmdlet, Function, HelpFile, Module, etc.).
        No ValidateSet — accepts any string so future PS categories work without a code change.
    .PARAMETER Force
        Bypass the topic list cache and regenerate from Get-Help *.
    .EXAMPLE
        Select-DFHelpTopic
    .EXAMPLE
        fh -Category HelpFile
    .EXAMPLE
        fh -Force
    #>
    [CmdletBinding()]
    param(
        [string]$Category = '',
        [switch]$Force
    )

    $topics = Get-DFHelpTopicList -Force:$Force
    if ($Category) {
        $topics = @($topics | Where-Object { ($_ -split "`t", 2)[1] -eq $Category })
    }

    Invoke-DFPicker `
        -List      { $topics }.GetNewClosure() `
        -Delimiter "`t" `
        -WithNth   '1' `
        -Header    'Browse help topics  [Enter to view full help]' `
        -Preview   'pwsh -NoProfile -NonInteractive -Command "Get-Help {1} -ErrorAction SilentlyContinue" 2>nul' `
        -Parse     { ($_ -split "`t", 2)[0] } `
        -Action    { param($topic) Invoke-DFHelp $topic }
}
Set-Alias -Name fh -Value Select-DFHelpTopic -Scope Global -Force
```

- [ ] **Step 4: Replace the `foreach` loop in `Invoke-DFHelp`**

In `Public/DFHelpers.Help.ps1`, find and replace the entire `foreach` block:

**Find:**
```powershell
        foreach ($h in 'NAME', 'TOPIC', 'SYNOPSIS', 'SYNTAX', 'DESCRIPTION', 'SHORT DESCRIPTION', 'LONG DESCRIPTION', 'PARAMETERS', 'INPUTS', 'OUTPUTS', 'NOTES', 'REMARKS', 'EXAMPLES', 'RELATED LINKS', 'LINKS', 'SEE ALSO', 'ALIASES', 'COMPONENT', 'ROLE', 'FUNCTIONALITY', 'DYNAMIC PARAMETERS') {
            $helpText = $helpText -replace "(?m)^($h)", "$yellow`$1$reset"
        }
```

**Replace with:**
```powershell
        $helpText = $helpText -replace '(?m)^([A-Z]{2,}(?: [A-Z]+)*)$', "$yellow`$1$reset"
```

- [ ] **Step 5: Run tests to confirm they pass**

```powershell
Invoke-Pester tests/DFHelpers.Help.Tests.ps1 -Output Detailed
```

Expected: all tests pass (VT-dependent tests may be skipped if terminal lacks VT support)

- [ ] **Step 6: Run full suite**

```powershell
Invoke-Pester tests/ -Output Detailed
```

Expected: all tests pass

- [ ] **Step 7: Commit**

```powershell
git add Public/DFHelpers.Help.ps1 tests/DFHelpers.Help.Tests.ps1
git commit -m "feat: add Select-DFHelpTopic (fh) and regex header colorization in Invoke-DFHelp"
```

---

## Task 3: Module Manifest Update

**Files:**
- Modify: `DotForge.psd1`

- [ ] **Step 1: Add `Select-DFHelpTopic` to `FunctionsToExport`**

In `DotForge.psd1`, find the `# General Helpers — Help & Discovery` section and add the new function:

```powershell
    # General Helpers — Help & Discovery
    'Invoke-DFHelp',
    'Select-DFCommand',
    'Select-DFVerb',
    'Select-DFModule',
    'Select-DFHelpTopic',
```

- [ ] **Step 2: Add `fh` to `AliasesToExport`**

In `DotForge.psd1`, find the `AliasesToExport` array and add `'fh'`:

```powershell
    AliasesToExport   = @(
        'pg',
        'hm', 'fcmd', 'fverb', 'fmod', 'fh',
        'up', 'mkcd', 'fcd',
        'touch', 'which', 'open',
        'fps', 'top',
        'path', 'fenv', 'ep', 'reload',
        'copy', 'paste'
    )
```

- [ ] **Step 3: Run full suite**

```powershell
Invoke-Pester tests/ -Output Detailed
```

Expected: all tests pass

- [ ] **Step 4: Smoke-test module import**

```powershell
Import-Module ./DotForge.psd1 -Force
Get-Command -Module DotForge | Where-Object Name -eq 'Select-DFHelpTopic'
Get-Alias fh
```

Expected: `Select-DFHelpTopic` listed, `fh` resolves to `Select-DFHelpTopic`

- [ ] **Step 5: Commit**

```powershell
git add DotForge.psd1
git commit -m "feat: export Select-DFHelpTopic and fh alias in module manifest"
```
