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
        The original preview text, as an array of lines. A $null or empty-string
        element anywhere in the array is tolerated (rendered as a single-space
        line) rather than throwing — real, undocumented tool output (winget/scoop/
        choco) sometimes contains blank lines interspersed with real content, and
        this function must degrade gracefully rather than error on that. The
        whole array may itself be $null, which is treated the same as an empty
        array.
    .EXAMPLE
        Format-DFPreviewSummary -Fields ([ordered]@{ Name = 'git'; Version = $null }) -Body @('raw', 'output')
        Renders "Name: git", a separator, then "raw"/"output" — Version is omitted since its value is $null.
    .OUTPUTS
        System.String[] — the combined preview text, one element per line.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary]$Fields,
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowNull()][object[]]$Body
    )

    # PowerShell's Mandatory-parameter binder rejects a $null element inside an
    # array argument as if the whole argument were null (a per-element check,
    # not just a top-level one), and a strictly-typed [string[]] parameter
    # separately throws a binding-validation error on a populated array that
    # contains an empty-string element. Declaring -Body as [AllowNull()][object[]]
    # avoids both binding-time failures; normalize here so every element is a
    # real, non-empty string before it's used.
    if ($null -eq $Body) { $Body = @() }
    $normalizedBody = foreach ($line in $Body) {
        if ([string]::IsNullOrEmpty($line)) { ' ' } else { [string]$line }
    }
    $normalizedBody = @($normalizedBody)

    $summaryLines = foreach ($label in $Fields.Keys) {
        $value = $Fields[$label]
        if ($value) { "${label}: $value" }
    }

    if (-not $summaryLines) { return $normalizedBody }

    @($summaryLines) + '' + ('-' * 40) + '' + $normalizedBody
}
