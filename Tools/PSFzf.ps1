# Companion for PSFzf — import module and configure PSReadLine key bindings
# PSReadline.ps1 must have already removed the default Ctrl+T/R handlers before this runs.
Import-Module PSFzf -ErrorAction SilentlyContinue

if (Get-Module -Name PSFzf) {
    Set-PsFzfOption -EnableFd

    Set-PsFzfOption `
        -PSReadlineChordProvider       'Ctrl+t' `
        -PSReadlineChordReverseHistory 'Ctrl+r'

    $commandOverride = [ScriptBlock] { param($Location) Set-Location $Location }
    Set-PsFzfOption -AltCCommand $commandOverride

    Set-PsFzfOption -EnableAliasFuzzyScoop
    Set-PsFzfOption -TabExpansion
    Set-PSReadLineKeyHandler -Key Tab -ScriptBlock { Invoke-FzfTabCompletion }
}
