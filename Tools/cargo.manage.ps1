#Requires -Version 7.2

function Get-DFCargoInstalled {
    <#
    .SYNOPSIS
        Lists crates installed by cargo.
    .DESCRIPTION
        Runs cargo through DotForge's manager-command seam and maps install-list headings to package rows.
    .PARAMETER Manager
        The cargo manager record.
    .EXAMPLE
        Get-DFCargoInstalled -Manager $manager

        Returns installed cargo crate versions.
    .OUTPUTS
        PSCustomObject with Id, Installed, and Available properties.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][pscustomobject]$Manager)

    $result = Invoke-DFManagerCommand -Operation list -Manager $Manager -Argv @('cargo', 'install', '--list')
    if ($result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($result.Output)) { return }
    $rows = foreach ($line in $result.Output -split "`r?`n" | Where-Object { $_.Trim() }) {
        if ($line -match '^\s') { continue }
        if ($line -notmatch '^(?<Id>\S+) v(?<Version>[^\s:]+)(?:\s.*)?:$') { return }
        [pscustomobject]@{ Id = $Matches.Id; Installed = $Matches.Version; Available = $null }
    }
    $rows
}
