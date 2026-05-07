# Companion for procs — defines Select-Process (fkill)
# Dot-sourced by Register-DFTool when procs is registered.

function global:Select-Process {
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
