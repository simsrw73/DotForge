#Requires -Version 7.2

function Get-DFPSResourceInstalledRaw {
    <#
    .SYNOPSIS
        Gets PSResourceGet modules installed for the current user.
    .DESCRIPTION
        Provides a mockable seam around the PSResourceGet cmdlet.
    .OUTPUTS
        Objects returned by Get-InstalledPSResource.
    #>
    [CmdletBinding()]
    param()

    Get-InstalledPSResource -Scope CurrentUser
}

function Get-DFPSResourceInstalled {
    <#
    .SYNOPSIS
        Lists PowerShell resources installed for the current user.
    .DESCRIPTION
        Maps PSResourceGet records to DotForge package rows through a mockable seam.
    .PARAMETER Manager
        The PSResourceGet manager record.
    .EXAMPLE
        Get-DFPSResourceInstalled -Manager $manager

        Returns current-user PowerShell resource versions.
    .OUTPUTS
        PSCustomObject with Id, Installed, and Available properties.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][pscustomobject]$Manager)

    try { $resources = @(Get-DFPSResourceInstalledRaw) } catch { return }
    if (-not $resources -or @($resources | Where-Object { $_.Name -isnot [string] -or -not $_.Name -or -not $_.Version }).Count) { return }
    foreach ($resource in $resources | Group-Object Name | ForEach-Object { $_.Group | Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1 }) {
        [pscustomobject]@{ Id = $resource.Name; Installed = [string]$resource.Version; Available = $null }
    }
}
