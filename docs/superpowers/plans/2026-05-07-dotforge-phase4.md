# DotForge Phase 4 — Completions + Polish + PSGallery Prep Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete DotForge to a publishable state: add `Update-DFCompletions`, extend the schema and registry for PowerShell module tools, add 4 module/prompt tool records, and prepare for PSGallery (real GUID, LICENSE, CHANGELOG, README).

**Architecture:** `Update-DFCompletions` deletes stale cache files and re-invokes `Get-DFCachedCompletion` for each dynamic-completion tool on PATH. PS module tool support adds `type = "module"` to the schema — `Register-DFTool` checks `Get-Module -ListAvailable` instead of `Get-Command`, and `Install-DFTool` supports `psresource` as a PM key. PSGallery prep is purely documentation and manifest polish — no logic changes.

**Tech Stack:** PowerShell 7+, Pester 5, `Microsoft.PowerShell.PSResourceGet` (for `Install-PSResource`). Builds on all Phase 1–3 code (113 tests, 9 exports, 26 tool records).

---

## Foundation (do not modify unless a task says to)

```
Public/:  Add-DFToPath, Ensure-DFDir, Find-DFTool, Get-DFCachedCompletion, Get-DFTool,
          Initialize-DFEnvironment, Install-DFTool, Invoke-DFPicker, Register-DFTool
Private/: Expand-DFXdgPath, Import-DFToolDb, Invoke-DFFzf, Resolve-DFPackageManager,
          Test-DFToolSchema
Tools/:   26 JSON records, ripgrep.ps1, procs.ps1, winget.ps1
tests/:   113 passing tests (StrictMode)
```

## File Map — New/Modified This Phase

| File | Role |
|------|------|
| `Public/Update-DFCompletions.ps1` | Invalidate + regenerate dynamic completion caches |
| `Private/Test-DFToolSchema.ps1` | Add `type` field validation (`exe` \| `module`) |
| `Public/Register-DFTool.ps1` | Check module availability for `type = "module"` tools |
| `Public/Install-DFTool.ps1` | Add `psresource` PM support |
| `Tools/posh-git.json` | PS module tool record |
| `Tools/PSFzf.json` | PS module tool record |
| `Tools/Terminal-Icons.json` | PS module tool record |
| `Tools/oh-my-posh.json` | Prompt engine (scoop binary, not PS module) |
| `Tools/posh-git.ps1` | Companion: git fzf pickers (fco, flog, fga, fstash) |
| `Tools/oh-my-posh.ps1` | Companion: Select-PoshTheme (fpot) |
| `DotForge.psd1` | Real GUID, ReleaseNotes, Add-DFCompletions export |
| `LICENSE` | MIT license |
| `CHANGELOG.md` | Version history |
| `README.md` | Installation, usage, cmdlet reference |
| `tests/Update-DFCompletions.Tests.ps1` | Pester tests |
| `tests/Test-DFToolSchema.Tests.ps1` | Add `type` field tests |
| `tests/Register-DFTool.Tests.ps1` | Add module availability test |
| `tests/Install-DFTool.Tests.ps1` | Add psresource test |
| `tests/Test-DFToolSchema.Tests.ps1` | Add 4 new tool names to seed list |

---

## Task 1: `Update-DFCompletions`

**Files:**
- Create: `Public/Update-DFCompletions.ps1`
- Create: `tests/Update-DFCompletions.Tests.ps1`

### What it does

Finds all tools with `completions.type = "dynamic"`, deletes their cache files
(from `$XDG_CACHE_HOME/dotforge/completions/`), then re-invokes `Get-DFCachedCompletion`
for each tool that is currently on PATH. Tools not on PATH have their cache cleared but
are not regenerated. Supports `-Name` to target specific tools.

- [ ] **Step 1: Write the failing tests**

