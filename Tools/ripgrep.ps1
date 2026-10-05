# Companion for ripgrep — defines Select-RipgrepResult (frg)
# Dot-sourced by Register-DFTool when ripgrep is registered.

function global:Select-RipgrepResult {
    <#
    .SYNOPSIS
        Searches files with ripgrep, fuzzy-picks a match, and opens its file in $Env:EDITOR.
    .DESCRIPTION
        Runs rg --line-number over -Path and lists every matching line in fzf,
        previewing the file with the match highlighted (the preview uses bat).
        Enter opens the selected file in $Env:EDITOR. Only the file is passed
        to the editor, not the line number. Esc does nothing.

        Defined by DotForge's ripgrep companion; requires rg, fzf (or
        $Env:Picker) and, for the preview, bat. $Env:EDITOR must be set to a
        single command name or path.
    .PARAMETER Pattern
        The ripgrep regular expression to search for. When omitted, you are
        prompted for it.
    .PARAMETER Path
        File or directory to search. Default: the current directory.
    .EXAMPLE
        frg 'TODO'

        Lists every TODO under the current directory; Enter opens the file.
    .EXAMPLE
        frg 'function\s+Get-' -Path ./Public

        Searches only the Public folder with a regular expression.
    .OUTPUTS
        None.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/tools.md
    #>
    [CmdletBinding()]
    param(
        [string]$Pattern = '',
        [string]$Path    = '.'
    )

    if (-not $Pattern) { $Pattern = Read-Host 'Search pattern' }

    Invoke-DFPicker `
        -List          { rg --line-number --no-heading --color=always $Pattern $Path 2>$null } `
        -Preview       'bat --color=always --highlight-line {2} {1}' `
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
