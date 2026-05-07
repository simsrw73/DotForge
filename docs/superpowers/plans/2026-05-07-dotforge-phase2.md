# DotForge Phase 2 — Tool Registry + Register-DFTool Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the tool registry (load/query JSON database) and `Register-DFTool` (configure any known tool in the current session — XDG env vars, completions, aliases, pickers, companion scripts).

**Architecture:** `Import-DFToolDb` (private) loads `Tools/*.json` into a module-scoped hashtable cache. `Get-DFTool`/`Find-DFTool` (public) query it. `Register-DFTool` (public) iterates over tool records, applies XDG env vars, registers argument completers, sets aliases (both `Set-Alias` for zero-arg and dynamic functions for arg-bearing aliases), creates declarative pickers via `Invoke-DFPicker`, and dot-sources companion `.ps1` files. All functions accept an optional `$ToolsPath` parameter for test isolation. Phase 2 handles `xdg.method = "env"` and `"default"`; `"config"` and `"wrapper"` are Phase 3.

**Tech Stack:** PowerShell 7+, Pester 5. Builds on Phase 1: `Add-DFToPath`, `Ensure-DFDir`, `Invoke-DFPicker`, `Get-DFCachedCompletion`, `Test-DFToolSchema`.

---

## Phase 1 Foundation (already exists, do not modify)

```
Public/Add-DFToPath.ps1
Public/Ensure-DFDir.ps1
Public/Invoke-DFPicker.ps1
Public/Get-DFCachedCompletion.ps1
Private/Invoke-DFFzf.ps1
Private/Test-DFToolSchema.ps1
Tools/bat.json  eza.json  fzf.json  ripgrep.json  zoxide.json
tests/ (38 passing tests)
```

## File Map — New Files This Phase

| File | Role |
|------|------|
| `Private/Import-DFToolDb.ps1` | Load + cache `Tools/*.json` → hashtable |
| `Private/Expand-DFXdgPath.ps1` | Expand `${XDG_*}` template strings |
| `Public/Get-DFTool.ps1` | Exact/filtered query against registry |
| `Public/Find-DFTool.ps1` | Wildcard/pattern search across registry |
| `Public/Register-DFTool.ps1` | Configure a tool in the current session |
| `Tools/<name>.json` | 20+ new tool records |
| `Tools/ripgrep.ps1` | Companion: `Select-RipgrepResult` / `frg` |
| `Tools/procs.ps1` | Companion: `Select-Process` / `fkill` |
| `tests/Import-DFToolDb.Tests.ps1` | Pester tests |
| `tests/Expand-DFXdgPath.Tests.ps1` | Pester tests |
| `tests/Get-DFTool.Tests.ps1` | Pester tests |
| `tests/Register-DFTool.Tests.ps1` | Pester tests |

---

## Task 1: `Import-DFToolDb`

**Files:**
- Create: `Private/Import-DFToolDb.ps1`
- Create: `tests/Import-DFToolDb.Tests.ps1`

### What it does

Loads all `*.json` files from a tools directory, validates each with `Test-DFToolSchema`,
caches the result in `$script:DFToolDb` (module-scoped when loaded via `DotForge.psm1`).
Returns the hashtable keyed by tool name. Accepts optional `$ToolsPath` for test isolation.

- [ ] **Step 1: Write the failing tests**

Create `C:\Users\simsr\projects\DotForge\tests\Import-DFToolDb.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/../Private/Test-DFToolSchema.ps1"
    . "$PSScriptRoot/../Private/Import-DFToolDb.ps1"
}

Describe 'Import-DFToolDb' {
    BeforeEach {
        $script:DFToolDb = $null  # reset cache between tests

        # Build a temp tools directory with controlled JSON content
        $script:TmpTools = Join-Path $TestDrive 'tools'
        New-Item -ItemType Directory -Force -Path $script:TmpTools | Out-Null

        $validJson = @'
{ "name": "mytool", "executable": "mytool.exe" }
'@
        $validJson | Set-Content (Join-Path $script:TmpTools 'mytool.json')
    }

    It 'returns a hashtable keyed by tool name' {
        $db = Import-DFToolDb -ToolsPath $script:TmpTools
        $db | Should -BeOfType [hashtable]
        $db.ContainsKey('mytool') | Should -BeTrue
    }

    It 'returns cached result on second call without -Force' {
        $db1 = Import-DFToolDb -ToolsPath $script:TmpTools
        # Modify the tools dir — second call should NOT pick this up
        '{ "name": "extra", "executable": "extra.exe" }' |
            Set-Content (Join-Path $script:TmpTools 'extra.json')
        $db2 = Import-DFToolDb -ToolsPath $script:TmpTools
        $db2.ContainsKey('extra') | Should -BeFalse
    }

    It 'reloads when -Force is specified' {
        $db1 = Import-DFToolDb -ToolsPath $script:TmpTools
        '{ "name": "extra", "executable": "extra.exe" }' |
            Set-Content (Join-Path $script:TmpTools 'extra.json')
        $db2 = Import-DFToolDb -ToolsPath $script:TmpTools -Force
        $db2.ContainsKey('extra') | Should -BeTrue
    }

    It 'emits a warning and skips files that fail schema validation' {
        '{ "missingName": true }' |
            Set-Content (Join-Path $script:TmpTools 'bad.json')
        $db = Import-DFToolDb -ToolsPath $script:TmpTools -WarningVariable warns 3>$null
        $db.ContainsKey('mytool') | Should -BeTrue
        $warns | Should -Not -BeNullOrEmpty
    }

    It 'returns empty hashtable when ToolsPath does not exist' {
        $db = Import-DFToolDb -ToolsPath 'C:\nonexistent\tools'
        $db | Should -BeOfType [hashtable]
        $db.Count | Should -Be 0
    }
}
```

- [ ] **Step 2: Run tests — confirm they fail**

```powershell
cd C:\Users\simsr\projects\DotForge
Invoke-Pester tests/Import-DFToolDb.Tests.ps1 -Output Detailed
```

Expected: All 5 tests fail.

- [ ] **Step 3: Implement `Import-DFToolDb`**

Create `C:\Users\simsr\projects\DotForge\Private\Import-DFToolDb.ps1`:

```powershell
#Requires -Version 7.0

$script:DFToolDb = $null

function script:Import-DFToolDb {
    <#
    .SYNOPSIS
        Loads Tools/*.json files into a cached hashtable keyed by tool name.
        Validates each file with Test-DFToolSchema; invalid files are skipped with a warning.
    .PARAMETER ToolsPath
        Path to the tools directory. Defaults to the module's Tools/ folder.
        Pass an explicit path in tests to control which JSON files are loaded.
    .PARAMETER Force
        Clears the cache and reloads from disk.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$ToolsPath = (Join-Path $PSScriptRoot '../Tools'),
        [switch]$Force
    )

    if ($script:DFToolDb -and -not $Force) { return $script:DFToolDb }

    $db = @{}

    if (Test-Path $ToolsPath -PathType Container) {
        Get-ChildItem $ToolsPath -Filter '*.json' -ErrorAction Ignore |
            ForEach-Object {
                try {
                    $tool = Get-Content $_.FullName -Raw | ConvertFrom-Json
                    $errors = @()
                    if (Test-DFToolSchema -Tool $tool -Errors ([ref]$errors)) {
                        $db[$tool.name] = $tool
                    } else {
                        Write-Warning "DotForge: $($_.Name) schema errors: $($errors -join '; ')"
                    }
                } catch {
                    Write-Warning "DotForge: Failed to parse $($_.Name): $($_.Exception.Message)"
                }
            }
    }

    $script:DFToolDb = $db
    return $db
}
```

