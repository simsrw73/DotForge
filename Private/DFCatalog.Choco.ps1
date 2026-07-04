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

function ConvertFrom-DFCatalogODataDetailEntry {
    <#
    .SYNOPSIS
        Maps one NuGet v2 OData entry (choco / PSGallery) to a
        DotForge.ToolSourceDetail. Shared by both OData providers.
    .PARAMETER Source
        Provider name to stamp on the result.
    .PARAMETER Entry
        One feed entry as returned by Invoke-RestMethod.
    .PARAMETER InstallHint
        The catalog's install one-liner for this package.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Source,

        [AllowNull()]
        [object]$Entry,

        [Parameter(Mandatory)]
        [string]$InstallHint
    )

    if (-not $Entry) { return $null }
    $props = $Entry.properties
    $id = [string]$props.Id
    if (-not $id) { return $null }

    # m:typed OData elements surface as XmlElement with '#text'.
    $text = { param($v) ($v -and $v -isnot [string]) ? [string]$v.'#text' : [string]$v }

    $downloads = $null
    $raw = & $text $props.DownloadCount
    if ($raw) { try { $downloads = [long]$raw } catch {} }

    $deps = @(foreach ($spec in ((& $text $props.Dependencies) -split '\|') -ne '') {
        $parts = $spec -split ':'
        $parts[1] ? "$($parts[0]) ($($parts[1]))" : $parts[0]
    })

    New-DFToolSourceDetail -Source $Source `
        -PackageId $id `
        -Publisher (& $text $props.Authors) `
        -Dependencies $deps `
        -Tags @(((& $text $props.Tags) -split '\s+') -ne '') `
        -Downloads $downloads `
        -ReleaseNotes (& $text $props.ReleaseNotes) `
        -RepositoryUrl ((& $text $props.ProjectSourceUrl) ? (& $text $props.ProjectSourceUrl) : (& $text $props.ProjectUrl)) `
        -DocsUrl (& $text $props.DocsUrl) `
        -InstallHint $InstallHint
}

function Invoke-DFCatalogChocoDetailFetch {
    <#
    .SYNOPSIS
        Live Chocolatey OData detail lookup (latest version of one id).
    .PARAMETER PackageId
        The choco package id.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$PackageId
    )

    $term = [uri]::EscapeDataString(($PackageId -replace "'", "''"))
    $uri = "https://community.chocolatey.org/api/v2/FindPackagesById()?id='$term'&`$filter=IsLatestVersion"
    $entry = @(Invoke-RestMethod -Uri $uri -TimeoutSec 15) | Select-Object -First 1
    ConvertFrom-DFCatalogODataDetailEntry -Source 'choco' -Entry $entry -InstallHint "choco install $PackageId"
}

function Get-DFCatalogChocoDetail {
    <#
    .SYNOPSIS
        Cache-first Chocolatey detail lookup (72h TTL — slow, rate-limited API).
    .PARAMETER PackageId
        The choco package id.
    .PARAMETER Fresh
        Force a live fetch.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$PackageId,

        [switch]$Fresh
    )

    Get-DFCatalogDetailCache -Provider 'choco' -PackageId $PackageId -Fresh:$Fresh `
        -Fetch { param($id) Invoke-DFCatalogChocoDetailFetch -PackageId $id }
}

if (-not $script:DFCatalogProviders) { $script:DFCatalogProviders = @{} }
$script:DFCatalogProviders['choco'] = @{
    Name         = 'choco'
    Kind         = 'query-cache'
    Test         = { $true }
    Search       = { param($Query, $Fresh) Search-DFCatalogChoco -Query $Query -Fresh:$Fresh }
    GetInstalled = { Get-DFCatalogChocoInstalled }
    Refresh      = { param($Query) if ($Query) { $null = Search-DFCatalogChoco -Query $Query -Fresh } }
    Detail       = { param($PackageId, $Fresh) Get-DFCatalogChocoDetail -PackageId $PackageId -Fresh:$Fresh }
}
