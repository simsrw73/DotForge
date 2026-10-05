# Companion for procs — defines Select-Process (fkill)
# Dot-sourced by Register-DFTool when procs is registered.

function global:Select-Process {
    <#
    .SYNOPSIS
        Fuzzy-picks a running process from procs' colored table and stops it.
    .DESCRIPTION
        Lists processes with procs --color=always in fzf. Enter runs
        Stop-Process -Confirm on the selected PID, so PowerShell asks before
        anything is stopped. Esc does nothing. Stopping another user's or an
        elevated process needs an elevated shell.

        Defined by DotForge's procs companion; requires procs and fzf (or
        $Env:Picker). For a picker that returns process objects instead of
        stopping them, use Select-DFProcess (fps).
    .EXAMPLE
        fkill

        Opens the process picker; Enter asks to stop the highlighted process.
    .OUTPUTS
        None.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/tools.md
    #>
    [CmdletBinding()]
    param()

    Invoke-DFPicker `
        -List          { procs --color=always 2>$null | Select-Object -Skip 1 } `
        -PreviewWindow 'hidden' `
        -Ansi `
        -Header        'Select process  [Enter to Stop-Process]' `
        -Parse         { ($_ -split '\s+')[1] } `
        -Action        {
            param($procId)
            if ($procId -match '^\d+$') {
                Stop-Process -Id $procId -Confirm
            }
        }
}
Set-Alias -Name fkill -Value Select-Process -Scope Global -Force
