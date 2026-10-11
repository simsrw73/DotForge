# Config Ownership (T-61) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A requested tool whose own default location already holds config or data is never pointed at XDG paths until the user resolves it with `Resolve-DFToolConflict -Move | -Adopt`.

**Architecture:** Tool records declare old locations in `xdg.native`. Stateless detection and ownership-file helpers live in `Shared/DFToolOwnership.ps1`, so the startup core and the on-demand Helpers module share them. Activation checks each requested, installed, unowned tool before ordering and role selection: a conflicted tool gets status `Conflict` and is dropped from the run. `Resolve-DFToolConflict` (Helpers) adopts, or moves after checks, with a copy-verify-record-remove sequence; unfinished removals retry on later loads.

**Tech Stack:** PowerShell 7.2+, Pester 6.

**Spec:** `docs/superpowers/specs/2026-10-11-config-ownership-design.md`

## Global Constraints

- Every path stored, compared or emitted goes through `ConvertTo-DFPath`; module code writes `$HOME`, never `~`.
- XDG folders come from `Get-DFXdgPath`; never read `$Env:XDG_*`.
- Directory creation through `New-DFDirectory`; state files written with `Write-DFFileAtomic`.
- No `$ErrorActionPreference = 'Stop'` in module files.
- `Shared/` holds no session state; the Helpers module gets its own copy of `Shared/`.
- Every public function has full comment-based help (`.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER` each, `.EXAMPLE`, `.OUTPUTS`).
- After `Shared/`, `Private/`, `Public/` changes: `./build/Build-DFCoreBundle.ps1`. After `Tools/*.json`: `./build/Build-DFToolRegistry.ps1`. After help: `./build/Build-DFReferenceDocs.ps1`.
- Tests: `. "$PSScriptRoot/TestSupport.ps1"`, `foreach ($f in Get-DFTestModuleFile) { . $f }`, `Set-DFTestXdg`/`Restore-DFTestXdg`, `Reset-DFTestSession` where tools register; nothing written outside `$TestDrive`; no real Recycle Bin, no real process inspection.
- Run a task's tests with `pwsh -NoProfile -Command "./build/Test-DFFull.ps1 -Path <file>,<file>"`.
- Commits are GPG-signed; batch them (one unlock): commit at the end of Tasks 3, 6 and 9, not after each task.

## Rulings carried from the spec (approved with the plan)

