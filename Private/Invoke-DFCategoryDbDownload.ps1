#Requires -Version 7.0

function Invoke-DFCategoryDbDownload {
    <#
    .SYNOPSIS
        Fetches and parses the published tool-categories.json release asset.
        Mockable seam so Update-DFCategoryDb's tests never hit the network.
    .PARAMETER Uri
        The asset URL.
    .OUTPUTS
        PSCustomObject — the parsed document. Throws on any failure.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Uri
    )

    Invoke-RestMethod -Uri $Uri -TimeoutSec 15
}
