#Requires -Version 7.0

# Core plumbing for the catalog provider system (trifle / Find-DFPackage).
#
# Providers self-register into $script:DFCatalogProviders from their own
# Private/DFCatalog.<Provider>.ps1 files. Because DotForge.psm1 dot-sources
# Private/*.ps1 alphabetically, provider files (e.g. DFCatalog.Choco.ps1) load
# BEFORE this file — every file that touches the table must guard-init it and
# never assume this file ran first. Canonical ordering lives here, not in
# registration order.

if (-not $script:DFCatalogProviders) { $script:DFCatalogProviders = @{} }
if (-not $script:DFCatalogAvailability) { $script:DFCatalogAvailability = @{} }

$script:DFCatalogOrder = @('scoop', 'winget', 'choco', 'npm', 'pypi', 'crates', 'psgallery')

# TTLs are test-overridable; choco gets a long TTL because the community OData
# API is slow and aggressively rate-limited.
$script:DFCatalogTtl = @{
    installed = [timespan]::FromMinutes(15)
    choco     = [timespan]::FromHours(72)
    default   = [timespan]::FromHours(24)
}

$script:DFCatalogSeenQueryLimit = 50

function Get-DFCatalogCacheRoot {
    <#
    .SYNOPSIS
        Returns the catalog cache root ($XDG_CACHE_HOME/dotforge/catalogs),
        or $null with a warning when XDG_CACHE_HOME is unset.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if (-not $Env:XDG_CACHE_HOME) {
        Write-Warning 'DotForge: $Env:XDG_CACHE_HOME is not set. Catalog caching is disabled; call Initialize-DFEnvironment first.'
        return $null
    }
    Join-Path $Env:XDG_CACHE_HOME 'dotforge/catalogs'
}

function ConvertTo-DFCatalogQueryKey {
    <#
    .SYNOPSIS
        Normalizes a search query and derives a filename-safe cache key.
    .DESCRIPTION
        Normalized form: trimmed, lowercased (invariant), internal whitespace runs
        collapsed to single spaces. Key: normalized text sanitized to [a-z0-9._-]
        (others become '_'), truncated to 40 chars, suffixed with '-' + the first
        8 hex chars of the SHA1 of the normalized query so truncation and
        sanitization can never collide.
    .PARAMETER Query
        The raw query text.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Query
    )

    $normalized = ($Query.Trim() -replace '\s+', ' ').ToLowerInvariant()

    $safe = $normalized -replace '[^a-z0-9._-]', '_'
    if ($safe.Length -gt 40) { $safe = $safe.Substring(0, 40) }

    $sha1 = [System.Security.Cryptography.SHA1]::HashData([System.Text.Encoding]::UTF8.GetBytes($normalized))
    $hash = [System.Convert]::ToHexString($sha1).Substring(0, 8).ToLowerInvariant()

    [pscustomobject]@{
        Normalized = $normalized
        Key        = "$safe-$hash"
    }
}

function Write-DFCatalogCacheFile {
    <#
    .SYNOPSIS
        Atomically writes a catalog cache envelope {timestamp, query, results}.
    .DESCRIPTION
        Writes to "<path>.tmp.<pid>" then renames over the target, so a
        concurrently running Update-DFPackageCache and an interactive session can
        never leave a half-written file — last writer wins, both are valid.
    .PARAMETER Path
        Destination cache file path.
    .PARAMETER Query
        The normalized query the results answer (stored for re-warming).
    .PARAMETER Results
        The result objects to store.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Query,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Results
    )

    New-DFDirectory (Split-Path $Path -Parent)

    $envelope = [ordered]@{
        timestamp = [datetime]::UtcNow.ToString('o')
        query     = $Query
        results   = @($Results)
    }

    $tmp = "$Path.tmp.$PID"
    $envelope | ConvertTo-Json -Depth 6 | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Path $tmp -Destination $Path -Force
}

function Read-DFCatalogCacheFile {
    <#
    .SYNOPSIS
        Reads a catalog cache envelope; returns @{Data; AgeMinutes; Stale; Query}
        or $null when the file is missing or unreadable.
    .PARAMETER Path
        Cache file path.
    .PARAMETER Ttl
        Age beyond which the entry is flagged Stale (it is still returned —
        staleness never blocks; callers serve stale data and refresh in the
        background).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [timespan]$Ttl
    )

    if (-not (Test-Path $Path)) { return $null }

    try {
        $envelope = Get-Content $Path -Raw | ConvertFrom-Json
        # ConvertFrom-Json auto-converts ISO 8601 strings to [datetime] (Local kind).
        $timestamp = if ($envelope.timestamp -is [datetime]) {
            $envelope.timestamp
        } else {
            [datetime]::Parse(
                $envelope.timestamp,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::RoundtripKind)
        }
    } catch {
        Write-Verbose "DotForge: unreadable catalog cache file '$Path': $_"
        return $null
    }

    $age = [datetime]::UtcNow - $timestamp.ToUniversalTime()
    @{
        Data       = @($envelope.results)
        AgeMinutes = [int]$age.TotalMinutes
        Stale      = $age -gt $Ttl
        Query      = $envelope.query
    }
}