- **Test roots:** `$HOME` is read-only, so the spec's `Set-DFTestNativeRoot` becomes a mockable `Get-DFNativeRoot -Name HOME|APPDATA|LOCALAPPDATA`.
- **Removal:** `Remove-DFItemToBin` renames the old location to `<leaf>.dotforge-moved` first (fails cleanly on a lock, no UI), then on Windows sends the renamed item to the Recycle Bin. If the recycle step fails, the renamed copy stays and that counts as removed (it's out of the tool's way and recoverable).
- **Retry check is size-only:** the next-load verification checks each moved file exists with its recorded length (hashes are checked at move time). Hashing a large folder on every load would be too slow.
- **User-set variables:** a variable already set in the process (the user set it) is not relocated by DotForge today, so its key is neither a conflict nor proof of ownership: the tool isn't recorded as owned while any key is skipped that way.
- **Companion relocations** (e.g. PSReadLine's history) are declared as `native` keys that are target templates (`${XDG_STATE_HOME}/...`).
- **Two old locations with content for one key** block `-Move` ("keep one").

## Review Focus

1. A tool required by another (PSFzf → fzf) is in conflict: the requiring tool must be blocked, not half-activated. (Task 3 test.)
2. A conflicted tool is a role's preferred member: the role must fall to another requested member or stay empty, never to the conflicted tool. (Task 3 test.)
3. `ownership.json` is corrupt or unreadable: activation must not crash or overwrite it with an empty object. (Task 2 test.)
4. An old location is a single file and the target is a file with a different name (`%APPDATA%\bat\config` → `bat.conf`): `-Move` copies the file to the target name. (Task 6 test.)
5. A process holds an old file open during removal: the move still records ownership, the rest is removed, and the locked path retries next load. (Task 6/7 tests.)

---

### Task 1: `xdg.native` in the record format; Expand-DFXdgPath to Shared

**Files:**
- Move: `Private/Expand-DFXdgPath.ps1` → `Shared/Expand-DFXdgPath.ps1` (`git mv`; content unchanged)
- Modify: `Shared/Import-DFToolDb.ps1` (`ConvertTo-DFXdgBlock`, new `ConvertTo-DFNativeMap`)
- Modify: `Shared/Test-DFToolSchema.ps1` (validation + `xdg` known keys)
- Test: `tests/ToolNative.Schema.Tests.ps1` (new)

**Interfaces:**
- Produces: normalized `$tool.xdg.native` = `$null` or a `[pscustomobject]` whose properties are keys; each value `[pscustomobject]@{ paths = [string[]]; move = [bool]; guide = [string] or $null }`.
- Produces: `Test-DFToolSchema` errors for a bad `native`.

- [ ] **Step 1: Write the failing tests**

```powershell
BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    function New-Rec($native) {
        [pscustomobject]@{ name = 't'; executable = 't.exe'; xdg = [pscustomobject]@{
            method = 'env'; vars = [pscustomobject]@{ T_CONF = '${XDG_CONFIG_HOME}/t' }; native = $native } }
    }
}
Describe 'xdg.native' {
    It 'normalizes a list to paths, move true, no guide' {
        $rec = ConvertTo-DFToolRecord (New-Rec ([pscustomobject]@{ T_CONF = @('${HOME}/.t') }))
        $entry = $rec.xdg.native.T_CONF
        $entry.paths | Should -Be @('${HOME}/.t')
        $entry.move | Should -BeTrue
        $entry.guide | Should -BeNullOrEmpty
    }
    It 'keeps an object entry''s move and guide' {
        $rec = ConvertTo-DFToolRecord (New-Rec ([pscustomobject]@{ T_CONF = [pscustomobject]@{ paths = @('${HOME}/.t'); move = $false; guide = 'do x' } }))
        $rec.xdg.native.T_CONF.move | Should -BeFalse
        $rec.xdg.native.T_CONF.guide | Should -Be 'do x'
    }
    It 'is null when absent' {
        (ConvertTo-DFToolRecord (New-Rec $null)).xdg.native | Should -BeNullOrEmpty
    }
    It 'accepts an empty list (default location is the XDG one)' {
        Test-DFToolSchema (New-Rec ([pscustomobject]@{ T_CONF = @() })) | Should -BeNullOrEmpty
    }
    It 'rejects a key that is neither a var, a seed target nor an XDG template' {
        Test-DFToolSchema (New-Rec ([pscustomobject]@{ NOPE = @('${HOME}/.t') })) | Should -Match "xdg.native key 'NOPE'"
    }
    It 'rejects move false without a guide' {
        Test-DFToolSchema (New-Rec ([pscustomobject]@{ T_CONF = [pscustomobject]@{ paths = @('${HOME}/.t'); move = $false } })) | Should -Match 'guide'
    }
    It 'rejects a string move' {
        Test-DFToolSchema (New-Rec ([pscustomobject]@{ T_CONF = [pscustomobject]@{ paths = @('${HOME}/.t'); move = 'false'; guide = 'g' } })) | Should -Match 'move'
    }
    It 'accepts a seed target and a ${XDG_ template as keys' {
        $rec = New-Rec ([pscustomobject]@{ '${XDG_STATE_HOME}/t/history' = @('${APPDATA}/t/history') })
        Test-DFToolSchema $rec | Should -BeNullOrEmpty
    }
}
```

- [ ] **Step 2: Run, expect FAIL** (`native` missing from the normalized block; no validation errors).

Run: `pwsh -NoProfile -Command "./build/Test-DFFull.ps1 -Path tests/ToolNative.Schema.Tests.ps1"`

- [ ] **Step 3: Implement**

`git mv Private/Expand-DFXdgPath.ps1 Shared/Expand-DFXdgPath.ps1` (the Helpers module needs it).

In `Shared/Import-DFToolDb.ps1`, add `native = ConvertTo-DFNativeMap (Get-DFToolRecordProperty $RawXdg 'native' $null)` to `ConvertTo-DFXdgBlock`, and:

```powershell
function ConvertTo-DFNativeMap {
    <#
    .SYNOPSIS
        Normalizes xdg.native: each key's old locations as { paths, move, guide }.
    .PARAMETER RawNative
        See the synopsis.
    #>
    param($RawNative)
    if (-not $RawNative) { return $null }
    $map = [ordered]@{}
    foreach ($p in $RawNative.PSObject.Properties) {
        $map[$p.Name] = if ($p.Value -is [pscustomobject]) {
            [pscustomobject]@{
                paths = [string[]]@(Get-DFToolRecordProperty $p.Value 'paths' @())
                move  = [bool](Get-DFToolRecordProperty $p.Value 'move' $true)
                guide = Get-DFToolRecordProperty $p.Value 'guide' $null
            }
        } else { [pscustomobject]@{ paths = [string[]]@($p.Value); move = $true; guide = $null } }
    }
    [pscustomobject]$map
}
```

In `Shared/Test-DFToolSchema.ps1`: add `'native'` to the `xdg` known keys; add `'paths','move','guide'` checks in a new function called from `Test-DFToolSchema`'s error list:

```powershell
function Get-DFNativeSchemaError ([PSCustomObject]$Tool) {
    <#
    .SYNOPSIS
        Schema errors in xdg.native.
    #>
    $xdg = Get-DFSchemaProperty $Tool 'xdg'
    $native = Get-DFSchemaProperty $xdg 'native'
    if ($null -eq $native) { return }
    if ($native -isnot [pscustomobject]) { return 'xdg.native must be an object' }
    $vars = @((Get-DFSchemaProperty $xdg 'vars')?.PSObject.Properties.Name)
    $seeds = @((Get-DFSchemaProperty (Get-DFSchemaProperty $Tool 'setup') 'seed')?.PSObject.Properties.Name)
    foreach ($p in $native.PSObject.Properties) {
        if ($p.Name -cnotin $vars -and $p.Name -cnotin $seeds -and $p.Name -cnotmatch '^\$\{XDG_(CONFIG|DATA|STATE)_HOME\}') {
            "xdg.native key '$($p.Name)' must name an xdg.vars variable, a setup.seed target, or start with `${XDG_CONFIG_HOME}, `${XDG_DATA_HOME} or `${XDG_STATE_HOME}"
        }
        $entry = $p.Value
        if ($entry -is [pscustomobject]) {
            $move = Get-DFSchemaProperty $entry 'move'
            if ($null -ne $move -and $move -isnot [bool]) { "xdg.native.$($p.Name).move must be true or false" }
            if ($move -eq $false -and -not (Get-DFSchemaProperty $entry 'guide')) { "xdg.native.$($p.Name) has move false, so it needs a guide" }
            $paths = Get-DFSchemaProperty $entry 'paths'
            if (@($paths | Where-Object { $_ -isnot [string] })) { "xdg.native.$($p.Name).paths must be strings" }
        } elseif (@($entry | Where-Object { $_ -isnot [string] })) { "xdg.native.$($p.Name) must be a list of paths or an object" }
    }
}
```

(`Get-DFSchemaProperty` returns `$null` for a `$null` parent; check it does, and guard if not.)

- [ ] **Step 4: Run, expect PASS** — the same command; also `tests/Test-DFToolSchema.Tests.ps1`, `tests/ToolRegistry.Tests.ps1`.

Rebuild `./build/Build-DFToolRegistry.ps1` (records gain `native: null`) and `./build/Build-DFCoreBundle.ps1`.

---

### Task 2: Ownership state and conflict detection (Shared)

**Files:**
- Create: `Shared/DFToolOwnership.ps1`
- Test: `tests/DFToolOwnership.Tests.ps1`

**Interfaces:**
- Consumes: `$tool.xdg.native` (Task 1), `Expand-DFXdgPath`.
- Produces:
  - `Get-DFNativeRoot -Name HOME|APPDATA|LOCALAPPDATA` → `[string]` or `$null`. Tests mock it.
  - `Expand-DFNativePath -Template` → canonical `[string]`, or `$null` when a root it names is unset.
  - `Get-DFToolRelocation -Tool` → objects `{ Key; Target; Native }` (Native = the normalized entry or `$null`): every `xdg.vars` entry whose template starts with `${XDG_CONFIG_HOME}`, `${XDG_DATA_HOME}` or `${XDG_STATE_HOME}` (method `env` only), every `setup.seed` target, and every `native` key that is a `${XDG_` template.
  - `Test-DFPathHasContent -Path` → `[bool]`: a file, or a folder with a file anywhere below.
  - `Get-DFToolOwnershipPath` → `$XDG_STATE_HOME/dotforge/ownership.json`.
  - `Read-DFToolOwnership` → `[hashtable]` name → entry (`[pscustomobject]` with `since`, `how`, optional `pending`). Missing file → `@{}`. Corrupt → warns and returns `$null`; callers treat `$null` as "can't record" and never save.
  - `Save-DFToolOwnership -Ownership [hashtable]` → writes with `Write-DFFileAtomic`.
  - `Find-DFToolConflict -Tool -Ownership [hashtable]` → `[pscustomobject]@{ Conflicts = [object[]]; Complete = [bool] }`. Each conflict: `{ Tool; Key; OldPaths = [string[]] (those with content); Target; Move = [bool]; Guide }`. Owned tool → `Conflicts @()`, `Complete $true`, no file-system calls. `Complete` is `$false` when a var key was skipped because the variable is already set in the process.

- [ ] **Step 1: Write the failing tests**

```powershell
BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
}
Describe 'Config ownership detection' {
    BeforeEach {
        Set-DFTestXdg
        $script:Home = Join-Path $TestDrive 'home'; $script:App = Join-Path $TestDrive 'appdata'
        Mock Get-DFNativeRoot { switch ($Name) { 'HOME' { $script:Home } 'APPDATA' { $script:App } default { $null } } }
        Remove-Item $script:Home, $script:App -Recurse -Force -ErrorAction Ignore
        [Environment]::SetEnvironmentVariable('T_CONF', $null, 'Process')
        $script:Tool = ConvertTo-DFToolRecord ([pscustomobject]@{ name = 't'; executable = 't.exe'; xdg = [pscustomobject]@{
            method = 'env'; vars = [pscustomobject]@{ T_CONF = '${XDG_CONFIG_HOME}/t'; T_CACHE = '${XDG_CACHE_HOME}/t' }
            native = [pscustomobject]@{ T_CONF = @('${APPDATA}/t', '${HOME}/.t') } } })
    }
    AfterEach { Restore-DFTestXdg }

    It 'lists config/data/state vars and native template keys, not caches' {
        (Get-DFToolRelocation -Tool $script:Tool).Key | Should -Be @('T_CONF')
    }
    It 'finds no conflict when the old locations are absent' {
        (Find-DFToolConflict -Tool $script:Tool -Ownership @{}).Conflicts | Should -BeNullOrEmpty
    }
    It 'treats an empty old folder as nothing there' {
        New-Item -ItemType Directory -Force (Join-Path $script:App 't' 'sub') | Out-Null
        (Find-DFToolConflict -Tool $script:Tool -Ownership @{}).Conflicts | Should -BeNullOrEmpty
    }
    It 'reports a conflict when an old location has a file' {
        New-Item -ItemType File -Force (Join-Path $script:App 't' 'config') | Out-Null
        $c = @((Find-DFToolConflict -Tool $script:Tool -Ownership @{}).Conflicts)
        $c.Count | Should -Be 1
        $c[0].OldPaths | Should -Be @(ConvertTo-DFPath (Join-Path $script:App 't'))
        $c[0].Target | Should -Be (ConvertTo-DFPath (Join-Path $Env:XDG_CONFIG_HOME 't'))
    }
    It 'reports a conflict even when the XDG location has content too' {
        New-Item -ItemType File -Force (Join-Path $script:App 't' 'config') | Out-Null
        New-Item -ItemType File -Force (Join-Path $Env:XDG_CONFIG_HOME 't' 'config') | Out-Null
        @((Find-DFToolConflict -Tool $script:Tool -Ownership @{}).Conflicts).Count | Should -Be 1
    }
    It 'skips an old path that is the target or inside it' {
        $tool = ConvertTo-DFToolRecord ([pscustomobject]@{ name = 't'; executable = 't.exe'; xdg = [pscustomobject]@{
            method = 'env'; vars = [pscustomobject]@{ T_CONF = '${XDG_CONFIG_HOME}/t' }
            native = [pscustomobject]@{ T_CONF = @('${XDG_CONFIG_HOME}/t', '${XDG_CONFIG_HOME}/t/inner') } } })
        New-Item -ItemType File -Force (Join-Path $Env:XDG_CONFIG_HOME 't' 'inner' 'x') | Out-Null
        (Find-DFToolConflict -Tool $tool -Ownership @{}).Conflicts | Should -BeNullOrEmpty
    }
    It 'makes no file-system calls for an owned tool' {
        Mock Test-DFPathHasContent { throw 'checked' }
        (Find-DFToolConflict -Tool $script:Tool -Ownership @{ t = [pscustomobject]@{ how = 'clean' } }).Conflicts | Should -BeNullOrEmpty
    }
    It 'skips a variable the user already set, and says the check is incomplete' {
        New-Item -ItemType File -Force (Join-Path $script:App 't' 'config') | Out-Null
        [Environment]::SetEnvironmentVariable('T_CONF', 'C:\mine', 'Process')
        try {
            $r = Find-DFToolConflict -Tool $script:Tool -Ownership @{}
            $r.Conflicts | Should -BeNullOrEmpty
            $r.Complete | Should -BeFalse
        } finally { [Environment]::SetEnvironmentVariable('T_CONF', $null, 'Process') }
    }
    It 'expands an unset root to nothing, so that path is skipped' {
        Expand-DFNativePath '${LOCALAPPDATA}/t' | Should -BeNullOrEmpty
    }
    It 'round-trips the ownership file' {
        Save-DFToolOwnership -Ownership @{ t = [pscustomobject]@{ since = 'x'; how = 'adopt' } }
        (Read-DFToolOwnership)['t'].how | Should -Be 'adopt'
    }
    It 'returns null for a corrupt ownership file and never overwrites it' {
        $path = Get-DFToolOwnershipPath
        New-DFDirectory (Split-Path $path) | Out-Null
        Set-Content $path '{ not json'
        Read-DFToolOwnership 3>$null | Should -BeNullOrEmpty
        Get-Content $path -Raw | Should -Match 'not json'
    }
}
```

- [ ] **Step 2: Run, expect FAIL** (commands not found).

- [ ] **Step 3: Implement `Shared/DFToolOwnership.ps1`**

```powershell
#Requires -Version 7.2

