#Requires -Version 7.2

function Get-DFPipxInstalled {
    <#
    .SYNOPSIS
        Lists packages installed by pipx.
    .DESCRIPTION
        Runs pipx through DotForge's manager-command seam and maps its JSON output to package rows.
    .PARAMETER Manager
        The pipx manager record.
    .EXAMPLE
        Get-DFPipxInstalled -Manager $manager

        Returns pipx environments and their main-package versions.
    .OUTPUTS
        PSCustomObject with Id, Installed, and Available properties.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][pscustomobject]$Manager)

    $result = Invoke-DFManagerCommand -Operation list -Manager $Manager -Argv @('pipx', 'list', '--json')
    if ($result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($result.Output)) { return }
    try { $venvs = ($result.Output | ConvertFrom-Json).venvs } catch { return }
    if (-not $venvs) { return }
    $rows = foreach ($property in $venvs.PSObject.Properties) {
        $version = $property.Value.metadata.main_package.package_version
        if ($property.Name -isnot [string] -or $version -isnot [string] -or -not $property.Name -or -not $version) { return }
        [pscustomobject]@{ Id = $property.Name; Installed = $version; Available = $null }
    }
    $rows
}