function New-DFToolSourceInfo {
    <#
    .SYNOPSIS
        Constructs a DotForge.ToolSourceInfo — one catalog's view of a package.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$PackageId,
        [Parameter(Mandatory)][string]$Name,
        [string]$Description,
        [string]$LatestVersion,
        [string]$InstalledVersion,
        [switch]$Installed,
        [string]$Homepage,
        [string]$License,
        [nullable[datetime]]$PublishedAt,
        [Parameter(Mandatory)]
        [ValidateSet('exact-id', 'exact-name', 'keyword')]
        [string]$MatchKind,
        [nullable[datetime]]$CacheTimestamp,
        [int]$CacheAgeMinutes
    )

    [pscustomobject]@{
        PSTypeName       = 'DotForge.ToolSourceInfo'
        Source           = $Source
        PackageId        = $PackageId
        Name             = $Name
        Description      = $Description
        LatestVersion    = $LatestVersion
        InstalledVersion = $InstalledVersion
        Installed        = [bool]$Installed
        Homepage         = $Homepage
        License          = $License
        PublishedAt      = $PublishedAt
        MatchKind        = $MatchKind
        CacheTimestamp   = $CacheTimestamp
        CacheAgeMinutes  = $CacheAgeMinutes
    }
}

function New-DFToolInfo {
    <#
    .SYNOPSIS
        Constructs a DotForge.ToolInfo — the merged, cross-catalog view emitted
        by Find-DFPackage.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Description,
        [switch]$Installed,
        [string[]]$InstalledVia = @(),
        [string]$InstalledVersion,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Sources,
        [System.Collections.Specialized.OrderedDictionary]$Latest,
        [string]$Homepage,
        [string]$License,
        [string]$DFTool,
        [string]$MatchKind,
        [int]$CacheAge,
        [System.Collections.Specialized.OrderedDictionary]$Details,
        [object]$GitHub
    )

    [pscustomobject]@{
        PSTypeName       = 'DotForge.ToolInfo'
        Name             = $Name
        Description      = $Description
        Installed        = [bool]$Installed
        InstalledVia     = $InstalledVia
        InstalledVersion = $InstalledVersion
        Sources          = @($Sources)
        Latest           = $Latest
        Homepage         = $Homepage
        License          = $License
        DFTool           = $DFTool
        MatchKind        = $MatchKind
        CacheAge         = $CacheAge
        Details          = $Details
        GitHub           = $GitHub
    }
}

function New-DFToolSourceDetail {
    <#
    .SYNOPSIS
        Constructs a DotForge.ToolSourceDetail — one catalog's deep view of a
        package (detail-endpoint data, beyond what search returns).
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$PackageId,
        [string]$Publisher,
        [string[]]$Maintainers = @(),
        [string[]]$Dependencies = @(),
        [string[]]$Tags = @(),
        [nullable[long]]$Downloads,
        [string]$ReleaseNotes,
        [string]$ReleaseNotesUrl,
        [string]$RepositoryUrl,
        [string]$DocsUrl,
        [string]$InstallHint,
        [string]$Notes,
        [string]$Readme,
        [System.Collections.Specialized.OrderedDictionary]$Extra
    )

    [pscustomobject]@{
        PSTypeName      = 'DotForge.ToolSourceDetail'
        Source          = $Source
        PackageId       = $PackageId
        Publisher       = $Publisher
        Maintainers     = $Maintainers
        Dependencies    = $Dependencies
        Tags            = $Tags
        Downloads       = $Downloads
        ReleaseNotes    = $ReleaseNotes
        ReleaseNotesUrl = $ReleaseNotesUrl
        RepositoryUrl   = $RepositoryUrl
        DocsUrl         = $DocsUrl
        InstallHint     = $InstallHint
        Notes           = $Notes
        Readme          = $Readme
        Extra           = $Extra
    }
}