- [ ] **Step 4: Run tests — confirm all 5 pass**

```powershell
Invoke-Pester tests/Import-DFToolDb.Tests.ps1 -Output Detailed
```

Expected: 5/5 passing.

- [ ] **Step 5: Commit**

```powershell
git add Private/Import-DFToolDb.ps1 tests/Import-DFToolDb.Tests.ps1
git commit -m "feat: Import-DFToolDb — cached JSON tool registry loader"
```

---

## Task 2: `Expand-DFXdgPath`

**Files:**
- Create: `Private/Expand-DFXdgPath.ps1`
- Create: `tests/Expand-DFXdgPath.Tests.ps1`

### What it does

Replaces `${XDG_CONFIG_HOME}`, `${XDG_DATA_HOME}`, `${XDG_STATE_HOME}`, `${XDG_CACHE_HOME}`
placeholders in a template string with the actual env var values.

- [ ] **Step 1: Write the failing tests**

Create `C:\Users\simsr\projects\DotForge\tests\Expand-DFXdgPath.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/../Private/Expand-DFXdgPath.ps1"
}

Describe 'Expand-DFXdgPath' {
    BeforeEach {
        $script:SavedConfigHome = $Env:XDG_CONFIG_HOME
        $script:SavedDataHome   = $Env:XDG_DATA_HOME
        $script:SavedStateHome  = $Env:XDG_STATE_HOME
        $script:SavedCacheHome  = $Env:XDG_CACHE_HOME
        $Env:XDG_CONFIG_HOME = 'C:\config'
        $Env:XDG_DATA_HOME   = 'C:\data'
        $Env:XDG_STATE_HOME  = 'C:\state'
        $Env:XDG_CACHE_HOME  = 'C:\cache'
    }
    AfterEach {
        $Env:XDG_CONFIG_HOME = $script:SavedConfigHome
        $Env:XDG_DATA_HOME   = $script:SavedDataHome
        $Env:XDG_STATE_HOME  = $script:SavedStateHome
        $Env:XDG_CACHE_HOME  = $script:SavedCacheHome
    }

    It 'expands ${XDG_CONFIG_HOME}' {
        Expand-DFXdgPath '${XDG_CONFIG_HOME}/bat/bat.conf' |
            Should -Be 'C:\config/bat/bat.conf'
    }

    It 'expands ${XDG_DATA_HOME}' {
        Expand-DFXdgPath '${XDG_DATA_HOME}/zoxide' |
            Should -Be 'C:\data/zoxide'
    }

    It 'expands ${XDG_STATE_HOME}' {
        Expand-DFXdgPath '${XDG_STATE_HOME}/less/history' |
            Should -Be 'C:\state/less/history'
    }

    It 'expands ${XDG_CACHE_HOME}' {
        Expand-DFXdgPath '${XDG_CACHE_HOME}/uv' | Should -Be 'C:\cache/uv'
    }

    It 'passes through strings with no placeholders unchanged' {
        Expand-DFXdgPath 'C:\absolute\path' | Should -Be 'C:\absolute\path'
    }

    It 'expands multiple placeholders in one string' {
        Expand-DFXdgPath '${XDG_CONFIG_HOME}/tool and ${XDG_CACHE_HOME}/tool' |
            Should -Be 'C:\config/tool and C:\cache/tool'
    }
}
```

- [ ] **Step 2: Run tests — confirm they fail**

```powershell
Invoke-Pester tests/Expand-DFXdgPath.Tests.ps1 -Output Detailed
```

Expected: All 6 tests fail.

- [ ] **Step 3: Implement `Expand-DFXdgPath`**

Create `C:\Users\simsr\projects\DotForge\Private\Expand-DFXdgPath.ps1`:

```powershell
#Requires -Version 7.0

function script:Expand-DFXdgPath {
    <#
    .SYNOPSIS
        Expands ${XDG_*} placeholder tokens in a template string to their
        actual environment variable values.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Template)

    $Template `
        -replace '\$\{XDG_CONFIG_HOME\}', $Env:XDG_CONFIG_HOME `
        -replace '\$\{XDG_DATA_HOME\}',   $Env:XDG_DATA_HOME `
        -replace '\$\{XDG_STATE_HOME\}',  $Env:XDG_STATE_HOME `
        -replace '\$\{XDG_CACHE_HOME\}',  $Env:XDG_CACHE_HOME
}
```

- [ ] **Step 4: Run tests — confirm all 6 pass**

```powershell
Invoke-Pester tests/Expand-DFXdgPath.Tests.ps1 -Output Detailed
```

Expected: 6/6 passing.

- [ ] **Step 5: Commit**

```powershell
git add Private/Expand-DFXdgPath.ps1 tests/Expand-DFXdgPath.Tests.ps1
git commit -m "feat: Expand-DFXdgPath — XDG template string expansion"
```

---

## Task 3: `Get-DFTool` and `Find-DFTool`

**Files:**
- Create: `Public/Get-DFTool.ps1`
- Create: `Public/Find-DFTool.ps1`
- Create: `tests/Get-DFTool.Tests.ps1`

### What they do

`Get-DFTool`: exact query by `-Name` or filter by `-Tag`, or list all tools.
`Find-DFTool`: wildcard/pattern search across name, description, and tags.

- [ ] **Step 1: Write the failing tests**

Create `C:\Users\simsr\projects\DotForge\tests\Get-DFTool.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/../Private/Test-DFToolSchema.ps1"
    . "$PSScriptRoot/../Private/Import-DFToolDb.ps1"
    . "$PSScriptRoot/../Public/Get-DFTool.ps1"
    . "$PSScriptRoot/../Public/Find-DFTool.ps1"

    # Build a controlled tools directory
    $script:TmpTools = Join-Path $TestDrive 'tools'
    New-Item -ItemType Directory -Force -Path $script:TmpTools | Out-Null

    @'
{ "name": "alpha", "executable": "alpha.exe", "description": "First tool",
  "tags": ["viewer", "pager"] }
'@ | Set-Content (Join-Path $script:TmpTools 'alpha.json')

    @'
{ "name": "beta", "executable": "beta.exe", "description": "Second viewer",
  "tags": ["viewer"] }
'@ | Set-Content (Join-Path $script:TmpTools 'beta.json')

    @'
{ "name": "gamma", "executable": "gamma.exe", "description": "Third tool",
  "tags": ["search"] }
'@ | Set-Content (Join-Path $script:TmpTools 'gamma.json')
}

BeforeEach { $script:DFToolDb = $null }

Describe 'Get-DFTool' {
    It 'returns all tools when called with no parameters' {
        $results = Get-DFTool -ToolsPath $script:TmpTools
        @($results).Count | Should -Be 3
    }

    It 'returns one tool by exact name' {
        $result = Get-DFTool -Name 'alpha' -ToolsPath $script:TmpTools
        $result.name | Should -Be 'alpha'
    }

    It 'returns null for an unknown name' {
        $result = Get-DFTool -Name 'unknown' -ToolsPath $script:TmpTools
        $result | Should -BeNullOrEmpty
    }

    It 'returns all tools with a matching tag' {
        $results = Get-DFTool -Tag 'viewer' -ToolsPath $script:TmpTools
        @($results).Count | Should -Be 2
        @($results).name | Should -Contain 'alpha'
        @($results).name | Should -Contain 'beta'
    }

    It 'returns nothing when no tools match the tag' {
        $results = Get-DFTool -Tag 'nonexistent' -ToolsPath $script:TmpTools
        @($results).Count | Should -Be 0
    }
}

Describe 'Find-DFTool' {
    It 'finds tools by name pattern' {
        $results = Find-DFTool -Pattern 'alph' -ToolsPath $script:TmpTools
        @($results).Count | Should -Be 1
        @($results)[0].name | Should -Be 'alpha'
    }

    It 'finds tools by description pattern' {
        $results = Find-DFTool -Pattern 'viewer' -ToolsPath $script:TmpTools
        @($results).Count | Should -Be 1
        @($results)[0].name | Should -Be 'beta'
    }

    It 'finds tools by tag pattern' {
        $results = Find-DFTool -Pattern 'search' -ToolsPath $script:TmpTools
        @($results).Count | Should -Be 1
        @($results)[0].name | Should -Be 'gamma'
    }

    It 'returns empty when pattern matches nothing' {
        $results = Find-DFTool -Pattern 'zzznomatch' -ToolsPath $script:TmpTools
        @($results).Count | Should -Be 0
    }
}
```

