#Requires -Version 7.0

# Chocolatey community-repository provider (query-cache kind). The OData API is
# slow and rate-limited, hence the extended 72h TTL set in DFCatalog.ps1.
# Installed state comes from $Env:ChocolateyInstall\lib nuspecs — no choco.exe.

function ConvertFrom-DFCatalogODataEntry {
    <#
    .SYNOPSIS
        Maps NuGet v2 OData feed entries (choco / PSGallery) to
        DotForge.ToolSourceInfo.
    .PARAMETER Source
        Provider name to stamp on the results.
    .PARAMETER Query
        Normalized query (drives MatchKind).
    .PARAMETER Entry
        The feed entry XML elements as returned by Invoke-RestMethod.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Source,

        [Parameter(Mandatory)]
        [string]$Query,

        [AllowEmptyCollection()]
        [AllowNull()]
        [object[]]$Entry
    )

    foreach ($e in @($Entry)) {
        if (-not $e) { continue }
        $props = $e.properties

        $id = [string]$props.Id
        if (-not $id) {
            $id = if ($e.title -is [string]) { $e.title } else { [string]$e.title.'#text' }
        }
        if (-not $id) { continue }

        # Typed OData elements (m:type attribute) come back as XmlElement with '#text'.
        $publishedRaw = $props.Published
        if ($publishedRaw -and $publishedRaw -isnot [string]) { $publishedRaw = [string]$publishedRaw.'#text' }
        $published = $null
        if ($publishedRaw) { try { $published = [datetime]$publishedRaw } catch {} }

        New-DFToolSourceInfo -Source $Source `
            -PackageId $id -Name $id `
            -Description ([string]$props.Description) `
            -LatestVersion ([string]$props.Version) `
            -Homepage ([string]$props.ProjectUrl) `
            -PublishedAt $published `
            -MatchKind ($id -eq $Query ? 'exact-name' : 'keyword')
    }
}

function Invoke-DFCatalogChocoFetch {
    <#
    .SYNOPSIS
        Live Chocolatey community OData search.
    .PARAMETER Query
        Normalized query text.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Query
    )

    $term = [uri]::EscapeDataString(($Query -replace "'", "''"))
    $uri = "https://community.chocolatey.org/api/v2/Search()?`$filter=IsLatestVersion&`$top=15&searchTerm='$term'&targetFramework=''&includePrerelease=false"
    $entries = Invoke-RestMethod -Uri $uri -TimeoutSec 15

    ConvertFrom-DFCatalogODataEntry -Source 'choco' -Query $Query -Entry @($entries)
}

function Search-DFCatalogChoco {
    <#
    .SYNOPSIS
        Cache-first Chocolatey community search.
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

    Search-DFCatalogQueryCache -Provider 'choco' -Query $Query -Fresh:$Fresh `
        -Fetch { param($q) Invoke-DFCatalogChocoFetch -Query $q }
}

function Get-DFCatalogChocoInstalled {
    <#
    .SYNOPSIS
        Lists choco-installed packages by parsing lib\*\*.nuspec — no choco.exe.
    .PARAMETER ChocolateyInstall
        Chocolatey root (defaults to $Env:ChocolateyInstall).
    #>
    [CmdletBinding()]
    param(
        [string]$ChocolateyInstall = $Env:ChocolateyInstall
    )

    if (-not $ChocolateyInstall) { return }
    $lib = Join-Path $ChocolateyInstall 'lib'
    if (-not (Test-Path $lib)) { return }

    foreach ($dir in Get-ChildItem $lib -Directory) {
        $nuspec = Get-ChildItem $dir.FullName -Filter '*.nuspec' -File -ErrorAction Ignore | Select-Object -First 1
        if (-not $nuspec) { continue }
        try {
            $metadata = ([xml](Get-Content $nuspec.FullName -Raw)).package.metadata
        } catch { continue }
        if (-not $metadata.id) { continue }
        [pscustomobject]@{
            Source           = 'choco'
            Name             = [string]$metadata.id
            PackageId        = [string]$metadata.id
            InstalledVersion = [string]$metadata.version
        }
    }
}

if (-not $script:DFCatalogProviders) { $script:DFCatalogProviders = @{} }
$script:DFCatalogProviders['choco'] = @{
    Name         = 'choco'
    Kind         = 'query-cache'
    Test         = { $true }
    Search       = { param($Query, $Fresh) Search-DFCatalogChoco -Query $Query -Fresh:$Fresh }
    GetInstalled = { Get-DFCatalogChocoInstalled }
    Refresh      = { param($Query) if ($Query) { $null = Search-DFCatalogChoco -Query $Query -Fresh } }
}
