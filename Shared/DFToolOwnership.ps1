#Requires -Version 7.2

# Config ownership: DotForge points a requested tool at XDG locations only
# once it owns that tool's config, so a user's existing config is never
# silently hidden. Stateless: the startup core and Resolve-DFToolConflict
# (DotForge.Helpers) both read the ownership file through these functions.
# See docs/superpowers/specs/2026-10-11-config-ownership-design.md.

function Get-DFNativeRoot {
    <#
    .SYNOPSIS
        The folder a ${HOME}, ${APPDATA} or ${LOCALAPPDATA} template names, or $null when it's unset.
    .DESCRIPTION
        The one place those roots are read. The test suite's loader sets the
        script variable DFTestNativeRoot (tests/TestSupport.ps1), so no test
        looks in the developer's real home. It is a script variable, never an
        environment variable, so it can't outlive a test run in a live shell.
    .PARAMETER Name
        HOME, APPDATA or LOCALAPPDATA.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][ValidateSet('HOME', 'APPDATA', 'LOCALAPPDATA')][string]$Name)
    $testRoot = Get-Variable -Name DFTestNativeRoot -Scope Script -ValueOnly -ErrorAction Ignore
    if ($testRoot) { return Join-Path $testRoot $Name }
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
        [pscustomobject]@{ Key = $Key; Target = Expand-DFXdgPath $Template; Native = $(if ($native) { $native.PSObject.Properties[$Key]?.Value }) }
    }
    if ($Tool.xdg?.method -eq 'env' -and $Tool.xdg.vars) {
        foreach ($p in $Tool.xdg.vars.PSObject.Properties) { if ($p.Value -cmatch $keep) { & $emit $p.Name $p.Value } }
    }
    $seed = if ($Tool.setup) { $Tool.setup.PSObject.Properties['seed']?.Value }
    if ($seed) { foreach ($p in $seed.PSObject.Properties) { & $emit $p.Name $p.Name } }
    if ($native) { foreach ($p in $native.PSObject.Properties) { if ($p.Name -cmatch $keep) { & $emit $p.Name $p.Name } } }
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
        A missing file is an empty table. A file that can't be read (in use,
        no access) or isn't a JSON object warns and returns $null: callers
        then record nothing, so the file is never overwritten with less than
        it held.
    .OUTPUTS
        System.Collections.Hashtable (name -> entry with since, how and an
        optional pending list), or $null.
    #>
    [CmdletBinding()]
    param()
    $path = Get-DFToolOwnershipPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @{} }
    try {
        $data = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ($data -isnot [System.Collections.IDictionary]) { throw 'it holds no JSON object' }
    } catch {
        Write-Warning "DotForge: $path can't be read ($($_.Exception.Message)), so tool ownership can't be read or recorded. Fix or delete it."
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
    param([Parameter(Mandatory)][AllowEmptyCollection()][hashtable]$Ownership)
    Write-DFFileAtomic -Path (Get-DFToolOwnershipPath) -Value ($Ownership | ConvertTo-Json -Depth 10)
}

function Find-DFToolConflict {
    <#
    .SYNOPSIS
        Finds a requested tool's old locations that hold content DotForge would hide.
    .DESCRIPTION
        An owned tool is not checked (no file-system calls). For each relocated
        path (Get-DFToolRelocation), an old location with content is a conflict
        unless it is the target or inside it. A variable already set in the
        process is the user's choice, which DotForge leaves alone, so it is
        skipped and Complete is false: the tool can't be recorded as owned on
        that check.
    .PARAMETER Tool
        A normalized tool record.
    .PARAMETER Ownership
        Read-DFToolOwnership result.
    .OUTPUTS
        pscustomobject: Conflicts (each with Tool, Key, OldPaths, Target,
        TargetHasContent, Move, Guide) and Complete.
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
            [pscustomobject]@{
                Tool = $Tool.name; Key = $reloc.Key; OldPaths = [string[]]$found; Target = $reloc.Target
                TargetHasContent = Test-DFPathHasContent -Path $reloc.Target
                Move = $reloc.Native.move; Guide = $reloc.Native.guide
            }
        }
    }
    [pscustomobject]@{ Conflicts = @($conflicts); Complete = $complete }
}

function Invoke-DFPendingRemoval {
    <#
    .SYNOPSIS
        Retries removing a moved tool's old copies, once the new location still holds every moved file.
    .DESCRIPTION
        Checks sizes only (hashes were checked when the files moved; hashing a
        large folder on every load would be too slow). A changed or missing
        file keeps that old copy and warns: the user checks it, deletes the old
        copy themselves, and runs Resolve-DFToolConflict <tool> -Done. A copy
        still in use warns and is retried on the next load.
    .PARAMETER Name
        The tool.
    .PARAMETER Ownership
        Read-DFToolOwnership result; the tool's pending list is updated in it.
    .OUTPUTS
        System.Boolean: whether the tool's entry changed.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][hashtable]$Ownership)
    $entry = $Ownership[$Name]
    $before = @($entry.pending)
    $left = @(foreach ($item in $before) {
        $changed = @(foreach ($file in @($item.Files)) {
            $path = if ($file.Path) { Join-Path $item.Target $file.Path } else { $item.Target }
            $info = Get-Item -LiteralPath $path -Force -ErrorAction Ignore
            if (-not $info -or $info.Length -ne $file.Length) { $path }
        })
        if ($changed) {
            Write-Warning "DotForge: $Name's moved config changed since the move ($($changed -join ', ')), so $($item.OldPath) was kept. Check it, delete $($item.OldPath) yourself, then run Resolve-DFToolConflict $Name -Done."
            $item
            continue
        }
        try { Remove-DFItemToBin -Path $item.OldPath }
        catch {
            Write-Warning "DotForge: $($item.OldPath) is still in use, so DotForge tries again on the next load. To stop this, delete it yourself and run Resolve-DFToolConflict $Name -Done."
            $item
        }
    })
    # Items only ever leave the list, so an unchanged count means nothing changed.
    if ($left.Count -eq $before.Count) { return $false }
    if ($left) { $entry.pending = $left } else { $entry.PSObject.Properties.Remove('pending') }
    $true
}
