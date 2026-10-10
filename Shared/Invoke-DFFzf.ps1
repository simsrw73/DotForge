#Requires -Version 7.0

function Invoke-DFFzf {
    <#
    .SYNOPSIS
        Thin wrapper around fzf (or the picker named in $Env:Picker).
        Exists as a separate function so tests can mock it without spawning fzf.
        Set $Env:Picker = 'skim' (or any fzf-compatible picker) to override the default.
    .PARAMETER InputItems
        Items to pipe into the picker.
    .PARAMETER FzfArgs
        Arguments array forwarded to the picker.
    #>
    [CmdletBinding()]
    param(
        [string[]]$InputItems,
        [string[]]$FzfArgs
    )

    [string] $picker = if ($Env:Picker) { $Env:Picker } else { 'fzf' }
    if (-not (Get-Command $picker -ErrorAction Ignore)) {
        Write-Error "DotForge: '$picker' is not on PATH. Install fzf or set `$Env:Picker to your picker's executable name." -ErrorAction Stop
    }
    $InputItems | & $picker @FzfArgs
}
