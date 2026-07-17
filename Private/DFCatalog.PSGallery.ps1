#Requires -Version 7.0

# PowerShell Gallery provider (query-cache kind). Uses the v2 OData API — the
# OData Version field is the source of truth (Find-PSResource normalizes away
# prerelease suffixes; see the release notes caveat in CLAUDE.md).

function Invoke-DFCatalogPSGalleryFetch {
    <#
    .SYNOPSIS
        Live PSGallery v2 OData search.
    .PARAMETER Query
        Normalized query text.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Query
    )

    $term = [uri]::EscapeDataString(($Query -replace "'", "''"))
    $uri = "https://www.powershellgallery.com/api/v2/Search()?`$filter=IsLatestVersion&`$top=15&searchTerm='$term'&targetFramework=''&includePrerelease=false"
    $entries = Invoke-RestMethod -Uri $uri -TimeoutSec 15

    ConvertFrom-DFCatalogODataEntry -Source 'psgallery' -Query $Query -Entry @($entries)
}

function Search-DFCatalogPSGallery {
    <#
    .SYNOPSIS
        Cache-first PowerShell Gallery search.
    .PARAMETER Query
        Name or keywords.
    .PARAMETER Fresh
        Block on a live fetch.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Query,

        [switch]$Fresh
    )

    Search-DFCatalogQueryCache -Provider 'psgallery' -Query $Query -Fresh:$Fresh `
        -Fetch { param($q) Invoke-DFCatalogPSGalleryFetch -Query $q }
}

function Get-DFCatalogPSGalleryInstalled {
    <#
    .SYNOPSIS
        Lists installed PowerShell modules (Get-InstalledPSResource when
        available, falling back to Get-Module -ListAvailable), highest version
        per module.
    #>
    [CmdletBinding()]
    param()

    $modules = if (Get-Command Get-InstalledPSResource -ErrorAction Ignore) {
        Get-InstalledPSResource -ErrorAction Ignore
    } else {
        Get-Module -ListAvailable
    }

    $modules | Group-Object Name | ForEach-Object {
        $newest = $_.Group | Sort-Object Version -Descending | Select-Object -First 1
        [pscustomobject]@{
            Source           = 'psgallery'
            Name             = $_.Name
            PackageId        = $_.Name
            InstalledVersion = [string]$newest.Version
        }
    }
}

function Invoke-DFCatalogPSGalleryDetailFetch {
    <#
    .SYNOPSIS
        Live PSGallery OData detail lookup (latest version of one id).
    .PARAMETER PackageId
        The module name.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$PackageId
    )

    $term = [uri]::EscapeDataString(($PackageId -replace "'", "''"))
    $uri = "https://www.powershellgallery.com/api/v2/FindPackagesById()?id='$term'&`$filter=IsLatestVersion"
    $entry = @(Invoke-RestMethod -Uri $uri -TimeoutSec 15) | Select-Object -First 1
    ConvertFrom-DFCatalogODataDetailEntry -Source 'psgallery' -Entry $entry -InstallHint "Install-PSResource $PackageId"
}

function Get-DFCatalogPSGalleryDetail {
    <#
    .SYNOPSIS
        Cache-first PSGallery detail lookup.
    .PARAMETER PackageId
        The module name.
    .PARAMETER Fresh
        Force a live fetch.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$PackageId,

        [switch]$Fresh
    )

    Get-DFCatalogDetailCache -Provider 'psgallery' -PackageId $PackageId -Fresh:$Fresh `
        -Fetch { param($id) Invoke-DFCatalogPSGalleryDetailFetch -PackageId $id }
}

if (-not (Get-Variable -Name DFCatalogProviders -Scope Script -ErrorAction Ignore)) { $script:DFCatalogProviders = @{} }
$script:DFCatalogProviders['psgallery'] = @{
    Name         = 'psgallery'
    Kind         = 'query-cache'
    Test         = { $true }
    Search       = { param($Query, $Fresh) Search-DFCatalogPSGallery -Query $Query -Fresh:$Fresh }
    GetInstalled = { Get-DFCatalogPSGalleryInstalled }
    Refresh      = { param($Query) if ($Query) { $null = Search-DFCatalogPSGallery -Query $Query -Fresh } }
    Detail       = { param($PackageId, $Fresh) Get-DFCatalogPSGalleryDetail -PackageId $PackageId -Fresh:$Fresh }
}
