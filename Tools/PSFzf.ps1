# Companion for PSFzf — imports the module and configures its key bindings:
#   Ctrl+T  fzf file picker, inserts the path       Ctrl+R  fuzzy history search
#   Alt+C   fuzzy cd (through zoxide's z when zoxide is installed)
#   Tab     fuzzy tab completion (the completion stack decides the final Tab binding)
# plus fd for file listing and fuzzy scoop aliases. PSFzf declares
# "dependsOn": ["psreadline"], so psreadline.ps1's settings are applied first.
# Reads nothing from $DFConfig; writes no files.
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
}
