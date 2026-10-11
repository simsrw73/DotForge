#Requires -Version 7.2

function Get-DFBunInstalled {
    <#
    .SYNOPSIS
        Lists globally installed bun packages.
    .DESCRIPTION
        Queries the bun package manager for globally installed packages using
        `bun pm ls -g` and returns normalized package status objects.
    .PARAMETER Manager
        The manager's tool record.
    .EXAMPLE
        Get-DFBunInstalled -Manager $script:Mgr

        Returns installed bun packages as [pscustomobject]@{ Id; Installed; Available }.
    .OUTPUTS
        [pscustomobject] -- Objects with Id, Installed, Available.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][pscustomobject]$Manager)

    $r = Invoke-DFManagerCommand -Operation list -Manager $Manager -Argv @('bun', 'pm', 'ls', '-g')
    if ($r.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($r.Output)) { return @() }

    $lines = $r.Output -split '\r?\n'
    $rows = [System.Collections.Generic.List[pscustomobject]]::new()

    foreach ($line in $lines) {
        $trimmed = $line.Trim() -replace '^[^\w@]+'
        $idx = $trimmed.LastIndexOf('@')
        if ($idx -gt 0) {
            $id = $trimmed.Substring(0, $idx)
            $installed = $trimmed.Substring($idx + 1)
            if ($installed -notmatch '\s') {
                $rows.Add([pscustomobject]@{
                    Id        = $id
                    Installed = $installed
                    Available = $null
                })
            }
        }
    }

    $rows.ToArray()
}