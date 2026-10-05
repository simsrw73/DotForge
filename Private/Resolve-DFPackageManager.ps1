#Requires -Version 7.0

$script:DFPackageManagers = $null

function Resolve-DFPackageManager {
    <#
    .SYNOPSIS
        Detects which package managers are available on PATH.
        Returns names in priority order. Result is cached; use -Force to reload.
    .PARAMETER Priority
        Ordered list of package manager names to check. Defaults to the
        package-manager role's order (Get-DFPackageManagerOrder): the
        $DFConfig.Defaults choice first, then by priority (scoop, winget,
        choco as shipped). Supplying this parameter always
        forces a fresh, uncached probe and never populates the shared cache --
        only calls using the default priority order participate in caching, so
        a one-off custom-priority call never overwrites the cached default
        result for later default-priority callers.
    .PARAMETER Force
        Clear cache and re-detect. Has no effect when -Priority is also supplied -- that
        call is always uncached regardless of -Force.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [string[]]$Priority,
        [switch]$Force
    )

    $explicitPriority = $PSBoundParameters.ContainsKey('Priority')
    if (-not $explicitPriority) { $Priority = Get-DFPackageManagerOrder }

    if (-not $explicitPriority -and -not $Force -and $script:DFPackageManagers) {
        return $script:DFPackageManagers
    }

    $available = @($Priority | Where-Object { Get-Command $_ -ErrorAction Ignore })
    if (-not $explicitPriority) { $script:DFPackageManagers = $available }
    return $available
}

function Get-DFPackageManagerOrder {
    <#
    .SYNOPSIS
        Returns the package-manager role's members in preference order.
    .DESCRIPTION
        The $DFConfig.Defaults['package-manager'] member first, then the other
        members by roles.package-manager.priority (highest first) and name.
        Falls back to scoop, winget, choco when no tool declares the role.
    .PARAMETER ToolDb
        The tool database. Defaults to Import-DFToolDb.
    .OUTPUTS
        System.String[].
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([hashtable]$ToolDb = (Import-DFToolDb))
    $members = @($ToolDb.Values | Where-Object { $_.roles.PSObject.Properties['package-manager'] } |
        Sort-Object @{ Expression = { $_.roles.'package-manager'.priority }; Descending = $true }, @{ Expression = { $_.name } } |
        ForEach-Object name)
    if (-not $members) { return [string[]]@('scoop', 'winget', 'choco') }
    $chosen = (Get-DFConfig Defaults -Default @{})['package-manager']
    if ($chosen -and $chosen -in $members) { $members = @($chosen) + @($members | Where-Object { $_ -ne $chosen }) }
    [string[]]$members
}
