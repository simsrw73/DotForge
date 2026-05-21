# Companion for PSFzf — import module and configure PSReadLine key bindings
Import-Module PSFzf -ErrorAction SilentlyContinue

if (Get-Module -Name PSFzf) {
    Set-PsFzfOption -EnableFd

    Set-PsFzfOption `
        -PSReadlineChordProvider 'Ctrl+t' `
        -PSReadlineChordReverseHistory 'Ctrl+r'

    $commandOverride = [ScriptBlock] {
        param($Location)
        if (Get-Command -Name zoxide.exe -ErrorAction SilentlyContinue) {
            z $Location
        } else {
            Set-Location $Location
        }
    }
    Set-PsFzfOption -AltCCommand $commandOverride

    Set-PsFzfOption -EnableAliasFuzzyScoop
    Set-PsFzfOption -TabExpansion
    Set-PSReadLineKeyHandler -Key Tab -ScriptBlock { Invoke-FzfTabCompletion }
}