function Get-DFNativeRoot {
    <#
    .SYNOPSIS
        The folder a ${HOME}, ${APPDATA} or ${LOCALAPPDATA} template names, or $null when unset.
    .DESCRIPTION
        The one seam for those roots ($HOME is read-only, so tests mock this).
    .PARAMETER Name
        HOME, APPDATA or LOCALAPPDATA.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][ValidateSet('HOME', 'APPDATA', 'LOCALAPPDATA')][string]$Name)
    switch ($Name) {
        'HOME' { $HOME }
        'APPDATA' { $Env:APPDATA }
        'LOCALAPPDATA' { $Env:LOCALAPPDATA }
    }
}

function Expand-DFNativePath {
    <#
    .SYNOPSIS
        Expands an xdg.native path template, or returns $null when a root it names is unset.
    .PARAMETER Template
        e.g. '${APPDATA}/bat/config'.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Template)
    $path = $Template
    foreach ($root in 'HOME', 'APPDATA', 'LOCALAPPDATA') {
        $token = '${' + $root + '}'
        if (-not $path.Contains($token)) { continue }
        $value = Get-DFNativeRoot -Name $root
        if (-not $value) { return $null }
        $path = $path.Replace($token, $value)
    }
    if ($path -cmatch '\$\{XDG_') { return Expand-DFXdgPath $path }
    ConvertTo-DFPath $path
}

function Get-DFToolRelocation {
    <#
    .SYNOPSIS
        The config, data and state paths DotForge points a tool at: its xdg.vars, seeds and native target keys.
    .DESCRIPTION
        Caches are left out: losing one costs nothing. Each result carries the
        key's xdg.native entry, or $null when the record declares none.
    .PARAMETER Tool
        A normalized tool record.
    .OUTPUTS
        pscustomobject: Key, Target (canonical path), Native.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$Tool)
    $keep = '^\$\{XDG_(CONFIG|DATA|STATE)_HOME\}'
    $native = $Tool.xdg?.native
    $seen = @{}
    $emit = {
        param([string]$Key, [string]$Template)
        if ($seen.ContainsKey($Key)) { return }
        $seen[$Key] = $true
        [pscustomobject]@{ Key = $Key; Target = Expand-DFXdgPath $Template; Native = $native?.PSObject.Properties[$Key]?.Value }
    }
    if ($Tool.xdg?.method -eq 'env' -and $Tool.xdg.vars) {
        foreach ($p in $Tool.xdg.vars.PSObject.Properties) { if ($p.Value -cmatch $keep) { & $emit $p.Name $p.Value } }
    }
    foreach ($p in @($Tool.setup?.seed?.PSObject.Properties)) { if ($p) { & $emit $p.Name $p.Name } }
    foreach ($p in @($native?.PSObject.Properties)) { if ($p -and $p.Name -cmatch $keep) { & $emit $p.Name $p.Name } }
}

function Test-DFPathHasContent {
    <#
    .SYNOPSIS
        True for a file, or a folder with at least one file anywhere below it.
    .PARAMETER Path
        The path to check.
    .OUTPUTS
        System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Leaf) { return $true }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    [bool](Get-ChildItem -LiteralPath $Path -File -Recurse -Force -ErrorAction Ignore | Select-Object -First 1)
}

function Get-DFToolOwnershipPath {
    <#
    .SYNOPSIS
        The ownership state file: $XDG_STATE_HOME\dotforge\ownership.json.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    Join-Path (Get-DFXdgPath State) 'dotforge' 'ownership.json'
}

function Read-DFToolOwnership {
    <#
    .SYNOPSIS
        Reads which tools DotForge owns the config of, keyed by tool name.
    .DESCRIPTION
        A missing file is an empty table. A file that isn't valid JSON warns
        and returns $null: callers then record nothing, so the file is never
        overwritten with less than it held.
    .OUTPUTS
        System.Collections.Hashtable, or $null.
    #>
    [CmdletBinding()]
    param()
    $path = Get-DFToolOwnershipPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @{} }
    try { $data = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
    catch {
        Write-Warning "DotForge: $path isn't valid JSON, so tool ownership can't be read or recorded. Fix or delete it."
        return $null
    }
    $table = @{}
    foreach ($name in @($data.Keys)) { $table[$name] = [pscustomobject]$data[$name] }
    $table
}

function Save-DFToolOwnership {
    <#
    .SYNOPSIS
        Writes the ownership table atomically.
    .PARAMETER Ownership
        Tool name -> entry.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Ownership)
    $path = Get-DFToolOwnershipPath
    New-DFDirectory (Split-Path $path) | Out-Null
    Write-DFFileAtomic -Path $path -Value ($Ownership | ConvertTo-Json -Depth 10)
}