Create `C:\Users\simsr\projects\DotForge\tests\Update-DFCompletions.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/../Public/Ensure-DFDir.ps1"
    . "$PSScriptRoot/../Public/Get-DFCachedCompletion.ps1"
    . "$PSScriptRoot/../Private/Test-DFToolSchema.ps1"
    . "$PSScriptRoot/../Private/Import-DFToolDb.ps1"
    . "$PSScriptRoot/../Public/Update-DFCompletions.ps1"
}

Describe 'Update-DFCompletions' {
    BeforeEach {
        $script:DFToolDb = $null
        $script:SavedCache  = $Env:XDG_CACHE_HOME
        $Env:XDG_CACHE_HOME = Join-Path $TestDrive 'cache'
        $script:TmpTools    = Join-Path $TestDrive 'tools'
        New-Item -ItemType Directory -Force -Path $script:TmpTools | Out-Null

        @'
{ "name": "dyntool", "executable": "dyntool.exe",
  "completions": { "type": "dynamic", "command": "dyntool completions powershell" } }
'@ | Set-Content (Join-Path $script:TmpTools 'dyntool.json')

        @'
{ "name": "statictool", "executable": "statictool.exe",
  "completions": { "type": "static", "flags": ["--verbose"] } }
'@ | Set-Content (Join-Path $script:TmpTools 'statictool.json')
    }
    AfterEach { $Env:XDG_CACHE_HOME = $script:SavedCache }

    It 'deletes the cache file for a dynamic-completion tool' {
        $cacheDir  = Join-Path $Env:XDG_CACHE_HOME 'dotforge' 'completions'
        $cacheFile = Join-Path $cacheDir 'dyntool.ps1'
        New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
        '# old completions' | Set-Content $cacheFile

        Mock Get-Command { $null }
        Update-DFCompletions -ToolsPath $script:TmpTools
        Test-Path $cacheFile | Should -BeFalse
    }

    It 'does not touch cache files for static-completion tools' {
        $cacheDir  = Join-Path $Env:XDG_CACHE_HOME 'dotforge' 'completions'
        $cacheFile = Join-Path $cacheDir 'statictool.ps1'
        New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
        '# static cache' | Set-Content $cacheFile

        Mock Get-Command { $null }
        Update-DFCompletions -ToolsPath $script:TmpTools
        Test-Path $cacheFile | Should -BeTrue
    }

    It 'filters to named tools when -Name is specified' {
        @'
{ "name": "tool2", "executable": "tool2.exe",
  "completions": { "type": "dynamic", "command": "tool2 completions ps" } }
'@ | Set-Content (Join-Path $script:TmpTools 'tool2.json')

        $cacheDir = Join-Path $Env:XDG_CACHE_HOME 'dotforge' 'completions'
        New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
        '# dyntool' | Set-Content (Join-Path $cacheDir 'dyntool.ps1')
        '# tool2'   | Set-Content (Join-Path $cacheDir 'tool2.ps1')

        Mock Get-Command { $null }
        Update-DFCompletions -Name 'dyntool' -ToolsPath $script:TmpTools

        Test-Path (Join-Path $cacheDir 'dyntool.ps1') | Should -BeFalse  # cleared
        Test-Path (Join-Path $cacheDir 'tool2.ps1')   | Should -BeTrue   # not touched
    }

    It 'does not throw when no cache files exist' {
        Mock Get-Command { $null }
        { Update-DFCompletions -ToolsPath $script:TmpTools } | Should -Not -Throw
    }

    It 'does not throw when tools directory is empty' {
        $emptyTools = Join-Path $TestDrive 'empty'
        New-Item -ItemType Directory -Force -Path $emptyTools | Out-Null
        { Update-DFCompletions -ToolsPath $emptyTools } | Should -Not -Throw
    }
}
```

- [ ] **Step 2: Run tests — confirm they fail**

```powershell
cd C:\Users\simsr\projects\DotForge
Invoke-Pester tests/Update-DFCompletions.Tests.ps1 -Output Detailed
```

Expected: All 5 tests fail.

- [ ] **Step 3: Implement `Update-DFCompletions`**

Create `C:\Users\simsr\projects\DotForge\Public\Update-DFCompletions.ps1`:

