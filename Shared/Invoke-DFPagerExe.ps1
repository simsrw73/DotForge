#Requires -Version 7.2

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
    # A double-quoted argument stays whole (DotForge quotes a path with a space, such as
    # ov's --config); single quotes aren't understood.
    if ($rest -match "\x27") {
        Write-Warning "DotForge: Single-quoted arguments in `$Env:Pager are not supported. Use double quotes or --key=value form (e.g. bat --theme=Dracula)."
    }
    [string[]] $pagerArgs = @([regex]::Matches($rest, '"([^"]*)"|(\S+)') | ForEach-Object {
        if ($_.Groups[1].Success) { $_.Groups[1].Value } else { $_.Groups[2].Value }
    })
    $Lines | & $program @pagerArgs
}