function Find-DFToolConflict {
    <#
    .SYNOPSIS
        Finds a requested tool's old locations that hold content DotForge would hide.
    .DESCRIPTION
        An owned tool is not checked (no file-system calls). For each relocated
        path (Get-DFToolRelocation), an old location with content is a conflict
        unless it is the target or inside it. A variable already set in the
        process is DotForge's to leave alone, so it is skipped and Complete is
        false: the tool can't be recorded as owned on that check.
    .PARAMETER Tool
        A normalized tool record.
    .PARAMETER Ownership
        Read-DFToolOwnership result.
    .OUTPUTS
        pscustomobject: Conflicts (Tool, Key, OldPaths, Target, Move, Guide), Complete.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Tool,
        [Parameter(Mandatory)][AllowEmptyCollection()][hashtable]$Ownership
    )
    if ($Ownership.ContainsKey($Tool.name)) { return [pscustomobject]@{ Conflicts = @(); Complete = $true } }
    $complete = $true
    $sep = [IO.Path]::DirectorySeparatorChar
    $conflicts = foreach ($reloc in @(Get-DFToolRelocation -Tool $Tool)) {
        if ($reloc.Key -cnotmatch '^\$\{' -and [Environment]::GetEnvironmentVariable($reloc.Key, 'Process')) { $complete = $false; continue }
        if (-not $reloc.Native) { continue }
        $found = @(foreach ($template in $reloc.Native.paths) {
            $old = Expand-DFNativePath $template
            if (-not $old) { continue }
            if ($old -eq $reloc.Target -or $old.StartsWith($reloc.Target + $sep, [StringComparison]::OrdinalIgnoreCase)) { continue }
            if (Test-DFPathHasContent -Path $old) { $old }
        })
        if ($found) {
            [pscustomobject]@{ Tool = $Tool.name; Key = $reloc.Key; OldPaths = [string[]]$found; Target = $reloc.Target; Move = $reloc.Native.move; Guide = $reloc.Native.guide }
        }
    }
    [pscustomobject]@{ Conflicts = @($conflicts); Complete = $complete }
}
```

(Check `Write-DFFileAtomic`'s parameter names before use; adjust `-Value` if it differs.)

- [ ] **Step 4: Run, expect PASS**, then `./build/Build-DFCoreBundle.ps1`.

---

### Task 3: Activation skips conflicted tools; Conflict status and notice

**Files:**
- Modify: `Private/Invoke-DFSessionActivation.ps1` (`Invoke-DFSessionActivation`, `New-DFToolStatus`, `Write-DFSessionNotice`, new `Select-DFOwnedRecord`)
- Modify: `Public/Get-DFToolStatus.ps1` (`-Conflict` switch, help)
- Test: `tests/Activation.Ownership.Tests.ps1`

**Interfaces:**
- Consumes: `Read-DFToolOwnership`, `Save-DFToolOwnership`, `Find-DFToolConflict`, `Get-DFToolRelocation` (Task 2).
- Produces: `Select-DFOwnedRecord -Records [List[object]] -RequestedBy [hashtable]` → `[List[object]]` without conflicted tools; sets their status. Status state `Conflict` with a `Conflicts` note property. Task 7 adds pending-removal processing inside it.

- [ ] **Step 1: Write the failing tests** (use the user-tools folder for records, as `tests/UserTools.Files.Tests.ps1` does; `executable` `Pester`, `type` `module` so they count as installed)

```powershell
BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
}
Describe 'Activation and config ownership' {
    BeforeEach {
        Set-DFTestXdg; Reset-DFTestSession
        $script:DFToolDb = $null; $script:DFToolRecordCache = @{}
        $script:Home = Join-Path $TestDrive 'home'
        Remove-Item $script:Home -Recurse -Force -ErrorAction Ignore
        Mock Get-DFNativeRoot { if ($Name -eq 'HOME') { $script:Home } }
        $script:User = Join-Path $Env:XDG_CONFIG_HOME 'dotforge' 'tools'
        Remove-Item $script:User -Recurse -Force -ErrorAction Ignore
        New-Item -ItemType Directory -Force $script:User | Out-Null
        foreach ($v in 'OWN_A', 'OWN_B') { [Environment]::SetEnvironmentVariable($v, $null, 'Process') }
        function Write-Rec([string]$Name, [string]$Var, [string[]]$Requires = @(), [string]$Roles = '') {
            $rec = [ordered]@{ name = $Name; executable = 'Pester'; type = 'module'
                xdg = @{ method = 'env'; vars = @{ $Var = "`${XDG_CONFIG_HOME}/$Name" }; native = @{ $Var = @("`${HOME}/.$Name") } }
                aliases = @{ "${Name}x" = @{ command = 'Get-Date' } } }
            if ($Requires) { $rec.requires = $Requires }
            $rec | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $script:User "$Name.json")
        }
        Write-Rec owna OWN_A
        Write-Rec ownb OWN_B -Requires owna
    }
    AfterEach {
        foreach ($v in 'OWN_A', 'OWN_B') { [Environment]::SetEnvironmentVariable($v, $null, 'Process') }
        foreach ($a in 'ownax', 'ownbx') { Remove-DFTestGlobal -Alias $a }
        $script:DFToolDb = $null; $script:DFToolRecordCache = @{}
        Restore-DFTestXdg
    }

    It 'activates and records ownership when nothing is in the old location' {
        Register-DFTool -Name owna 3>$null
        (Get-DFToolStatus owna).State | Should -Be 'Active'
        $Env:OWN_A | Should -Not -BeNullOrEmpty
        (Read-DFToolOwnership)['owna'].how | Should -Be 'clean'
    }
    It 'skips a conflicted tool entirely and warns once' {
        New-Item -ItemType File -Force (Join-Path $script:Home '.owna' 'cfg') | Out-Null
        Register-DFTool -Name owna -WarningVariable w 3>$null
        (Get-DFToolStatus owna).State | Should -Be 'Conflict'
        $Env:OWN_A | Should -BeNullOrEmpty
        Get-Alias ownax -Scope Global -ErrorAction Ignore | Should -BeNullOrEmpty
        @($w | Where-Object { "$_" -match "owna isn't active" }).Count | Should -Be 1
        "$w" | Should -Match 'Resolve-DFToolConflict owna -Move'
        (Read-DFToolOwnership).ContainsKey('owna') | Should -BeFalse
    }
    It 'blocks a tool that requires a conflicted tool' {
        New-Item -ItemType File -Force (Join-Path $script:Home '.owna' 'cfg') | Out-Null
        Register-DFTool -Name ownb 3>$null
        (Get-DFToolStatus ownb).State | Should -Be 'Missing'
        (Get-DFToolStatus ownb).Detail | Should -Match 'owna'
        $Env:OWN_B | Should -BeNullOrEmpty
    }
    It 'activates an owned tool despite leftovers in the old location' {
        New-Item -ItemType File -Force (Join-Path $script:Home '.owna' 'cfg') | Out-Null
        Save-DFToolOwnership -Ownership @{ owna = [pscustomobject]@{ since = 'x'; how = 'adopt' } }
        Register-DFTool -Name owna 3>$null
        (Get-DFToolStatus owna).State | Should -Be 'Active'
    }
    It 'lists conflicts with Get-DFToolStatus -Conflict' {
        New-Item -ItemType File -Force (Join-Path $script:Home '.owna' 'cfg') | Out-Null
        Register-DFTool -Name owna 3>$null
        (Get-DFToolStatus -Conflict).Name | Should -Be @('owna')
    }
    It 'names the guide instead of -Move when the location must not be moved' {
        $rec = Get-Content (Join-Path $script:User 'owna.json') -Raw | ConvertFrom-Json
        $rec.xdg.native.OWN_A = [pscustomobject]@{ paths = @('${HOME}/.owna'); move = $false; guide = 'Use owna''s own mover.' }
        $rec | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $script:User 'owna.json')
        New-Item -ItemType File -Force (Join-Path $script:Home '.owna' 'cfg') | Out-Null
        Register-DFTool -Name owna -WarningVariable w 3>$null
        "$w" | Should -Match "Use owna's own mover"
        "$w" | Should -Not -Match '-Move'
    }
    It 'does not record ownership when the ownership file is corrupt' {
        $path = Get-DFToolOwnershipPath; New-DFDirectory (Split-Path $path) | Out-Null
        Set-Content $path '{ bad'
        Register-DFTool -Name owna 3>$null
        Get-Content $path -Raw | Should -Match 'bad'
    }
}
```

Add the role case (Review Focus 2) to the same file: two user records sharing a role from `data/roles.json` that takes any member (pick the `pager` role or whichever `data/roles.json` defines as a single role; read the file first), the higher-priority one in conflict: `Get-DFRole <role>` returns the other one.

- [ ] **Step 2: Run, expect FAIL** (state `Conflict` not valid; tool activates).

- [ ] **Step 3: Implement**

`New-DFToolStatus`: `ValidateSet('Active', 'Missing', 'Failed', 'Excluded', 'Conflict')`; help text lists it.

In `Invoke-DFSessionActivation`, right after `$requirements = Resolve-DFToolRequirements ...`:

```powershell
    # A tool whose old config location still holds the user's config is left
    # alone entirely until they resolve it (Resolve-DFToolConflict).
    $records = Select-DFOwnedRecord -Records $records -RequestedBy $requestedBy -Reactivate $Reactivate
```

New function in the same file:

```powershell
function Select-DFOwnedRecord {
    <#
    .SYNOPSIS
        Drops requested tools whose config DotForge would hide, recording their Conflict status; records the rest as owned.
    .DESCRIPTION
        Only installed tools that aren't already active are checked. A tool with
        no conflict, a full check and a relocated path is recorded as owned
        (how: clean), all in one write. See
        docs/superpowers/specs/2026-10-11-config-ownership-design.md.
    .PARAMETER Records
        The requested records (after Resolve-DFToolRequirements).
    .PARAMETER RequestedBy
        Name -> RequestedBy.
    .PARAMETER Reactivate
        Names re-registered on purpose (checked even if active).
    .OUTPUTS
        System.Collections.Generic.List[object].
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Records,
        [Parameter(Mandatory)][hashtable]$RequestedBy,
        [AllowEmptyCollection()][string[]]$Reactivate = @()
    )
    $kept = [System.Collections.Generic.List[object]]::new()
    $ownership = Read-DFToolOwnership
    $readable = $null -ne $ownership
    if (-not $readable) { $ownership = @{} }
    $changed = $false
    foreach ($record in $Records) {
        $skip = ((Test-DFToolActive $record.name) -and $record.name -notin $Reactivate) -or
            -not (Test-DFToolAvailable -Executable $record.executable -Type $record.type)
        if ($skip) { $kept.Add($record); continue }
        $check = Find-DFToolConflict -Tool $record -Ownership $ownership
        if ($check.Conflicts) {
            $paths = @($check.Conflicts.OldPaths) -join ', '
            $status = New-DFToolStatus -Name $record.name -State Conflict -RequestedBy $RequestedBy[$record.name] -Detail "your existing config at $paths would be hidden"
            $status | Add-Member -NotePropertyName Conflicts -NotePropertyValue $check.Conflicts
            $script:DFSessionStatus[$record.name] = $status
            continue
        }
        if ($readable -and $check.Complete -and -not $ownership.ContainsKey($record.name) -and @(Get-DFToolRelocation -Tool $record)) {
            $ownership[$record.name] = [pscustomobject]@{ since = [DateTime]::UtcNow.ToString('o'); how = 'clean' }
            $changed = $true
        }
        $kept.Add($record)
    }
    if ($changed) { Save-DFToolOwnership -Ownership $ownership }
    , $kept
}
```

`Write-DFSessionNotice`: after the failed block,

```powershell
    foreach ($c in @($all | Where-Object State -eq 'Conflict')) {
        $paths = @($c.Conflicts.OldPaths) -join ', '
        $guides = @($c.Conflicts | Where-Object { -not $_.Move } | ForEach-Object Guide)
        $how = if ($guides) { "$($guides -join ' ') Then run Resolve-DFToolConflict $($c.Name) -Adopt" }
               else { "Run Resolve-DFToolConflict $($c.Name) -Move (or -Adopt)" }
        Write-Warning "DotForge: $($c.Name) isn't active: your existing config at $paths would be hidden. $how, or remove $($c.Name) from Tools."
    }
