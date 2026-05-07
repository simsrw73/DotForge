#Requires -Version 7.0

function Find-DFTool {
    <#
    .SYNOPSIS
        Searches the DotForge tool registry by wildcard pattern across name,
        description, and tags.
    .PARAMETER Pattern
        Wildcard pattern to match (e.g. 'rip', 'grep*', '*viewer*').
    .PARAMETER ToolsPath
        Override the tools directory (used in tests).
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][string]$Pattern,
        [string]$ToolsPath
    )

    $dbArgs = if ($ToolsPath) { @{ ToolsPath = $ToolsPath } } else { @{} }
    $db = Import-DFToolDb @dbArgs

    $db.Values | Where-Object {
        $_.name -like "*$Pattern*" -or
        ($_.PSObject.Properties['description']?.Value -like "*$Pattern*") -or
        (@($_.PSObject.Properties['tags']?.Value) | Where-Object { $_ -like "*$Pattern*" })
    }
}
