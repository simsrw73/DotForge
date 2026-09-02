# Companion for ripgrep — defines Select-RipgrepResult (frg)
# Dot-sourced by Register-DFTool when ripgrep is registered.

function global:Select-RipgrepResult {
    [CmdletBinding()]
    param(
        [string]$Pattern = '',
        [string]$Path    = '.'
    )

    if (-not $Pattern) { $Pattern = Read-Host 'Search pattern' }

    Invoke-DFPicker `
        -List          { rg --line-number --no-heading --color=always $Pattern $Path 2>$null } `
        -Preview       'Start-Sleep -Milliseconds 1000; bat --color=always --highlight-line {2} {1}' `
        -PreviewWindow 'right:60%' `
        -Delimiter     ':' `
        -Ansi `
        -Header        'Select result  [Enter to open in editor]' `
        -Parse         { ($_ -split ':')[0..1] -join ':' } `
        -Action        {
            param($v)
            $parts = $v -split ':'
            $file  = $parts[0]
            & $Env:EDITOR $file
        }
}
Set-Alias -Name frg -Value Select-RipgrepResult -Scope Global -Force
