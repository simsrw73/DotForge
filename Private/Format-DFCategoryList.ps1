#Requires -Version 7.0

function Format-DFCategoryList {
    <#
    .SYNOPSIS
        Renders the taxonomy vocabulary (function/worksWith values, optionally
        with live tool counts from the db's facet index) as plain lines.
    .PARAMETER Database
        The category db (as returned by Get-DFCategoryDb).
    .PARAMETER Facet
        'function', 'worksWith', or $null for both.
    .PARAMETER Counts
        When true, appends each value's tool count from the facet index.
    .PARAMETER Color
        When false, plain text.
    .OUTPUTS
        System.String[]
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        $Database,

        [AllowNull()]
        [string]$Facet,

        [Parameter(Mandatory)]
        [bool]$Counts,

        [Parameter(Mandatory)]
        [bool]$Color
    )

    if (-not $Database.Raw) {
        return "Category database unavailable — run Update-DFCategoryDb or check the module install."
    }

    $bold = $Color ? "`e[1;36m" : ''
    $reset = $Color ? "`e[0m" : ''

    $facets = $Facet ? @($Facet) : @('function', 'worksWith')
    $lines = [System.Collections.Generic.List[string]]::new()

    foreach ($f in $facets) {
        $label = $f -eq 'function' ? 'Function' : 'WorksWith'
        $lines.Add("$bold$label$reset")
        $values = @($Database.Raw.taxonomy.$f) | Sort-Object
        foreach ($v in $values) {
            if ($Counts) {
                $count = @($Database.FacetIndex["${f}:$v"]).Count
                $lines.Add("  $v ($count)")
            } else {
                $lines.Add("  $v")
            }
        }
    }

    $lines
}