```powershell
#Requires -Version 7.0

function Update-DFCompletions {
    <#
    .SYNOPSIS
        Invalidates and regenerates dynamic completion caches for known CLI tools.
        Tools not currently on PATH have their cache cleared but are not regenerated.
    .PARAMETER Name
        Limit to specific tool names. If omitted, all dynamic-completion tools are updated.
    .PARAMETER ToolsPath
        Override the tools directory (used in tests).
    #>
    [CmdletBinding()]
    param(
        [string[]]$Name,
        [string]$ToolsPath
    )

    $dbArgs = if ($ToolsPath) { @{ ToolsPath = $ToolsPath } } else { @{} }
    $db = Import-DFToolDb @dbArgs

    $cacheDir = Join-Path $Env:XDG_CACHE_HOME 'dotforge' 'completions'

    $tools = $db.Values | Where-Object {
        $_.PSObject.Properties['completions']?.Value?.PSObject.Properties['type']?.Value -eq 'dynamic'
    }

    if ($Name) {
        $tools = $tools | Where-Object { $_.name -in $Name }
    }

    foreach ($tool in $tools) {
        $cacheFile = Join-Path $cacheDir "$($tool.name).ps1"
        Remove-Item $cacheFile -Force -ErrorAction Ignore

        $exe    = $tool.PSObject.Properties['executable']?.Value
        $exeCmd = if ($exe) { Get-Command $exe -ErrorAction Ignore } else { $null }

        if (-not $exeCmd) {
            Write-Verbose "DotForge: $($tool.name) not on PATH — cache cleared, skipping regeneration"
            continue
        }

        $genCmd = $tool.completions.PSObject.Properties['command']?.Value
        if ($genCmd) {
            $capturedCmd = $genCmd
            Get-DFCachedCompletion `
                -CacheKey $tool.name `
                -ExePath  $exeCmd.Path `
                -Generate { & ([scriptblock]::Create($capturedCmd)) }.GetNewClosure()
            Write-Host "✓ $($tool.name) completions updated" -ForegroundColor Green
        }
    }
}
```

- [ ] **Step 4: Run tests — confirm all 5 pass**

```powershell
Invoke-Pester tests/Update-DFCompletions.Tests.ps1 -Output Detailed
```

Expected: 5/5 passing.

- [ ] **Step 5: Commit**

```powershell
git add Public/Update-DFCompletions.ps1 tests/Update-DFCompletions.Tests.ps1
git commit -m "feat: Update-DFCompletions — invalidate and regenerate dynamic completion caches"
```

---

## Task 2: PS module tool type support

**Files:**
- Modify: `Private/Test-DFToolSchema.ps1` — add `type` field validation
- Modify: `Public/Register-DFTool.ps1` — check module availability for `type = "module"`
- Modify: `Public/Install-DFTool.ps1` — add `psresource` PM support
- Modify: `tests/Test-DFToolSchema.Tests.ps1` — add `type` field tests
- Modify: `tests/Register-DFTool.Tests.ps1` — add module availability test
- Modify: `tests/Install-DFTool.Tests.ps1` — add psresource test

### What it does

Extends the tool schema with an optional `type` field (`"exe"` | `"module"`). When
`type = "module"`, `Register-DFTool` checks `Get-Module -Name $exe -ListAvailable`
instead of `Get-Command $exe`. `Install-DFTool` handles `packages.psresource` by calling
`Install-PSResource`. The `psresource` key can be added to `$DFConfig.PackageManagerOrder`.

- [ ] **Step 1: Add `type` field tests to schema test file**

Read `tests/Test-DFToolSchema.Tests.ps1`. In the `Context 'valid records'` block, add:

```powershell
        It 'passes a tool with type = "exe"' {
            $tool = [PSCustomObject]@{ name = 't'; executable = 't.exe'; type = 'exe' }
            Test-DFToolSchema -Tool $tool -Errors ([ref]$null) | Should -BeTrue
        }

        It 'passes a tool with type = "module"' {
            $tool = [PSCustomObject]@{ name = 't'; executable = 't'; type = 'module' }
            Test-DFToolSchema -Tool $tool -Errors ([ref]$null) | Should -BeTrue
        }
```

In the `Context 'invalid records'` block, add:

```powershell
        It 'fails when type is not a valid value' {
            $tool = [PSCustomObject]@{ name = 't'; executable = 't.exe'; type = 'binary' }
            $errors = @()
            Test-DFToolSchema -Tool $tool -Errors ([ref]$errors) | Should -BeFalse
            $errors | Where-Object { $_ -match 'type' } | Should -Not -BeNullOrEmpty
        }
```

Append to `tests/Register-DFTool.Tests.ps1` inside the `Describe` block:

```powershell
    It 'uses Get-Module -ListAvailable for type=module tools' {
        @'
{ "name": "mymod", "type": "module", "executable": "MyModule" }
'@ | Set-Content (Join-Path $script:TmpTools 'mymod.json')
        $script:DFToolDb = $null

        # Module NOT available — should skip without error
        Mock Get-Module { $null }
        { Register-DFTool -Name 'mymod' -ToolsPath $script:TmpTools } | Should -Not -Throw
        # Module IS available — should proceed
        Mock Get-Module { [PSCustomObject]@{ Name = 'MyModule' } }
        { Register-DFTool -Name 'mymod' -ToolsPath $script:TmpTools } | Should -Not -Throw

        Remove-Item (Join-Path $script:TmpTools 'mymod.json') -ErrorAction Ignore
        $script:DFToolDb = $null
    }
