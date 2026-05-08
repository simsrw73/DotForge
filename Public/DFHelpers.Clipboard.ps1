#Requires -Version 7.0

function Copy-DFToClipboard {
    <#
    .SYNOPSIS
        Copies pipeline input to the system clipboard (copy equivalent).
    .PARAMETER InputObject
        String values piped in from the pipeline.
    .EXAMPLE
        Get-Content file.txt | Copy-DFToClipboard
    .EXAMPLE
        git log --oneline | copy
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
Set-Alias -Name copy -Value Copy-DFToClipboard -Scope Global -Force -Option AllScope

function Get-DFFromClipboard {
    <#
    .SYNOPSIS
        Retrieves the current contents of the system clipboard (paste equivalent).
    .EXAMPLE
        Get-DFFromClipboard
    .EXAMPLE
        paste
    #>
    [CmdletBinding()]
    param()
    Get-Clipboard
}
Set-Alias -Name paste -Value Get-DFFromClipboard -Scope Global -Force
