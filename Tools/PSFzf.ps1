# Companion for PSFzf — imports the module and configures its key bindings:
#   Ctrl+T  fzf file picker (when PSFzf wins path-insert)   Ctrl+R  history (when it wins history-search)
#   Alt+A   fuzzy pick from the arguments in your history
#   Tab     fuzzy tab completion (when PSFzf wins tab-completion)
# plus fd for file listing and fuzzy scoop aliases. PSFzf declares
# "after": ["psreadline"], so psreadline.ps1's settings are applied first.
# Reads nothing from $DFConfig; writes no files.
# Without its own Ctrl+T/Ctrl+R: importing PSFzf binds them, and the history-search and
# path-insert hooks below bind them only when PSFzf wins (the chords are positional
# module parameters; '' skips one). Alt+C belongs to the directory-jump role (fzf,
# skim or broot), so PSFzf doesn't bind it either. Alt+A keeps its default.
Import-Module PSFzf -ArgumentList '', '', '', 'Alt+a' -ErrorAction SilentlyContinue

if (Get-Module -Name PSFzf) {
    Set-PsFzfOption -EnableFd


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
    # Through Set-DFEnv, so DotForge's record matches and a later theme switch doesn't warn.
    $value = if ($existing) { "$existing --ansi" } else { '--ansi' }
    Set-DFEnv -Name 'FZF_DEFAULT_OPTS' -Value $value -Tool 'PSFzf' -ExplicitReason "Carapace's colored completions need --ansi"
}

function Initialize-DFRoleTabCompletion {
    param($Tool, $Role)
    # Startup already probed carapace (Test-DFToolAvailable remembers it); don't look it up again.
    if (Test-DFToolAvailable -Executable 'carapace.exe') { Enable-DFFzfAnsiOption }
    Set-PSReadLineKeyHandler -Key Tab -ScriptBlock { Invoke-FzfTabCompletion }
}

function Initialize-DFRoleHistorySearch {
    param($Tool, $Role)
    if (-not (Get-Module -Name PSFzf)) { return }
    Set-DFRoleKeyHandler -Role $Role -Chord 'Ctrl+r' -Tool $Tool.name -Bind { Set-PsFzfOption -PSReadlineChordReverseHistory 'Ctrl+r' }
}

function Initialize-DFRolePathInsert {
    param($Tool, $Role)
    if (-not (Get-Module -Name PSFzf)) { return }
    Set-DFRoleKeyHandler -Role $Role -Chord 'Ctrl+t' -Tool $Tool.name -Bind { Set-PsFzfOption -PSReadlineChordProvider 'Ctrl+t' }
}
