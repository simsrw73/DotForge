#Requires -Version 7.0

$script:DFPackageManagers = $null

function script:Resolve-DFPackageManager {
    <#
    .SYNOPSIS
        Detects which package managers are available on PATH.
        Returns names in priority order. Result is cached; use -Force to reload.
    .PARAMETER Priority
        Ordered list of package manager names to check.
        Defaults to scoop, winget, choco.
    .PARAMETER Force
        Clear cache and re-detect.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [string[]]$Priority = @('scoop', 'winget', 'choco'),
        [switch]$Force
    )

    if ($script:DFPackageManagers -and -not $Force) { return $script:DFPackageManagers }

    $available = $Priority | Where-Object { Get-Command $_ -ErrorAction Ignore }
    $script:DFPackageManagers = @($available)
    return $script:DFPackageManagers
}
