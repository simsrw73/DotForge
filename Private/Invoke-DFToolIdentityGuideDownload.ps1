#Requires -Version 7.0

function Invoke-DFToolIdentityGuideDownload {
    <#
    .SYNOPSIS
        Fetches and parses the published tool-identities.json release asset.
        Mockable seam so Update-DFToolIdentityGuide's tests never hit the network.
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
