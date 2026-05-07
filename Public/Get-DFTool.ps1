#Requires -Version 7.0

function Get-DFTool {
    <#
    .SYNOPSIS
        Queries the DotForge tool registry.
    .PARAMETER Name
        Return the tool with this exact name.
    .PARAMETER Tag
        Return all tools that have this tag.
    .PARAMETER ToolsPath
        Override the tools directory (used in tests).
    #>
    [CmdletBinding(DefaultParameterSetName = 'All')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(ParameterSetName = 'ByName')][string]$Name,
        [Parameter(ParameterSetName = 'ByTag')][string]$Tag,
        [string]$ToolsPath
    )

    $dbArgs = if ($ToolsPath) { @{ ToolsPath = $ToolsPath } } else { @{} }
    $db = Import-DFToolDb @dbArgs
    $results = $db.Values

    switch ($PSCmdlet.ParameterSetName) {
        'ByName' { $results = $results | Where-Object { $_.name -eq $Name } }
        'ByTag'  {
            $results = $results | Where-Object {
                $tags = $_.PSObject.Properties['tags']?.Value
                $tags -and ($tags -contains $Tag)
            }
        }
    }

    $results
}
