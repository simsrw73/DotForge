#Requires -Version 7.0

function Invoke-DFPagerExe {
    <#
    .SYNOPSIS
        Thin wrapper around an external pager command.
        Exists as a separate function so tests can mock it without spawning a real pager.
    .PARAMETER Lines
        Lines of text to pipe into the pager.
    .PARAMETER Pager
        The pager command string (e.g. 'less', 'less -R', 'bat --paging=always').
    #>
    param(
        [Parameter(Mandatory)][string[]]$Lines,
        [Parameter(Mandatory)][string]$Pager
    )
    $parts     = $Pager -split '\s+', 2
    $pagerArgs = if ($parts.Count -gt 1) { $parts[1] -split '\s+' } else { @() }
    $Lines | & $parts[0] @pagerArgs
}
