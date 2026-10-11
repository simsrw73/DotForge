#Requires -Version 7.2

function Get-DFPnpmInstalled {
    <#
    .SYNOPSIS
        Lists globally installed pnpm packages.
    .DESCRIPTION
        Queries the pnpm package manager for globally installed packages using
        `pnpm ls -g --json` and returns normalized package status objects.
    .PARAMETER Manager
        The manager's tool record.
    .EXAMPLE
        Get-DFPnpmInstalled -Manager $script:Mgr

        Returns installed pnpm packages as [pscustomobject]@{ Id; Installed; Available }.
    .OUTPUTS
        [pscustomobject] -- Objects with Id, Installed, Available.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][pscustomobject]$Manager)

    $r = Invoke-DFManagerCommand -Operation list -Manager $Manager -Argv @('pnpm', 'ls', '-g', '--json')
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
    $projects = if ($json -is [array]) { $json } else { @($json) }
    foreach ($proj in $projects) {
        if ($proj -and $proj.PSObject.Properties['dependencies'] -and $proj.dependencies) {
            foreach ($prop in $proj.dependencies.PSObject.Properties) {
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
        } elseif ($proj -and $proj.PSObject.Properties['name'] -and $proj.PSObject.Properties['version']) {
            $rows.Add([pscustomobject]@{
                Id        = [string]$proj.name
                Installed = [string]$proj.version
                Available = $null
            })
        }
    }
    $rows.ToArray()
}

function Get-DFPnpmOutdated {
    <#
    .SYNOPSIS
        Lists outdated globally installed pnpm packages.
    .DESCRIPTION
        Queries the pnpm package manager for outdated packages using
        `pnpm outdated -g --format json` and returns normalized package status objects.
    .PARAMETER Manager
        The manager's tool record.
    .EXAMPLE
        Get-DFPnpmOutdated -Manager $script:Mgr

        Returns outdated pnpm packages as [pscustomobject]@{ Id; Installed; Available }.
    .OUTPUTS
        [pscustomobject] -- Objects with Id, Installed, Available.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][pscustomobject]$Manager)

    $r = Invoke-DFManagerCommand -Operation outdated -Manager $Manager -Argv @('pnpm', 'outdated', '-g', '--format', 'json')
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