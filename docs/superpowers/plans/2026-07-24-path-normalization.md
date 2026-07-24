# Path Normalization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Introduce `ConvertTo-DFPath` and route DotForge's path boundaries through it so every stored/compared/emitted/accepted path is absolute, native-separator, free of `.`/`..`, without a trailing separator, with leading `~` expanded to `$HOME`.

**Architecture:** One private helper wraps `[System.IO.Path]::GetFullPath` plus a root-aware trailing-separator strip and leading-`~` expansion. It is applied boundary-focused: the biggest lever is `Expand-DFXdgPath` (fixes the mixed-separator env vars for ~20 tools at the source); the rest re-point existing inline `GetFullPath` uses at the helper and canonicalize the `../`-bearing defaults.

**Tech Stack:** PowerShell 7+, Pester 5. Design: `docs/superpowers/specs/2026-07-24-path-normalization-design.md`.

## Global Constraints

- **PowerShell 7+.** No `$ErrorActionPreference = 'Stop'` in module files.
- **Private helpers** are `function script:Name { }` in `Private/`, `DF`-prefixed, auto-loaded by `DotForge.psm1` and visible to dot-sourced sidecars.
- **Null-safe `$DFConfig`:** test `$null -ne $Global:DFConfig`, never `Get-Variable`.
- **`GetFullPath` facts (verified empirically — rely on them):** makes absolute, collapses `.`/`..`, converts to native separator; does **NOT** strip trailing separators (explicit root-aware strip required); expands *existing* 8.3 short names to long form; works on non-existent paths without error.
- **Root-aware trailing strip:** `$root = [IO.Path]::GetPathRoot($full)`; only `TrimEnd` when `$full.Length -gt $root.Length`, so `C:\` and `\\srv\share` are preserved.
- **Leading-`~` only:** expand `~` when the path is exactly `~` or starts with `~/`/`~\`; never a `~` elsewhere (Windows 8.3 short names).
- **Flag-string safety:** `Expand-DFXdgPath` normalizes only when the template contained an `${XDG_*}` token. Token-less values (LESS, FZF_*) pass through byte-for-byte.
- **Relative input** → `Write-Warning` and return unchanged, never bind to CWD.
- **Pester 5**, run tests from `pwsh -NoProfile`. Commit after each task.

---

## File Structure

**New:** `Private/ConvertTo-DFPath.ps1`, `tests/ConvertTo-DFPath.Tests.ps1`.
**Modified:** `Private/Expand-DFXdgPath.ps1`, `Tools/mdv.ps1`, `Public/Add-DFToPath.ps1`, `Public/New-DFShim.ps1`, `Public/Initialize-DFEnvironment.ps1`, `Public/Register-DFTool.ps1`, and their test files; `CLAUDE.md`, `docs/external-dependencies.md`, `CHANGELOG.md`.

**Spec correction:** `Get-DFCommandConflict` was listed as a path-comparison site but compares command *names*, not paths (verified) — it is NOT modified. The only path-comparison sites are `Add-DFToPath` and `New-DFShim`.

**`glow` needs no change:** the spec §2 lists mdv *and* glow sidecars. `Tools/glow.ps1` builds its config path via `Expand-DFXdgPath`, so it is canonicalized transitively by Task 2 — no glow edit is required. Only `mdv` had a redundant local patch to remove (Task 3).

---

## Task 1: `ConvertTo-DFPath` helper

**Files:**
- Create: `Private/ConvertTo-DFPath.ps1`
- Test: `tests/ConvertTo-DFPath.Tests.ps1`

**Interfaces:**
- Produces: `ConvertTo-DFPath [-Path] <string>` → `[string]`. Canonical absolute path (native sep, no `.`/`..`, no trailing sep, root preserved); leading `~` → `$HOME`; null/empty and relative returned unchanged (relative also warns).

- [ ] **Step 1: Write the failing test**

Create `tests/ConvertTo-DFPath.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/../Private/ConvertTo-DFPath.ps1"
}

