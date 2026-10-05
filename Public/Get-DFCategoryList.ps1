#Requires -Version 7.0

function Get-DFCategoryList {
    <#
    .SYNOPSIS
        Lists the valid trifle discovery vocabulary — the exact terms usable
        with Find-DFPackage -Category / -WorksWith.
    .DESCRIPTION
        Prints the function and/or worksWith taxonomy, each value annotated
        with the number of seed-db tools currently carrying it (from the same
        index -Category/-WorksWith search uses, so counts never drift from
        what a matching search would actually return). Always plain strings —
        there's nothing to act on beyond the term itself.

        Each facet is printed as a heading line (Function, WorksWith) followed
        by its terms, indented two spaces. To get bare terms in a script, keep
        the indented lines and trim them (see the last example). Reads only the
        category database on disk; no network.
    .PARAMETER Facet
        Restrict to 'function' or 'worksWith'. Omit for both.
    .PARAMETER Counts
        Append each value's tool count, e.g. 'binaries (8)'. Default: on. Use
        -Counts:$false to print the terms alone.
    .EXAMPLE
        Get-DFCategoryList

        Prints both vocabularies with counts.
    .EXAMPLE
        tcats -Facet function -Counts:$false

        The valid -Category values under a Function heading, without counts.
    .EXAMPLE
        tcats -Facet function -Counts:$false | Where-Object { $_ -like '  *' } | ForEach-Object Trim

        Just the terms, one per line, for use in a script.
    .OUTPUTS
        System.String[]
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/package-catalog.md
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [ValidateSet('function', 'worksWith')]
        [string]$Facet,

        [switch]$Counts = $true
    )

    $color = (-not $Env:NO_COLOR) -and $Host.UI.SupportsVirtualTerminal
    Format-DFCategoryList -Database (Get-DFCategoryDb) -Facet $Facet -Counts $Counts.IsPresent -Color $color
}

Set-Alias -Name tcats -Value Get-DFCategoryList