```

`Get-DFToolStatus`: `[switch]$Conflict`, `if ($Conflict -and $s.State -ne 'Conflict') { continue }`, help `.PARAMETER Conflict` and an example.

- [ ] **Step 4: Run, expect PASS**: this file plus `tests/Register-DFTool.Tests.ps1`, `tests/Start-DFSession*.Tests.ps1`, `tests/Get-DFToolStatus*.Tests.ps1` (use `git ls-files tests` for exact names). Rebuild bundle and reference.

- [ ] **Step 5: Full run and commit** (Tasks 1–3, plus the reviewed `df-quickfixes` diff applied first as its own commit):

```bash
pwsh -NoProfile -File build/Test-DFFull.ps1
git add -A Shared Private Public Bundle data tests docs/reference.md
git commit -m "feat(tools): leave a tool alone while its old config location holds the user's config (T-61, part 1)"
```

---

### Task 4: `Resolve-DFToolConflict` with `-Adopt` and `-Done`

**Files:**
- Create: `Modules/DotForge.Helpers/Public/Resolve-DFToolConflict.ps1`
- Modify: `Modules/DotForge.Helpers/DotForge.Helpers.psd1` (export, under `# Layer 3 — Tool Operations: your own tools`), `build/Build-DFReferenceDocs.ps1` (`'Resolve-DFToolConflict' = 'Core'`)
- Test: `tests/Resolve-DFToolConflict.Tests.ps1`

**Interfaces:**
- Consumes: Task 2 functions; `Import-DFToolDb -Name`.
- Produces: `Resolve-DFToolConflict [-Name] <string> (-Move | -Adopt | -Done) [-WhatIf] [-Confirm]` → `[pscustomobject]@{ PSTypeName='DotForge.ConflictResult'; Tool; Action; Moved=[string[]]; Pending=[string[]]; Problems=[string[]] }`. Task 5–6 fill the `-Move` branch.

- [ ] **Step 1: Write the failing tests**

```powershell
BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
}
Describe 'Resolve-DFToolConflict' {
    BeforeEach {
        Set-DFTestXdg
        $script:DFToolDb = $null; $script:DFToolRecordCache = @{}
        $script:Home = Join-Path $TestDrive 'home'
        Remove-Item $script:Home -Recurse -Force -ErrorAction Ignore
        Mock Get-DFNativeRoot { if ($Name -eq 'HOME') { $script:Home } }
        Mock Get-Process { }
        Mock Remove-DFItemToBin { }
        $script:User = Join-Path $Env:XDG_CONFIG_HOME 'dotforge' 'tools'
        Remove-Item $script:User -Recurse -Force -ErrorAction Ignore
        New-Item -ItemType Directory -Force $script:User | Out-Null
        [Environment]::SetEnvironmentVariable('OWN_A', $null, 'Process')
        @{ name = 'owna'; executable = 'Pester'; type = 'module'
           xdg = @{ method = 'env'; vars = @{ OWN_A = '${XDG_CONFIG_HOME}/owna' }; native = @{ OWN_A = @('${HOME}/.owna') } } } |
            ConvertTo-Json -Depth 6 | Set-Content (Join-Path $script:User 'owna.json')
        New-Item -ItemType File -Force (Join-Path $script:Home '.owna' 'cfg') | Out-Null
    }
    AfterEach { $script:DFToolDb = $null; $script:DFToolRecordCache = @{}; Restore-DFTestXdg }

    It '-Adopt records ownership and moves nothing' {
        $r = Resolve-DFToolConflict owna -Adopt -Confirm:$false
        $r.Action | Should -Be 'Adopt'
        (Read-DFToolOwnership)['owna'].how | Should -Be 'adopt'
        Test-Path (Join-Path $script:Home '.owna' 'cfg') | Should -BeTrue
    }
    It '-Adopt -WhatIf records nothing' {
        Resolve-DFToolConflict owna -Adopt -WhatIf | Out-Null
        (Read-DFToolOwnership).ContainsKey('owna') | Should -BeFalse
    }
    It 'says an owned tool is already owned and changes nothing' {
        Save-DFToolOwnership -Ownership @{ owna = [pscustomobject]@{ since = 'x'; how = 'clean' } }
        $r = Resolve-DFToolConflict owna -Adopt -Confirm:$false 6>$null
        $r.Action | Should -Be 'AlreadyOwned'
        (Read-DFToolOwnership)['owna'].how | Should -Be 'clean'
    }
    It '-Done clears pending and keeps ownership' {
        Save-DFToolOwnership -Ownership @{ owna = [pscustomobject]@{ since = 'x'; how = 'move'; pending = @(@{ OldPath = 'p'; Target = 't'; Files = @() }) } }
        Resolve-DFToolConflict owna -Done -Confirm:$false | Out-Null
        $entry = (Read-DFToolOwnership)['owna']
        $entry.how | Should -Be 'move'
        $entry.PSObject.Properties['pending'] | Should -BeNullOrEmpty
    }
    It 'errors for an unknown tool' {
        { Resolve-DFToolConflict nosuch -Adopt -Confirm:$false -ErrorAction Stop } | Should -Throw '*nosuch*'
    }
    It 'refuses when the ownership file is corrupt' {
        $path = Get-DFToolOwnershipPath; New-DFDirectory (Split-Path $path) | Out-Null; Set-Content $path '{ bad'
        { Resolve-DFToolConflict owna -Adopt -Confirm:$false -ErrorAction Stop 3>$null } | Should -Throw '*ownership*'
        Get-Content $path -Raw | Should -Match 'bad'
    }
}
```

- [ ] **Step 2: Run, expect FAIL** (command not found).

- [ ] **Step 3: Implement** the public function with full help (synopsis; description of the three choices, what `-Move` checks, Recycle Bin / `.dotforge-moved`, the next-load retry; parameters; three examples; outputs). Body:

```powershell
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'Move')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name,
        [Parameter(Mandatory, ParameterSetName = 'Move')][switch]$Move,
        [Parameter(Mandatory, ParameterSetName = 'Adopt')][switch]$Adopt,
        [Parameter(Mandatory, ParameterSetName = 'Done')][switch]$Done
    )
    $tool = (Import-DFToolDb -Name $Name)[$Name]
    if (-not $tool) { Write-Error "DotForge: no tool record named '$Name'."; return }
    $ownership = Read-DFToolOwnership
    if ($null -eq $ownership) { Write-Error "DotForge: $(Get-DFToolOwnershipPath) can't be read, so ownership can't be recorded; fix or delete that file first."; return }
    $result = New-DFConflictResult -Tool $Name -Action $PSCmdlet.ParameterSetName
    switch ($PSCmdlet.ParameterSetName) {
        'Done' { return Complete-DFConflictPending -Name $Name -Ownership $ownership -Result $result -Cmdlet $PSCmdlet }
        default {
            if ($ownership.ContainsKey($Name)) {
                Write-Host "DotForge already owns $Name's config; nothing to do."
                $result.Action = 'AlreadyOwned'; return $result
            }
        }
    }
    if ($Adopt) {
        if ($PSCmdlet.ShouldProcess($Name, 'Record that DotForge owns its config (nothing is moved)')) {
            $ownership[$Name] = [pscustomobject]@{ since = [DateTime]::UtcNow.ToString('o'); how = 'adopt' }
            Save-DFToolOwnership -Ownership $ownership
            Write-Host "DotForge now owns $Name's config. Load it with: Register-DFTool -Name $Name"
        }
        return $result
    }
    Invoke-DFConflictMove -Tool $tool -Ownership $ownership -Result $result -Cmdlet $PSCmdlet
```

Private helpers in `Modules/DotForge.Helpers/Private/Resolve-DFToolConflict.Steps.ps1`: `New-DFConflictResult` (the result object), `Complete-DFConflictPending` (remove `pending`, save, under ShouldProcess), and a stub `Invoke-DFConflictMove` that writes `Write-Error 'not yet'` (replaced in Task 6). Add manifest export and reference mapping.

- [ ] **Step 4: Run, expect PASS**; also `tests/ModuleSplit.Tests.ps1`, `tests/PublicSurface*.Tests.ps1`, `tests/Docs.Help.Tests.ps1`.

---

### Task 5: `-Move` checks

**Files:**
- Modify: `Modules/DotForge.Helpers/Private/Resolve-DFToolConflict.Steps.ps1` (`Get-DFPathSpelling`, `Find-DFOldPathReference`, `Get-DFMoveProblem`)
- Test: `tests/Resolve-DFToolConflict.Move.Tests.ps1` (Describe 'Move checks')

**Interfaces:**
- Produces: `Get-DFMoveProblem -Tool -Conflicts` → `[string[]]` (empty = safe). `Get-DFPathSpelling -Path` → `[string[]]`. `Find-DFOldPathReference -Root -Spelling [string[]]` → `[string[]]` of `"<file>:<line>"`.

- [ ] **Step 1: Write the failing tests** (same BeforeEach as Task 4, `$c = (Find-DFToolConflict -Tool $tool -Ownership @{}).Conflicts`)

