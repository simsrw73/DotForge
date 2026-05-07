# DotForge Phase 1 — Core Primitives Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the four core primitive functions, tool JSON schema validator, and five seed tool records that form the foundation every other DotForge phase builds on.

**Architecture:** TDD with Pester 5. Private helper `Invoke-DFFzf` wraps the external `fzf` call so it can be mocked in tests without spawning a real process. All four primitives live in `Public/` (they are usable API surface, not implementation details). The tool schema is validated by a private `Test-DFToolSchema` function exercised against the five seed JSON files.

**Tech Stack:** PowerShell 7+, Pester 5, JSON (no external schema library — hand-rolled validator).

**Scope:** Phase 1 only. Phases 2–4 each get their own plan.

---

## File Map

| File | Role |
|------|------|
| `CLAUDE.md` | Project conventions for future Claude sessions |
| `.gitattributes` | Normalize line endings (LF in repo, CRLF on checkout) |
| `Public/Add-DFToPath.ps1` | PATH dedup helper — normalized, guarded |
| `Public/Ensure-DFDir.ps1` | Idempotent directory creation |
| `Public/Invoke-DFPicker.ps1` | Generalized fzf picker skeleton |
| `Public/Get-DFCachedCompletion.ps1` | Mtime-based completion script caching |
| `Private/Invoke-DFFzf.ps1` | Thin fzf wrapper (enables mocking in tests) |
| `Private/Test-DFToolSchema.ps1` | Validates a tool PSCustomObject against the schema |
| `Tools/bat.json` | Seed: bat |
| `Tools/eza.json` | Seed: eza |
| `Tools/fzf.json` | Seed: fzf |
| `Tools/ripgrep.json` | Seed: ripgrep |
| `Tools/zoxide.json` | Seed: zoxide |
| `DotForge.psd1` | Updated: `FunctionsToExport` for the 4 public functions |
| `tests/Add-DFToPath.Tests.ps1` | Pester tests |
| `tests/Ensure-DFDir.Tests.ps1` | Pester tests |
| `tests/Invoke-DFPicker.Tests.ps1` | Pester tests |
| `tests/Get-DFCachedCompletion.Tests.ps1` | Pester tests |
| `tests/Test-DFToolSchema.Tests.ps1` | Pester tests + seed file validation |

---

## Task 1: Project infrastructure

**Files:**
- Create: `CLAUDE.md`
- Create: `.gitattributes`
- Create: `tests/.gitkeep` (already exists as directory)

- [ ] **Step 1: Verify Pester 5 is available**

```powershell
# Run in project directory
pwsh -NoProfile -Command "
  \$p = Get-Module Pester -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
  if (-not \$p -or \$p.Version.Major -lt 5) {
    Write-Error 'Pester 5 required. Run: Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force'
  } else {
    Write-Host \"Pester \$(\$p.Version) — OK\"
  }
"
```

Expected: `Pester 5.x.x — OK`

- [ ] **Step 2: Create `.gitattributes`**

Create `C:\Users\simsr\projects\DotForge\.gitattributes` with this content:

```
* text=auto eol=lf
*.ps1 text eol=lf
*.psd1 text eol=lf
*.psm1 text eol=lf
*.json text eol=lf
*.md text eol=lf
```

- [ ] **Step 3: Create `CLAUDE.md`**

Create `C:\Users\simsr\projects\DotForge\CLAUDE.md` with this content:

```markdown
# DotForge

PowerShell 7+ module that configures CLI tools (XDG paths, completions, fzf pickers,
aliases) from a JSON tool database. Extracted and generalized from a real-world
PowerShell profile.

## Structure

```
DotForge/
├── Public/          # Exported cmdlets and helpers
├── Private/         # Internal functions
├── Tools/           # Per-tool JSON + optional .ps1
└── tests/           # Pester 5 tests
```

## Conventions

- **All public functions** use the `DF` prefix: `Add-DFToPath`, `Invoke-DFPicker`, etc.
- **Private helpers** also use `DF` prefix but live in `Private/` and are not exported.
- **Tool JSON files** are named `<toolname>.json` (lowercase, no spaces).
- **Optional `.ps1` companions** share the same basename as the JSON file.
- **No `$ErrorActionPreference = 'Stop'`** in any module file — inherited from caller.
- **All directory creation** goes through `Ensure-DFDir`, never raw `New-Item`.
- **All PATH additions** go through `Add-DFToPath`, never raw `$Env:Path +=`.

## Architecture (3 layers)

```
Layer 1 — Core Primitives (this phase)
  Add-DFToPath, Ensure-DFDir, Invoke-DFPicker, Get-DFCachedCompletion

Layer 2 — Tool Registry (Phase 2)
  Import-DFToolDb, Get-DFTool, Find-DFTool, Register-DFTool

Layer 3 — Tool Operations (Phase 3)
  Install-DFTool, Initialize-DFEnvironment, Update-DFCompletions
