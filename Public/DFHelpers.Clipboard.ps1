#Requires -Version 7.0

function Copy-DFToClipboard {
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
    [CmdletBinding()]
    param()
    Get-Clipboard
}
Set-Alias -Name paste -Value Get-DFFromClipboard -Scope Global -Force