```

Append to `tests/Install-DFTool.Tests.ps1` inside the `Describe` block:

```powershell
    It 'installs via Install-PSResource when psresource package is specified' {
        @'
{ "name": "psmod", "type": "module", "executable": "PsMod",
  "packages": { "psresource": "PsMod" } }
'@ | Set-Content (Join-Path $script:TmpTools 'psmod.json')
        $script:DFToolDb = $null

        $script:PSResourceCalled = $false
        function script:Install-PSResource {
            param($Name, $Scope, $ErrorAction)
            $script:PSResourceCalled = $true
        }
        Mock Get-Command { [PSCustomObject]@{ Name = 'Install-PSResource' } } `
            -ParameterFilter { $Name -eq 'Install-PSResource' }

        Install-DFTool -Name 'psmod' -PackageManager 'psresource' -ToolsPath $script:TmpTools
        $script:PSResourceCalled | Should -BeTrue

        Remove-Item (Join-Path $script:TmpTools 'psmod.json') -ErrorAction Ignore
        $script:DFToolDb = $null
    }
```

- [ ] **Step 2: Run new tests — confirm they fail**

```powershell
Invoke-Pester tests/Test-DFToolSchema.Tests.ps1, tests/Register-DFTool.Tests.ps1, tests/Install-DFTool.Tests.ps1 -Output Detailed
```

Expected: 3 new tests fail; all existing tests still pass.

- [ ] **Step 3: Update `Test-DFToolSchema.ps1`**

In `Private/Test-DFToolSchema.ps1`, after the `# required fields` block and before the `# xdg.method` block, add:

```powershell
    # type field
    $validToolTypes = @('exe', 'module')
    $toolType = $Tool.PSObject.Properties['type']?.Value
    if ($toolType -and $toolType -notin $validToolTypes) {
        $errs.Add("Invalid type '$toolType'. Valid: $($validToolTypes -join ', ')")
    }
```

- [ ] **Step 4: Update `Register-DFTool.ps1`**

In `Public/Register-DFTool.ps1`, find the PATH guard section (after the `foreach ($tool in $tools)` line):

```powershell
        if (-not (Get-Command $tool.executable -ErrorAction Ignore)) {
            Write-Verbose "DotForge: '$($tool.executable)' not on PATH — skipping $($tool.name)"
            continue
        }
```

Replace with:

```powershell
        $toolType = $tool.PSObject.Properties['type']?.Value ?? 'exe'
        $isAvailable = if ($toolType -eq 'module') {
            Get-Module -Name $tool.executable -ListAvailable -ErrorAction Ignore
        } else {
            Get-Command $tool.executable -ErrorAction Ignore
        }
        if (-not $isAvailable) {
            Write-Verbose "DotForge: '$($tool.executable)' not available — skipping $($tool.name)"
            continue
        }
```

- [ ] **Step 5: Update `Install-DFTool.ps1`**

In `Public/Install-DFTool.ps1`, find the `foreach ($pm in $pmOrder)` loop. Replace the
`$pmAvailable = if ($pm -eq 'psresource') { ... } else { ... }` section (or the existing
`if (-not (Get-Command $pm -ErrorAction Ignore)) { continue }` line) with:

```powershell
        foreach ($pm in $pmOrder) {
            # Availability check — psresource uses Install-PSResource cmdlet, not a $pm command
            $pmAvailable = if ($pm -eq 'psresource') {
                Get-Command Install-PSResource -ErrorAction Ignore
            } else {
                Get-Command $pm -ErrorAction Ignore
            }
            if (-not $pmAvailable) { continue }

            $pkgId = $packages?.PSObject.Properties[$pm]?.Value
            if (-not $pkgId) { continue }

            if ($PSCmdlet.ShouldProcess("$toolName via $pm ($pkgId)", 'Install')) {
                Write-Host "  Installing $toolName via $pm ($pkgId)…" `
                    -ForegroundColor DarkGray -NoNewline

                $null = switch ($pm) {
                    'scoop'      { scoop  install $pkgId 2>&1 }
                    'winget'     { winget install --id $pkgId --silent `
                                       --accept-source-agreements `
                                       --accept-package-agreements 2>&1 }
                    'choco'      { choco  install $pkgId -y 2>&1 }
                    'psresource' {
                        try {
                            Install-PSResource -Name $pkgId -Scope CurrentUser -ErrorAction Stop | Out-Null
                            $global:LASTEXITCODE = 0
                        } catch {
                            $global:LASTEXITCODE = 1
                        }
                    }
                }

                if ($LASTEXITCODE -eq 0) {
                    Write-Host ' ✓' -ForegroundColor Green
                    $installedVia = $pm
                    break
                } else {
                    Write-Host ' failed' -ForegroundColor Red
                }
            } else {
                $installedVia = $pm
                break
            }
        }
```

**Note:** Read the current `Install-DFTool.ps1` first to see the exact structure of the
existing PM loop and replace the entire `foreach ($pm in $pmOrder)` block with the above.

- [ ] **Step 6: Run all three test files — confirm new tests now pass**

```powershell
Invoke-Pester tests/Test-DFToolSchema.Tests.ps1, tests/Register-DFTool.Tests.ps1, tests/Install-DFTool.Tests.ps1 -Output Detailed
```

Expected: All tests pass including the 3 new ones.

- [ ] **Step 7: Run full StrictMode suite**

```powershell
pwsh -NoProfile -Command "
  Set-StrictMode -Version Latest
  `$ErrorActionPreference = 'Continue'
  Import-Module Pester -MinimumVersion 5.0
  `$r = Invoke-Pester 'C:\Users\simsr\projects\DotForge\tests\' -PassThru -Output Normal
  Write-Host \"Passed: `$(`$r.PassedCount)  Failed: `$(`$r.FailedCount)\"
