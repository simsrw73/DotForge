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
        A double-quoted program path may come first (a path with spaces).
        Quoted arguments (e.g. --theme "Dracula") are not supported; use
        --key=value form instead (e.g. --theme=Dracula).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Lines,
        [Parameter(Mandatory)][string]$Pager
    )
    # A leading double-quoted program path (what ${DF_TOOL_EXE} produces for a
    # path with spaces) is the program; the rest splits on whitespace.
    if ($Pager -match '^\s*"([^"]+)"\s*(.*)$') {
        $program = $Matches[1]
        $rest    = $Matches[2]
    } else {
        $parts   = $Pager.Trim() -split '\s+', 2
        $program = $parts[0]
        $rest    = if ($parts.Count -gt 1) { $parts[1] } else { '' }
    }
    if ($rest -match '["\x27]') {
        Write-Warning "DotForge: Quoted arguments in `$Env:Pager are not supported. Use --key=value form (e.g. bat --theme=Dracula)."
    }
    [string[]] $pagerArgs = if ($rest) { $rest -split '\s+' } else { @() }
    $Lines | & $program @pagerArgs
}
