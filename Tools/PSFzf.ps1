# Companion for PSFzf — import module and configure PSReadLine key bindings
Import-Module PSFzf -ErrorAction SilentlyContinue

if (Get-Module -Name PSFzf) {
    Set-PsFzfOption -EnableFd

    Set-PsFzfOption `
        -PSReadlineChordProvider 'Ctrl+t' `
        -PSReadlineChordReverseHistory 'Ctrl+r'

    $ZoxideAltCScriptBlock = [ScriptBlock]{
        $selectedDir = zoxide query -l | Invoke-PoshFzfStartProcess -FileName "fzf" -Arguments @("--height=40%", "--layout=reverse") -HeightRowsOrPercent "40%"

        if ($selectedDir) {
            if (Get-Command "__zoxide_z" -ErrorAction SilentlyContinue) {
                __zoxide_z $selectedDir
            } else {
                Set-Location $selectedDir
            }

            # Clear the current line and redraw prompt cleanly
            [Microsoft.PowerShell.PSConsoleReadLine]::DeleteLine()
            [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine()
        }
    }

    Set-PsFzfOption -AltCCommand $ZoxideAltCScriptBlock

    Set-PsFzfOption -EnableAliasFuzzyScoop
    Set-PsFzfOption -TabExpansion
}
