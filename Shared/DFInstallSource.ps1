#Requires -Version 7.2

function Get-DFSourceManager {
    <#
    .SYNOPSIS
        Returns the managers that install from one source, best first.
    .DESCRIPTION
        A manager is any tool record whose installs.from names the source.
        A system manager (scoop) is its own only manager; a registry (npm)
        can have several (npm, pnpm, bun). Order: a manager the user named in
        Defaults (for any role), then the highest priority among its roles,
        then name.
    .PARAMETER Source
        The source name, e.g. 'scoop' or 'npm'.
    .PARAMETER ToolDb
        Name -> tool record; must include the manager records.
    .OUTPUTS
        PSCustomObject[]. Manager records.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][hashtable]$ToolDb)
    $chosen = @((Get-DFConfig Defaults -Default @{}).Values)
    $topPriority = { param($m) (@($m.roles.PSObject.Properties.Value | ForEach-Object { $_.priority }) + 0 | Measure-Object -Maximum).Maximum }
    @($ToolDb.Values | Where-Object { $_.installs -and @($_.installs | Where-Object { $_.from -eq $Source }).Count } |
        Sort-Object @{ Expression = { $_.name -in $chosen }; Descending = $true },
                    @{ Expression = { & $topPriority $_ }; Descending = $true },
                    name)
}

function Get-DFBuiltInSourceOrder {
    <#
    .SYNOPSIS
        DotForge's fallback source order: system managers by package-manager priority, then every other source by name.
    .PARAMETER ToolDb
        Name -> tool record; must include the manager records.
    .OUTPUTS
        System.String[].
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][hashtable]$ToolDb)
    $managers = @($ToolDb.Values | Where-Object installs)
    $system = @(Get-DFRoleMember -Role 'package-manager' -Tools $managers |
        Sort-Object @{ Expression = { $_.roles.'package-manager'.priority }; Descending = $true }, name |
        ForEach-Object { $_.installs[0].from })
    $other = @($managers | ForEach-Object { $_.installs | ForEach-Object { $_.from } } | Where-Object { $_ -notin $system } | Sort-Object -Unique)
    [string[]]@($system + $other | Select-Object -Unique)
}

function Test-DFSourceAllowed {
    <#
    .SYNOPSIS
        Whether the user's IncludeSources and ExcludeSources allow a source (before any per-tool InstallVia).
    .PARAMETER Source
        The source name.
    .OUTPUTS
        System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Source)
    $included = @(Get-DFConfig IncludeSources | Where-Object { $_ })
    ($Source -notin @(Get-DFConfig ExcludeSources)) -and (-not $included -or $Source -in $included)
}

function Get-DFToolInstallPreference {
    <#
    .SYNOPSIS
        Reads a tool record's install.prefer and install.avoid, StrictMode-safe even for a hand-built record without them.
    .PARAMETER Tool
        The tool record.
    .OUTPUTS
        PSCustomObject: Prefer (string[]), Avoid (hashtable source -> reason).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][pscustomobject]$Tool)
    $install = $Tool.PSObject.Properties['install']?.Value
    $prefer = if ($install) { $install.PSObject.Properties['prefer']?.Value }
    $avoidObject = if ($install) { $install.PSObject.Properties['avoid']?.Value }
    $avoid = @{}
    if ($avoidObject) { foreach ($entry in $avoidObject.PSObject.Properties) { $avoid[$entry.Name] = $entry.Value } }
    [pscustomobject]@{ Prefer = [string[]]@($prefer | Where-Object { $_ }); Avoid = $avoid }
}

