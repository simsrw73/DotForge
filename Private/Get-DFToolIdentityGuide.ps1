#Requires -Version 7.0

# Lazy-loaded, indexed tool-identity guide: canonical tool -> verified
# per-catalog package ids, consulted by Resolve-DFCatalogQueryMerge as an
# additional (never sole, never authoritative-over-Tools/*.json) identity
# source. Ships as data/tool-identities.json; Update-DFToolIdentityGuide can
# place a newer copy under $XDG_DATA_HOME/dotforge/.

function Get-DFToolIdentityGuide {
    <#
    .SYNOPSIS
        Loads (and indexes) the trifle tool-identity guide. Lazy singleton;
        never throws — an unreadable file degrades to an empty, valid,
        harmless guide object.
    .PARAMETER Path
        Override the shipped-side location (a test seam — lets a fixture
        stand in for the real shipped file). The refreshed-vs-shipped
        precedence check against $Env:XDG_DATA_HOME still runs normally
        against this override. Always forces a fresh, uncached read.
    .PARAMETER Force
        Reload from the resolved location, bypassing the singleton cache.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [string]$Path,
        [switch]$Force
    )

    if (-not $Path -and -not $Force -and $script:DFToolIdentityGuide) {
        return $script:DFToolIdentityGuide
    }

    $readArgs = @{
        FileName           = 'tool-identities.json'
        Validator          = 'Test-DFToolIdentityGuideSchema'
        Label              = 'tool-identity guide'
        UnavailableMessage = 'tool-identity guide is unavailable — cross-catalog identity resolution falls back to Tools/*.json only.'
    }
    if ($Path) { $readArgs.ShippedPath = $Path }
    $raw = Read-DFReleaseData @readArgs

    $idIndex = @{}
    if ($raw) {
        foreach ($prop in $raw.tools.PSObject.Properties) {
            $key = $prop.Name
            $entry = $prop.Value
            if (-not $entry.packages) { continue }
            foreach ($pkgProp in $entry.packages.PSObject.Properties) {
                $ref = Get-DFPackageRef $pkgProp.Value
                if ($ref) { $idIndex["$(ConvertTo-DFCatalogSource $pkgProp.Name):$($ref.Id)".ToLowerInvariant()] = $key }
            }
        }
    }

    $guide = [pscustomobject]@{
        Raw     = $raw
        IdIndex = $idIndex
    }

    if (-not $Path) { $script:DFToolIdentityGuide = $guide }
    $guide
}