```

## Testing

Pester 5. Run all tests:
```powershell
Invoke-Pester tests/ -Output Detailed
```

Run a single file:
```powershell
Invoke-Pester tests/Add-DFToPath.Tests.ps1 -Output Detailed
```

## Tool JSON Schema

Each `Tools/*.json` must have at minimum:
- `name` (string, required)
- `executable` (string, required)
- `xdg.method`: one of `default | env | config | wrapper | manual`
- `completions.type`: one of `static | dynamic`
- dynamic completions require `completions.command`

See `docs/superpowers/specs/2026-05-07-dotforge-design.md` for full schema.

## Key Design Decisions

- `Invoke-DFPicker` uses a private `Invoke-DFFzf` wrapper so tests can mock fzf
  without spawning a real process.
- `Get-DFCachedCompletion` caches to `$XDG_CACHE_HOME/dotforge/completions/<key>.ps1`
  and only regenerates when the tool binary is newer than the cache file.
- The `Parse` scriptblock in `Invoke-DFPicker` receives `$_` via `ForEach-Object`,
  not as a positional argument.
```

- [ ] **Step 4: Commit infrastructure**

```powershell
cd C:\Users\simsr\projects\DotForge
git add CLAUDE.md .gitattributes
git commit -m "chore: add CLAUDE.md and .gitattributes"
```

---

## Task 2: `Add-DFToPath`

**Files:**
- Create: `Public/Add-DFToPath.ps1`
- Create: `tests/Add-DFToPath.Tests.ps1`

- [ ] **Step 1: Write the failing tests**

Create `C:\Users\simsr\projects\DotForge\tests\Add-DFToPath.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/../Public/Add-DFToPath.ps1"
}

Describe 'Add-DFToPath' {
    BeforeEach { $script:SavedPath = $Env:Path }
    AfterEach  { $Env:Path = $script:SavedPath }

    It 'appends an absolute path not already in PATH' {
        $Env:Path = 'C:\Windows\system32'
        Add-DFToPath 'C:\tools\bin'
        $Env:Path -split [IO.Path]::PathSeparator | Should -Contain 'C:\tools\bin'
    }

    It 'does not add a path already present (case-insensitive)' {
        $Env:Path = 'C:\tools\bin'
        Add-DFToPath 'c:\tools\bin'
        ($Env:Path -split [IO.Path]::PathSeparator |
            Where-Object { $_ -ieq 'C:\tools\bin' }).Count | Should -Be 1
    }

    It 'prepends when -Prepend is specified' {
        $Env:Path = 'C:\Windows\system32'
        Add-DFToPath 'C:\tools\bin' -Prepend
        ($Env:Path -split [IO.Path]::PathSeparator)[0] | Should -Be 'C:\tools\bin'
    }

    It 'silently skips empty string' {
        $before = $Env:Path
        Add-DFToPath ''
        $Env:Path | Should -Be $before
    }

    It 'skips relative paths and emits a warning' {
        $before = $Env:Path
        Add-DFToPath 'relative\path' -WarningVariable warns 3>$null
        $Env:Path | Should -Be $before
        $warns | Should -Not -BeNullOrEmpty
    }

    It 'normalizes .. segments before dedup comparison' {
        $Env:Path = 'C:\tools\bin'
        Add-DFToPath 'C:\tools\other\..\bin'
        ($Env:Path -split [IO.Path]::PathSeparator |
            Where-Object { $_ -ieq 'C:\tools\bin' }).Count | Should -Be 1
    }

    It 'handles malformed PATH entries without throwing' {
        $Env:Path = 'C:\good\path;:::bad:::;C:\other'
        { Add-DFToPath 'C:\new\path' } | Should -Not -Throw
        $Env:Path -split [IO.Path]::PathSeparator | Should -Contain 'C:\new\path'
    }
}
```

- [ ] **Step 2: Run tests — confirm they fail**

```powershell
cd C:\Users\simsr\projects\DotForge
Invoke-Pester tests/Add-DFToPath.Tests.ps1 -Output Detailed
```

Expected: All tests fail with "The term 'Add-DFToPath' is not recognized..."

- [ ] **Step 3: Implement `Add-DFToPath`**

Create `C:\Users\simsr\projects\DotForge\Public\Add-DFToPath.ps1`:

```powershell
#Requires -Version 7.0

function Add-DFToPath {
    <#
    .SYNOPSIS
        Adds a directory to $Env:Path with normalization and deduplication.
    .PARAMETER Dir
        Absolute path to add. Relative paths are rejected with a warning.
    .PARAMETER Prepend
        Add to the front of PATH instead of the end.
    #>
    [CmdletBinding()]
    param(
        [string]$Dir,
        [switch]$Prepend
    )

    if (-not $Dir) { return }

    if (-not [IO.Path]::IsPathRooted($Dir)) {
        Write-Warning "Add-DFToPath: '$Dir' is not an absolute path — skipped."
        return
    }

    $normalized = [IO.Path]::GetFullPath($Dir)

    $existing = ($Env:Path -split [IO.Path]::PathSeparator) |
        Where-Object { $_ -and [IO.Path]::IsPathRooted($_) } |
        ForEach-Object { try { [IO.Path]::GetFullPath($_) } catch { $_ } }

    if ($normalized -notin $existing) {
        if ($Prepend) {
            $Env:Path = $normalized + [IO.Path]::PathSeparator + $Env:Path
        } else {
            $Env:Path += [IO.Path]::PathSeparator + $normalized
        }
    }
}
```

- [ ] **Step 4: Run tests — confirm they pass**

```powershell
Invoke-Pester tests/Add-DFToPath.Tests.ps1 -Output Detailed
```

Expected: 7 tests, all passing.

- [ ] **Step 5: Commit**

```powershell
git add Public/Add-DFToPath.ps1 tests/Add-DFToPath.Tests.ps1
git commit -m "feat: Add-DFToPath — normalized, dedup PATH helper"
```

---

## Task 3: `Ensure-DFDir`

**Files:**
- Create: `Public/Ensure-DFDir.ps1`
- Create: `tests/Ensure-DFDir.Tests.ps1`

- [ ] **Step 1: Write the failing tests**

Create `C:\Users\simsr\projects\DotForge\tests\Ensure-DFDir.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/../Public/Ensure-DFDir.ps1"
}

Describe 'Ensure-DFDir' {
    It 'creates a directory that does not exist' {
        $dir = Join-Path $TestDrive 'newdir'
        Ensure-DFDir $dir
        Test-Path $dir -PathType Container | Should -BeTrue
    }

    It 'is idempotent — no error when directory already exists' {
        $dir = Join-Path $TestDrive 'existing'
        New-Item -ItemType Directory -Path $dir | Out-Null
        { Ensure-DFDir $dir } | Should -Not -Throw
        Test-Path $dir -PathType Container | Should -BeTrue
    }

    It 'creates nested directories' {
        $dir = Join-Path $TestDrive 'a' 'b' 'c'
        Ensure-DFDir $dir
        Test-Path $dir -PathType Container | Should -BeTrue
    }

    It 'silently skips empty string' {
        { Ensure-DFDir '' } | Should -Not -Throw
    }

    It 'silently skips null' {
        { Ensure-DFDir $null } | Should -Not -Throw
    }
}
```

- [ ] **Step 2: Run tests — confirm they fail**

```powershell
Invoke-Pester tests/Ensure-DFDir.Tests.ps1 -Output Detailed
```

Expected: All tests fail with "The term 'Ensure-DFDir' is not recognized..."

- [ ] **Step 3: Implement `Ensure-DFDir`**

Create `C:\Users\simsr\projects\DotForge\Public\Ensure-DFDir.ps1`:

```powershell
#Requires -Version 7.0

function Ensure-DFDir {
    <#
    .SYNOPSIS
        Creates a directory if it does not exist. Idempotent, silent.
    .PARAMETER Path
        Directory path to create. Empty or null values are silently skipped.
    #>
    [CmdletBinding()]
    param([string]$Path)

    if ($Path) {
        New-Item -ItemType Directory -Force -Path $Path -ErrorAction SilentlyContinue | Out-Null
    }
}
```

- [ ] **Step 4: Run tests — confirm they pass**

```powershell
Invoke-Pester tests/Ensure-DFDir.Tests.ps1 -Output Detailed
```

Expected: 5 tests, all passing.

- [ ] **Step 5: Commit**

```powershell
git add Public/Ensure-DFDir.ps1 tests/Ensure-DFDir.Tests.ps1
git commit -m "feat: Ensure-DFDir — idempotent directory creation"
```

---

## Task 4: `Invoke-DFFzf` (private) + `Invoke-DFPicker`

**Files:**
- Create: `Private/Invoke-DFFzf.ps1`
- Create: `Public/Invoke-DFPicker.ps1`
- Create: `tests/Invoke-DFPicker.Tests.ps1`

- [ ] **Step 1: Write the failing tests**

Create `C:\Users\simsr\projects\DotForge\tests\Invoke-DFPicker.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/../Private/Invoke-DFFzf.ps1"
    . "$PSScriptRoot/../Public/Invoke-DFPicker.ps1"
}

Describe 'Invoke-DFPicker' {
    It 'outputs the selected item when no Action is given' {
        Mock Invoke-DFFzf { 'selected-item' }
        $result = Invoke-DFPicker -List { 'item1'; 'item2' } -Header 'Test'
        $result | Should -Be 'selected-item'
    }

    It 'calls Action with the selected item' {
        Mock Invoke-DFFzf { 'selected-item' }
        $received = $null
        Invoke-DFPicker -List { 'item1' } -Action { param($v) $received = $v }
        $received | Should -Be 'selected-item'
    }

    It 'applies Parse before Action — $_ is the raw line' {
        Mock Invoke-DFFzf { 'abc  def  ghi' }
        $parsed = $null
        Invoke-DFPicker -List { 'abc  def  ghi' } `
            -Parse { ($_ -split '\s+')[0] } `
            -Action { param($v) $parsed = $v }
        $parsed | Should -Be 'abc'
    }

    It 'returns nothing when fzf produces no selection (user cancelled)' {
        Mock Invoke-DFFzf { $null }
        $result = Invoke-DFPicker -List { 'item' }
        $result | Should -BeNullOrEmpty
    }

    It 'passes --preview-window to fzf' {
        Mock Invoke-DFFzf { } -Verifiable
        Invoke-DFPicker -List { 'x' } -PreviewWindow 'right:60%'
        Should -Invoke Invoke-DFFzf -ParameterFilter {
            $FzfArgs -contains '--preview-window' -and $FzfArgs -contains 'right:60%'
        }
    }

    It 'passes --ansi to fzf when -Ansi is specified' {
        Mock Invoke-DFFzf { } -Verifiable
        Invoke-DFPicker -List { 'x' } -Ansi
        Should -Invoke Invoke-DFFzf -ParameterFilter { $FzfArgs -contains '--ansi' }
    }

    It 'passes --header to fzf when -Header is specified' {
        Mock Invoke-DFFzf { } -Verifiable
        Invoke-DFPicker -List { 'x' } -Header 'Pick one'
        Should -Invoke Invoke-DFFzf -ParameterFilter {
            $FzfArgs -contains '--header' -and $FzfArgs -contains 'Pick one'
        }
    }

    It 'handles multi-select — Action called once per selected item' {
        Mock Invoke-DFFzf { 'item1', 'item2' }
        $calls = [System.Collections.Generic.List[string]]::new()
        Invoke-DFPicker -List { 'item1'; 'item2' } -Multi `
            -Action { param($v) $calls.Add($v) }
        $calls.Count | Should -Be 2
        $calls | Should -Contain 'item1'
        $calls | Should -Contain 'item2'
    }
}
```

- [ ] **Step 2: Run tests — confirm they fail**

```powershell
Invoke-Pester tests/Invoke-DFPicker.Tests.ps1 -Output Detailed
```

Expected: All tests fail.

- [ ] **Step 3: Implement `Invoke-DFFzf`**

Create `C:\Users\simsr\projects\DotForge\Private\Invoke-DFFzf.ps1`:

```powershell
#Requires -Version 7.0

function Invoke-DFFzf {
    <#
    .SYNOPSIS
        Thin wrapper around the fzf external command.
        Exists as a separate function so tests can mock it without spawning fzf.
    .PARAMETER FzfArgs
        Arguments array forwarded to fzf.
    #>
    [CmdletBinding()]
    param([string[]]$FzfArgs)

    $input | fzf @FzfArgs
}
```

- [ ] **Step 4: Implement `Invoke-DFPicker`**

Create `C:\Users\simsr\projects\DotForge\Public\Invoke-DFPicker.ps1`:

```powershell
#Requires -Version 7.0

function Invoke-DFPicker {
    <#
    .SYNOPSIS
        Generalized fzf picker. Handles list → fzf → parse → action skeleton.
    .PARAMETER List
        Scriptblock that produces the items to display in fzf.
    .PARAMETER Header
        Header text shown at the top of the fzf window.
    .PARAMETER Preview
        fzf --preview string. Use {} as the placeholder for the selected item.
    .PARAMETER PreviewWindow
        fzf --preview-window value. Default: 'right:60%'.
    .PARAMETER Ansi
        Pass --ansi to fzf (for ANSI-colored input).
    .PARAMETER Multi
        Pass --multi to fzf; Action is called once per selected item.
    .PARAMETER Delimiter
        fzf --delimiter value.
    .PARAMETER WithNth
        fzf --with-nth value (which fields to display).
    .PARAMETER Parse
        Scriptblock to transform the raw fzf output line. $_ is the raw line.
        If omitted, the raw line is used as-is.
    .PARAMETER Action
        Scriptblock to invoke with the parsed value. Receives $value as param($v).
        If omitted, the parsed value is written to the output stream.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$List,
        [string]$Header        = '',
        [string]$Preview       = '',
        [string]$PreviewWindow = 'right:60%',
        [switch]$Ansi,
        [switch]$Multi,
        [string]$Delimiter     = '',
        [string]$WithNth       = '',
        [scriptblock]$Parse,
        [scriptblock]$Action
    )

    $fzfArgs = @('--preview-window', $PreviewWindow)
    if ($Preview)   { $fzfArgs += '--preview',   $Preview }
    if ($Header)    { $fzfArgs += '--header',     $Header }
    if ($Ansi)      { $fzfArgs += '--ansi' }
    if ($Multi)     { $fzfArgs += '--multi' }
    if ($Delimiter) { $fzfArgs += '--delimiter',  $Delimiter }
    if ($WithNth)   { $fzfArgs += '--with-nth',   $WithNth }

    $selected = & $List | Invoke-DFFzf -FzfArgs $fzfArgs
    if (-not $selected) { return }

    foreach ($item in @($selected)) {
        $value = if ($Parse) { $item | ForEach-Object $Parse } else { $item }
        if ($Action) { & $Action $value } else { $value }
    }
}
```

- [ ] **Step 5: Run tests — confirm they pass**

```powershell
Invoke-Pester tests/Invoke-DFPicker.Tests.ps1 -Output Detailed
```

Expected: 8 tests, all passing.

- [ ] **Step 6: Commit**

```powershell
git add Private/Invoke-DFFzf.ps1 Public/Invoke-DFPicker.ps1 tests/Invoke-DFPicker.Tests.ps1
git commit -m "feat: Invoke-DFPicker — generalized fzf picker with mockable fzf wrapper"
```

---

## Task 5: `Get-DFCachedCompletion`

**Files:**
- Create: `Public/Get-DFCachedCompletion.ps1`
- Create: `tests/Get-DFCachedCompletion.Tests.ps1`

- [ ] **Step 1: Write the failing tests**

Create `C:\Users\simsr\projects\DotForge\tests\Get-DFCachedCompletion.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/../Public/Ensure-DFDir.ps1"
    . "$PSScriptRoot/../Public/Get-DFCachedCompletion.ps1"
}

Describe 'Get-DFCachedCompletion' {
    BeforeEach {
        $script:SavedCache  = $Env:XDG_CACHE_HOME
        $Env:XDG_CACHE_HOME = Join-Path $TestDrive 'cache'
    }
    AfterEach {
        $Env:XDG_CACHE_HOME = $script:SavedCache
    }

    It 'calls Generate and writes cache file on first run' {
        $fakeExe = Join-Path $TestDrive 'tool.exe'
        New-Item -ItemType File -Path $fakeExe | Out-Null

        $called = $false
        Get-DFCachedCompletion -CacheKey 'tool1' -ExePath $fakeExe -Generate {
            $called = $true
            '# completion'
        }

        $called | Should -BeTrue
        $cacheFile = Join-Path $Env:XDG_CACHE_HOME 'dotforge' 'completions' 'tool1.ps1'
        Test-Path $cacheFile | Should -BeTrue
        Get-Content $cacheFile | Should -Be '# completion'
    }

    It 'skips Generate when cache file is newer than the exe' {
        $fakeExe = Join-Path $TestDrive 'tool.exe'
        New-Item -ItemType File -Path $fakeExe | Out-Null

        $cacheDir  = Join-Path $Env:XDG_CACHE_HOME 'dotforge' 'completions'
        $cacheFile = Join-Path $cacheDir 'tool2.ps1'
        New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
        '# cached' | Set-Content $cacheFile

        # Make cache newer than exe
        (Get-Item $cacheFile).LastWriteTime = (Get-Date).AddHours(1)

        $called = $false
        Get-DFCachedCompletion -CacheKey 'tool2' -ExePath $fakeExe -Generate { $called = $true }
        $called | Should -BeFalse
    }

    It 'regenerates when exe is newer than cache' {
        $fakeExe = Join-Path $TestDrive 'tool.exe'
        New-Item -ItemType File -Path $fakeExe | Out-Null

        $cacheDir  = Join-Path $Env:XDG_CACHE_HOME 'dotforge' 'completions'
        $cacheFile = Join-Path $cacheDir 'tool3.ps1'
        New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
        '# old' | Set-Content $cacheFile

        # Make exe newer than cache
        (Get-Item $fakeExe).LastWriteTime = (Get-Date).AddHours(1)

        $called = $false
        Get-DFCachedCompletion -CacheKey 'tool3' -ExePath $fakeExe -Generate {
            $called = $true
            '# new'
        }
        $called | Should -BeTrue
        Get-Content $cacheFile | Should -Be '# new'
    }

    It 'does not throw when ExePath does not exist (tool not installed)' {
        { Get-DFCachedCompletion -CacheKey 'missing' -ExePath 'C:\nonexistent.exe' -Generate { '# x' } } |
            Should -Not -Throw
    }

    It 'creates the cache directory if it does not exist' {
        $fakeExe = Join-Path $TestDrive 'tool.exe'
        New-Item -ItemType File -Path $fakeExe | Out-Null
        $cacheDir = Join-Path $Env:XDG_CACHE_HOME 'dotforge' 'completions'
        Test-Path $cacheDir | Should -BeFalse

        Get-DFCachedCompletion -CacheKey 'tool5' -ExePath $fakeExe -Generate { '# c' }
        Test-Path $cacheDir | Should -BeTrue
    }
}
```

- [ ] **Step 2: Run tests — confirm they fail**

```powershell
Invoke-Pester tests/Get-DFCachedCompletion.Tests.ps1 -Output Detailed
```

Expected: All tests fail.

- [ ] **Step 3: Implement `Get-DFCachedCompletion`**

Create `C:\Users\simsr\projects\DotForge\Public\Get-DFCachedCompletion.ps1`:

```powershell
#Requires -Version 7.0

function Get-DFCachedCompletion {
    <#
    .SYNOPSIS
        Mtime-based completion script caching. Only regenerates when the tool
        binary is newer than the cached .ps1 file.
    .PARAMETER CacheKey
        Unique key for this tool's cache file (e.g. 'rg', 'chezmoi').
    .PARAMETER ExePath
        Full path to the tool's executable. Used for mtime comparison.
    .PARAMETER Generate
        Scriptblock that produces the completion script text.
        Only called when the cache is stale or absent.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CacheKey,
        [Parameter(Mandatory)][string]$ExePath,
        [Parameter(Mandatory)][scriptblock]$Generate
    )

    $cacheDir  = Join-Path $Env:XDG_CACHE_HOME 'dotforge' 'completions'
    $cacheFile = Join-Path $cacheDir "$CacheKey.ps1"
    $cacheItem = Get-Item $cacheFile -ErrorAction Ignore
    $exeItem   = Get-Item $ExePath   -ErrorAction Ignore

    $upToDate = $cacheItem -and $exeItem -and
                ($cacheItem.LastWriteTime -gt $exeItem.LastWriteTime)

    if (-not $upToDate) {
        Ensure-DFDir $cacheDir
        $content = & $Generate
        if ($content) {
            Set-Content -Path $cacheFile -Value $content -Encoding UTF8
        }
        $cacheItem = Get-Item $cacheFile -ErrorAction Ignore
    }

    if ($cacheItem) { . $cacheFile }
}
```

- [ ] **Step 4: Run tests — confirm they pass**

```powershell
Invoke-Pester tests/Get-DFCachedCompletion.Tests.ps1 -Output Detailed
```

Expected: 5 tests, all passing.

- [ ] **Step 5: Commit**

```powershell
git add Public/Get-DFCachedCompletion.ps1 tests/Get-DFCachedCompletion.Tests.ps1
git commit -m "feat: Get-DFCachedCompletion — mtime-based completion script caching"
```

---

## Task 6: Tool JSON schema + validator

**Files:**
- Create: `Private/Test-DFToolSchema.ps1`
- Create: `tests/Test-DFToolSchema.Tests.ps1`

- [ ] **Step 1: Write the failing tests**

Create `C:\Users\simsr\projects\DotForge\tests\Test-DFToolSchema.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/../Private/Test-DFToolSchema.ps1"
}

Describe 'Test-DFToolSchema' {
    Context 'valid records' {
        It 'passes a minimal valid tool record' {
            $tool = [PSCustomObject]@{
                name       = 'mytool'
                executable = 'mytool.exe'
            }
            $errors = @()
            Test-DFToolSchema -Tool $tool -Errors ([ref]$errors) | Should -BeTrue
            $errors | Should -BeNullOrEmpty
        }

        It 'passes a fully populated valid record' {
            $tool = [PSCustomObject]@{
                name        = 'bat'
                executable  = 'bat.exe'
                description = 'Modern cat'
                tags        = @('viewer')
                packages    = [PSCustomObject]@{ scoop = 'bat' }
                xdg         = [PSCustomObject]@{
                    compliance = 'partial'
                    method     = 'env'
                    vars       = [PSCustomObject]@{ BAT_CONFIG_PATH = '${XDG_CONFIG_HOME}/bat/bat.conf' }
                    dirs       = @()
                }
                completions = [PSCustomObject]@{
                    type  = 'static'
                    flags = @('--theme', '--language')
                }
                aliases = [PSCustomObject]@{}
                picker  = $null
            }
            Test-DFToolSchema -Tool $tool -Errors ([ref]$null) | Should -BeTrue
        }
    }

    Context 'invalid records' {
        It 'fails when name is missing' {
            $tool = [PSCustomObject]@{ executable = 'tool.exe' }
            $errors = @()
            Test-DFToolSchema -Tool $tool -Errors ([ref]$errors) | Should -BeFalse
            $errors | Where-Object { $_ -match 'name' } | Should -Not -BeNullOrEmpty
        }

        It 'fails when executable is missing' {
            $tool = [PSCustomObject]@{ name = 'mytool' }
            $errors = @()
            Test-DFToolSchema -Tool $tool -Errors ([ref]$errors) | Should -BeFalse
            $errors | Where-Object { $_ -match 'executable' } | Should -Not -BeNullOrEmpty
        }

        It 'fails when xdg.method is not a valid value' {
            $tool = [PSCustomObject]@{
                name       = 'mytool'
                executable = 'mytool.exe'
                xdg        = [PSCustomObject]@{ method = 'invalid' }
            }
            $errors = @()
            Test-DFToolSchema -Tool $tool -Errors ([ref]$errors) | Should -BeFalse
            $errors | Where-Object { $_ -match 'xdg.method' } | Should -Not -BeNullOrEmpty
        }

        It 'fails when completions.type is not a valid value' {
            $tool = [PSCustomObject]@{
                name        = 'mytool'
                executable  = 'mytool.exe'
                completions = [PSCustomObject]@{ type = 'magic' }
            }
            $errors = @()
            Test-DFToolSchema -Tool $tool -Errors ([ref]$errors) | Should -BeFalse
            $errors | Where-Object { $_ -match 'completions.type' } | Should -Not -BeNullOrEmpty
        }

        It 'fails when completions.type is dynamic but command is missing' {
            $tool = [PSCustomObject]@{
                name        = 'mytool'
                executable  = 'mytool.exe'
                completions = [PSCustomObject]@{ type = 'dynamic' }
            }
            $errors = @()
            Test-DFToolSchema -Tool $tool -Errors ([ref]$errors) | Should -BeFalse
            $errors | Where-Object { $_ -match 'command' } | Should -Not -BeNullOrEmpty
        }
    }
}
```

- [ ] **Step 2: Run tests — confirm they fail**

```powershell
Invoke-Pester tests/Test-DFToolSchema.Tests.ps1 -Output Detailed
```

Expected: All tests fail.

- [ ] **Step 3: Implement `Test-DFToolSchema`**

Create `C:\Users\simsr\projects\DotForge\Private\Test-DFToolSchema.ps1`:

```powershell
#Requires -Version 7.0

function Test-DFToolSchema {
    <#
    .SYNOPSIS
        Validates a tool PSCustomObject against the DotForge tool schema.
        Returns $true if valid; populates -Errors with any violation messages.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Tool,
        [ref]$Errors
    )

    $errs = [System.Collections.Generic.List[string]]::new()

    # Required fields
    if (-not $Tool.name)       { $errs.Add("Missing required field: name") }
    if (-not $Tool.executable) { $errs.Add("Missing required field: executable") }

    # xdg.method
    $validMethods = @('default', 'env', 'config', 'wrapper', 'manual')
    if ($Tool.xdg -and $Tool.xdg.method -and $Tool.xdg.method -notin $validMethods) {
        $errs.Add("Invalid xdg.method '$($Tool.xdg.method)'. Valid: $($validMethods -join ', ')")
    }

    # completions.type
    $validTypes = @('static', 'dynamic')
    if ($Tool.completions -and $Tool.completions.type -and
        $Tool.completions.type -notin $validTypes) {
        $errs.Add("Invalid completions.type '$($Tool.completions.type)'. Valid: $($validTypes -join ', ')")
    }

    # dynamic completions require command
    if ($Tool.completions.type -eq 'dynamic' -and -not $Tool.completions.command) {
        $errs.Add("completions.type 'dynamic' requires completions.command")
    }

    if ($Errors) { $Errors.Value = $errs.ToArray() }
    return $errs.Count -eq 0
}
```

- [ ] **Step 4: Run tests — confirm they pass**

```powershell
Invoke-Pester tests/Test-DFToolSchema.Tests.ps1 -Output Detailed
```

Expected: All tests passing.

- [ ] **Step 5: Commit**

```powershell
git add Private/Test-DFToolSchema.ps1 tests/Test-DFToolSchema.Tests.ps1
git commit -m "feat: Test-DFToolSchema — tool JSON schema validator"
```

---

## Task 7: Five seed tool JSON records

**Files:**
- Create: `Tools/bat.json`
- Create: `Tools/eza.json`
- Create: `Tools/fzf.json`
- Create: `Tools/ripgrep.json`
- Create: `Tools/zoxide.json`

All 5 JSON files must pass `Test-DFToolSchema`. The test for this is added to
`tests/Test-DFToolSchema.Tests.ps1` (append to the file, don't replace it).

- [ ] **Step 1: Create `Tools/bat.json`**

```json
{
  "name": "bat",
  "description": "Modern cat replacement with syntax highlighting and Git integration",
  "tags": ["viewer", "pager", "file"],
  "executable": "bat.exe",
  "packages": {
    "scoop":  "bat",
    "winget": "sharkdp.bat",
    "choco":  "bat"
  },
  "xdg": {
    "compliance": "partial",
    "method": "env",
    "vars": {
      "BAT_CONFIG_PATH": "${XDG_CONFIG_HOME}/bat/bat.conf"
    },
    "dirs": []
  },
  "completions": {
    "type": "static",
    "flags": [
      "--language", "--theme", "--style", "--paging", "--color",
      "--line-range", "--highlight-line", "--diff", "--show-all",
      "--plain", "--number", "--decorations", "--italic-text",
      "--tabs", "--wrap", "--terminal-width", "--map-syntax",
      "--list-languages", "--list-themes"
    ]
  },
  "aliases": {
    "cat": { "command": "bat", "args": ["-pp"] }
  },
  "picker": null
}
```

- [ ] **Step 2: Create `Tools/eza.json`**

```json
{
  "name": "eza",
  "description": "Modern ls replacement with icons, Git integration, and color",
  "tags": ["file", "directory", "ls"],
  "executable": "eza.exe",
  "packages": {
    "scoop":  "eza",
    "winget": "eza-community.eza",
    "choco":  "eza"
  },
  "xdg": {
    "compliance": "none",
    "method": "default"
  },
  "completions": {
    "type": "static",
    "flags": [
      "--long", "--all", "--tree", "--icons", "--git", "--color",
      "--group-directories-first", "--sort", "--reverse", "--header",
      "--group", "--oneline", "--classify", "--level", "--ignore-glob",
      "--time-style", "--hyperlink", "--no-permissions", "--no-filesize",
      "--no-user", "--no-time", "--stdin", "--list-dirs", "--dereference"
    ]
  },
  "aliases": {
    "ls":   { "command": "eza", "args": ["--color=auto", "--icons", "--group-directories-first"] },
    "ll":   { "command": "eza", "args": ["--all", "--long", "--header"] },
    "la":   { "command": "eza", "args": ["--all", "--group"] },
    "tree": { "command": "eza", "args": ["--tree"] }
  },
  "picker": {
    "alias": "ff",
    "function": "Select-File",
    "list": "eza --icons -1 --color=always",
    "list_accepts_path": true,
    "preview": "bat --color=always --line-range=:200 {}",
    "preview_window": "right:60%",
    "ansi": true,
    "header": "Select file  [Enter to open]",
    "action": "output"
  }
}
```

- [ ] **Step 3: Create `Tools/fzf.json`**

```json
{
  "name": "fzf",
  "description": "General-purpose command-line fuzzy finder",
  "tags": ["fuzzy", "picker", "search"],
  "executable": "fzf.exe",
  "packages": {
    "scoop":  "fzf",
    "winget": "junegunn.fzf",
    "choco":  "fzf"
  },
  "xdg": {
    "compliance": "none",
    "method": "default"
  },
  "completions": {
    "type": "static",
    "flags": [
      "--query", "--filter", "--select-1", "--exit-0", "--multi",
      "--no-sort", "--reverse", "--exact", "--ansi", "--preview",
      "--preview-window", "--height", "--border", "--header",
      "--delimiter", "--with-nth", "--nth", "--cycle", "--layout",
      "--bind", "--color"
    ]
  },
  "aliases": {},
  "picker": null
}
```

- [ ] **Step 4: Create `Tools/ripgrep.json`**

```json
{
  "name": "ripgrep",
  "description": "Recursively search directories for a regex pattern, respecting gitignore",
  "tags": ["search", "grep", "text"],
  "executable": "rg.exe",
  "packages": {
    "scoop":  "ripgrep",
    "winget": "BurntSushi.ripgrep.MSVC",
    "choco":  "ripgrep"
  },
  "xdg": {
    "compliance": "partial",
    "method": "env",
    "vars": {
      "RIPGREP_CONFIG_PATH": "${XDG_CONFIG_HOME}/ripgrep/ripgreprc"
    },
    "dirs": ["${XDG_CONFIG_HOME}/ripgrep"]
  },
  "completions": {
    "type": "dynamic",
    "command": "rg --generate complete-powershell",
    "cache": true
  },
  "aliases": {},
  "picker": "custom"
}
```

- [ ] **Step 5: Create `Tools/zoxide.json`**

```json
{
  "name": "zoxide",
  "description": "Smarter cd that learns your most-used directories",
  "tags": ["navigation", "cd", "directory"],
  "executable": "zoxide.exe",
  "packages": {
    "scoop":  "zoxide",
    "winget": "ajeetdsouza.zoxide",
    "choco":  "zoxide"
  },
  "xdg": {
    "compliance": "partial",
    "method": "env",
    "vars": {
      "_ZO_DATA_DIR": "${XDG_DATA_HOME}/zoxide"
    },
    "dirs": []
  },
  "completions": {
    "type": "static",
    "flags": ["query", "add", "remove", "edit", "import", "init"]
  },
  "aliases": {
    "cd": { "command": "z", "args": [] }
  },
  "picker": {
    "alias": "fcd",
    "function": "Select-Directory",
    "list": "zoxide query --list",
    "preview": "eza --icons --color=always {}",
    "preview_window": "right:60%",
    "ansi": false,
    "header": "Select directory  [Enter to cd]",
    "action": "Set-Location {}"
  }
}
```

- [ ] **Step 6: Add seed file validation to the test suite**

Append to `tests/Test-DFToolSchema.Tests.ps1` (at the end of the file, after the existing Describe block):

```powershell
Describe 'Seed tool JSON files' {
    BeforeAll {
        . "$PSScriptRoot/../Private/Test-DFToolSchema.ps1"
        $toolsDir = Join-Path $PSScriptRoot '../Tools'
    }

    $seedFiles = @('bat', 'eza', 'fzf', 'ripgrep', 'zoxide') |
        ForEach-Object { @{ Name = $_; Path = Join-Path $PSScriptRoot "../Tools/$_.json" } }

    It 'seed file <Name>.json exists and passes schema validation' -ForEach $seedFiles {
        Test-Path $Path | Should -BeTrue -Because "$Name.json must exist in Tools/"
        $tool = Get-Content $Path -Raw | ConvertFrom-Json
        $errors = @()
        Test-DFToolSchema -Tool $tool -Errors ([ref]$errors) |
            Should -BeTrue -Because ($errors -join '; ')
    }
}
```

- [ ] **Step 7: Run schema tests — confirm all 5 pass**

```powershell
Invoke-Pester tests/Test-DFToolSchema.Tests.ps1 -Output Detailed
```

Expected: All tests passing including 5 seed file tests.

- [ ] **Step 8: Commit**

```powershell
git add Tools/ tests/Test-DFToolSchema.Tests.ps1
git commit -m "feat: add 5 seed tool records (bat, eza, fzf, ripgrep, zoxide)"
```

---

## Task 8: Module wiring, full test run, push

**Files:**
- Modify: `DotForge.psd1` — update `FunctionsToExport`

- [ ] **Step 1: Update `DotForge.psd1` to export the 4 public functions**

In `DotForge.psd1`, change:
```powershell
FunctionsToExport = @()
```
to:
```powershell
FunctionsToExport = @(
    'Add-DFToPath',
    'Ensure-DFDir',
    'Invoke-DFPicker',
    'Get-DFCachedCompletion'
)
```

- [ ] **Step 2: Verify the module imports cleanly**

```powershell
pwsh -NoProfile -Command "
  Import-Module 'C:\Users\simsr\projects\DotForge\DotForge.psd1' -Force
  Get-Command -Module DotForge | Select-Object Name
"
```

Expected output:
```
Name
----
Add-DFToPath
Ensure-DFDir
Get-DFCachedCompletion
Invoke-DFPicker
```

- [ ] **Step 3: Run the full test suite**

```powershell
cd C:\Users\simsr\projects\DotForge
Invoke-Pester tests/ -Output Detailed
```

Expected: All tests passing. Count: 7 + 5 + 8 + 5 + 10 = 35 tests.

- [ ] **Step 4: Commit and push**

```powershell
git add DotForge.psd1
git commit -m "feat: wire module manifest — Phase 1 complete

Exports: Add-DFToPath, Ensure-DFDir, Invoke-DFPicker, Get-DFCachedCompletion
Tests: 35 passing
Seed tools: bat, eza, fzf, ripgrep, zoxide"

git push
```

---

## Self-Review Notes

**Spec coverage:**
- `Add-DFToPath` ✓ (Task 2)
- `Ensure-DFDir` ✓ (Task 3)
- `Invoke-DFPicker` ✓ (Task 4, including `Invoke-DFFzf` private wrapper)
- `Get-DFCachedCompletion` ✓ (Task 5)
- Tool JSON schema definition ✓ (Task 6 — `Test-DFToolSchema`)
- 5 seed tool records ✓ (Task 7)
- Pester tests for all primitives ✓ (each task has TDD steps)
- Module manifest `FunctionsToExport` ✓ (Task 8)

**Phases 2–4:** Not planned here. Each gets its own plan when Phase 1 ships.

**Type consistency:**
- `Invoke-DFFzf -FzfArgs [string[]]` — used consistently in `Invoke-DFPicker` and the mock filter
- `Test-DFToolSchema -Tool [PSCustomObject] -Errors [ref]` — consistent across implementation and tests
- Cache path `$XDG_CACHE_HOME/dotforge/completions/<key>.ps1` — consistent in implementation and tests