function Get-DFInstallSourceOrder {
    <#
    .SYNOPSIS
        Orders one tool's candidate sources: -Via, InstallVia, the tool's install.prefer, InstallOrder, then DotForge's order.
    .DESCRIPTION
        Only sources the tool has a package for are returned. When
        IncludeSources is set, only the sources it lists are used, registries
        included; ExcludeSources removes the sources it lists. -Via or
        InstallVia naming a source for this tool beats both. An InstallVia
        source the tool has no package for warns and is ignored, so it never
        loosens either list. An IncludeSources entry DotForge doesn't know
        warns. Sources the record avoids (install.avoid) go last, unless -Via
        or InstallVia names them.
    .PARAMETER Tool
        The tool record.
    .PARAMETER ToolDb
        Name -> tool record; must include the manager records.
    .PARAMETER Via
        Tool -> source for this call (Install-DFTool -Via); beats the InstallVia setting.
    .OUTPUTS
        System.String[].
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][pscustomobject]$Tool, [Parameter(Mandatory)][hashtable]$ToolDb, [hashtable]$Via = @{})
    $have = @(if ($Tool.packages) { $Tool.packages.PSObject.Properties | Where-Object { Get-DFPackageRef $_.Value } | ForEach-Object { $_.Name } })
    # (A local named $via would be the $Via parameter: names are case-insensitive.)
    $pinned = $Via[$Tool.name] ?? (Get-DFConfig InstallVia -Default @{})[$Tool.name]
    if ($pinned -and $pinned -notin $have) {
        Write-DFInstallWarning "DotForge: InstallVia for $($Tool.name) names '$pinned', which has no package for it; ignoring that."
        $pinned = $null
    }
    $known = Get-DFBuiltInSourceOrder -ToolDb $ToolDb
    foreach ($unknown in @(Get-DFConfig IncludeSources) | Where-Object { $_ -and $_ -notin $known }) {
        Write-DFInstallWarning "DotForge: IncludeSources lists '$unknown', which no package manager installs from; ignoring that entry."
    }
    $preference = Get-DFToolInstallPreference -Tool $Tool
    $ordered = @(@($pinned) + $preference.Prefer + @(Get-DFConfig InstallOrder) + $known + $have |
        Where-Object { $_ -and $_ -in $have } | Select-Object -Unique)
    $ordered = @($ordered | Where-Object { $_ -eq $pinned -or (Test-DFSourceAllowed -Source $_) })
    # Sources the record avoids go last, unless the user named one for this tool.
    $avoided = @($preference.Avoid.Keys)
    [string[]]@(@($ordered | Where-Object { $_ -eq $pinned -or $_ -notin $avoided }) + @($ordered | Where-Object { $_ -ne $pinned -and $_ -in $avoided }))
}

