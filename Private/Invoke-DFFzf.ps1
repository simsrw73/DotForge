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

    if (-not (Get-Command fzf -ErrorAction Ignore)) {
        Write-Error 'fzf is not installed or not on PATH. Install it (e.g. scoop install fzf).' -ErrorAction Stop
    }
    $InputItems | fzf @FzfArgs
}