"
```

Expected: 0 failures.

- [ ] **Step 8: Commit**

```powershell
git add Private/Test-DFToolSchema.ps1 Public/Register-DFTool.ps1 Public/Install-DFTool.ps1 `
    tests/Test-DFToolSchema.Tests.ps1 tests/Register-DFTool.Tests.ps1 tests/Install-DFTool.Tests.ps1
git commit -m "feat: PS module tool type support — type=module schema, Register/Install-DFTool"
```

---

## Task 3: PS module tool records + companion files

**Files:**
- Create: `Tools/posh-git.json`, `Tools/PSFzf.json`, `Tools/Terminal-Icons.json`, `Tools/oh-my-posh.json`
- Create: `Tools/posh-git.ps1` (git pickers: fco, flog, fga, fstash)
- Create: `Tools/oh-my-posh.ps1` (theme picker: fpot)
- Modify: `tests/Test-DFToolSchema.Tests.ps1` — add 4 names to seed list

- [ ] **Step 1: Create `Tools/posh-git.json`**

```json
{
  "name": "posh-git",
  "type": "module",
  "description": "Git status summary in the PowerShell prompt with tab completion for git commands",
  "tags": ["git", "prompt", "module"],
  "executable": "posh-git",
  "packages": { "psresource": "posh-git", "scoop": "posh-git" },
  "xdg": { "compliance": "none", "method": "default" },
  "completions": { "type": "static", "flags": [] },
  "aliases": {},
  "picker": "custom"
}
```

- [ ] **Step 2: Create `Tools/PSFzf.json`**

```json
{
  "name": "PSFzf",
  "type": "module",
  "description": "PowerShell wrapper around fzf with PSReadLine key handler integration",
  "tags": ["fuzzy", "picker", "module"],
  "executable": "PSFzf",
  "packages": { "psresource": "PSFzf", "scoop": "psfzf" },
  "xdg": { "compliance": "none", "method": "default" },
  "completions": { "type": "static", "flags": [] },
  "aliases": {},
  "picker": null
}
```

- [ ] **Step 3: Create `Tools/Terminal-Icons.json`**

```json
{
  "name": "Terminal-Icons",
  "type": "module",
  "description": "Adds Nerd Font file and folder icons to terminal output (ls, eza, etc.)",
  "tags": ["icons", "display", "module"],
  "executable": "Terminal-Icons",
  "packages": { "psresource": "Terminal-Icons" },
  "xdg": { "compliance": "none", "method": "default" },
  "completions": { "type": "static", "flags": [] },
  "aliases": {},
  "picker": null
}
```

- [ ] **Step 4: Create `Tools/oh-my-posh.json`**

```json
{
  "name": "oh-my-posh",
  "description": "Cross-shell prompt theme engine with hundreds of built-in themes",
  "tags": ["prompt", "theme", "display"],
  "executable": "oh-my-posh.exe",
  "packages": { "scoop": "oh-my-posh", "winget": "JanDeDobbeleer.OhMyPosh" },
  "xdg": {
    "compliance": "partial",
    "method": "env",
    "vars": { "POSH_THEMES_PATH": "${XDG_DATA_HOME}/oh-my-posh/themes" },
    "dirs": ["${XDG_DATA_HOME}/oh-my-posh/themes", "${XDG_CONFIG_HOME}/oh-my-posh"]
  },
  "completions": {
    "type": "dynamic",
    "command": "oh-my-posh completion powershell",
    "cache": true
  },
  "aliases": {},
  "picker": "custom"
}
```

- [ ] **Step 5: Create `Tools/posh-git.ps1`**

```powershell
# Companion for posh-git — git fzf pickers (fco, flog, fga, fstash)
# Dot-sourced by Register-DFTool when posh-git module is available.

function global:Select-GitBranch {
    [CmdletBinding()]
    param()
    Invoke-DFPicker `
        -List          { git branch --all --color=always } `
        -Preview       'git log --oneline --color=always {1}' `
        -PreviewWindow 'right:60%' `
        -Ansi `
        -Header        'Select branch  [Enter to checkout]' `
        -Parse         { $_ -replace '^\*\s+', '' -replace '^\s+remotes/origin/', '' -replace '^\s+', '' } `
        -Action        { param($b) git checkout $b }
}
Set-Alias -Name fco -Value Select-GitBranch -Scope Global -Force