function Resolve-DFInstallSource {
    <#
    .SYNOPSIS
        Picks the source and manager that will install one tool, or says why none can.
    .DESCRIPTION
        Walks Get-DFInstallSourceOrder. For each source, the manager is the
        user's -Choice for that source if given, else the first of
        Get-DFSourceManager that is available or -Planned (an earlier stage
        installs it). The first source with a manager wins. Otherwise Gap
        explains why, and Options lists the managers that could serve the
        first source, for the interactive question.
    .PARAMETER Tool
        The tool record.
    .PARAMETER ToolDb
        Name -> tool record; must include the manager records.
    .PARAMETER IsAvailable
        { param($record) } -> whether that manager is installed now.
    .PARAMETER Planned
        Manager names an earlier stage installs.
    .PARAMETER Choice
        Source -> manager name the user picked for it.
    .PARAMETER Via
        Tool -> source for this call; passed to Get-DFInstallSourceOrder.
    .PARAMETER CanElevate
        Whether a manager that needs admin rights (installs.elevate) can run:
        the shell is elevated, or an elevator is installed or planned. When
        not, such a manager is passed over like an unavailable one.
    .OUTPUTS
        PSCustomObject: Tool, Source, Manager, Block (the manager's installs
        block for Source), Ref, Gap, Options, Sources (the candidate order it
        walked), and AvoidReason (why the record avoids Source, when it does).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Tool,
        [Parameter(Mandatory)][hashtable]$ToolDb,
        [Parameter(Mandatory)][scriptblock]$IsAvailable,
        [AllowEmptyCollection()][string[]]$Planned = @(),
        [hashtable]$Choice = @{},
        [hashtable]$Via = @{},
        [bool]$CanElevate = $true
    )
    $sources = @(Get-DFInstallSourceOrder -Tool $Tool -ToolDb $ToolDb -Via $Via)
    $result = [pscustomobject]@{ Tool = $Tool.name; Source = $null; Manager = $null; Block = $null; Ref = $null; Gap = $null; Options = @(); Sources = [string[]]$sources; AvoidReason = $null }
    if (-not $sources) {
        $have = @(if ($Tool.packages) { $Tool.packages.PSObject.Properties.Name })
        if (-not $have) { $result.Gap = 'no package in any source'; return $result }
        $one = $have.Count -eq 1
        $them = if ($one) { 'it' } else { 'them' }
        $included = @(Get-DFConfig IncludeSources | Where-Object { $_ })
        $byInclude = $included -and @($have | Where-Object { $_ -notin $included }).Count
        $byExclude = @($have | Where-Object { $_ -in @(Get-DFConfig ExcludeSources) }).Count
        $why = if ($byInclude -and $byExclude) { "IncludeSources and ExcludeSources rule $them out" }
               elseif ($byInclude) { "IncludeSources doesn't list $them" }
               else { "ExcludeSources removes $them" }
        $result.Gap = "no source left (only $($have -join ', ') $(if ($one) { 'has' } else { 'have' }) it, and $why)"
        return $result
    }
    foreach ($s in $sources) {
        $managers = @(Get-DFSourceManager -Source $s -ToolDb $ToolDb | Where-Object { $CanElevate -or -not (Get-DFInstallBlock -Manager $_ -Source $s).elevate })
        $pick = if ($Choice[$s]) { $managers | Where-Object name -eq $Choice[$s] | Select-Object -First 1 }
                else { $managers | Where-Object { $_.name -in $Planned -or (& $IsAvailable $_) } | Select-Object -First 1 }
        if ($pick) {
            $pinned = $Via[$Tool.name] ?? (Get-DFConfig InstallVia -Default @{})[$Tool.name]
            if ($pinned -and $pinned -ne $s -and $pinned -in $sources) {
                Write-DFInstallWarning "DotForge: InstallVia for $($Tool.name) names '$pinned', whose manager is not installed or requested; installing from $s instead."
            }
            $result.Source = $s
            $result.Manager = $pick
            $result.Block = Get-DFInstallBlock -Manager $pick -Source $s
            $result.Ref = Get-DFPackageRef $Tool.packages.$s
            $result.AvoidReason = (Get-DFToolInstallPreference -Tool $Tool).Avoid[$s]
            return $result
        }
    }
    $first = $sources[0]
    $result.Options = [string[]]@(Get-DFSourceManager -Source $first -ToolDb $ToolDb | ForEach-Object { $_.name })
    $result.Gap = "needs a manager for $first ($(if ($result.Options) { $result.Options -join ', ' } else { 'none known' })), and none is installed or requested"
    $result
}

function Write-DFInstallWarning {
    <#
    .SYNOPSIS
        Writes a planning warning once per Install-DFTool call (its question loop re-plans after every answer).
    .PARAMETER Message
        The warning.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message)
    if ($script:DFInstallWarned -and -not $script:DFInstallWarned.Add($Message)) { return }
    Write-Warning $Message
}

function Get-DFInstallBlock {
    <#
    .SYNOPSIS
        Returns a manager's installs block for one source (uv has one for PyPI tools and one for Python).
    .PARAMETER Manager
        The manager's tool record.
    .PARAMETER Source
        The source. Omitted: the first block.
    .OUTPUTS
        PSCustomObject, or nothing when the manager doesn't install from Source.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][pscustomobject]$Manager, [string]$Source)
    $blocks = @($Manager.installs | Where-Object { $_ })
    if (-not $Source) { return $blocks | Select-Object -First 1 }
    $blocks | Where-Object { $_.from -eq $Source } | Select-Object -First 1
}
