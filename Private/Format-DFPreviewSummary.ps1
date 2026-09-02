function Format-DFPreviewSummary {
    <#
    .SYNOPSIS
        Prepends a label/value summary block above a body of fzf preview text.
    .DESCRIPTION
        Given an ordered set of labels to values (a value may be $null or empty
        to mean "not found for this item"), renders only the populated labels as
        "Label: value" lines, followed by a blank line, a separator, another
        blank line, and the original body. If no label has a value, returns the
        body unchanged — used by the winget/scoop/choco preview scripts so a
        tool's undocumented output format changing upstream degrades to plain
        passthrough instead of an error or a garbled summary.
    .PARAMETER Fields
        Ordered dictionary of label -> value, in display order. Null/empty
        values are skipped.
    .PARAMETER Body
        The original preview text, as an array of lines.
    .EXAMPLE
        Format-DFPreviewSummary -Fields ([ordered]@{ Name = 'git'; Version = $null }) -Body @('raw', 'output')
        Renders "Name: git", a separator, then "raw"/"output" — Version is omitted since its value is $null.
    .OUTPUTS
        System.String[] — the combined preview text, one element per line.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary]$Fields,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Body
    )

    $summaryLines = foreach ($label in $Fields.Keys) {
        $value = $Fields[$label]
        if ($value) { "${label}: $value" }
    }

    if (-not $summaryLines) { return $Body }

    @($summaryLines) + '' + ('-' * 40) + '' + $Body
}