function Get-DFCatalogDetailCache {
    <#
    .SYNOPSIS
        Cache-first engine for per-package detail lookups — the detail-side
        mirror of Search-DFCatalogQueryCache.
    .DESCRIPTION
        Fresh hit → served instantly. Stale hit → served instantly while a
        background job re-warms it. Miss or -Fresh → inline fetch, falling back
        to any cached data when the fetch fails. A fetch that returns nothing
        (package has no detail) is NOT cached, so transient failures don't
        poison the cache. Cache-hit rehydration returns plain PSCustomObjects —
        consumers must be duck-typed, not PSTypeName-typed.
    .PARAMETER Provider
        Provider name (cache subdirectory and TTL key). 'github' is valid here
        too — the GitHub enrichment reuses this engine.
    .PARAMETER PackageId
        The raw package id (stored verbatim in the envelope's query field so
        Update-DFPackageCache can re-warm with the exact id).
    .PARAMETER Fetch
        Scriptblock taking the raw PackageId, returning ONE object or $null.
    .PARAMETER Fresh
        Force an inline live fetch.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Provider,

        [Parameter(Mandatory)]
        [string]$PackageId,

        [Parameter(Mandatory)]
        [scriptblock]$Fetch,

        [switch]$Fresh
    )

    $keyInfo = ConvertTo-DFCatalogQueryKey -Query $PackageId
    $ttl = $script:DFCatalogTtl.ContainsKey($Provider) ? $script:DFCatalogTtl[$Provider] : $script:DFCatalogTtl.default

    $cacheRoot = Get-DFCatalogCacheRoot
    $file = $cacheRoot ? (Join-Path $cacheRoot "$Provider/details/$($keyInfo.Key).json") : $null
    $cached = $file ? (Read-DFCatalogCacheFile -Path $file -Ttl $ttl) : $null

    if (-not $Fresh -and $cached) {
        if ($cached.Stale) {
            Start-DFCatalogRefreshJob -Provider $Provider -Query $PackageId -Kind detail
        }
        return @($cached.Data) | Select-Object -First 1
    }

    try {
        $result = & $Fetch $PackageId
    } catch {
        Write-Verbose "DotForge: live $Provider detail fetch for '$PackageId' failed: $_"
        if ($cached) { return @($cached.Data) | Select-Object -First 1 }
        return $null
    }

    if ($null -eq $result) { return $null }

    if ($file) {
        Write-DFCatalogCacheFile -Path $file -Query $PackageId -Results @($result)
    }
    $result
}

function Get-DFCatalogDetail {
    <#
    .SYNOPSIS
        Dispatches a detail lookup to a provider's Detail hook. Returns $null
        when the provider has no hook or the hook fails — detail failures
        never block the caller.
    .PARAMETER Source
        Provider name.
    .PARAMETER PackageId
        Raw package id as reported by that provider's search.
    .PARAMETER Fresh
        Force a live fetch.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Source,

        [Parameter(Mandatory)]
        [string]$PackageId,

        [switch]$Fresh
    )

    $provider = $script:DFCatalogProviders[$Source]
    if (-not $provider -or -not $provider.Detail) { return $null }
    try {
        & $provider.Detail $PackageId $Fresh.IsPresent
    } catch {
        Write-Verbose "DotForge: $Source detail hook for '$PackageId' failed: $_"
        $null
    }
}

function Get-DFToolInfoDetails {
    <#
    .SYNOPSIS
        Fetches per-source details for every source of a merged ToolInfo.
        Returns an ordered dict source → detail; a $null value marks a source
        whose Detail hook exists but failed (renders as 'details unavailable').
        Sources whose provider has no Detail hook are omitted entirely.
    .PARAMETER Info
        The merged DotForge.ToolInfo.
    .PARAMETER Fresh
        Force live fetches.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Info,

        [switch]$Fresh
    )

    $details = [ordered]@{}
    foreach ($source in @($Info.Sources)) {
        $provider = $script:DFCatalogProviders[$source.Source]
        if (-not $provider -or -not $provider.Detail) { continue }
        if ($details.Contains($source.Source)) { continue }
        $details[$source.Source] = Get-DFCatalogDetail -Source $source.Source -PackageId $source.PackageId -Fresh:$Fresh
    }
    $details
}

function Get-DFCatalogProvider {
    <#
    .SYNOPSIS
        Returns registered, available catalog providers in canonical order,
        optionally filtered by -Source. Availability probes are memoized for
        the session.
    .PARAMETER Source
        Restrict to these provider names.
    #>
    [CmdletBinding()]
    param(
        [string[]]$Source
    )

    foreach ($name in $script:DFCatalogOrder) {
        if (-not $script:DFCatalogProviders.ContainsKey($name)) { continue }
        if ($Source -and $name -notin $Source) { continue }

        if (-not $script:DFCatalogAvailability.ContainsKey($name)) {
            $script:DFCatalogAvailability[$name] = [bool](& $script:DFCatalogProviders[$name].Test)
        }
        if ($script:DFCatalogAvailability[$name]) {
            $script:DFCatalogProviders[$name]
        }
    }
}

