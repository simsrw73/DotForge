#Requires -Version 7.0

$script:DFPackageManagers = $null

function Resolve-DFPackageManager {
    <#
    .SYNOPSIS
        Detects which package managers are available on PATH.
        Returns names in priority order. Result is cached; use -Force to reload.
    .PARAMETER Priority
        Ordered list of package manager names to check.
        Defaults to scoop, winget, choco. Supplying this parameter always
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
        [string[]]$Priority = @('scoop', 'winget', 'choco'),
        [switch]$Force
    )

    $explicitPriority = $PSBoundParameters.ContainsKey('Priority')

    if (-not $explicitPriority -and -not $Force -and $script:DFPackageManagers) {
        return $script:DFPackageManagers
    }

    $available = @($Priority | Where-Object { Get-Command $_ -ErrorAction Ignore })
    if (-not $explicitPriority) { $script:DFPackageManagers = $available }
    return $available
}
