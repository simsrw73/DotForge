#Requires -Version 7.2

function Get-DFChocoRows {
    param([pscustomobject]$Result, [switch]$Outdated)
    # choco outdated exits 2 when it finds outdated packages (enhanced exit codes); only a real failure stops parsing.
    $ok = $Result.ExitCode -eq 0 -or ($Outdated -and $Result.ExitCode -eq 2)
    if (-not $ok -or [string]::IsNullOrWhiteSpace($Result.Output)) { return }
    foreach ($line in $Result.Output -split "`r?`n") {
        $parts = $line -split '\|'
        if ((-not $Outdated -and $parts.Count -eq 2) -or ($Outdated -and $parts.Count -ge 3)) {
            if ($parts[0] -and $parts[1] -and (-not $Outdated -or $parts[2])) {
                [pscustomobject]@{ Id = $parts[0]; Installed = $parts[1]; Available = $(if ($Outdated) { $parts[2] } else { $null }) }
            }
        }
    }
}

function Get-DFChocoInstalled {
    <#
    .SYNOPSIS
        Lists packages installed by Chocolatey.
    .DESCRIPTION
        Runs Chocolatey through DotForge's manager command seam and parses limit output.
    .PARAMETER Manager
        The Chocolatey manager tool record.
    .EXAMPLE
        Get-DFChocoInstalled -Manager $manager

        Returns Chocolatey package ids and installed versions.
    .OUTPUTS
        PSCustomObject with Id, Installed, and Available.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][pscustomobject]$Manager)
    Get-DFChocoRows (Invoke-DFManagerCommand -Operation list -Manager $Manager -Argv @('choco', 'list', '--limit-output'))
}

function Get-DFChocoOutdated {
    <#
    .SYNOPSIS
        Lists Chocolatey packages with available updates.
    .DESCRIPTION
        Runs Chocolatey through DotForge's manager command seam and parses limit output.
    .PARAMETER Manager
        The Chocolatey manager tool record.
    .EXAMPLE
        Get-DFChocoOutdated -Manager $manager

        Returns Chocolatey package ids with installed and available versions.
    .OUTPUTS
        PSCustomObject with Id, Installed, and Available.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][pscustomobject]$Manager)
    Get-DFChocoRows (Invoke-DFManagerCommand -Operation outdated -Manager $Manager -Argv @('choco', 'outdated', '--limit-output')) -Outdated
}
