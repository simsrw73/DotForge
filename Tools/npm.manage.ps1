#Requires -Version 7.2

function Get-DFNpmInstalled {
    <#
    .SYNOPSIS
        Lists globally installed npm packages.
    .DESCRIPTION
        Queries the npm package manager for globally installed packages using
        `npm ls -g --depth=0 --json` and returns normalized package status objects.
    .PARAMETER Manager
        The manager's tool record.
    .EXAMPLE
        Get-DFNpmInstalled -Manager $script:Mgr

        Returns installed npm packages as [pscustomobject]@{ Id; Installed; Available }.
    .OUTPUTS
        [pscustomobject] -- Objects with Id, Installed, Available.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][pscustomobject]$Manager)

    $r = Invoke-DFManagerCommand -Operation list -Manager $Manager -Argv @('npm', 'ls', '-g', '--depth=0', '--json')
    # Exit codes are ignored: npm and pnpm exit 1 when something is outdated (and npm ls when the tree
    # has problems) while still printing valid JSON. Output that is not JSON gives no rows.
    if ([string]::IsNullOrWhiteSpace($r.Output)) { return @() }

    $json = $null
    try {
        $json = $r.Output | ConvertFrom-Json
    } catch {
        return @()
    }

    if (-not $json -or -not $json.dependencies) { return @() }

    $rows = [System.Collections.Generic.List[pscustomobject]]::new()
    foreach ($prop in $json.dependencies.PSObject.Properties) {
        $version = $null
        if ($prop.Value -and $prop.Value.PSObject.Properties['version']) {
            $version = [string]$prop.Value.version
        }
        $rows.Add([pscustomobject]@{
            Id        = [string]$prop.Name
            Installed = $version
            Available = $null
        })
    }
    $rows.ToArray()
}

function Get-DFNpmOutdated {
    <#
    .SYNOPSIS
        Lists outdated globally installed npm packages.
    .DESCRIPTION
        Queries the npm package manager for outdated packages using
        `npm outdated -g --json` and returns normalized package status objects.
    .PARAMETER Manager
        The manager's tool record.
    .EXAMPLE
        Get-DFNpmOutdated -Manager $script:Mgr

        Returns outdated npm packages as [pscustomobject]@{ Id; Installed; Available }.
    .OUTPUTS
        [pscustomobject] -- Objects with Id, Installed, Available.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][pscustomobject]$Manager)

    $r = Invoke-DFManagerCommand -Operation outdated -Manager $Manager -Argv @('npm', 'outdated', '-g', '--json')
    # Exit codes are ignored: npm and pnpm exit 1 when something is outdated (and npm ls when the tree
    # has problems) while still printing valid JSON. Output that is not JSON gives no rows.
    if ([string]::IsNullOrWhiteSpace($r.Output)) { return @() }

    $json = $null
    try {
        $json = $r.Output | ConvertFrom-Json
    } catch {
        return @()
    }

    if (-not $json) { return @() }

    $rows = [System.Collections.Generic.List[pscustomobject]]::new()
    foreach ($prop in $json.PSObject.Properties) {
        $installed = $null
        $available = $null
        if ($prop.Value) {
            if ($prop.Value.PSObject.Properties['current']) {
                $installed = [string]$prop.Value.current
            }
            if ($prop.Value.PSObject.Properties['latest']) {
                $available = [string]$prop.Value.latest
            }
        }
        $rows.Add([pscustomobject]@{
            Id        = [string]$prop.Name
            Installed = $installed
            Available = $available
        })
    }
    $rows.ToArray()
}