function global:Select-GitLog {
    [CmdletBinding()]
    param()
    Invoke-DFPicker `
        -List          { git log --oneline --color=always } `
        -Preview       'git show --color=always {1}' `
        -PreviewWindow 'right:60%' `
        -Ansi `
        -Header        'Select commit  [Enter to show]' `
        -Parse         { ($_ -split ' ')[0] } `
        -Action        { param($sha) git show $sha }
}
Set-Alias -Name flog -Value Select-GitLog -Scope Global -Force

function global:Select-GitFile {
    [CmdletBinding()]
    param()
    $files = Invoke-DFPicker `
        -List          { git status --short } `
        -Preview       'git diff --color=always {2}' `
        -PreviewWindow 'right:60%' `
        -Ansi `
        -Multi `
        -Header        'Select files to stage  [Tab=multi, Enter to git add]'
    if ($files) {
        @($files) | ForEach-Object {
            $file = ($_ -split '\s+', 2)[1].Trim()
            git add $file
        }
        git status --short
    }
}
Set-Alias -Name fga -Value Select-GitFile -Scope Global -Force

function global:Select-GitStash {
    [CmdletBinding()]
    param()
    Invoke-DFPicker `
        -List          { git stash list } `
        -Preview       'git stash show -p {1}' `
        -PreviewWindow 'right:60%' `
        -Ansi `
        -Header        'Select stash  [Enter to apply]' `
        -Parse         { ($_ -split ':')[0] } `
        -Action        { param($ref) git stash apply $ref }
}
Set-Alias -Name fstash -Value Select-GitStash -Scope Global -Force
```

- [ ] **Step 6: Create `Tools/oh-my-posh.ps1`**

```powershell
# Companion for oh-my-posh — theme picker (fpot)
# Dot-sourced by Register-DFTool when oh-my-posh is registered.