```powershell
    It 'is clean for a plain config' { Get-DFMoveProblem -Tool $tool -Conflicts $c | Should -BeNullOrEmpty }
    It 'refuses when the target has content' {
        New-Item -ItemType File -Force (Join-Path $Env:XDG_CONFIG_HOME 'owna' 'x') | Out-Null
        Get-DFMoveProblem -Tool $tool -Conflicts $c | Should -Match 'already has files'
    }
    It 'refuses while the tool runs' {
        $tool.type = 'exe'; $tool.executable = 'owna.exe'
        Mock Get-Process { [pscustomobject]@{ Name = 'owna' } } -ParameterFilter { $Name -eq 'owna' }
        Get-DFMoveProblem -Tool $tool -Conflicts $c | Should -Match 'close owna'
    }
    It 'reports a file that names the old location, as file:line' {
        $old = Join-Path $script:Home '.owna'
        Set-Content (Join-Path $old 'hooks.ps1') "x`n. $old/hook.ps1"
        Get-DFMoveProblem -Tool $tool -Conflicts $c | Should -Match 'hooks\.ps1:2'
    }
    It 'reports a ~ spelling too' {
        Set-Content (Join-Path $script:Home '.owna' 'rc') 'include ~/.owna/more'
        Get-DFMoveProblem -Tool $tool -Conflicts $c | Should -Match 'rc:1'
    }
    It 'ignores binary files' {
        [IO.File]::WriteAllBytes((Join-Path $script:Home '.owna' 'bin.db'), [byte[]](0, 1) + [Text.Encoding]::UTF8.GetBytes((Join-Path $script:Home '.owna')))
        Get-DFMoveProblem -Tool $tool -Conflicts $c | Should -BeNullOrEmpty
    }
    It 'reports an environment variable that names the old location' {
        $Env:DF_TEST_OLDREF = "x;$(Join-Path $script:Home '.owna' 'bin')"
        try { Get-DFMoveProblem -Tool $tool -Conflicts $c | Should -Match 'DF_TEST_OLDREF' }
        finally { Remove-Item Env:DF_TEST_OLDREF }
    }
    It 'refuses a location marked move false, giving its guide' {
        $c[0].Move = $false; $c[0].Guide = 'Use the mover.'
        Get-DFMoveProblem -Tool $tool -Conflicts $c | Should -Match 'Use the mover'
    }
    It 'refuses two old locations with content for one path' {
        $c[0].OldPaths = @($c[0].OldPaths) + (Join-Path $TestDrive 'other')
        Get-DFMoveProblem -Tool $tool -Conflicts $c | Should -Match 'keep one'
    }