- [ ] **Step 2: Run tests — confirm they fail**

```powershell
Invoke-Pester tests/Get-DFTool.Tests.ps1 -Output Detailed
```

Expected: All 9 tests fail.

- [ ] **Step 3: Implement `Get-DFTool`**

Create `C:\Users\simsr\projects\DotForge\Public\Get-DFTool.ps1`:

```powershell
#Requires -Version 7.0

function Get-DFTool {
    <#
    .SYNOPSIS
        Queries the DotForge tool registry.
    .PARAMETER Name
        Return the tool with this exact name.
    .PARAMETER Tag
        Return all tools that have this tag.
    .PARAMETER ToolsPath
        Override the tools directory (used in tests).
    #>
    [CmdletBinding(DefaultParameterSetName = 'All')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(ParameterSetName = 'ByName')][string]$Name,
        [Parameter(ParameterSetName = 'ByTag')][string]$Tag,
        [string]$ToolsPath
    )

    $dbArgs = if ($ToolsPath) { @{ ToolsPath = $ToolsPath } } else { @{} }
    $db = Import-DFToolDb @dbArgs
    $results = $db.Values

    switch ($PSCmdlet.ParameterSetName) {
        'ByName' { $results = $results | Where-Object { $_.name -eq $Name } }
        'ByTag'  {
            $results = $results | Where-Object {
                $tags = $_.PSObject.Properties['tags']?.Value
                $tags -and ($tags -contains $Tag)
            }
        }
    }

    $results
}
```

- [ ] **Step 4: Implement `Find-DFTool`**

Create `C:\Users\simsr\projects\DotForge\Public\Find-DFTool.ps1`:

```powershell
#Requires -Version 7.0

function Find-DFTool {
    <#
    .SYNOPSIS
        Searches the DotForge tool registry by wildcard pattern across name,
        description, and tags.
    .PARAMETER Pattern
        Wildcard pattern to match (e.g. 'rip', 'grep*', '*viewer*').
    .PARAMETER ToolsPath
        Override the tools directory (used in tests).
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][string]$Pattern,
        [string]$ToolsPath
    )

    $dbArgs = if ($ToolsPath) { @{ ToolsPath = $ToolsPath } } else { @{} }
    $db = Import-DFToolDb @dbArgs

    $db.Values | Where-Object {
        $_.name -like "*$Pattern*" -or
        ($_.PSObject.Properties['description']?.Value -like "*$Pattern*") -or
        ($_.PSObject.Properties['tags']?.Value | Where-Object { $_ -like "*$Pattern*" })
    }
}
```

- [ ] **Step 5: Run tests — confirm all 9 pass**

```powershell
Invoke-Pester tests/Get-DFTool.Tests.ps1 -Output Detailed
```

Expected: 9/9 passing.

- [ ] **Step 6: Commit**

```powershell
git add Public/Get-DFTool.ps1 Public/Find-DFTool.ps1 tests/Get-DFTool.Tests.ps1
git commit -m "feat: Get-DFTool + Find-DFTool — tool registry query functions"
```

---

## Task 4: `Register-DFTool`

**Files:**
- Create: `Public/Register-DFTool.ps1`
- Create: `tests/Register-DFTool.Tests.ps1`

### What it does

For each specified tool:
1. Checks `$tool.executable` is on PATH — skips with `Write-Verbose` if not found
2. **XDG** (`method = "env"`): sets env vars from `xdg.vars` (expanding `${XDG_*}`); creates dirs from `xdg.dirs`
3. **Completions** (`type = "static"`): `Register-ArgumentCompleter`; (`type = "dynamic"`): `Get-DFCachedCompletion`
4. **Aliases**: zero-arg → `Set-Alias -Force`; arg-bearing → dynamic function via `Set-Item`
5. **Declarative picker** (`picker` is a PSCustomObject): creates a global function calling `Invoke-DFPicker`
6. **Companion `.ps1`**: if `Tools/<name>.ps1` exists, dot-sources it

Phase 2 only handles `xdg.method = "env"` and `"default"`. `"config"` and `"wrapper"` log a Verbose message and are deferred to Phase 3. `"manual"` emits a Warning.

- [ ] **Step 1: Write the failing tests**