function global:Select-PoshTheme {
    [CmdletBinding()]
    param()

    $themesPath = $Env:POSH_THEMES_PATH
    if (-not $themesPath -or -not (Test-Path $themesPath)) {
        Write-Warning 'DotForge: POSH_THEMES_PATH not set or directory not found'
        return
    }

    Invoke-DFPicker `
        -List          { Get-ChildItem $themesPath -Filter '*.omp.json' | Select-Object -ExpandProperty Name } `
        -Preview       "oh-my-posh print primary --config '$themesPath\{}' --shell pwsh" `
        -PreviewWindow 'bottom:3' `
        -Header        'Select oh-my-posh theme  [Enter to apply for this session]' `
        -Action        {
            param($theme)
            oh-my-posh init pwsh --config "$themesPath\$theme" | Invoke-Expression
            Write-Host "✓ Theme applied: $theme  (to persist: update oh-my-posh config path)" -ForegroundColor Green
        }
}
Set-Alias -Name fpot -Value Select-PoshTheme -Scope Global -Force
```

- [ ] **Step 7: Add 4 new names to seed file validation**

In `tests/Test-DFToolSchema.Tests.ps1`, find the `$seedFiles = @(...)` array. Add the 4 new names:

```powershell
    $seedFiles = @(
        'bat', 'eza', 'fzf', 'ripgrep', 'zoxide',
        'fd', 'broot', 'jq', 'glow', 'procs', 'winfetch',
        'curl', 'wget', 'docker', 'less', 'gh', 'delta',
        'lazygit', 'rustup', 'uv', 'chezmoi', 'micro',
        'bitwarden', 'npm', 'scoop', 'winget',
        'posh-git', 'PSFzf', 'Terminal-Icons', 'oh-my-posh'
    ) | ForEach-Object {
        @{ Name = $_; Path = Join-Path $PSScriptRoot "../Tools/$_.json" }
    }
```

- [ ] **Step 8: Run schema tests — 7 + 30 = 37 tests must pass**

```powershell
Invoke-Pester tests/Test-DFToolSchema.Tests.ps1 -Output Detailed
```

Expected: 37/37 passing (7 schema unit tests + 30 seed file tests).

- [ ] **Step 9: Commit**

```powershell
git add Tools/posh-git.json Tools/PSFzf.json Tools/Terminal-Icons.json Tools/oh-my-posh.json `
    Tools/posh-git.ps1 Tools/oh-my-posh.ps1 tests/Test-DFToolSchema.Tests.ps1
git commit -m "feat: PS module tool records (posh-git, PSFzf, Terminal-Icons, oh-my-posh) + git/theme pickers"
```

---

## Task 4: PSGallery prep — GUID, LICENSE, CHANGELOG, README

**Files:**
- Modify: `DotForge.psd1` — real GUID, ReleaseNotes
- Create: `LICENSE`
- Create: `CHANGELOG.md`
- Create: `README.md`

- [ ] **Step 1: Generate a real GUID and update `DotForge.psd1`**

Run in PowerShell to get a real GUID:
```powershell
[System.Guid]::NewGuid().ToString()
```

In `DotForge.psd1`, replace the placeholder GUID `a1b2c3d4-e5f6-7890-abcd-ef1234567890`
with the generated value. Also update `ModuleVersion` to `'0.1.0'` (already set) and
add `ReleaseNotes`:

```powershell
    PrivateData       = @{
        PSData = @{
            Tags         = @('CLI', 'Tools', 'Profile', 'XDG', 'fzf', 'Configuration', 'Windows')
            LicenseUri   = 'https://github.com/simsrw73/DotForge/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/simsrw73/DotForge'
            ReleaseNotes = 'Initial release: tool registry, Register-DFTool, Install-DFTool, Initialize-DFEnvironment, Update-DFCompletions, 30 tool records.'
        }
    }
```

- [ ] **Step 2: Create `LICENSE`**

```
MIT License

Copyright (c) 2026 Randy W. Sims

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

- [ ] **Step 3: Create `CHANGELOG.md`**

```markdown
# Changelog

All notable changes to DotForge are documented here.

## [Unreleased]

## [0.1.0] — 2026-05-07

### Added

- **Core primitives:** `Add-DFToPath` (normalized PATH dedup), `Ensure-DFDir` (idempotent
  directory creation), `Invoke-DFPicker` (generalized fzf picker), `Get-DFCachedCompletion`
  (mtime-based completion caching)
- **Tool registry:** `Import-DFToolDb` (JSON DB loader), `Get-DFTool`, `Find-DFTool`
- **Configuration:** `Register-DFTool` — applies XDG env vars, static/dynamic completions,
  aliases, declarative fzf pickers, companion .ps1 dot-sourcing
- **Installation:** `Install-DFTool` (scoop / winget / choco / psresource), `Initialize-DFEnvironment`
- **Completions:** `Update-DFCompletions` — on-demand completion cache refresh
- **Tool records:** 30 JSON records covering file tools, dev tools, pagers, package managers,
  Python, Rust, Node, dotfiles, security, and PowerShell module tools
- **`$DFConfig`** user configuration hashtable (`SkipTools`, `PackageManagerOrder`)
- **PS module tool type:** `type = "module"` in tool JSON; checks `Get-Module -ListAvailable`
```

- [ ] **Step 4: Create `README.md`**

```markdown
# DotForge

**PowerShell module for registering and configuring CLI tools — XDG paths, completion
caching, fzf pickers, and one-command installation.**

DotForge encodes CLI tool configuration knowledge (the kind you normally copy-paste
between dotfiles repos) into a JSON database, then applies it on demand.

## Requirements

- PowerShell 7.0+
- Windows 11 (v0.1 — macOS/Linux in a future release)
- At least one package manager: [scoop](https://scoop.sh), [winget](https://learn.microsoft.com/en-us/windows/package-manager/winget/), or [choco](https://chocolatey.org/)
- [fzf](https://github.com/junegunn/fzf) for picker functions (optional but recommended)

## Installation

### From GitHub (current)

```powershell
git clone https://github.com/simsrw73/DotForge.git
Import-Module C:\path\to\DotForge\DotForge.psd1
```

### From PSGallery (coming soon)

```powershell
Install-PSResource -Name DotForge -Scope CurrentUser
```

## Quick Start

```powershell
# 1. Bootstrap XDG dirs and detect package managers
Initialize-DFEnvironment

# 2. Configure all installed tools in the current session
Register-DFTool -All

# 3. Install a tool you don't have yet
Install-DFTool -Name ripgrep

# 4. Update completion scripts after upgrading tools
Update-DFCompletions
```

## User Configuration (`$DFConfig`)

Set `$DFConfig` in your profile **before** importing DotForge:

```powershell
$DFConfig = @{
    PackageManagerOrder = @('scoop', 'winget')   # PM preference for Install-DFTool
    SkipTools           = @('lsd')               # excluded from Register-DFTool -All
}
Import-Module DotForge
Register-DFTool -All
```

## Exported Cmdlets

| Cmdlet | Purpose |
|--------|---------|
| `Initialize-DFEnvironment` | Bootstrap XDG dirs; detect package managers |
| `Register-DFTool [-Name] [-All]` | Configure tools in the current session |
| `Install-DFTool -Name <tool>` | Install via scoop/winget/choco/psresource |
| `Update-DFCompletions [-Name]` | Refresh dynamic completion caches |
| `Get-DFTool [-Name] [-Tag]` | Query the tool registry |
| `Find-DFTool -Pattern <str>` | Wildcard search across name/description/tags |
| `Add-DFToPath <dir> [-Prepend]` | Normalized, dedup PATH addition |
| `Ensure-DFDir <path>` | Idempotent directory creation |
| `Invoke-DFPicker` | Generalized fzf picker skeleton |
| `Get-DFCachedCompletion` | Mtime-based completion script caching |

## Tool Records

Each tool is described by a `Tools/<name>.json` file. Required fields:
- `name` — tool identifier
- `executable` — exe name (or module name for `type = "module"`)

Optional fields:
- `type` — `"exe"` (default) or `"module"` (PS module)
- `packages` — package manager IDs: `scoop`, `winget`, `choco`, `psresource`
- `xdg` — XDG compliance: `method` (`default`/`env`/`config`/`wrapper`/`manual`), `vars`, `dirs`
- `completions` — `type` (`static`/`dynamic`), `flags` or `command`
- `aliases` — `{ "alias": { "command": "...", "args": [...] } }`
- `picker` — declarative fzf picker spec or `"custom"` (companion `.ps1`)

Companion `Tools/<name>.ps1` files are dot-sourced automatically when the tool is registered.

## Known Tools (30 included)

File/dir: bat, eza, fd, ripgrep, broot
Text/data: jq, glow
System: procs, winfetch
Network: curl, wget
Container: docker
Editors: micro
Fuzzy/nav: fzf, zoxide
Pagers: less
Package managers: scoop, winget, npm
Dev: gh, delta, lazygit, rustup, cargo, uv, chezmoi
PS modules: posh-git, PSFzf, Terminal-Icons, oh-my-posh

## License

MIT — see [LICENSE](LICENSE).
```

- [ ] **Step 5: Commit**

```powershell
git add DotForge.psd1 LICENSE CHANGELOG.md README.md
git commit -m "docs: PSGallery prep — real GUID, LICENSE, CHANGELOG, README"
```

---

## Task 5: Module wiring + full test run + push

**Files:**
- Modify: `DotForge.psd1` — add `Update-DFCompletions` to `FunctionsToExport`

- [ ] **Step 1: Update `DotForge.psd1` exports**

Add `Update-DFCompletions` to `FunctionsToExport`:

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
    'Install-DFTool',
    'Update-DFCompletions'
)
```

- [ ] **Step 2: Verify module imports with 10 exports**

```powershell
pwsh -NoProfile -Command "
  Import-Module 'C:\Users\simsr\projects\DotForge\DotForge.psd1' -Force
  Get-Command -Module DotForge | Select-Object Name | Sort-Object Name
