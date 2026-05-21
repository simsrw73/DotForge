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
    .DESCRIPTION
        Performs a wildcard search across each tool's name, description, and tags.
        Useful for discovering tools in the registry by keyword.
    .EXAMPLE
        Find-DFTool 'grep'
        Returns all tools whose name, description, or tags contain 'grep'.
    .EXAMPLE
        Find-DFTool '*pager*' | Select-Object name
        Lists tool names that relate to paging.
    .OUTPUTS
        PSCustomObject — matching tool registry records.
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