Create `C:\Users\simsr\projects\DotForge\tests\Register-DFTool.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/../Public/Ensure-DFDir.ps1"
    . "$PSScriptRoot/../Public/Get-DFCachedCompletion.ps1"
    . "$PSScriptRoot/../Private/Invoke-DFFzf.ps1"
    . "$PSScriptRoot/../Public/Invoke-DFPicker.ps1"
    . "$PSScriptRoot/../Private/Test-DFToolSchema.ps1"
    . "$PSScriptRoot/../Private/Expand-DFXdgPath.ps1"
    . "$PSScriptRoot/../Private/Import-DFToolDb.ps1"
    . "$PSScriptRoot/../Public/Get-DFTool.ps1"
    . "$PSScriptRoot/../Public/Find-DFTool.ps1"
    . "$PSScriptRoot/../Public/Register-DFTool.ps1"
}

Describe 'Register-DFTool' {
    BeforeEach {
        $script:DFToolDb = $null
        $script:SavedConfigHome = $Env:XDG_CONFIG_HOME
        $script:SavedCacheHome  = $Env:XDG_CACHE_HOME
        $Env:XDG_CONFIG_HOME = Join-Path $TestDrive 'config'
        $Env:XDG_CACHE_HOME  = Join-Path $TestDrive 'cache'

        # Create a minimal test tools directory
        $script:TmpTools = Join-Path $TestDrive 'tools'
        New-Item -ItemType Directory -Force -Path $script:TmpTools | Out-Null

        @'
{
  "name": "testtool",
  "executable": "testtool.exe",
  "xdg": {
    "compliance": "partial",
    "method": "env",
    "vars": { "TESTTOOL_CONFIG": "${XDG_CONFIG_HOME}/testtool/config.conf" },
    "dirs": ["${XDG_CONFIG_HOME}/testtool"]
  },
  "completions": { "type": "static", "flags": ["--verbose", "--output"] },
  "aliases": {
    "tt": { "command": "testtool", "args": [] },
    "tt-v": { "command": "testtool", "args": ["--verbose"] }
  },
  "picker": {
    "alias": "ftt",
    "function": "Select-TestTool",
    "list": "testtool list",
    "preview_window": "hidden",
    "header": "Select item",
    "action": "testtool show {}"
  }
}
'@ | Set-Content (Join-Path $script:TmpTools 'testtool.json')
    }

    AfterEach {
        $Env:XDG_CONFIG_HOME = $script:SavedConfigHome
        $Env:XDG_CACHE_HOME  = $script:SavedCacheHome
        Remove-Item Env:\TESTTOOL_CONFIG -ErrorAction Ignore
        Remove-Alias tt -Force -Scope Global -ErrorAction Ignore
        Remove-Item 'function:global:tt-v'        -ErrorAction Ignore
        Remove-Item 'function:global:Select-TestTool' -ErrorAction Ignore
        Remove-Alias ftt -Force -Scope Global -ErrorAction Ignore
    }

    It 'skips tools not found on PATH (no error)' {
        Mock Get-Command { $null }
        { Register-DFTool -Name 'testtool' -ToolsPath $script:TmpTools } |
            Should -Not -Throw
    }

    It 'sets XDG env vars when method is env' {
        Mock Get-Command { [PSCustomObject]@{ Path = 'C:\fake\testtool.exe' } }
        Mock Register-ArgumentCompleter { }
        Register-DFTool -Name 'testtool' -ToolsPath $script:TmpTools
        $Env:TESTTOOL_CONFIG | Should -Be "$($Env:XDG_CONFIG_HOME)/testtool/config.conf"
    }

    It 'creates XDG dirs when method is env' {
        Mock Get-Command { [PSCustomObject]@{ Path = 'C:\fake\testtool.exe' } }
        Mock Register-ArgumentCompleter { }
        Register-DFTool -Name 'testtool' -ToolsPath $script:TmpTools
        Test-Path (Join-Path $Env:XDG_CONFIG_HOME 'testtool') -PathType Container |
            Should -BeTrue
    }

    It 'registers static completions via Register-ArgumentCompleter' {
        Mock Get-Command { [PSCustomObject]@{ Path = 'C:\fake\testtool.exe' } }
        Mock Register-ArgumentCompleter { } -Verifiable
        Register-DFTool -Name 'testtool' -ToolsPath $script:TmpTools
        Should -Invoke Register-ArgumentCompleter -Times 1
    }

    It 'creates a Set-Alias for zero-arg aliases' {
        Mock Get-Command { [PSCustomObject]@{ Path = 'C:\fake\testtool.exe' } }
        Mock Register-ArgumentCompleter { }
        Register-DFTool -Name 'testtool' -ToolsPath $script:TmpTools
        Get-Alias tt -ErrorAction Ignore | Should -Not -BeNullOrEmpty
    }

    It 'creates a wrapper function for arg-bearing aliases' {
        Mock Get-Command { [PSCustomObject]@{ Path = 'C:\fake\testtool.exe' } }
        Mock Register-ArgumentCompleter { }
        Register-DFTool -Name 'testtool' -ToolsPath $script:TmpTools
        Test-Path 'function:global:tt-v' | Should -BeTrue
    }

    It 'creates a global picker function from declarative picker JSON' {
        Mock Get-Command { [PSCustomObject]@{ Path = 'C:\fake\testtool.exe' } }
        Mock Register-ArgumentCompleter { }
        Register-DFTool -Name 'testtool' -ToolsPath $script:TmpTools
        Test-Path 'function:global:Select-TestTool' | Should -BeTrue
    }

    It 'creates a picker alias when picker.alias is set' {
        Mock Get-Command { [PSCustomObject]@{ Path = 'C:\fake\testtool.exe' } }
        Mock Register-ArgumentCompleter { }
        Register-DFTool -Name 'testtool' -ToolsPath $script:TmpTools
        Get-Alias ftt -ErrorAction Ignore | Should -Not -BeNullOrEmpty
    }

    It 'dot-sources a companion .ps1 when it exists' {
        Mock Get-Command { [PSCustomObject]@{ Path = 'C:\fake\testtool.exe' } }
        Mock Register-ArgumentCompleter { }
        # Create a companion that sets a sentinel variable
        '$global:CompanionLoaded = $true' |
            Set-Content (Join-Path $script:TmpTools 'testtool.ps1')
        Register-DFTool -Name 'testtool' -ToolsPath $script:TmpTools
        $Global:CompanionLoaded | Should -BeTrue
        Remove-Variable CompanionLoaded -Scope Global -ErrorAction Ignore
    }

    It 'warns for unknown tool name' {
        Register-DFTool -Name 'nosuch' -ToolsPath $script:TmpTools `
            -WarningVariable warns 3>$null
        $warns | Where-Object { $_ -match 'nosuch' } | Should -Not -BeNullOrEmpty
    }

    It 'registers all installed tools when -All is specified' {
        Mock Get-Command { [PSCustomObject]@{ Path = 'C:\fake\tool.exe' } }
        Mock Register-ArgumentCompleter { }
        { Register-DFTool -All -ToolsPath $script:TmpTools } | Should -Not -Throw
    }
}
```

- [ ] **Step 2: Run tests — confirm they fail**

```powershell
Invoke-Pester tests/Register-DFTool.Tests.ps1 -Output Detailed
```

Expected: All 11 tests fail.

- [ ] **Step 3: Implement `Register-DFTool`**

Create `C:\Users\simsr\projects\DotForge\Public\Register-DFTool.ps1`:

```powershell
#Requires -Version 7.0