"
```

Expected (10 functions sorted):
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
Update-DFCompletions
```

- [ ] **Step 3: Run full StrictMode suite**

```powershell
pwsh -NoProfile -Command "
  Set-StrictMode -Version Latest
  `$ErrorActionPreference = 'Continue'
  Import-Module Pester -MinimumVersion 5.0
  `$r = Invoke-Pester 'C:\Users\simsr\projects\DotForge\tests\' -PassThru -Output Normal
  Write-Host \"Passed: `$(`$r.PassedCount)  Failed: `$(`$r.FailedCount)\"
"
```

Expected: 0 failures. Approximate test count:
113 (Phase 1-3) + 5 (Update-DFCompletions) + 3 (type support) + 4 (new seeds) = ~125 tests.

- [ ] **Step 4: Commit and push**

```powershell
cd C:\Users\simsr\projects\DotForge
git add DotForge.psd1
git commit -m "feat: Phase 4 complete — Update-DFCompletions, PS module support, 30 tool records

New export: Update-DFCompletions (10 total)
Schema: type=module field with exe/module validation
Register-DFTool: Get-Module check for type=module
Install-DFTool: psresource PM support
Tool records: posh-git, PSFzf, Terminal-Icons, oh-my-posh (30 total)
Companions: posh-git.ps1 (fco/flog/fga/fstash), oh-my-posh.ps1 (fpot)
Docs: LICENSE, CHANGELOG, README, real module GUID"

git push
```

---

## Self-Review Notes

**Spec coverage:**
- `Update-DFCompletions` ✓ Task 1
- PS module type support ✓ Task 2 (schema, Register-DFTool, Install-DFTool)
- PS module tool records (posh-git, PSFzf, Terminal-Icons) ✓ Task 3
- oh-my-posh record ✓ Task 3
- Companion files (posh-git.ps1, oh-my-posh.ps1) ✓ Task 3
- `FunctionsToExport` finalized ✓ Task 5
- README ✓ Task 4
- LICENSE ✓ Task 4
- CHANGELOG ✓ Task 4
- Real GUID ✓ Task 4

**Not in Phase 4 (future work):**
- macOS/Linux support
- PSGallery publishing (requires `Publish-PSResource` + API key)
- `xdg.method = "wrapper"` deeper implementation (currently verbose-log; companion .ps1 already handles it)
- Async profile loading optimization

**Type consistency:**
- `type = "module"` used consistently in JSON, schema validator, Register-DFTool, Install-DFTool
- `psresource` PM key used consistently in JSON `packages` field and Install-DFTool switch
- `Update-DFCompletions -Name` matches the `-Name [string[]]` convention from `Install-DFTool`
