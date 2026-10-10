#Requires -Version 7.0

function Copy-DFToClipboard {
    <#
    .SYNOPSIS
        Copies pipeline input to the system clipboard (copy equivalent).
    .DESCRIPTION
        Collects all input and joins it with LF newlines before writing to the
        clipboard, so multi-line pipeline output is preserved as a single
        clipboard entry rather than overwriting line by line. Objects are
        converted with their default ToString(), not their formatted table view:
        pipe through Out-String first to copy what you see on screen. Replaces
        the clipboard's current contents.

        Named yank, not copy: copy is a built-in PowerShell alias for Copy-Item,
        and DotForge never overrides built-ins.
    .PARAMETER InputObject
        Text to copy, from the pipeline or as the first argument.
    .EXAMPLE
        Get-Content file.txt | Copy-DFToClipboard

        Copies the entire file contents to the clipboard.
    .EXAMPLE
        git log --oneline | yank

        Copies the git log output to the clipboard using the yank alias.
    .EXAMPLE
        Get-Process | Select-Object -First 5 | Out-String | yank

        Copies a formatted table, as it would appear on screen.
    .OUTPUTS
        None. Replaces the clipboard contents.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/pickers-and-helpers.md
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
function Get-DFFromClipboard {
    <#
    .SYNOPSIS
        Retrieves the current contents of the system clipboard (paste equivalent).
    .DESCRIPTION
        Thin wrapper around Get-Clipboard that provides a memorable alias (paste)
        consistent with the yank/paste pair established by Copy-DFToClipboard.
        Returns one string per line of clipboard text, or nothing when the
        clipboard holds no text. Read-only.

        If Coreutils for Windows is installed, its own paste can shadow this
        alias at the prompt; see Get-DFCommandConflict.
    .EXAMPLE
        Get-DFFromClipboard

        Outputs the current clipboard contents to the terminal.
    .EXAMPLE
        paste | Set-Content output.txt

        Writes clipboard contents to a file using the paste alias.
    .OUTPUTS
        System.String — the current clipboard text.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/pickers-and-helpers.md
    #>
    [CmdletBinding()]
    param()
    Get-Clipboard
}
