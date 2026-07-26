#Requires -Version 7.0

function Copy-DFToClipboard {
    <#
    .SYNOPSIS
        Copies pipeline input to the system clipboard (copy equivalent).
    .PARAMETER InputObject
        String values piped in from the pipeline.
    .DESCRIPTION
        Collects all pipeline strings and joins them with newlines before writing
        to the clipboard, so multi-line pipeline output is preserved as a single
        clipboard entry rather than overwriting line by line.
    .EXAMPLE
        Get-Content file.txt | Copy-DFToClipboard
        Copies the entire file contents to the clipboard.
    .EXAMPLE
        git log --oneline | yank
        Copies the git log output to the clipboard using the yank alias.
    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromPipeline)]
        [string]$InputObject
    )
    begin   { $lines = [System.Collections.Generic.List[string]]@() }
    process { if ($null -ne $InputObject) { $lines.Add($InputObject) } }
    end     { Set-Clipboard -Value ($lines -join "`n") }
}
Set-Alias -Name yank -Value Copy-DFToClipboard

function Get-DFFromClipboard {
    <#
    .SYNOPSIS
        Retrieves the current contents of the system clipboard (paste equivalent).
    .DESCRIPTION
        Thin wrapper around Get-Clipboard that provides a memorable alias (paste)
        consistent with the copy/paste convention established by Copy-DFToClipboard.
    .EXAMPLE
        Get-DFFromClipboard
        Outputs the current clipboard contents to the terminal.
    .EXAMPLE
        paste | Set-Content output.txt
        Writes clipboard contents to a file using the paste alias.
    .OUTPUTS
        System.String — the current clipboard text.
    #>
    [CmdletBinding()]
    param()
    Get-Clipboard
}
Set-Alias -Name paste -Value Get-DFFromClipboard -Scope Global -Force
