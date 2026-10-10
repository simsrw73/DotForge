#Requires -Version 7.2

function Find-DFTool {
    <#
    .SYNOPSIS
        Searches the DotForge tool registry by wildcard pattern across name,
        description, and tags.
    .DESCRIPTION
        Performs a case-insensitive wildcard search across each tool's name,
        description, and tags, and returns every record with at least one match.
        The pattern is wrapped in '*...*', so a plain word matches anywhere.
        Useful for discovering tools in the registry by keyword. Searches only
        DotForge's own tool records; to search package-manager catalogs, use
        Find-DFPackage. Read-only; changes nothing.
    .PARAMETER Pattern
        Text or wildcard pattern to match (e.g. 'rip', 'grep*', 'mark?own').
        Matched as '*<Pattern>*'. Optional when -Role is given.
    .PARAMETER Role
        Only tools that declare this role (see Get-DFRole), e.g. pager or
        listing. Combine with -Pattern to narrow further.
    .PARAMETER ToolsPath
        Read tool records from this directory instead of the module's Tools
        folder. Intended for tests.
    .EXAMPLE
        Find-DFTool 'grep'

        Returns all tools whose name, description, or tags contain 'grep'.
    .EXAMPLE
        Find-DFTool '*pager*' | Select-Object name

        Lists tool names that relate to paging.
    .EXAMPLE
        Find-DFTool -Role pager

        Lists every tool that can be the pager.
    .OUTPUTS
        PSCustomObject — matching tool registry records.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/tools.md
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Position = 0)][string]$Pattern,
        [string]$Role,
        [string]$ToolsPath
    )

    if (-not $Pattern -and -not $Role) {
        Write-Error 'Specify -Pattern, -Role, or both.' -ErrorAction Stop
        return
    }

    $dbArgs = if ($ToolsPath) { @{ ToolsPath = $ToolsPath } } else { @{} }
    $db = Import-DFToolDb @dbArgs

    $db.Values | Where-Object {
        (-not $Role -or $_.roles.PSObject.Properties[$Role]) -and
        (-not $Pattern -or
            $_.name -like "*$Pattern*" -or
            ($_.description -like "*$Pattern*") -or
            (@($_.tags) | Where-Object { $_ -like "*$Pattern*" }))
    }
}
