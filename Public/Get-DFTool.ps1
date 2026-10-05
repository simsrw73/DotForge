#Requires -Version 7.0

function Get-DFTool {
    <#
    .SYNOPSIS
        Queries the DotForge tool registry.
    .DESCRIPTION
        Returns tool records from the JSON tool database (one per Tools/*.json
        file), whether or not the tool is installed. With no parameters, returns
        every known tool, in no particular order. Use -Name for an exact lookup
        or -Tag to filter by capability tag (e.g. 'fuzzy', 'prompt', 'git').

        Each record is the parsed JSON: name, executable, description, tags,
        packages, xdg, aliases, picker, and any other fields the tool declares.
        Read-only; changes nothing.
    .PARAMETER Name
        Return only the tool with this exact name (case-insensitive). Returns
        nothing when no tool matches.
    .PARAMETER Tag
        Return every tool whose tags include this exact value.
    .PARAMETER ToolsPath
        Read tool records from this directory instead of the module's Tools
        folder. Intended for tests.
    .EXAMPLE
        Get-DFTool -Name ripgrep

        Returns the tool record for ripgrep.
    .EXAMPLE
        Get-DFTool -Tag fuzzy

        Returns all tools tagged 'fuzzy' (fzf, PSFzf, etc.).
    .EXAMPLE
        Get-DFTool | Select-Object name, description

        Lists all registered tools with their descriptions.
    .OUTPUTS
        PSCustomObject — one or more tool registry records.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/tools.md
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
            $results = $results | Where-Object { $_.tags -contains $Tag }
        }
    }

    $results
}
