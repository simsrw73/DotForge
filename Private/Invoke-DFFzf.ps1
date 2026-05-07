#Requires -Version 7.0

function Invoke-DFFzf {
    <#
    .SYNOPSIS
        Thin wrapper around the fzf external command.
        Exists as a separate function so tests can mock it without spawning fzf.
    .PARAMETER InputItems
        Items to pipe into fzf.
    .PARAMETER FzfArgs
        Arguments array forwarded to fzf.
    #>
    [CmdletBinding()]
    param(
        [string[]]$InputItems,
        [string[]]$FzfArgs
    )

    $InputItems | fzf @FzfArgs
}
