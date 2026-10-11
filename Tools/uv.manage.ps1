#Requires -Version 7.2

function Get-DFUvInstalled {
    <#
    .SYNOPSIS
        Lists tools installed by uv.
    .DESCRIPTION
        Runs uv through DotForge's manager-command seam and maps tool-list rows to package rows.
    .PARAMETER Manager
        The uv manager record.
    .EXAMPLE
        Get-DFUvInstalled -Manager $manager

        Returns uv-managed tool versions.
    .OUTPUTS
        PSCustomObject with Id, Installed, and Available properties.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][pscustomobject]$Manager)

    $result = Invoke-DFManagerCommand -Operation list -Manager $Manager -Argv @('uv', 'tool', 'list')
    if ($result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($result.Output)) { return }
    $rows = foreach ($line in $result.Output -split "`r?`n" | Where-Object { $_.Trim() -and $_ -notmatch '^- ' }) {
        if ($line -notmatch '^(?<Id>\S+) v(?<Version>\S+)$') { return }
        [pscustomobject]@{ Id = $Matches.Id; Installed = $Matches.Version; Available = $null }
    }
    $rows
}
