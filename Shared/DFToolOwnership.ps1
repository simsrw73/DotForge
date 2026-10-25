#Requires -Version 7.2

# Config ownership: DotForge points a requested tool at XDG locations only
# once it owns that tool's config, so a user's existing config is never
# silently hidden. Stateless: the startup core and Resolve-DFToolConflict
# (DotForge.Helpers) both read the ownership file through these functions.
# See docs/superpowers/specs/2026-10-11-config-ownership-design.md.

function Get-DFNativeRoot {
    <#
    .SYNOPSIS
        The folder a ${HOME}, ${APPDATA}, ${LOCALAPPDATA} or ${SCOOP} template names, or $null when it's unset.
    .DESCRIPTION
        The one place those roots are read. The test suite's loader sets the
        script variable DFTestNativeRoot (tests/TestSupport.ps1), so no test
        looks in the developer's real home. It is a script variable, never an
        environment variable, so it can't outlive a test run in a live shell.
    .PARAMETER Name
        HOME, APPDATA, LOCALAPPDATA or SCOOP (where a manager keeps data beside the program).
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][ValidateSet('HOME', 'APPDATA', 'LOCALAPPDATA', 'SCOOP')][string]$Name)
    $testRoot = Get-Variable -Name DFTestNativeRoot -Scope Script -ValueOnly -ErrorAction Ignore
    if ($testRoot) { return Join-Path $testRoot $Name }
    # Every root but HOME is the environment variable of that name.
    if ($Name -eq 'HOME') { $HOME } else { [Environment]::GetEnvironmentVariable($Name) }
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
    foreach ($root in 'HOME', 'APPDATA', 'LOCALAPPDATA', 'SCOOP') {
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
        key's xdg.native entry, or $null when the record declares none. When
        that entry names a setting (fastfetch's configPath) and the record's
        settings set it, that value is the target.
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
        $entry = if ($native) { $native.PSObject.Properties[$Key]?.Value }
        $override = if ($entry -and $entry.setting -and $Tool.settings) { $Tool.settings.PSObject.Properties[$entry.setting]?.Value }
        $target = if ($override) { ConvertTo-DFPath (Expand-DFXdgPath $override) } else { Expand-DFXdgPath $Template }
        [pscustomobject]@{ Key = $Key; Target = $target; Native = $entry }
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
        Writes the ownership table atomically; with -Name, merges only those tools' entries into the file as it is now.
    .DESCRIPTION
        Two shells can load at once, and Resolve-DFToolConflict can run while a
        shell loads. With -Name, the file is read again just before writing and
        only the named tools' entries are taken from Ownership (a name missing
        from it is removed), so another shell's records are kept. A file that
        can't be read then is left alone. Without -Name, Ownership replaces the
        whole file.
    .PARAMETER Ownership
        Tool name -> entry.
    .PARAMETER Name
        The tools whose entries this caller changed.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][hashtable]$Ownership,
        [string[]]$Name
    )
    $table = $Ownership
    if ($PSBoundParameters.ContainsKey('Name')) {
        $table = Read-DFToolOwnership
        if ($null -eq $table) { return }
        foreach ($toolName in $Name) {
            if ($Ownership.ContainsKey($toolName)) { $table[$toolName] = $Ownership[$toolName] } else { $table.Remove($toolName) }
        }
    }
    Write-DFFileAtomic -Path (Get-DFToolOwnershipPath) -Value ($table | ConvertTo-Json -Depth 10)
}
function Find-DFToolConflict {
    <#
    .SYNOPSIS
        Finds where a requested tool's existing data is, for each location DotForge relocates, and what to do about it.
    .DESCRIPTION
        An owned tool is not checked (no file-system calls). For each relocated
        path (Get-DFToolRelocation), the existing location is the variable's
        value when it was set outside DotForge (not what DotForge last wrote)
        and differs from the XDG path, else the first xdg.native path with
        content. With the XDG location empty, the action is Link: DotForge links
        it to the existing data and leaves the variable unset. With content in
        both, the action is Conflict. A variable DotForge itself set earlier
        makes the check incomplete (Complete false): the tool can't be recorded
        as owned on that check.
    .PARAMETER Tool
        A normalized tool record.
    .PARAMETER Ownership
        Read-DFToolOwnership result.
    .PARAMETER Written
        Variable -> the value DotForge last wrote (Get-DFEnvState's Written),
        so a value DotForge set isn't taken for one set outside it.
    .OUTPUTS
        pscustomobject: Conflicts (each with Tool, Key, OldPaths, Existing,
        Target, TargetHasContent, Guide, Action: Link or Conflict) and Complete.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Tool,
        [Parameter(Mandatory)][AllowEmptyCollection()][hashtable]$Ownership,
        [AllowEmptyCollection()][hashtable]$Written = @{}
    )
    if ($Ownership.ContainsKey($Tool.name)) { return [pscustomobject]@{ Conflicts = @(); Complete = $true } }
    $complete = $true
    $sep = [IO.Path]::DirectorySeparatorChar
    $written = $Written
    $inside = { param($path, $target) $path -eq $target -or $path.StartsWith($target + $sep, [StringComparison]::OrdinalIgnoreCase) }
    $conflicts = foreach ($reloc in @(Get-DFToolRelocation -Tool $Tool)) {
        $found = @()
        if ($reloc.Key -cnotmatch '^\$\{') {
            $value = [Environment]::GetEnvironmentVariable($reloc.Key, 'Process')
            if ($value -and $written.ContainsKey($reloc.Key) -and $written[$reloc.Key] -ceq $value) { $complete = $false; continue }
            if ($value) {
                $outside = ConvertTo-DFPath $value
                # Never a folder that contains the target (a junction into its own parent).
                if (-not (& $inside $outside $reloc.Target) -and -not (& $inside $reloc.Target $outside) -and (Test-Path -LiteralPath $outside)) { $found = @($outside) }
                else {
                    # The user's own choice, not checked against the native paths: not a complete check.
                    $complete = $false
                    continue
                }
            }
        }
        if (-not $found -and $reloc.Native) {
            $found = @(foreach ($template in $reloc.Native.paths) {
                $old = Expand-DFNativePath $template
                if (-not $old -or (& $inside $old $reloc.Target) -or (& $inside $reloc.Target $old)) { continue }
                if (Test-DFPathHasContent -Path $old) { $old }
            })
        }
        if (-not $found) { continue }
        # A link already at the XDG location: to the existing data, DotForge's own (link again,
        # idempotently); anywhere else, the user's, which DotForge never replaces.
        $current = Get-DFToolLinkTarget -Path $reloc.Target
        $hasContent = if ($current) { $current -ne $found[0] } else { Test-DFPathHasContent -Path $reloc.Target }
        [pscustomobject]@{
            Tool = $Tool.name; Key = $reloc.Key; OldPaths = [string[]]$found; Existing = $found[0]; Target = $reloc.Target
            TargetHasContent = $hasContent; Guide = $reloc.Native?.guide
            Action = if ($hasContent) { 'Conflict' } else { 'Link' }
        }
    }
    [pscustomobject]@{ Conflicts = @($conflicts); Complete = $complete }
}

function Get-DFConflictAdvice {
    <#
    .SYNOPSIS
        What to do about a tool whose old and XDG locations both hold content: one rule, used by the status detail and Resolve-DFToolConflict.
    .DESCRIPTION
        -Adopt keeps the existing data: the XDG copy is set aside and the XDG
        location linked to the existing one. A record's guide says how to keep
        the XDG copy instead. Each guide is given once, even when several
        paths share it.
    .PARAMETER Name
        The tool.
    .PARAMETER Conflicts
        Find-DFToolConflict's Conflicts with Action Conflict.
    .OUTPUTS
        pscustomobject: Action (Adopt) and Text.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][object[]]$Conflicts)
    $guides = @($Conflicts | ForEach-Object Guide | Where-Object { $_ } | Select-Object -Unique)
    $inUse = @($Conflicts | ForEach-Object Target | Select-Object -Unique)
    $text = "$($inUse -join ', ') has content too. Run Resolve-DFToolConflict $Name -Adopt to keep the existing copy and link to it (the XDG copy is set aside, never deleted), or remove $Name from Tools."
    if ($guides) { $text += " To keep the XDG copy instead: $($guides -join ' ')" }
    [pscustomobject]@{ Action = 'Adopt'; Text = $text }
}