```

- [ ] **Step 2: Run, expect FAIL.**

- [ ] **Step 3: Implement**

```powershell
function Get-DFPathSpelling {
    <#
    .SYNOPSIS
        The ways a config file might write a path: both separators, ~, and the env-var forms.
    .PARAMETER Path
        A canonical path.
    .OUTPUTS
        System.String[].
    #>
    param([Parameter(Mandatory)][string]$Path)
    $forms = [System.Collections.Generic.List[string]]::new()
    $forms.Add($Path)
    $roots = @(
        @{ Value = Get-DFNativeRoot -Name HOME; Names = '~', '$HOME', '${HOME}', '%USERPROFILE%', '$env:USERPROFILE' }
        @{ Value = Get-DFNativeRoot -Name APPDATA; Names = '%APPDATA%', '$env:APPDATA', '${APPDATA}' }
        @{ Value = Get-DFNativeRoot -Name LOCALAPPDATA; Names = '%LOCALAPPDATA%', '$env:LOCALAPPDATA', '${LOCALAPPDATA}' }
    )
    foreach ($root in $roots) {
        if (-not $root.Value) { continue }
        $base = ConvertTo-DFPath $root.Value
        if (-not $Path.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $rest = $Path.Substring($base.Length)
        foreach ($n in $root.Names) { $forms.Add($n + $rest) }
    }
    @($forms | ForEach-Object { $_; $_.Replace('\', '/') } | Select-Object -Unique)
}

function Find-DFOldPathReference {
    <#
    .SYNOPSIS
        Text files under Root that name any of the spellings, as "<file>:<line>".
    .DESCRIPTION
        Text means under 1 MB with no NUL byte in the first 8 KB. Case-insensitive.
    .PARAMETER Root
        A file or folder.
    .PARAMETER Spelling
        Get-DFPathSpelling result.
    .OUTPUTS
        System.String[].
    #>
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string[]]$Spelling)
    $files = if (Test-Path -LiteralPath $Root -PathType Leaf) { Get-Item -LiteralPath $Root -Force }
             else { Get-ChildItem -LiteralPath $Root -File -Recurse -Force -ErrorAction Ignore }
    foreach ($file in $files) {
        if ($file.Length -ge 1MB) { continue }
        $head = [byte[]]::new([Math]::Min(8KB, $file.Length))
        $stream = [IO.File]::OpenRead($file.FullName)
        try { $null = $stream.Read($head, 0, $head.Length) } finally { $stream.Dispose() }
        if ($head -contains 0) { continue }
        $hits = Select-String -LiteralPath $file.FullName -SimpleMatch -Pattern $Spelling -ErrorAction Ignore
        foreach ($hit in $hits) { "$($file.FullName):$($hit.LineNumber)" }
    }
}

function Get-DFMoveProblem {
    <#
    .SYNOPSIS
        Why moving a tool's old config to its XDG location isn't safe; empty when it is.
    .PARAMETER Tool
        The tool record.
    .PARAMETER Conflicts
        Find-DFToolConflict's Conflicts.
    .OUTPUTS
        System.String[].
    #>
    param([Parameter(Mandatory)][pscustomobject]$Tool, [Parameter(Mandatory)][object[]]$Conflicts)
    foreach ($c in $Conflicts) {
        if (-not $c.Move) { "$($c.Key): DotForge doesn't move this one. $($c.Guide)"; continue }
        if (@($c.OldPaths).Count -gt 1) { "$($c.Key): there are copies in $(@($c.OldPaths) -join ' and '); keep one and delete the others, then run this again."; continue }
        if (Test-DFPathHasContent -Path $c.Target) { "$($c.Key): $($c.Target) already has files; merge them yourself, or run Resolve-DFToolConflict $($Tool.name) -Adopt." }
        $old = @($c.OldPaths)[0]
        $spellings = Get-DFPathSpelling -Path $old
        foreach ($ref in @(Find-DFOldPathReference -Root $old -Spelling $spellings)) { "$ref names the old location; change it to $($c.Target), then run this again." }
        foreach ($scope in 'User', 'Process') {
            $vars = [Environment]::GetEnvironmentVariables($scope)
            foreach ($key in $vars.Keys) {
                $value = "$($vars[$key])"
                if (@($spellings | Where-Object { $value.IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -ge 0 })) {
                    "the $scope environment variable $key names $old; change it first."
                }
            }
        }
    }
    if ($Tool.type -ne 'module') {
        $exe = [IO.Path]::GetFileNameWithoutExtension($Tool.executable)
        if (Get-Process -Name $exe -ErrorAction Ignore) { "$exe is running; close $exe first." }
    }
}
```

(On non-Windows the `User` scope is empty; that's fine. Deduplicate the env-variable messages if a var hits through several spellings: `Select-Object -Unique` on the output in the caller.)

- [ ] **Step 4: Run, expect PASS.**

---

### Task 6: `-Move` copy, verify, record, remove

**Files:**
- Create: `Shared/Remove-DFItemToBin.ps1`
- Modify: `Modules/DotForge.Helpers/Private/Resolve-DFToolConflict.Steps.ps1` (`Copy-DFVerified`, real `Invoke-DFConflictMove`)
- Test: `tests/Resolve-DFToolConflict.Move.Tests.ps1` (Describe 'Move'), `tests/Remove-DFItemToBin.Tests.ps1`

**Interfaces:**
- Produces: `Remove-DFItemToBin -Path` (throws on failure; renames to `<leaf>.dotforge-moved`, then on Windows recycles it). `Copy-DFVerified -Source -Target` → `[object[]]` manifest `{ Path (relative; '' for a single file); Length; Hash }`, or throws after removing staging.
- Ownership entry after a move: `{ since; how = 'move'; pending = @({ OldPath; Target; Files = manifest }) }` — `pending` holds only items not yet removed; omitted when empty.

- [ ] **Step 1: Write the failing tests**

```powershell
Describe 'Move' {
    # BeforeEach as Task 4, plus: Set-Content (Join-Path $script:Home '.owna' 'cfg') 'v=1'
    It 'copies, records ownership and removes the old copy' {
        $r = Resolve-DFToolConflict owna -Move -Confirm:$false
        Get-Content (Join-Path $Env:XDG_CONFIG_HOME 'owna' 'cfg') | Should -Be 'v=1'
        Should -Invoke Remove-DFItemToBin -Times 1 -ParameterFilter { $Path -eq (ConvertTo-DFPath (Join-Path $script:Home '.owna')) }
        $entry = (Read-DFToolOwnership)['owna']
        $entry.how | Should -Be 'move'
        $entry.PSObject.Properties['pending'] | Should -BeNullOrEmpty
        $r.Moved | Should -Not -BeNullOrEmpty
    }
    It 'moves a single file to a target of a different name' {
        # record: OWN_A = '${XDG_CONFIG_HOME}/owna/owna.conf', native '${HOME}/.ownarc'
        # (rewrite owna.json in this test, create $script:Home/.ownarc with 'v=2')
        Resolve-DFToolConflict owna -Move -Confirm:$false | Out-Null
        Get-Content (Join-Path $Env:XDG_CONFIG_HOME 'owna' 'owna.conf') | Should -Be 'v=2'
    }
    It 'changes nothing when a check fails' {
        New-Item -ItemType File -Force (Join-Path $Env:XDG_CONFIG_HOME 'owna' 'x') | Out-Null
        $r = Resolve-DFToolConflict owna -Move -Confirm:$false 3>$null
        $r.Problems | Should -Match 'already has files'
        (Read-DFToolOwnership).ContainsKey('owna') | Should -BeFalse
        Should -Invoke Remove-DFItemToBin -Times 0
    }
    It 'removes staging and records nothing on a hash mismatch' {
        Mock Get-FileHash { [pscustomobject]@{ Hash = [guid]::NewGuid().ToString() } }
        { Resolve-DFToolConflict owna -Move -Confirm:$false -ErrorAction Stop } | Should -Throw '*verify*'
        Test-Path (Join-Path $Env:XDG_CONFIG_HOME 'owna') | Should -BeFalse
        Test-Path (Join-Path $Env:XDG_CONFIG_HOME 'owna.dotforge-staging') | Should -BeFalse
        (Read-DFToolOwnership).ContainsKey('owna') | Should -BeFalse
    }
    It 'records a locked old copy as pending' {
        Mock Remove-DFItemToBin { throw 'in use' }
        $r = Resolve-DFToolConflict owna -Move -Confirm:$false 3>$null
        (Read-DFToolOwnership)['owna'].pending[0].OldPath | Should -Be (ConvertTo-DFPath (Join-Path $script:Home '.owna'))
        $r.Pending | Should -Not -BeNullOrEmpty
    }
    It '-WhatIf copies and records nothing' {
        Resolve-DFToolConflict owna -Move -WhatIf | Out-Null
        Test-Path (Join-Path $Env:XDG_CONFIG_HOME 'owna') | Should -BeFalse
        (Read-DFToolOwnership).ContainsKey('owna') | Should -BeFalse
    }
}
```

`tests/Remove-DFItemToBin.Tests.ps1`: on non-Windows (`-Skip:$IsWindows`), a folder ends up renamed to `<leaf>.dotforge-moved`; on all platforms, mock nothing and check that a path under `$TestDrive` that doesn't exist throws. Do not exercise the real Recycle Bin: on Windows, test only the rename-failure path (open a file inside with `[IO.File]::Open(..., 'Open', 'Read', 'None')`, expect a throw and the folder unchanged).

- [ ] **Step 2: Run, expect FAIL.**

- [ ] **Step 3: Implement**

`Shared/Remove-DFItemToBin.ps1`:

```powershell
#Requires -Version 7.2

function Remove-DFItemToBin {
    <#
    .SYNOPSIS
        Moves an old config file or folder out of the tool's way, recoverably.
    .DESCRIPTION
        Renames it to <leaf>.dotforge-moved first: that fails cleanly, with no
        window, when anything inside is in use. On Windows the renamed item
        then goes to the Recycle Bin; if that step fails, the renamed copy
        stays where it is, which still counts as removed.
    .PARAMETER Path
        The old location.
    .OUTPUTS
        None. Throws when the rename fails.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $moved = Join-Path (Split-Path $Path) ((Split-Path $Path -Leaf) + '.dotforge-moved')
    Rename-Item -LiteralPath $Path -NewName (Split-Path $moved -Leaf) -ErrorAction Stop
    if (-not $IsWindows) { return }
    try {
        Add-Type -AssemblyName Microsoft.VisualBasic
        $ui = [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs
        $bin = [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
        if (Test-Path -LiteralPath $moved -PathType Container) { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($moved, $ui, $bin) }
        else { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($moved, $ui, $bin) }
    } catch {
        Write-Verbose "DotForge: $moved stays where it is: $($_.Exception.Message)"
    }
}
```

In the Steps file:

```powershell
function Copy-DFVerified {
    <#
    .SYNOPSIS
        Copies a file or folder to Target through a staging copy, checking every file's size and SHA-256.
    .PARAMETER Source
        The old location.
    .PARAMETER Target
        The XDG location (must not exist with content).
    .OUTPUTS
        The manifest: Path (relative), Length, Hash per file. Throws, with staging removed, on any mismatch.
    #>
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Target)
    $staging = "$Target.dotforge-staging"
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction Ignore
    New-DFDirectory (Split-Path $Target) | Out-Null
    try {
        Copy-Item -LiteralPath $Source -Destination $staging -Recurse -Force -ErrorAction Stop
        $isFile = Test-Path -LiteralPath $Source -PathType Leaf
        $files = if ($isFile) { Get-Item -LiteralPath $Source -Force } else { Get-ChildItem -LiteralPath $Source -File -Recurse -Force }
        $n = 0; $total = @($files).Count
        $manifest = foreach ($file in $files) {
            $n++
            Write-Progress -Activity "Checking the copy of $Source" -Status $file.Name -PercentComplete ($n * 100 / [Math]::Max($total, 1))
            $rel = if ($isFile) { '' } else { [IO.Path]::GetRelativePath($Source, $file.FullName) }
            $copy = if ($isFile) { $staging } else { Join-Path $staging $rel }
            $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
            if ((Get-Item -LiteralPath $copy -Force).Length -ne $file.Length -or (Get-FileHash -LiteralPath $copy -Algorithm SHA256).Hash -ne $hash) {
                throw "DotForge: the copy of $($file.FullName) didn't verify."
            }
            [pscustomobject]@{ Path = $rel; Length = $file.Length; Hash = $hash }
        }
        Write-Progress -Activity "Checking the copy of $Source" -Completed
        if (Test-Path -LiteralPath $Target) { Remove-Item -LiteralPath $Target -Recurse -Force }   # empty by the checks
        Move-Item -LiteralPath $staging -Destination $Target -ErrorAction Stop
        @($manifest)
    } catch {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction Ignore
        throw
    }
}

function Invoke-DFConflictMove {
    <#
    .SYNOPSIS
        Resolve-DFToolConflict -Move: checks, copies and verifies, records, then removes the old copies.
    .PARAMETER Tool
        The tool record.
    .PARAMETER Ownership
        Read-DFToolOwnership result (updated and saved).
    .PARAMETER Result
        The result object to fill and return.
    .PARAMETER Cmdlet
        The caller's $PSCmdlet, for ShouldProcess.
    .OUTPUTS
        DotForge.ConflictResult.
    #>
    param($Tool, [hashtable]$Ownership, $Result, $Cmdlet)
    $conflicts = @((Find-DFToolConflict -Tool $Tool -Ownership $Ownership).Conflicts)
    if (-not $conflicts) {
        Write-Host "Nothing of $($Tool.name)'s is in its old locations; it will be owned on its next load."
        return $Result
    }
    $Result.Problems = [string[]]@(Get-DFMoveProblem -Tool $Tool -Conflicts $conflicts | Select-Object -Unique)
    if ($Result.Problems) {
        Write-Warning "DotForge: $($Tool.name) can't be moved safely yet:"
        foreach ($p in $Result.Problems) { Write-Warning "  $p" }
        return $Result
    }
    $plan = ($conflicts | ForEach-Object { "$(@($_.OldPaths)[0]) -> $($_.Target)" }) -join '; '
    if (-not $Cmdlet.ShouldProcess($Tool.name, "Move $plan, then send the old copies to the Recycle Bin")) { return $Result }
    $pending = foreach ($c in $conflicts) {
        $old = @($c.OldPaths)[0]
        $manifest = Copy-DFVerified -Source $old -Target $c.Target
        $Result.Moved = [string[]](@($Result.Moved) + $c.Target)
        [pscustomobject]@{ OldPath = $old; Target = $c.Target; Files = $manifest }
    }
    $Ownership[$Tool.name] = [pscustomobject]@{ since = [DateTime]::UtcNow.ToString('o'); how = 'move'; pending = @($pending) }
    Save-DFToolOwnership -Ownership $Ownership
    $left = @(foreach ($item in $pending) {
        try { Remove-DFItemToBin -Path $item.OldPath } catch { $item }
    })
    $entry = $Ownership[$Tool.name]
    if ($left) { $entry.pending = $left } else { $entry.PSObject.Properties.Remove('pending') }
    Save-DFToolOwnership -Ownership $Ownership
    $Result.Pending = [string[]]@($left.OldPath)
    if ($left) { Write-Warning "DotForge: $(@($left.OldPath) -join ', ') is in use; DotForge removes it on a later load." }
    Write-Host "DotForge now owns $($Tool.name)'s config. Load it with: Register-DFTool -Name $($Tool.name)"
    $Result
}
```

(If a `Copy-DFVerified` throws for the second of two conflicts, the first's target already exists: before throwing out of the loop, remove targets created so far. Add a test: two conflicts, the second fails verification, neither target remains.)

- [ ] **Step 4: Run, expect PASS**; rebuild bundle (Shared changed).

- [ ] **Step 5: Full run and commit** (Tasks 4–6).

---

### Task 7: Pending removals on later loads

**Files:**
- Modify: `Shared/DFToolOwnership.ps1` (`Invoke-DFPendingRemoval`)
- Modify: `Private/Invoke-DFSessionActivation.ps1` (`Select-DFOwnedRecord` calls it for owned tools with `pending`)
- Test: `tests/Activation.Ownership.Tests.ps1` (Context 'pending removals')

**Interfaces:**
- Produces: `Invoke-DFPendingRemoval -Name -Ownership [hashtable]` → `[bool]` changed. Warns per item still left.

- [ ] **Step 1: Write the failing tests**

```powershell
    Context 'pending removals' {
        BeforeEach {
            $script:Old = Join-Path $script:Home '.owna'
            $script:Target = Join-Path $Env:XDG_CONFIG_HOME 'owna'
            New-Item -ItemType File -Force (Join-Path $script:Target 'cfg') -Value 'v' | Out-Null
            New-Item -ItemType File -Force (Join-Path $script:Old 'cfg') -Value 'v' | Out-Null
            Save-DFToolOwnership -Ownership @{ owna = [pscustomobject]@{ since = 'x'; how = 'move'; pending = @(
                [pscustomobject]@{ OldPath = (ConvertTo-DFPath $script:Old); Target = (ConvertTo-DFPath $script:Target)
                    Files = @([pscustomobject]@{ Path = 'cfg'; Length = (Get-Item (Join-Path $script:Target 'cfg')).Length; Hash = 'h' }) }) } }
        }
        It 'removes the old copy and clears pending' {
            Mock Remove-DFItemToBin { }
            Register-DFTool -Name owna 3>$null
            Should -Invoke Remove-DFItemToBin -Times 1
            (Read-DFToolOwnership)['owna'].PSObject.Properties['pending'] | Should -BeNullOrEmpty
        }
        It 'keeps pending and warns when still locked' {
            Mock Remove-DFItemToBin { throw 'in use' }
            Register-DFTool -Name owna -WarningVariable w 3>$null
            "$w" | Should -Match ([regex]::Escape((ConvertTo-DFPath $script:Old)))
            (Read-DFToolOwnership)['owna'].pending | Should -Not -BeNullOrEmpty
        }
        It 'does not remove the old copy when the new one changed size, and says so' {
            Mock Remove-DFItemToBin { }
            Set-Content (Join-Path $script:Target 'cfg') 'much longer now'
            Register-DFTool -Name owna -WarningVariable w 3>$null
            Should -Invoke Remove-DFItemToBin -Times 0
            "$w" | Should -Match '-Done'
        }
        It 'costs nothing for an owned tool without pending' {
            Save-DFToolOwnership -Ownership @{ owna = [pscustomobject]@{ since = 'x'; how = 'clean' } }
            Mock Invoke-DFPendingRemoval { throw 'called' }
            { Register-DFTool -Name owna 3>$null } | Should -Not -Throw
        }
    }
```

- [ ] **Step 2: Run, expect FAIL.**

- [ ] **Step 3: Implement**

```powershell
function Invoke-DFPendingRemoval {
    <#
    .SYNOPSIS
        Retries removing a moved tool's old copies, after checking the new location still holds every moved file.
    .DESCRIPTION
        Size-only check (hashes were checked when the files were moved). A
        changed or missing file stops that item's removal and warns: the user
        checks it, removes the old copy themselves, and runs
        Resolve-DFToolConflict <tool> -Done.
    .PARAMETER Name
        The tool.
    .PARAMETER Ownership
        Read-DFToolOwnership result; the tool's pending list is updated in it.
    .OUTPUTS
        System.Boolean: whether the entry changed.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][hashtable]$Ownership)
    $entry = $Ownership[$Name]
    $left = @(foreach ($item in @($entry.pending)) {
        $bad = @(foreach ($file in @($item.Files)) {
            $path = if ($file.Path) { Join-Path $item.Target $file.Path } else { $item.Target }
            $info = Get-Item -LiteralPath $path -Force -ErrorAction Ignore
            if (-not $info -or $info.Length -ne $file.Length) { $path }
        })
        if ($bad) {
            Write-Warning "DotForge: $Name's moved config changed ($($bad -join ', ')), so $($item.OldPath) was kept. Check it, delete $($item.OldPath) yourself, then run Resolve-DFToolConflict $Name -Done."
            $item; continue
        }
        try { Remove-DFItemToBin -Path $item.OldPath }
        catch { Write-Warning "DotForge: $($item.OldPath) is still in use; DotForge tries again on the next load. Delete it yourself and run Resolve-DFToolConflict $Name -Done to stop this."; $item }
    })
    if ($left.Count -eq @($entry.pending).Count) { return $false }
    if ($left) { $entry.pending = $left } else { $entry.PSObject.Properties.Remove('pending') }
    $true
}
```

(Note the `$false` early return compares counts only, which is right because items are only ever removed.)

In `Select-DFOwnedRecord`, before `$kept.Add($record)` for a non-conflicted tool:

```powershell
        if ($readable -and $ownership[$record.name]?.PSObject.Properties['pending']) {
            if (Invoke-DFPendingRemoval -Name $record.name -Ownership $ownership) { $changed = $true }
        }
```

- [ ] **Step 4: Run, expect PASS**; rebuild bundle.

---

### Task 8 (worker): `xdg.native` data for every relocating tool, and the coverage test

**Files:**
- Modify: `Tools/*.json` for each tool listed by the coverage test
- Create: `tests/ToolNative.Coverage.Tests.ps1` (coordinator writes this first)
- Regenerate: `data/tool-registry.json`, `docs/reference.md` only if the builder shows `native` (it doesn't need to)

**Interfaces:**
- Consumes: Task 1's format; Task 2's `Get-DFToolRelocation`.

- [ ] **Step 1 (coordinator): Write the coverage test**

```powershell
BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    $script:Records = foreach ($file in Get-ChildItem "$PSScriptRoot/../Tools/*.json") {
        ConvertTo-DFToolRecord (Get-Content $file -Raw | ConvertFrom-Json)
    }
}
Describe 'Every relocated config, data and state path declares its old locations' {
    It '<name> declares xdg.native for each relocated path' -ForEach @(
        foreach ($r in $script:Records) { @{ name = $r.name; record = $r } }
    ) {
        $missing = @(Get-DFToolRelocation -Tool $record | Where-Object { -not $_.Native } | ForEach-Object Key)
        $missing | Should -BeNullOrEmpty -Because "add xdg.native entries for: $($missing -join ', ') (use [] when the default location is the XDG one)"
    }
    It '<name> (wrapper) declares at least one native target' -ForEach @(
        foreach ($r in $script:Records | Where-Object { $_.xdg.method -eq 'wrapper' }) { @{ name = $r.name; record = $r } }
    ) {
        @($record.xdg.native.PSObject.Properties).Count | Should -BeGreaterThan 0
    }
}
```

(`-ForEach` data is built at discovery, so move the record loading into a `BeforeDiscovery` block; adjust accordingly.)

Run it: expect FAIL listing ~20 tools.

- [ ] **Step 2 (worker, via Orca `orchestration` so it reports back):** brief = the coverage-test failure list, the format from the spec's "Tool data" section, and these rules:
  - For every tool the test lists, add `xdg.native` with the tool's documented default locations on Windows, Linux and macOS when the variable is unset (files or folders), as `${HOME}`/`${APPDATA}`/`${LOCALAPPDATA}` templates.
  - Read every `Tools/<tool>.ps1` companion for paths it points at `${XDG_*}` (e.g. PSReadLine's `HistorySavePath`, glow's `--config`, fastfetch's `--config`) and add a `native` entry keyed by that target template.
  - `RUSTUP_HOME`, `CARGO_HOME`, `VCPKG_ROOT`: `move: false` with a one-sentence guide naming the tool's own documentation on moving it.
  - Report, per entry, the source (doc URL or source file + line) for each path. Unverifiable paths: leave out and list them.
  - No commits; run only `tests/ToolNative.Coverage.Tests.ps1`, `tests/Test-DFToolSchema.Tests.ps1`, then `./build/Build-DFToolRegistry.ps1` and `tests/ToolRegistry.Tests.ps1`.

- [ ] **Step 3 (coordinator):** review every entry against its source; spot-check five sources directly. Run the three test files: expect PASS.

---

### Task 9: Docs, changelog, backlog; final run

**Files:**
- Modify: `docs/guide/configuration.md` (section "When DotForge finds your existing config" + troubleshooting rows), `docs/guide/writing-a-tool.md` (`xdg.native`), `CLAUDE.md` (Tool JSON Schema: one `xdg.native` bullet), `CHANGELOG.md` (`[Unreleased]` Added), `TODO.md` (delete T-61)
- Regenerate: bundle, registry, reference.

- [ ] **Step 1:** Write the guide section: the rule (opt-in, owned, conflict), the warning text, `-Move` (what it checks, the copy and verify, Recycle Bin / `.dotforge-moved`, retries, `-Done`), `-Adopt`, the outside-PowerShell note. Doc code blocks that change files are marked `<!-- system -->` or written as `<!-- fragment -->`; a runnable example uses the sandbox (empty HOME) and `Get-DFToolStatus -Conflict`.
- [ ] **Step 2:** `pwsh -NoProfile -Command "./build/Test-DFFull.ps1 -Path tests/Docs.Examples.Tests.ps1,tests/Docs.Help.Tests.ps1,tests/Docs.Reference.Tests.ps1"`: PASS.
- [ ] **Step 3:** Full run `pwsh -NoProfile -File build/Test-DFFull.ps1`: 0 failed, 0 sentinel files.
- [ ] **Step 4:** Commit Tasks 7–9 with `Closes T-61.`; fast-forward `main`, push.
