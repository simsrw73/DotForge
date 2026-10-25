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

function Get-DFInstallAlways {
    <#
    .SYNOPSIS
        Returns the source the InstallAlways setting imposes on one tool, or nothing.
    .DESCRIPTION
        InstallAlways covers a tool only when the tool has a package in some
        system manager's source (a member of the package-manager role: scoop,
        winget, choco); a tool only a registry or version manager provides
        (PowerShell Gallery, npm, fnm) installs as usual. -Via or InstallVia
        naming a source for the tool beats it. A source DotForge doesn't know
        warns and is ignored.
    .PARAMETER Tool
        The tool record.
    .PARAMETER ToolDb
        Name -> tool record; must include the manager records.
    .PARAMETER Via
        Tool -> source for this call (Install-DFTool -Via).
    .OUTPUTS
        System.String, or nothing.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][pscustomobject]$Tool, [Parameter(Mandatory)][hashtable]$ToolDb, [hashtable]$Via = @{})
    $always = Get-DFConfig InstallAlways
    if (-not $always) { return }
    if ($always -notin (Get-DFBuiltInSourceOrder -ToolDb $ToolDb)) {
        Write-DFInstallWarning "DotForge: InstallAlways names '$always', which no package manager installs from; ignoring it."
        return
    }
    if ($Via[$Tool.name] ?? (Get-DFConfig InstallVia -Default @{})[$Tool.name]) { return }
    $managers = @($ToolDb.Values | Where-Object installs)
    $system = @(Get-DFRoleMember -Role 'package-manager' -Tools $managers | ForEach-Object { $_.installs.from })
    $have = @(if ($Tool.packages) { $Tool.packages.PSObject.Properties | Where-Object { Get-DFPackageRef $_.Value } | ForEach-Object { $_.Name } })
    if (@($have | Where-Object { $_ -in $system }).Count) { $always }
}

function Get-DFInstallSourceOrder {
    <#
    .SYNOPSIS
        Orders one tool's candidate sources: -Via, InstallVia, InstallAlways, the tool's install.prefer, InstallOrder, then DotForge's order.
    .DESCRIPTION
        Only sources the tool has a package for are returned. ExcludeSources
        removes a source unless InstallVia or InstallAlways names it for this
        tool. An InstallVia source the tool has no package for warns and is
        ignored. A tool InstallAlways covers (Get-DFInstallAlways) gets that
        source alone, or nothing when it has no package there. Sources the
        record avoids (install.avoid) go last, unless -Via, InstallVia or
        InstallAlways names them.
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
    $excluded = @(Get-DFConfig ExcludeSources)
    $always = if (-not $pinned) { Get-DFInstallAlways -Tool $Tool -ToolDb $ToolDb -Via $Via }
    if ($always) {
        if ($always -in $excluded) { Write-DFInstallWarning "DotForge: InstallAlways names '$always', which ExcludeSources also lists; using it." }
        return [string[]]@($always | Where-Object { $_ -in $have })
    }
    $ordered = @(@($pinned) + @($Tool.install?.prefer) + @(Get-DFConfig InstallOrder) + (Get-DFBuiltInSourceOrder -ToolDb $ToolDb) + $have |
        Where-Object { $_ -and $_ -in $have } | Select-Object -Unique)
    $ordered = @($ordered | Where-Object { $_ -eq $pinned -or $_ -notin $excluded })
    # Sources the record avoids go last, unless the user named one for this tool.
    $avoided = @($Tool.install?.avoid?.PSObject.Properties.Name)
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
        $always = Get-DFInstallAlways -Tool $Tool -ToolDb $ToolDb -Via $Via
        if ($always) {
            $result.Gap = "InstallAlways is $always, which has no package for it"
            return $result
        }
        $have = @(if ($Tool.packages) { $Tool.packages.PSObject.Properties.Name })
        $result.Gap = if (-not $have) { 'no package in any source' }
                      else { "no source left (only $($have -join ', ') $(if ($have.Count -eq 1) { 'has' } else { 'have' }) it, and ExcludeSources removes $(if ($have.Count -eq 1) { 'it' } else { 'them' }))" }
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
            $result.AvoidReason = $Tool.install?.avoid?.PSObject.Properties[$s]?.Value
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
