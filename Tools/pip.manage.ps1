#Requires -Version 7.2

function Get-DFPipInstalled {
    <#
    .SYNOPSIS
        Lists packages installed by pip for the current user.
    .DESCRIPTION
        Runs pip through DotForge's manager-command seam and maps its JSON output to package rows.
    .PARAMETER Manager
        The pip manager record.
    .EXAMPLE
        Get-DFPipInstalled -Manager $manager

        Returns the current user's pip packages.
    .OUTPUTS
        PSCustomObject with Id, Installed, and Available properties.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][pscustomobject]$Manager)

    $result = Invoke-DFManagerCommand -Operation list -Manager $Manager -Argv @('pip', 'list', '--user', '--format=json')
    if ($result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($result.Output)) { return }
    try { $packages = @($result.Output | ConvertFrom-Json) } catch { return }
    if (-not $packages -or @($packages | Where-Object { $_.name -isnot [string] -or $_.version -isnot [string] -or -not $_.name -or -not $_.version }).Count) { return }
    foreach ($package in $packages) { [pscustomobject]@{ Id = $package.name; Installed = $package.version; Available = $null } }
}

function Get-DFPipOutdated {
    <#
    .SYNOPSIS
        Lists outdated pip packages for the current user.
    .DESCRIPTION
        Runs pip through DotForge's manager-command seam and maps its JSON output to package rows.
    .PARAMETER Manager
        The pip manager record.
    .EXAMPLE
        Get-DFPipOutdated -Manager $manager

        Returns current and available versions for outdated pip packages.
    .OUTPUTS
        PSCustomObject with Id, Installed, and Available properties.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][pscustomobject]$Manager)

    $result = Invoke-DFManagerCommand -Operation outdated -Manager $Manager -Argv @('pip', 'list', '--user', '--outdated', '--format=json')
    if ($result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($result.Output)) { return }
    try { $packages = @($result.Output | ConvertFrom-Json) } catch { return }
    if (-not $packages -or @($packages | Where-Object { $_.name -isnot [string] -or $_.version -isnot [string] -or $_.latest_version -isnot [string] -or -not $_.name -or -not $_.version -or -not $_.latest_version }).Count) { return }
    foreach ($package in $packages) { [pscustomobject]@{ Id = $package.name; Installed = $package.version; Available = $package.latest_version } }
}