function Register-DFTool {
    <#
    .SYNOPSIS
        Configures one or more known CLI tools in the current session.
        Applies XDG env vars, registers argument completers, sets aliases,
        creates declarative fzf pickers, and dot-sources companion .ps1 files.
    .PARAMETER Name
        One or more tool names to configure.
    .PARAMETER All
        Configure every known tool that is installed on PATH.
    .PARAMETER ToolsPath
        Override the tools directory (used in tests).
    #>
    [CmdletBinding()]
    param(
        [string[]]$Name,
        [switch]$All,
        [string]$ToolsPath
    )

    if (-not $Name -and -not $All) {
        Write-Error 'Specify -Name <tool> or -All.' -ErrorAction Stop
        return
    }

    $dbArgs = if ($ToolsPath) { @{ ToolsPath = $ToolsPath } } else { @{} }
    $db = Import-DFToolDb @dbArgs

    $resolvedToolsPath = if ($ToolsPath) { $ToolsPath }
                         else            { Join-Path $PSScriptRoot '../Tools' }

    $tools = if ($All) {
        $db.Values
    } else {
        @($Name) | ForEach-Object {
            if ($db.ContainsKey($_)) { $db[$_] }
            else { Write-Warning "DotForge: Unknown tool '$_'"; $null }
        } | Where-Object { $_ }
    }

    foreach ($tool in $tools) {
        # ── Guard: skip if not on PATH ─────────────────────────────────────
        if (-not (Get-Command $tool.executable -ErrorAction Ignore)) {
            Write-Verbose "DotForge: '$($tool.executable)' not on PATH — skipping $($tool.name)"
            continue
        }

        # ── XDG configuration ──────────────────────────────────────────────
        $xdgMethod = $tool.PSObject.Properties['xdg']?.Value?.PSObject.Properties['method']?.Value
        switch ($xdgMethod) {
            'env' {
                $xdg = $tool.xdg
                $vars = $xdg.PSObject.Properties['vars']?.Value
                if ($vars) {
                    $vars.PSObject.Properties | ForEach-Object {
                        [System.Environment]::SetEnvironmentVariable(
                            $_.Name,
                            (Expand-DFXdgPath $_.Value),
                            'Process'
                        )
                    }
                }
                $dirs = $xdg.PSObject.Properties['dirs']?.Value
                if ($dirs) {
                    @($dirs) | Where-Object { $_ } |
                        ForEach-Object { Ensure-DFDir (Expand-DFXdgPath $_) }
                }
            }
            'manual' {
                $instructions = $tool.PSObject.Properties['xdg']?.Value?.PSObject.Properties['instructions']?.Value
                Write-Warning "DotForge: $($tool.name) requires manual XDG configuration.$(if ($instructions) { " $instructions" })"
            }
            { $_ -in 'config', 'wrapper' } {
                Write-Verbose "DotForge: $($tool.name) xdg.method '$xdgMethod' deferred to Phase 3"
            }
            # 'default' or null: do nothing
        }

        # ── Argument completions ────────────────────────────────────────────
        $completionsType = $tool.PSObject.Properties['completions']?.Value?.PSObject.Properties['type']?.Value
        $exeBase = [IO.Path]::GetFileNameWithoutExtension($tool.executable)

        if ($completionsType -eq 'static') {
            $flags = $tool.completions.PSObject.Properties['flags']?.Value
            if ($flags) {
                $capturedFlags = @($flags)
                Register-ArgumentCompleter -Native -CommandName $exeBase -ScriptBlock {
                    param($wordToComplete, $commandAst, $cursorPosition)
                    $capturedFlags | Where-Object { $_ -like "$wordToComplete*" } |
                        ForEach-Object {
                            [System.Management.Automation.CompletionResult]::new(
                                $_, $_, 'ParameterValue', $_)
                        }
                }.GetNewClosure()
            }
        } elseif ($completionsType -eq 'dynamic') {
            $genCmd = $tool.completions.PSObject.Properties['command']?.Value
            if ($genCmd) {
                $exePath      = (Get-Command $tool.executable -ErrorAction Ignore).Path
                $capturedCmd  = $genCmd
                Get-DFCachedCompletion -CacheKey $tool.name -ExePath $exePath -Generate {
                    & ([scriptblock]::Create($capturedCmd))
                }.GetNewClosure()
            }
        }

        # ── Aliases ─────────────────────────────────────────────────────────
        $aliases = $tool.PSObject.Properties['aliases']?.Value
        if ($aliases) {
            $aliases.PSObject.Properties | ForEach-Object {
                $aliasName = $_.Name
                $aliasCmd  = $_.Value.PSObject.Properties['command']?.Value
                $rawArgs   = $_.Value.PSObject.Properties['args']?.Value
                $aliasArgs = if ($rawArgs) { @($rawArgs) } else { @() }

                if (-not $aliasCmd) { return }

                if ($aliasArgs.Count -eq 0) {
                    Set-Alias -Name $aliasName -Value $aliasCmd -Scope Global -Force
                } else {
                    $capturedCmd  = $aliasCmd
                    $capturedArgs = $aliasArgs
                    Set-Item -Path "function:global:$aliasName" -Value {
                        & $capturedCmd @capturedArgs @args
                    }.GetNewClosure()
                }
            }
        }

        # ── Declarative picker ──────────────────────────────────────────────
        $picker = $tool.PSObject.Properties['picker']?.Value
        if ($picker -and $picker -is [PSCustomObject]) {
            $pAlias    = $picker.PSObject.Properties['alias']?.Value
            $pFunction = $picker.PSObject.Properties['function']?.Value
            $pList     = $picker.PSObject.Properties['list']?.Value
            $pPreview  = $picker.PSObject.Properties['preview']?.Value ?? ''
            $pWindow   = $picker.PSObject.Properties['preview_window']?.Value ?? 'right:60%'
            $pAnsi     = [bool]($picker.PSObject.Properties['ansi']?.Value)
            $pHeader   = $picker.PSObject.Properties['header']?.Value ?? ''
            $pAction   = $picker.PSObject.Properties['action']?.Value
            $pParse    = $picker.PSObject.Properties['parse']?.Value
            $pAccPath  = [bool]($picker.PSObject.Properties['list_accepts_path']?.Value)

            if ($pFunction -and $pList) {
                $capturedList   = $pList
                $capturedPreview = $pPreview
                $capturedWindow = $pWindow
                $capturedAnsi   = $pAnsi
                $capturedHeader = $pHeader
                $capturedAction = if ($pAction -and $pAction -ne 'output') {
                    [scriptblock]::Create("param(`$v) " + $pAction.Replace('{}', '$v'))
                } else { $null }
                $capturedParse  = if ($pParse) {
                    [scriptblock]::Create($pParse)
                } else { $null }

                $fn = if ($pAccPath) {
                    {
                        [CmdletBinding()]
                        param([string]$Path = '.')
                        Invoke-DFPicker `
                            -List          ([scriptblock]::Create("$capturedList '$Path'")) `
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

                Set-Item -Path "function:global:$pFunction" -Value $fn
                if ($pAlias) {
                    Set-Alias -Name $pAlias -Value $pFunction -Scope Global -Force
                }
            }
        }

        # ── Companion .ps1 ──────────────────────────────────────────────────
        $companion = Join-Path $resolvedToolsPath "$($tool.name).ps1"
        if (Test-Path $companion -PathType Leaf) {
            . ($companion)
        }

        Write-Verbose "DotForge: $($tool.name) registered"
    }
}
```

- [ ] **Step 4: Run tests — confirm all 11 pass**

```powershell
Invoke-Pester tests/Register-DFTool.Tests.ps1 -Output Detailed
```

Expected: 11/11 passing.

- [ ] **Step 5: Commit**

```powershell
git add Public/Register-DFTool.ps1 tests/Register-DFTool.Tests.ps1
git commit -m "feat: Register-DFTool — configure CLI tools in current session"
```

---

## Task 5: 20+ tool JSON records

**Files:** Create 20 new files in `Tools/`. All must pass `Test-DFToolSchema`.
The existing seed-file validation test in `tests/Test-DFToolSchema.Tests.ps1` will be
extended with the new names.

- [ ] **Step 1: Create `Tools/fd.json`**

```json
{
  "name": "fd",
  "description": "Fast and user-friendly alternative to find",
  "tags": ["file", "search", "find"],
  "executable": "fd.exe",
  "packages": { "scoop": "fd", "winget": "sharkdp.fd", "choco": "fd" },
  "xdg": { "compliance": "none", "method": "default" },
  "completions": {
    "type": "dynamic",
    "command": "fd --gen-completions powershell",
    "cache": true
  },
  "aliases": {},
  "picker": {
    "alias": "ffd",
    "function": "Select-FdResult",
    "list": "fd --color=always",
    "preview": "bat --color=always --line-range=:100 {} 2>$null",
    "preview_window": "right:60%",
    "ansi": true,
    "header": "Select file  [Enter to open]",
    "action": "output"
  }
}
```

- [ ] **Step 2: Create `Tools/broot.json`**

```json
{
  "name": "broot",
  "description": "Interactive file browser with fuzzy search",
  "tags": ["file", "browser", "navigation"],
  "executable": "broot.exe",
  "packages": { "scoop": "broot", "choco": "broot" },
  "xdg": {
    "compliance": "full",
    "method": "env",
    "vars": {},
    "dirs": ["${XDG_CONFIG_HOME}/broot"]
  },
  "completions": { "type": "static", "flags": [
    "--sizes", "--dates", "--permissions", "--hidden", "--git-ignored",
    "--no-sizes", "--no-dates", "--no-permissions", "--color",
    "--sort-by-count", "--sort-by-date", "--sort-by-size",
    "--only-folders", "--show-root-fs", "--install", "--help"
  ]},
  "aliases": {},
  "picker": null
}
```

- [ ] **Step 3: Create `Tools/jq.json`**

```json
{
  "name": "jq",
  "description": "Command-line JSON processor",
  "tags": ["json", "data", "text"],
  "executable": "jq.exe",
  "packages": { "scoop": "jq", "winget": "jqlang.jq", "choco": "jq" },
  "xdg": { "compliance": "none", "method": "default" },
  "completions": { "type": "static", "flags": [
    "--compact-output", "--raw-output", "--raw-input", "--null-input",
    "--sort-keys", "--tab", "--indent", "--join-output", "--arg",
    "--argjson", "--slurpfile", "--rawfile", "--args", "--jsonargs"
  ]},
  "aliases": {},
  "picker": "custom"
}
```

- [ ] **Step 4: Create `Tools/glow.json`**

```json
{
  "name": "glow",
  "description": "Render Markdown on the CLI",
  "tags": ["markdown", "viewer", "text"],
  "executable": "glow.exe",
  "packages": { "scoop": "glow", "choco": "glow" },
  "xdg": {
    "compliance": "partial",
    "method": "env",
    "vars": { "GLOW_CONFIG_DIR": "${XDG_CONFIG_HOME}/glow" },
    "dirs": ["${XDG_CONFIG_HOME}/glow"]
  },
  "completions": {
    "type": "dynamic",
    "command": "glow completion powershell",
    "cache": true
  },
  "aliases": {},
  "picker": "custom"
}
```

- [ ] **Step 5: Create `Tools/procs.json`**

```json
{
  "name": "procs",
  "description": "Modern replacement for ps",
  "tags": ["system", "process", "monitor"],
  "executable": "procs.exe",
  "packages": { "scoop": "procs", "choco": "procs" },
  "xdg": { "compliance": "none", "method": "default" },
  "completions": {
    "type": "dynamic",
    "command": "procs --gen-completion-out powershell",
    "cache": true
  },
  "aliases": {},
  "picker": "custom"
}
```

- [ ] **Step 6: Create `Tools/winfetch.json`**

```json
{
  "name": "winfetch",
  "description": "Neofetch-like system information tool for Windows",
  "tags": ["system", "info"],
  "executable": "winfetch.ps1",
  "packages": { "scoop": "winfetch" },
  "xdg": {
    "compliance": "partial",
    "method": "env",
    "vars": { "WINFETCH_CONFIG_PATH": "${XDG_CONFIG_HOME}/winfetch/config.ps1" },
    "dirs": ["${XDG_CONFIG_HOME}/winfetch"]
  },
  "completions": { "type": "static", "flags": [
    "--image", "--genconf", "--noimage", "--legacylogo", "--blink",
    "--help", "--version", "--all"
  ]},
  "aliases": {},
  "picker": null
}
```

- [ ] **Step 7: Create `Tools/curl.json`**

```json
{
  "name": "curl",
  "description": "Transfer data with URLs",
  "tags": ["network", "http", "download"],
  "executable": "curl.exe",
  "packages": { "scoop": "curl", "winget": "cURL.cURL", "choco": "curl" },
  "xdg": {
    "compliance": "partial",
    "method": "env",
    "vars": { "CURL_HOME": "${XDG_CONFIG_HOME}/curl" },
    "dirs": ["${XDG_CONFIG_HOME}/curl"]
  },
  "completions": { "type": "static", "flags": [
    "--silent", "--verbose", "--output", "--header", "--request",
    "--data", "--form", "--user", "--location", "--compressed",
    "--max-time", "--retry", "--cookie", "--cookie-jar", "--insecure"
  ]},
  "aliases": {},
  "picker": null
}
```

- [ ] **Step 8: Create `Tools/wget.json`**

```json
{
  "name": "wget",
  "description": "Non-interactive network downloader",
  "tags": ["network", "download"],
  "executable": "wget.exe",
  "packages": { "scoop": "wget", "choco": "wget" },
  "xdg": {
    "compliance": "partial",
    "method": "env",
    "vars": { "WGETRC": "${XDG_CONFIG_HOME}/wget/wgetrc" },
    "dirs": ["${XDG_CONFIG_HOME}/wget"]
  },
  "completions": { "type": "static", "flags": [
    "--quiet", "--verbose", "--output-document", "--recursive",
    "--no-parent", "--level", "--accept", "--reject",
    "--user", "--password", "--no-check-certificate"
  ]},
  "aliases": {},
  "picker": null
}
```

- [ ] **Step 9: Create `Tools/docker.json`**

```json
{
  "name": "docker",
  "description": "Container runtime and management",
  "tags": ["container", "dev"],
  "executable": "docker.exe",
  "packages": { "winget": "Docker.DockerDesktop" },
  "xdg": {
    "compliance": "partial",
    "method": "env",
    "vars": { "DOCKER_CONFIG": "${XDG_CONFIG_HOME}/docker" },
    "dirs": ["${XDG_CONFIG_HOME}/docker"]
  },
  "completions": { "type": "static", "flags": [
    "run", "build", "pull", "push", "ps", "images", "exec",
    "logs", "stop", "start", "rm", "rmi", "inspect", "network",
    "volume", "compose", "system"
  ]},
  "aliases": {},
  "picker": "custom"
}
```

- [ ] **Step 10: Create `Tools/less.json`**

```json
{
  "name": "less",
  "description": "Opposite of more — terminal pager",
  "tags": ["pager", "viewer"],
  "executable": "less.exe",
  "packages": { "scoop": "less", "choco": "less" },
  "xdg": {
    "compliance": "partial",
    "method": "env",
    "vars": {
      "LESSHISTFILE": "${XDG_STATE_HOME}/less/history",
      "LESSKEY": "${XDG_CONFIG_HOME}/less/lesskey",
      "LESS": "--RAW-CONTROL-CHARS --quit-if-one-screen --no-init"
    },
    "dirs": ["${XDG_STATE_HOME}/less", "${XDG_CONFIG_HOME}/less"]
  },
  "completions": { "type": "static", "flags": [
    "--RAW-CONTROL-CHARS", "--quit-if-one-screen", "--no-init",
    "--chop-long-lines", "--ignore-case", "--IGNORE-CASE",
    "--line-numbers", "--squeeze-blank-lines", "--tabs"
  ]},
  "aliases": {},
  "picker": null
}
```

- [ ] **Step 11: Create `Tools/gh.json`**

```json
{
  "name": "gh",
  "description": "GitHub CLI",
  "tags": ["git", "github", "dev"],
  "executable": "gh.exe",
  "packages": { "scoop": "gh", "winget": "GitHub.cli", "choco": "gh" },
  "xdg": { "compliance": "none", "method": "default" },
  "completions": {
    "type": "dynamic",
    "command": "gh completion -s powershell",
    "cache": true
  },
  "aliases": {},
  "picker": "custom"
}
```

- [ ] **Step 12: Create `Tools/delta.json`**

```json
{
  "name": "delta",
  "description": "Syntax-highlighting pager for git diff output",
  "tags": ["git", "diff", "pager"],
  "executable": "delta.exe",
  "packages": { "scoop": "delta", "winget": "dandavison.delta", "choco": "delta" },
  "xdg": {
    "compliance": "none",
    "method": "default"
  },
  "completions": { "type": "static", "flags": [
    "--navigate", "--side-by-side", "--line-numbers",
    "--syntax-theme", "--diff-so-fancy", "--features", "--color-only"
  ]},
  "aliases": {},
  "picker": null
}
```

- [ ] **Step 13: Create `Tools/lazygit.json`**

```json
{
  "name": "lazygit",
  "description": "Simple terminal UI for git commands",
  "tags": ["git", "tui", "dev"],
  "executable": "lazygit.exe",
  "packages": { "scoop": "lazygit", "winget": "JesseDuffield.lazygit", "choco": "lazygit" },
  "xdg": {
    "compliance": "partial",
    "method": "env",
    "vars": { "LG_CONFIG_FILE": "${XDG_CONFIG_HOME}/lazygit/config.yml" },
    "dirs": ["${XDG_CONFIG_HOME}/lazygit"]
  },
  "completions": { "type": "static", "flags": [
    "--path", "--git-dir", "--work-tree", "--use-config-dir",
    "--debug", "--logs", "--version", "--help"
  ]},
  "aliases": { "lg": { "command": "lazygit", "args": [] } },
  "picker": null
}
```

- [ ] **Step 14: Create `Tools/rustup.json`**

```json
{
  "name": "rustup",
  "description": "Rust toolchain installer and version manager",
  "tags": ["rust", "dev", "toolchain"],
  "executable": "rustup.exe",
  "packages": { "scoop": "rustup", "winget": "Rustlang.Rustup" },
  "xdg": { "compliance": "none", "method": "default" },
  "completions": {
    "type": "dynamic",
    "command": "rustup completions powershell",
    "cache": true
  },
  "aliases": {},
  "picker": "custom"
}
```

- [ ] **Step 15: Create `Tools/uv.json`**

```json
{
  "name": "uv",
  "description": "Extremely fast Python package and project manager",
  "tags": ["python", "dev", "package-manager"],
  "executable": "uv.exe",
  "packages": { "scoop": "uv", "winget": "astral-sh.uv" },
  "xdg": {
    "compliance": "partial",
    "method": "env",
    "vars": {
      "UV_CACHE_DIR": "${XDG_CACHE_HOME}/uv",
      "UV_DATA_DIR": "${XDG_DATA_HOME}/uv"
    },
    "dirs": ["${XDG_CACHE_HOME}/uv", "${XDG_DATA_HOME}/uv"]
  },
  "completions": { "type": "static", "flags": [
    "pip", "venv", "run", "sync", "lock", "add", "remove", "tool",
    "python", "init", "build", "publish", "cache", "version", "help"
  ]},
  "aliases": {},
  "picker": "custom"
}
```

- [ ] **Step 16: Create `Tools/chezmoi.json`**

```json
{
  "name": "chezmoi",
  "description": "Manage your dotfiles across multiple diverse machines",
  "tags": ["dotfiles", "config", "dev"],
  "executable": "chezmoi.exe",
  "packages": { "scoop": "chezmoi", "winget": "twpayne.chezmoi", "choco": "chezmoi" },
  "xdg": {
    "compliance": "partial",
    "method": "env",
    "vars": { "CHEZMOI_CONFIG_DIR": "${XDG_CONFIG_HOME}/chezmoi" },
    "dirs": ["${XDG_CONFIG_HOME}/chezmoi"]
  },
  "completions": {
    "type": "dynamic",
    "command": "chezmoi completion powershell",
    "cache": true
  },
  "aliases": { "cz": { "command": "chezmoi", "args": [] } },
  "picker": "custom"
}
```

- [ ] **Step 17: Create `Tools/micro.json`**

```json
{
  "name": "micro",
  "description": "Modern and intuitive terminal-based text editor",
  "tags": ["editor", "text"],
  "executable": "micro.exe",
  "packages": { "scoop": "micro", "choco": "micro" },
  "xdg": {
    "compliance": "partial",
    "method": "env",
    "vars": { "MICRO_CONF_DIR": "${XDG_CONFIG_HOME}/micro" },
    "dirs": ["${XDG_CONFIG_HOME}/micro"]
  },
  "completions": { "type": "static", "flags": [
    "--config-dir", "--version", "--help", "--options",
    "--startpos", "--parsecursor"
  ]},
  "aliases": {},
  "picker": null
}
```

- [ ] **Step 18: Create `Tools/bitwarden.json`**

```json
{
  "name": "bitwarden",
  "description": "Bitwarden CLI — open-source password manager",
  "tags": ["security", "secrets", "password"],
  "executable": "bw.exe",
  "packages": { "scoop": "bitwarden-cli", "winget": "Bitwarden.CLI" },
  "xdg": { "compliance": "none", "method": "default" },
  "completions": { "type": "static", "flags": [
    "login", "logout", "lock", "unlock", "sync", "list", "get",
    "create", "edit", "delete", "restore", "move", "confirm",
    "import", "export", "generate", "encode", "config", "update",
    "completion", "status", "serve", "receive"
  ]},
  "aliases": {},
  "picker": "custom"
}
```

- [ ] **Step 19: Create `Tools/npm.json`**

```json
{
  "name": "npm",
  "description": "Node.js package manager",
  "tags": ["node", "javascript", "dev", "package-manager"],
  "executable": "npm.cmd",
  "packages": {},
  "xdg": {
    "compliance": "partial",
    "method": "env",
    "vars": {
      "NPM_CONFIG_USERCONFIG": "${XDG_CONFIG_HOME}/npm/npmrc",
      "NODE_REPL_HISTORY": "${XDG_DATA_HOME}/node_repl_history"
    },
    "dirs": ["${XDG_CONFIG_HOME}/npm"]
  },
  "completions": { "type": "static", "flags": [
    "install", "uninstall", "update", "run", "start", "stop", "test",
    "list", "link", "unlink", "publish", "pack", "version", "view",
    "search", "audit", "fund", "init", "exec", "prefix", "config",
    "cache", "rebuild", "prune", "outdated", "ci", "dedupe", "diff"
  ]},
  "aliases": { "nls": { "command": "npm", "args": ["list", "-g", "--depth=0"] } },
  "picker": "custom"
}
```

- [ ] **Step 20: Create `Tools/scoop.json`**

```json
{
  "name": "scoop",
  "description": "Windows command-line installer",
  "tags": ["package-manager", "windows"],
  "executable": "scoop.cmd",
  "packages": {},
  "xdg": { "compliance": "none", "method": "default" },
  "completions": { "type": "static", "flags": [
    "install", "uninstall", "update", "status", "list", "search",
    "info", "home", "depends", "export", "import", "cleanup",
    "cache", "bucket", "checkver", "cat", "virustotal"
  ]},
  "aliases": {},
  "picker": "custom"
}
```

- [ ] **Step 21: Extend seed validation test**

Append to the `Describe 'Seed tool JSON files'` block in
`tests/Test-DFToolSchema.Tests.ps1`. Find the `$seedFiles = @('bat', 'eza', ...)` line
and add the new names:

```powershell
    $seedFiles = @(
        'bat', 'eza', 'fzf', 'ripgrep', 'zoxide',   # Phase 1 seeds
        'fd', 'broot', 'jq', 'glow', 'procs', 'winfetch',
        'curl', 'wget', 'docker', 'less', 'gh', 'delta',
        'lazygit', 'rustup', 'uv', 'chezmoi', 'micro',
        'bitwarden', 'npm', 'scoop'
    ) | ForEach-Object {
        @{ Name = $_; Path = Join-Path $PSScriptRoot "../Tools/$_.json" }
    }
```

- [ ] **Step 22: Run schema validation — all 25 tools must pass**

```powershell
Invoke-Pester tests/Test-DFToolSchema.Tests.ps1 -Output Detailed
```

Expected: 7 + 25 = 32 tests passing.

- [ ] **Step 23: Commit**

```powershell
git add Tools/*.json tests/Test-DFToolSchema.Tests.ps1
git commit -m "feat: add 20 tool records (fd, broot, jq, glow, procs, winfetch, curl, wget, docker, less, gh, delta, lazygit, rustup, uv, chezmoi, micro, bitwarden, npm, scoop)"
```

---

## Task 6: Companion `.ps1` files for custom pickers

**Files:**
- Create: `Tools/ripgrep.ps1`
- Create: `Tools/procs.ps1`

These are dot-sourced by `Register-DFTool` when the tool's `picker` field is `"custom"`.
They have access to all public module functions (`Invoke-DFPicker`, `Ensure-DFDir`, etc.)
since the module is loaded first.

- [ ] **Step 1: Create `Tools/ripgrep.ps1`** — `frg` picker

```powershell
# Companion for ripgrep — defines Select-RipgrepResult (frg)
# Dot-sourced by Register-DFTool when ripgrep is registered.

function global:Select-RipgrepResult {
    [CmdletBinding()]
    param(
        [string]$Pattern = '',
        [string]$Path    = '.'
    )

    if (-not $Pattern) { $Pattern = Read-Host 'Search pattern' }

    $result = Invoke-DFPicker `
        -List {
            rg --line-number --no-heading --color=always $Pattern $Path 2>$null
        } `
        -Preview       'bat --color=always --highlight-line {2} {1}' `
        -PreviewWindow 'right:60%' `
        -Delimiter     ':' `
        -Ansi `
        -Header        'Select result  [Enter to open in editor]' `
        -Parse         { ($_ -split ':')[0..1] -join ':' } `
        -Action        {
            param($v)
            $parts = $v -split ':'
            $file  = $parts[0]
            $line  = if ($parts.Count -gt 1) { $parts[1] } else { '1' }
            & $Env:EDITOR $file
        }
}
Set-Alias -Name frg -Value Select-RipgrepResult -Scope Global -Force
```

- [ ] **Step 2: Create `Tools/procs.ps1`** — `fkill` picker

```powershell
# Companion for procs — defines Select-Process (fkill)
# Dot-sourced by Register-DFTool when procs is registered.

function global:Select-Process {
    [CmdletBinding()]
    param()

    $proc = Invoke-DFPicker `
        -List          { procs --color=always 2>$null | Select-Object -Skip 1 } `
        -PreviewWindow 'hidden' `
        -Ansi `
        -Header        'Select process  [Enter to Stop-Process]' `
        -Parse         { ($_ -split '\s+')[1] } `
        -Action        {
            param($pid)
            if ($pid -match '^\d+$') {
                Stop-Process -Id $pid -Confirm
            }
        }
}
Set-Alias -Name fkill -Value Select-Process -Scope Global -Force
```

- [ ] **Step 3: Verify companions are dot-sourced by Register-DFTool**

Run with Verbose to see dot-sourcing messages:

```powershell
pwsh -NoProfile -Command "
  Import-Module 'C:\Users\simsr\projects\DotForge\DotForge.psd1' -Force
  Register-DFTool -Name ripgrep -Verbose
  Get-Command Select-RipgrepResult -ErrorAction Ignore
  Get-Alias frg -ErrorAction Ignore
"
```

Expected: `Select-RipgrepResult` and `frg` resolve (if `rg.exe` is on PATH).

- [ ] **Step 4: Commit**

```powershell
git add Tools/ripgrep.ps1 Tools/procs.ps1
git commit -m "feat: companion .ps1 files — ripgrep (frg), procs (fkill)"
```

---

## Task 7: Module wiring, full test run, push

**Files:**
- Modify: `DotForge.psd1` — add `Get-DFTool`, `Find-DFTool`, `Register-DFTool` to `FunctionsToExport`

- [ ] **Step 1: Update `DotForge.psd1`**

Find:
```powershell
FunctionsToExport = @(
    'Add-DFToPath',
    'Ensure-DFDir',
    'Invoke-DFPicker',
    'Get-DFCachedCompletion'
)
```

Replace with:
```powershell
FunctionsToExport = @(
    'Add-DFToPath',
    'Ensure-DFDir',
    'Invoke-DFPicker',
    'Get-DFCachedCompletion',
    'Get-DFTool',
    'Find-DFTool',
    'Register-DFTool'
)
```

- [ ] **Step 2: Verify module imports cleanly and exports 7 functions**

```powershell
pwsh -NoProfile -Command "
  Import-Module 'C:\Users\simsr\projects\DotForge\DotForge.psd1' -Force
  Get-Command -Module DotForge | Select-Object Name | Sort-Object Name
"
```

Expected:
```
Add-DFToPath
Ensure-DFDir
Find-DFTool
Get-DFCachedCompletion
Get-DFTool
Invoke-DFPicker
Register-DFTool
```

- [ ] **Step 3: Run the full test suite with StrictMode active**

```powershell
pwsh -NoProfile -Command "
  Set-StrictMode -Version Latest
  `$ErrorActionPreference = 'Continue'
  Import-Module Pester -MinimumVersion 5.0
  `$r = Invoke-Pester 'C:\Users\simsr\projects\DotForge\tests\' -PassThru -Output Normal
  Write-Host \"Passed: `$(`$r.PassedCount)  Failed: `$(`$r.FailedCount)\"
"
```

Expected: All tests passing. Count: 38 (Phase 1) + 5 + 6 + 9 + 11 + 20 (schema) = ~89 tests.
Zero failures.

- [ ] **Step 4: Commit and push**

```powershell
cd C:\Users\simsr\projects\DotForge
git add DotForge.psd1
git commit -m "feat: Phase 2 complete — tool registry + Register-DFTool

New exports: Get-DFTool, Find-DFTool, Register-DFTool
New private: Import-DFToolDb, Expand-DFXdgPath
New tool records: 20 (fd, broot, jq, glow, procs, winfetch, curl, wget,
  docker, less, gh, delta, lazygit, rustup, uv, chezmoi, micro,
  bitwarden, npm, scoop) — 25 total
Companion .ps1: ripgrep (frg), procs (fkill)"

git push
```

---

## Self-Review Notes

**Spec coverage:**
- `Import-DFToolDb` ✓ Task 1
- `Expand-DFXdgPath` ✓ Task 2
- `Get-DFTool` ✓ Task 3
- `Find-DFTool` ✓ Task 3
- `Register-DFTool` ✓ Task 4 (XDG env, static/dynamic completions, zero/arg aliases, declarative pickers, companion .ps1)
- Full initial tool set (25 total) ✓ Tasks 1 (5 seeds) + Task 5 (20 new)
- Tests for registry and registration ✓ Tasks 1–4

**Deferred to Phase 3:** `xdg.method = "config"` and `"wrapper"`, PSFzf/posh-git/Terminal-Icons as PS module tools, `Install-DFTool`, `Initialize-DFEnvironment`, `Update-DFCompletions`.

**Type consistency:**
- `Import-DFToolDb` returns `[hashtable]` — used consistently in `Get-DFTool`, `Find-DFTool`, `Register-DFTool`
- `$ToolsPath` parameter accepted by `Import-DFToolDb`, `Get-DFTool`, `Find-DFTool`, `Register-DFTool` — consistent signature
- `Expand-DFXdgPath` called in `Register-DFTool` for both `vars` values and `dirs` entries
- `Get-DFCachedCompletion` called in `Register-DFTool` with `-CacheKey $tool.name`, `-ExePath`, `-Generate` — matches Phase 1 signature
