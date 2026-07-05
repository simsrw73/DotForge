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
    .PARAMETER Facet
        Restrict to 'function' or 'worksWith'. Omit for both.
    .PARAMETER Counts
        Append each value's live tool count. Default: on. Use -Counts:$false
        for a bare term list (scripting, shell completion).
    .EXAMPLE
        Get-DFCategoryList
        Prints both vocabularies with counts.
    .EXAMPLE
        tcats -Facet function -Counts:$false
        Bare list of valid -Category values, no counts.
    .OUTPUTS
        System.String[]
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

Set-Alias -Name tcats -Value Get-DFCategoryList -Scope Global -Force
