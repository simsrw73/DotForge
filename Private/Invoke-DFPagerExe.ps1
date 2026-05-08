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
        Arguments with spaces (e.g. --theme "Dracula") are not supported; use
        --key=value form instead (e.g. --theme=Dracula).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Lines,
        [Parameter(Mandatory)][string]$Pager
    )
    if ($Pager -match '["\x27]') {
        Write-Warning "DotForge: Quoted arguments in `$Env:Pager are not supported. Use --key=value form (e.g. bat --theme=Dracula)."
    }
    $parts                  = $Pager -split '\s+', 2
    [string[]] $pagerArgs  = if ($parts.Count -gt 1) { $parts[1] -split '\s+' } else { }
    $Lines | & $parts[0] @pagerArgs
}
