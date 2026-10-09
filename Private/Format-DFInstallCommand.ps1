#Requires -Version 7.0

function Format-DFInstallCommand {
    <#
    .SYNOPSIS
        A manager's install command as one line of text, for a picker, a catalog hint, or the plan.
    .PARAMETER Manager
        The manager's tool record (has installs).
    .PARAMETER Id
        The package id. Omitted: {0} stands in for it (a format string).
    .PARAMETER Feed
        A feed name; the id is then formed by installs.feeds.id.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][pscustomobject]$Manager, [string]$Id, [string]$Feed)
    $i = $Manager.installs
    $idText = if ($Id) { $Id } else { '{0}' }
    if ($Feed -and $i.feeds) { $idText = $i.feeds.id.Replace('{feed}', $Feed).Replace('{id}', $idText) }
    if ($i.function) {
        # A [bool] argument is a switch: -TrustRepository.
        $fnArgs = @(foreach ($p in $i.args.PSObject.Properties) {
            if ($p.Value -is [bool]) { if ($p.Value) { "-$($p.Name)" } }
            elseif ($p.Value -eq '{id}') { "-$($p.Name) $idText" }
            else { "-$($p.Name) $($p.Value)" }
        })
        return (@($i.function) + $fnArgs) -join ' '
    }
    (@($i.command | ForEach-Object { if ($_ -eq '{id}') { $idText } else { $_ } })) -join ' '
}

function Get-DFInstallHint {
    <#
    .SYNOPSIS
        The command that installs one catalog package, from the best manager for its source.
    .PARAMETER Source
        The catalog source (scoop, winget, choco, npm, crates, psgallery).
    .PARAMETER Id
        The package id.
    .PARAMETER Feed
        The feed (e.g. a scoop bucket), when the id needs one.
    .OUTPUTS
        System.String, or nothing when no manager installs from the source.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Id, [string]$Feed)
    $m = Get-DFSourceManager -Source $Source -ToolDb (Import-DFToolDb) | Select-Object -First 1
    if ($m) { Format-DFInstallCommand -Manager $m -Id $Id -Feed $Feed }
}