function ConvertTo-DFToolSourceInfoFromCache {
    <#
    .SYNOPSIS
        Rehydrates cached envelope entries into DotForge.ToolSourceInfo objects,
        stamping the envelope's age onto every result.
    .PARAMETER Provider
        The provider name (becomes Source).
    .PARAMETER Cached
        The result of Read-DFCatalogCacheFile.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Provider,

        [Parameter(Mandatory)]
        $Cached
    )

    foreach ($entry in $Cached.Data) {
        $published = $null
        if ($entry.PublishedAt) {
            $published = if ($entry.PublishedAt -is [datetime]) { $entry.PublishedAt }
                         else { try { [datetime]$entry.PublishedAt } catch { $null } }
        }
        New-DFToolSourceInfo -Source $Provider `
            -PackageId $entry.PackageId `
            -Name $entry.Name `
            -Description ([string]$entry.Description) `
            -LatestVersion ([string]$entry.LatestVersion) `
            -Homepage ([string]$entry.Homepage) `
            -License ([string]$entry.License) `
            -PublishedAt $published `
            -MatchKind $entry.MatchKind `
            -CacheTimestamp ([datetime]::UtcNow.AddMinutes(-$Cached.AgeMinutes)) `
            -CacheAgeMinutes $Cached.AgeMinutes
    }
}

function Search-DFCatalogQueryCache {
    <#
    .SYNOPSIS
        Cache-first search engine for web-API (query-cache) providers.
    .DESCRIPTION
        Fresh cache hit → served instantly, no web call. Stale hit → served
        instantly while a background ThreadJob re-warms the entry (staleness
        never blocks). Miss or -Fresh → inline fetch (bounded by the fetcher's
        timeout), falling back to any cached data when the fetch fails.
    .PARAMETER Provider
        Provider name (cache subdirectory and TTL key).
    .PARAMETER Query
        Raw query text.
    .PARAMETER Fetch
        Scriptblock taking the normalized query and returning ToolSourceInfo
        objects from the live API.
    .PARAMETER Fresh
        Force an inline live fetch.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Provider,

        [Parameter(Mandatory)]
        [string]$Query,

        [Parameter(Mandatory)]
        [scriptblock]$Fetch,

        [switch]$Fresh
    )

    $keyInfo = ConvertTo-DFCatalogQueryKey -Query $Query
    $ttl = $script:DFCatalogTtl.ContainsKey($Provider) ? $script:DFCatalogTtl[$Provider] : $script:DFCatalogTtl.default

    $cacheRoot = Get-DFCatalogCacheRoot
    $file = $cacheRoot ? (Join-Path $cacheRoot "$Provider/queries/$($keyInfo.Key).json") : $null
    $cached = $file ? (Read-DFCatalogCacheFile -Path $file -Ttl $ttl) : $null

    if (-not $Fresh -and $cached) {
        if ($cached.Stale) {
            Start-DFCatalogRefreshJob -Provider $Provider -Query $keyInfo.Normalized
        }
        return ConvertTo-DFToolSourceInfoFromCache -Provider $Provider -Cached $cached
    }

    try {
        $results = @(& $Fetch $keyInfo.Normalized)
    } catch {
        Write-Verbose "DotForge: live $Provider fetch for '$($keyInfo.Normalized)' failed: $_"
        if ($cached) { return ConvertTo-DFToolSourceInfoFromCache -Provider $Provider -Cached $cached }
        return
    }

    if ($file) {
        Write-DFCatalogCacheFile -Path $file -Query $keyInfo.Normalized -Results $results
    }
    $results
}

function Add-DFCatalogSeenQuery {
    <#
    .SYNOPSIS
        Records a query in the seen-queries LRU (cap 50) so Update-DFPackageCache
        can re-warm it. No-op when catalog caching is disabled.
    .PARAMETER Query
        The raw query text; stored in normalized form.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Query
    )

    $root = Get-DFCatalogCacheRoot
    if (-not $root) { return }

    $normalized = (ConvertTo-DFCatalogQueryKey -Query $Query).Normalized
    $file = Join-Path $root 'seen-queries.json'

    $seen = @()
    if (Test-Path $file) {
        try { $seen = @(Get-Content $file -Raw | ConvertFrom-Json) } catch { $seen = @() }
    }

    $entry = [pscustomobject]@{ query = $normalized; lastUsed = [datetime]::UtcNow.ToString('o') }
    $seen = @($entry) + @($seen | Where-Object query -ne $normalized)
    if ($seen.Count -gt $script:DFCatalogSeenQueryLimit) {
        $seen = $seen[0..($script:DFCatalogSeenQueryLimit - 1)]
    }

    New-DFDirectory $root
    $tmp = "$file.tmp.$PID"
    # -InputObject (not pipeline/-AsArray) so the array serializes as ONE array
    # instead of being wrapped in another level on every write.
    ConvertTo-Json -InputObject @($seen) -Depth 3 | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Path $tmp -Destination $file -Force
}
