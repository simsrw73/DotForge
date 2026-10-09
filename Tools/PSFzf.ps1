# Companion for PSFzf — imports the module and configures its key bindings:
#   Ctrl+T  fzf file picker, inserts the path       Ctrl+R  fuzzy history search
#   Alt+C   fuzzy cd (through zoxide's z when zoxide is installed)
#   Tab     fuzzy tab completion (when PSFzf wins tab-completion)
# plus fd for file listing and fuzzy scoop aliases. PSFzf declares
# "after": ["psreadline"], so psreadline.ps1's settings are applied first.
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

function Enable-DFFzfAnsiOption {
    <#
    .SYNOPSIS
        Appends --ansi to FZF_DEFAULT_OPTS unless it is already present.
    .DESCRIPTION
        Carapace produces ANSI-styled list items. PSFzf uses fzf to display
        them, so fzf needs --ansi to render them rather than show raw escapes.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param()
    $existing = [string]$Env:FZF_DEFAULT_OPTS
    foreach ($tok in ($existing -split '\s+')) { if ($tok -ceq '--ansi') { return } }
    $Env:FZF_DEFAULT_OPTS = if ($existing) { "$existing --ansi" } else { '--ansi' }
}

function Initialize-DFRoleTabCompletion {
    param($Tool, $Role)
    if (Get-Command carapace -ErrorAction Ignore) { Enable-DFFzfAnsiOption }
    Set-PSReadLineKeyHandler -Key Tab -ScriptBlock { Invoke-FzfTabCompletion }
}