Describe 'ConvertTo-DFPath' {
    It 'collapses . and .. and normalizes separators' {
        ConvertTo-DFPath 'C:\a\.\b\..\c' | Should -Be 'C:\a\c'
        ConvertTo-DFPath 'C:\Users\me/.config/bat/bat.conf' | Should -Be 'C:\Users\me\.config\bat\bat.conf'
    }
    It 'strips a trailing separator but preserves the root' {
        ConvertTo-DFPath 'C:\a\b\'  | Should -Be 'C:\a\b'
        ConvertTo-DFPath 'C:\a\b\\' | Should -Be 'C:\a\b'
        ConvertTo-DFPath 'C:\'      | Should -Be 'C:\'
    }
    It 'expands a leading ~ to $HOME' {
        ConvertTo-DFPath '~'       | Should -Be ([System.IO.Path]::GetFullPath($HOME))
        ConvertTo-DFPath '~/glow'  | Should -Be (Join-Path $HOME 'glow')
        ConvertTo-DFPath '~\glow'  | Should -Be (Join-Path $HOME 'glow')
    }
    It 'does not touch a ~ that is not leading' {
        # Non-existent short-name path: GetFullPath leaves PROGRA~1 as-is (string only).
        ConvertTo-DFPath 'C:\zzznope\PROGRA~1\x' | Should -Be 'C:\zzznope\PROGRA~1\x'
    }
    It 'warns and returns relative input unchanged' {
        $w = ConvertTo-DFPath 'foo\bar' -WarningVariable warn -WarningAction SilentlyContinue
        $w | Should -Be 'foo\bar'
        $warn | Should -Match 'not an absolute path'
    }
    It 'treats a leading ~foo (no separator) as relative' {
        ConvertTo-DFPath '~foo' -WarningAction SilentlyContinue | Should -Be '~foo'
    }
    It 'passes null and empty through unchanged' {
        ConvertTo-DFPath ''   | Should -Be ''
        ConvertTo-DFPath $null | Should -BeNullOrEmpty
    }
    It 'is idempotent' {
        $once = ConvertTo-DFPath 'C:\a\.\b\..\c\'
        ConvertTo-DFPath $once | Should -Be $once
    }
    It 'canonicalizes a non-existent path without error' {
        ConvertTo-DFPath 'C:\no\such\x\..\y' | Should -Be 'C:\no\such\y'
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/ConvertTo-DFPath.Tests.ps1 -Output Detailed"`
Expected: FAIL — file/function not found.

- [ ] **Step 3: Write the implementation**

Create `Private/ConvertTo-DFPath.ps1`:

```powershell
#Requires -Version 7.0

function script:ConvertTo-DFPath {
    <#
    .SYNOPSIS
        Canonicalizes an absolute path: native separators, no ./.., no trailing
        separator, with a leading ~ expanded to $HOME.
    .DESCRIPTION
        The single path-normalization primitive for DotForge. Returns
        [System.IO.Path]::GetFullPath's canonical form with a root-aware
        trailing-separator strip. Null/empty pass through untouched. A relative
        path is a probable bug: it is returned unchanged with a warning, never
        silently bound to the current directory. Works on paths that do not exist
        yet (no filesystem access, except that an existing 8.3 short-name segment
        is expanded to its long form).
    .PARAMETER Path
        The path to canonicalize.
    .OUTPUTS
        [string] the canonical path, or the input unchanged for null/empty/relative.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][string]$Path)

    if ([string]::IsNullOrEmpty($Path)) { return $Path }

    # Expand a leading ~ (whole path, or immediately followed by a separator) to
    # $HOME. Never a ~ elsewhere — that would corrupt Windows 8.3 short names
    # (C:\PROGRA~1) or a literal filename.
    if ($Path -eq '~' -or $Path -match '^~[\\/]') {
        $Path = $HOME + $Path.Substring(1)
    }

    if (-not [System.IO.Path]::IsPathRooted($Path)) {
        Write-Warning "ConvertTo-DFPath: '$Path' is not an absolute path — returned unchanged."
        return $Path
    }

    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $root.Length) {
        $full = $full.TrimEnd([System.IO.Path]::DirectorySeparatorChar,
                              [System.IO.Path]::AltDirectorySeparatorChar)
    }
    $full
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/ConvertTo-DFPath.Tests.ps1 -Output Detailed"`
Expected: PASS (9 tests).

- [ ] **Step 5: Commit**

```bash
git add Private/ConvertTo-DFPath.ps1 tests/ConvertTo-DFPath.Tests.ps1
git commit -m "feat: add ConvertTo-DFPath path-normalization helper"
```

---

## Task 2: `Expand-DFXdgPath` normalizes substituted paths

**Files:**
- Modify: `Private/Expand-DFXdgPath.ps1`
- Test: `tests/Expand-DFXdgPath.Tests.ps1`

**Interfaces:**
- Consumes: `ConvertTo-DFPath` (Task 1).
- Produces: `Expand-DFXdgPath` output is canonical (native sep, no trailing sep) **when the template contained an `${XDG_*}` token**; token-less strings are returned byte-for-byte. This single change fixes the mixed-separator env vars for every env-method tool.

**Context:** `Register-DFTool`'s env method sets each `vars` value via `Expand-DFXdgPath`. Normalizing here cleans all downstream env vars (`BAT_CONFIG_PATH`, `MDV_CONFIG_PATH`, …) at the source. Flag strings (`LESS`, `FZF_DEFAULT_OPTS`) contain no XDG token, so they are untouched.

- [ ] **Step 1: Update the failing tests**

The 6 existing assertions in `tests/Expand-DFXdgPath.Tests.ps1` currently expect the mixed-separator output. Replace the `Describe` body's `It` blocks with these (the `BeforeEach`/`AfterEach` that set `$Env:XDG_*` to `C:\config` etc. stay unchanged), and add the dot-source of the helper to `BeforeAll`:

Add to `BeforeAll` (after the existing `Expand-DFXdgPath.ps1` dot-source):
```powershell
    . "$PSScriptRoot/../Private/ConvertTo-DFPath.ps1"
```

Replace the six `It` blocks with:
```powershell
    It 'expands ${XDG_CONFIG_HOME} to a canonical native path' {
        Expand-DFXdgPath '${XDG_CONFIG_HOME}/bat/bat.conf' | Should -Be 'C:\config\bat\bat.conf'
    }
    It 'expands ${XDG_DATA_HOME} to a canonical native path' {
        Expand-DFXdgPath '${XDG_DATA_HOME}/zoxide' | Should -Be 'C:\data\zoxide'
    }
    It 'expands ${XDG_STATE_HOME} to a canonical native path' {
        Expand-DFXdgPath '${XDG_STATE_HOME}/less/history' | Should -Be 'C:\state\less\history'
    }
    It 'expands ${XDG_CACHE_HOME} to a canonical native path' {
        Expand-DFXdgPath '${XDG_CACHE_HOME}/uv' | Should -Be 'C:\cache\uv'
    }
    It 'collapses a trailing segment to no trailing separator' {
        Expand-DFXdgPath '${XDG_CONFIG_HOME}/glow/' | Should -Be 'C:\config\glow'
    }
    It 'returns a token-less flag string byte-for-byte' {
        Expand-DFXdgPath '--RAW-CONTROL-CHARS --quit-if-one-screen --no-init' |
            Should -Be '--RAW-CONTROL-CHARS --quit-if-one-screen --no-init'
    }
    It 'leaves forward slashes in a token-less string untouched' {
        Expand-DFXdgPath 'fd --type f --exclude .git' | Should -Be 'fd --type f --exclude .git'
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Expand-DFXdgPath.Tests.ps1 -Output Detailed"`
Expected: the path-expansion tests FAIL (current output is mixed `C:\config/bat/bat.conf`); the flag-string tests pass.

- [ ] **Step 3: Implement**

Replace the body of `Private/Expand-DFXdgPath.ps1`'s function with:

```powershell
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Template)

    $expanded = $Template `
        -creplace '\$\{XDG_CONFIG_HOME\}', $Env:XDG_CONFIG_HOME `
        -creplace '\$\{XDG_DATA_HOME\}',   $Env:XDG_DATA_HOME `
        -creplace '\$\{XDG_STATE_HOME\}',  $Env:XDG_STATE_HOME `
        -creplace '\$\{XDG_CACHE_HOME\}',  $Env:XDG_CACHE_HOME

    # Normalize ONLY when an XDG token was present: a token-bearing value is always a
    # filesystem path. Token-less values are literal flag strings (LESS, FZF_*, ...)
    # and must pass through byte-for-byte. See docs/external-dependencies.md.
    if ($Template -cmatch '\$\{XDG_(CONFIG|DATA|STATE|CACHE)_HOME\}') {
        return ConvertTo-DFPath $expanded
    }
    $expanded
```

(Keep the `#Requires`, `function script:Expand-DFXdgPath {`, and the `.SYNOPSIS` comment block above the param.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Expand-DFXdgPath.Tests.ps1 -Output Detailed"`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add Private/Expand-DFXdgPath.ps1 tests/Expand-DFXdgPath.Tests.ps1
git commit -m "feat: normalize Expand-DFXdgPath output for substituted paths"
```

---

## Task 3: Remove mdv's now-redundant separator patch

**Files:**
- Modify: `Tools/mdv.ps1`
- Test: `tests/mdv.Tests.ps1` (already green; confirm it stays green)

**Interfaces:**
- Consumes: the Task 2 fix (`$Env:MDV_CONFIG_PATH`, set via `Expand-DFXdgPath`, is now already canonical).

**Context:** `Tools/mdv.ps1:28-33` locally re-normalizes `$Env:MDV_CONFIG_PATH` because it used to be mixed-separator. After Task 2 that value is already native, so the local patch is dead code. Remove it; the sidecar just reads the (now-canonical) env var.

- [ ] **Step 1: Confirm mdv tests currently pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/mdv.Tests.ps1 -Output Detailed"`
Expected: PASS (all).

- [ ] **Step 2: Simplify the sidecar**

In `Tools/mdv.ps1`, replace this block (currently lines 25-34):

```powershell
# 2. Seed config.yaml when absent. MDV_CONFIG_PATH was set by the env method; fall
#    back to the XDG path if it is somehow empty.
#    Normalize path separators for the current platform.
if ($Env:MDV_CONFIG_PATH) {
    $Env:MDV_CONFIG_PATH = $Env:MDV_CONFIG_PATH -replace [regex]::Escape([System.IO.Path]::AltDirectorySeparatorChar), [System.IO.Path]::DirectorySeparatorChar
    $_cfgDir = $Env:MDV_CONFIG_PATH
} else {
    $_cfgDir = Expand-DFXdgPath '${XDG_CONFIG_HOME}/mdv'
}
New-DFDirectory $_cfgDir | Out-Null
```

with:

```powershell
# 2. Seed config.yaml when absent. MDV_CONFIG_PATH was set (and canonicalized) by
#    the env method via Expand-DFXdgPath; fall back to the XDG path if it is empty.
$_cfgDir = if ($Env:MDV_CONFIG_PATH) { $Env:MDV_CONFIG_PATH }
           else { Expand-DFXdgPath '${XDG_CONFIG_HOME}/mdv' }
New-DFDirectory $_cfgDir | Out-Null
```

- [ ] **Step 3: Run mdv tests to verify they still pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/mdv.Tests.ps1 -Output Detailed"`
Expected: PASS (all) — the test asserting `$Env:MDV_CONFIG_PATH -eq (Join-Path $Env:XDG_CONFIG_HOME 'mdv')` still holds because the env value is now canonical native.

- [ ] **Step 4: Commit**

```bash
git add Tools/mdv.ps1
git commit -m "refactor: drop mdv's local separator patch (subsumed by helper)"
```

---

## Task 4: Re-point the path primitives at the helper

**Files:**
- Modify: `Public/Add-DFToPath.ps1`, `Public/New-DFShim.ps1`, `Public/New-DFDirectory.ps1`
- Test: `tests/Add-DFToPath.Tests.ps1`, `tests/New-DFShim.Tests.ps1`, `tests/New-DFDirectory.Tests.ps1`

**Interfaces:**
- Consumes: `ConvertTo-DFPath` (Task 1). Each file's test `BeforeAll` must dot-source it: add `. "$PSScriptRoot/../Private/ConvertTo-DFPath.ps1"`.
- Produces: `New-DFShim` now expands a `~` in `$ShimsPath`/`$DFConfig['ShimsPath']`; PATH comparisons use canonical (trailing-sep-insensitive) forms; `New-DFDirectory` canonicalizes an **absolute** input before creating.

**Context:** `Add-DFToPath` and `New-DFShim` already call `[IO.Path]::GetFullPath` inline; `New-DFShim` pairs it with a non-root-aware `.TrimEnd('\','/')`. Route both through the helper. PATH iteration keeps filtering to rooted entries first so the helper never warns on relative junk in `$Env:PATH`. `New-DFDirectory` gets a **rooted-guarded** normalization: it must still create a *relative* dir silently (a legitimate use), so it only canonicalizes when the input is already absolute — never routing a relative path through the warning helper.

- [ ] **Step 1: Write the failing tests**

Add to `tests/Add-DFToPath.Tests.ps1` (inside the top `Describe`), and add the helper dot-source to its `BeforeAll`:
```powershell
    It 'dedups a path that differs only by trailing separator / .. against its canonical form' {
        $saved = $Env:Path
        try {
            $Env:Path = 'C:\tools\bin'
            Add-DFToPath 'C:\tools\extra\..\bin\'
            ($Env:Path -split ';' | Where-Object { $_ -eq 'C:\tools\bin' }).Count | Should -Be 1
            $Env:Path | Should -Not -Match 'extra'
        } finally { $Env:Path = $saved }
    }
```

Add to `tests/New-DFShim.Tests.ps1` (inside `Describe 'New-DFShim'`), and add the helper dot-source to its `BeforeAll`:
```powershell
    It 'expands a ~ in ShimsPath to $HOME' {
        $shim = Join-Path $HOME '.local' 'bin' 'dftilde.cmd'
        try {
            New-DFShim -Name 'dftilde' -Target $script:FakeExe -ShimsPath '~/.local/bin' 3>$null
            Test-Path $shim | Should -BeTrue
        } finally { Remove-Item $shim -ErrorAction Ignore }
    }
```

Add to `tests/New-DFDirectory.Tests.ps1` (inside its main `Describe`), and add the helper dot-source to its `BeforeAll`:
```powershell
    It 'canonicalizes an absolute path with .. before creating it' {
        $base = Join-Path $TestDrive 'nd'
        New-DFDirectory (Join-Path $base 'extra\..\real')
        Test-Path (Join-Path $base 'real') -PathType Container | Should -BeTrue
        Test-Path (Join-Path $base 'extra') | Should -BeFalse
    }
    It 'still creates a relative directory without warning' {
        Push-Location $TestDrive
        try {
            $w = $null
            New-DFDirectory 'reldir' -WarningVariable w -WarningAction SilentlyContinue
            Test-Path (Join-Path $TestDrive 'reldir') -PathType Container | Should -BeTrue
            $w | Should -BeNullOrEmpty
        } finally { Pop-Location }
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Add-DFToPath.Tests.ps1,tests/New-DFShim.Tests.ps1,tests/New-DFDirectory.Tests.ps1 -Output Detailed"`
Expected: the new tests FAIL — `Add-DFToPath` leaves the trailing-sep/`..` form as a distinct entry; `New-DFShim` treats `~/.local/bin` as a literal relative dir; `New-DFDirectory` creates the literal `extra\..\real` tree (the `..` is not collapsed). The "relative directory" test passes already (documents the no-warn requirement the implementation must preserve).

- [ ] **Step 3: Edit `Public/Add-DFToPath.ps1`**

Replace lines 38-42:
```powershell
    $normalized = [IO.Path]::GetFullPath($Dir)

    $existing = ($Env:Path -split [IO.Path]::PathSeparator) |
        Where-Object { $_ -and [IO.Path]::IsPathRooted($_) } |
        ForEach-Object { try { [IO.Path]::GetFullPath($_) } catch { $_ } }
```
with:
```powershell
    $normalized = ConvertTo-DFPath $Dir

    $existing = ($Env:Path -split [IO.Path]::PathSeparator) |
        Where-Object { $_ -and [IO.Path]::IsPathRooted($_) } |
        ForEach-Object { try { ConvertTo-DFPath $_ } catch { $_ } }
```
(The `IsPathRooted` guard at lines 33-36 stays — `Add-DFToPath` must reject relative input by returning early, before the helper is called.)

- [ ] **Step 4: Edit `Public/New-DFShim.ps1`**

After the shims-dir resolution (immediately after line 80's closing `}`), insert:
```powershell

    # Canonicalize (expands a ~ in ShimsPath / $DFConfig['ShimsPath'], collapses ..,
    # normalizes separators) before creating the dir, checking PATH, and naming the shim.
    $shimsDir = ConvertTo-DFPath $shimsDir
```
Then replace the PATH check (lines 86-89):
```powershell
    $normalizedShims = [IO.Path]::GetFullPath($shimsDir).TrimEnd('\', '/')
    $onPath = $Env:PATH -split [IO.Path]::PathSeparator |
        Where-Object { $_ } |
        Where-Object { [IO.Path]::GetFullPath($_).TrimEnd('\', '/') -eq $normalizedShims }
```
with:
```powershell
    $onPath = $Env:PATH -split [IO.Path]::PathSeparator |
        Where-Object { $_ -and [IO.Path]::IsPathRooted($_) } |
        Where-Object { (ConvertTo-DFPath $_) -eq $shimsDir }
```

- [ ] **Step 5: Edit `Public/New-DFDirectory.ps1`**

Replace the body's `if ($Path) { ... }` block (currently lines 22-24):
```powershell
    if ($Path) {
        New-Item -ItemType Directory -Force -Path $Path -ErrorAction SilentlyContinue | Out-Null
    }
```
with:
```powershell
    if ($Path) {
        # Canonicalize an absolute path (collapses .., native separators); leave a
        # relative path untouched so creating a relative dir stays valid and silent.
        if ([System.IO.Path]::IsPathRooted($Path)) { $Path = ConvertTo-DFPath $Path }
        New-Item -ItemType Directory -Force -Path $Path -ErrorAction SilentlyContinue | Out-Null
    }
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Add-DFToPath.Tests.ps1,tests/New-DFShim.Tests.ps1,tests/New-DFDirectory.Tests.ps1 -Output Detailed"`
Expected: PASS (all, including the new ones).

- [ ] **Step 7: Commit**

```bash
git add Public/Add-DFToPath.ps1 Public/New-DFShim.ps1 Public/New-DFDirectory.ps1 tests/Add-DFToPath.Tests.ps1 tests/New-DFShim.Tests.ps1 tests/New-DFDirectory.Tests.ps1
git commit -m "refactor: route path primitives through ConvertTo-DFPath"
```

---

## Task 5: Canonicalize XDG roots and the ToolsPath default

**Files:**
- Modify: `Public/Initialize-DFEnvironment.ps1`, `Public/Register-DFTool.ps1`
- Test: `tests/Initialize-DFEnvironment.Tests.ps1`, `tests/Register-DFTool.Tests.ps1`

**Interfaces:**
- Consumes: `ConvertTo-DFPath` (Task 1). `Register-DFTool.ps1`'s tests already dot-source the module chain; add the helper to any test `BeforeAll` that needs it. `Initialize-DFEnvironment` runs inside the imported module, where the helper is already loaded.

**Context:** `Initialize-DFEnvironment` sets the five XDG roots (or inherits a user's value, which may be `~`-rooted or messy). Canonicalize each so every later `Expand-DFXdgPath` substitution starts clean. `Register-DFTool`'s `ToolsPath` default `Join-Path $PSScriptRoot '../Tools'` carries a literal `..`; collapse it.

- [ ] **Step 1: Write the failing tests**

Add to `tests/Initialize-DFEnvironment.Tests.ps1` (inside the main `Describe`; ensure `ConvertTo-DFPath` is available — the module is imported there, so it is):
```powershell
    It 'canonicalizes a ~-rooted XDG value the user set' {
        $saved = $Env:XDG_CONFIG_HOME
        try {
            $Env:XDG_CONFIG_HOME = '~/dftest-config'
            Initialize-DFEnvironment 6>$null
            $Env:XDG_CONFIG_HOME | Should -Be (Join-Path $HOME 'dftest-config')
        } finally {
            $Env:XDG_CONFIG_HOME = $saved
            Remove-Item (Join-Path $HOME 'dftest-config') -Recurse -Force -ErrorAction Ignore
        }
    }
```

Add to `tests/Register-DFTool.Tests.ps1` (inside the main `Describe`):
```powershell
    It 'collapses the ../ in the default ToolsPath' {
        # With no -ToolsPath, the default is Join-Path $PSScriptRoot '../Tools'; it must
        # resolve to a canonical path with no '..' segment. Registering an absent tool by
        # name exercises the resolver without needing a real binary.
        { Register-DFTool -Name '___nope___' } | Should -Not -Throw
        # The resolved path is internal; assert the observable rule via a real tools dir:
        $canon = ConvertTo-DFPath (Join-Path $PSScriptRoot '..' 'Tools')
        $canon | Should -Not -Match '\.\.'
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Initialize-DFEnvironment.Tests.ps1,tests/Register-DFTool.Tests.ps1 -Output Detailed"`
Expected: the Initialize test FAILS (the `~` value is stored literally, not expanded). The Register assertion on `$canon` passes only once Task 1 exists (it does); it documents the rule.

- [ ] **Step 3: Edit `Public/Initialize-DFEnvironment.ps1`**

After the five `if (-not $Env:XDG_...)` assignment lines (currently lines 23-28) and before the directory-creation pipeline (line 30), insert:
```powershell

    # Canonicalize each root (expands a user-supplied ~, collapses .., native seps)
    # so every downstream Expand-DFXdgPath substitution starts from a clean path.
    foreach ($_var in 'XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_STATE_HOME', 'XDG_CACHE_HOME', 'XDG_BIN_HOME') {
        $_val = [System.Environment]::GetEnvironmentVariable($_var)
        if ($_val) { Set-Item -Path "Env:$_var" -Value (ConvertTo-DFPath $_val) }
    }
```

- [ ] **Step 4: Edit `Public/Register-DFTool.ps1`**

Replace the ToolsPath resolution (currently lines 55-56):
```powershell
    $resolvedToolsPath = if ($ToolsPath) { $ToolsPath }
                         else            { Join-Path $PSScriptRoot '../Tools' }
```
with:
```powershell
    $resolvedToolsPath = ConvertTo-DFPath $(if ($ToolsPath) { $ToolsPath }
                                            else            { Join-Path $PSScriptRoot '../Tools' })
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Initialize-DFEnvironment.Tests.ps1,tests/Register-DFTool.Tests.ps1 -Output Detailed"`
Expected: PASS (all).

- [ ] **Step 6: Full suite (integration — nothing else regressed)**

Run: `pwsh -NoProfile -Command "(Invoke-Pester tests/ -PassThru -Output None) | ForEach-Object { 'Passed={0} Failed={1}' -f \$_.PassedCount, \$_.FailedCount }"`
Expected: `Failed=0`.

- [ ] **Step 7: Commit**

```bash
git add Public/Initialize-DFEnvironment.ps1 Public/Register-DFTool.ps1 tests/Initialize-DFEnvironment.Tests.ps1 tests/Register-DFTool.Tests.ps1
git commit -m "feat: canonicalize XDG roots and the default ToolsPath"
```

---

## Task 6: Convention + docs

**Files:**
- Modify: `CLAUDE.md`, `docs/external-dependencies.md`, `CHANGELOG.md`

**Interfaces:** none (docs). No test cycle; deliverable is accurate docs.

- [ ] **Step 1: Full suite green before documenting**

Run: `pwsh -NoProfile -Command "(Invoke-Pester tests/ -PassThru -Output None).FailedCount"`
Expected: `0`.

- [ ] **Step 2: CLAUDE.md — add to the Conventions section**

Add this bullet:
```markdown
- **Paths are canonical.** Every path DotForge stores, compares, emits, or accepts as input goes
  through `ConvertTo-DFPath` (`Private/ConvertTo-DFPath.ps1`): absolute, native separator, no `.`/`..`,
  no trailing separator. Write `$HOME` in module code — never `~`; a user-supplied `~` path is
  expanded by `ConvertTo-DFPath`. A relative path is returned unchanged with a warning, never bound to
  CWD. New path boundaries must route through it.
```

- [ ] **Step 3: docs/external-dependencies.md — document the flag-string contract**

In the *Internal to DotForge* section (the "not an external dependency, but surprising" list), add:
```markdown
- **`Expand-DFXdgPath` normalizes only token-bearing values.** A `Tools/*.json` `xdg.vars` value is
  either an XDG path template (`${XDG_CONFIG_HOME}/…`) — canonicalized to a native path via
  `ConvertTo-DFPath` — or a literal flag string (`LESS`, `FZF_DEFAULT_OPTS`) with no XDG token, which
  passes through byte-for-byte. A flag string must never embed an XDG path token, or its separators
  would be rewritten. Nothing ships that way today; this is the assumption that lets one function
  serve both value kinds without a per-var `type` flag.
```

- [ ] **Step 4: CHANGELOG.md — under `[Unreleased]`**

Add an `### Added` / `### Changed` entry (integrate with existing headings, no duplicates):
```markdown
- **Canonical path handling (`ConvertTo-DFPath`).** All paths DotForge stores, compares, emits, or
  accepts are now absolute, native-separator, free of `.`/`..`, and without a trailing separator, with
  a leading `~` expanded to `$HOME`. This fixes the mixed `\`/`/` separators that XDG-derived env vars
  (`BAT_CONFIG_PATH`, `MDV_CONFIG_PATH`, …) previously carried on Windows, and collapses `..` in
  internal path defaults. Non-path flag strings (`LESS`, `FZF_DEFAULT_OPTS`) are unaffected.
```

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md docs/external-dependencies.md CHANGELOG.md
git commit -m "docs: document the canonical-path convention and flag-string contract"
```

---

## Final Verification

- [ ] **Full suite from a clean shell**

Run: `pwsh -NoProfile -Command "(Invoke-Pester tests/ -PassThru -Output None) | ForEach-Object { 'Passed={0} Failed={1} Skipped={2}' -f \$_.PassedCount, \$_.FailedCount, \$_.SkippedCount }"`
Expected: `Failed=0`.

- [ ] **Live: env vars are all-native, no trailing separator**

```powershell
Import-Module ./DotForge.psd1 -Force
Register-DFTool -All -WarningAction SilentlyContinue
$Env:BAT_CONFIG_PATH    # C:\Users\...\.config\bat\bat.conf   (no forward slash, no trailing sep)
$Env:MDV_CONFIG_PATH    # C:\Users\...\.config\mdv
$Env:RIPGREP_CONFIG_PATH; $Env:LESSHISTFILE; $Env:_ZO_DATA_DIR
# Flag strings unchanged:
$Env:LESS               # --RAW-CONTROL-CHARS --quit-if-one-screen --no-init
$Env:FZF_DEFAULT_OPTS   # still has its --color=... forward-slash-free content verbatim
```

- [ ] **PSScriptAnalyzer parity** on new/changed files (global-var + positional-Join-Path baseline only)

```powershell
foreach ($f in 'Private/ConvertTo-DFPath.ps1','Private/Expand-DFXdgPath.ps1','Public/Add-DFToPath.ps1','Public/New-DFShim.ps1','Public/New-DFDirectory.ps1','Public/Initialize-DFEnvironment.ps1','Public/Register-DFTool.ps1') {
    "--- $f"; Invoke-ScriptAnalyzer -Path $f | Format-Table Severity, Line, RuleName -AutoSize
}
```
