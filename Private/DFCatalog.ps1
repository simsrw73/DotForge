#Requires -Version 7.0

# Core plumbing for the catalog provider system (trifle / Find-DFPackage).
#
# The provider registry, Register-DFCatalogProvider and the canonical order
# (Get-DFCatalogName) live in DFCatalog.Base.ps1, which loads before the
# provider files.

# Guard-init via Get-Variable, not `if (-not $script:X)`: reading a variable to
# test whether it exists is itself a strict-mode violation, so the bare-read
# idiom throws under Set-StrictMode (build/ tooling runs strict).
if (-not (Get-Variable -Name DFCatalogAvailability -Scope Script -ErrorAction Ignore)) { $script:DFCatalogAvailability = @{} }

# TTLs are test-overridable; choco gets a long TTL because the community OData
# API is slow and aggressively rate-limited.
$script:DFCatalogTtl = @{
    choco   = [timespan]::FromHours(72)
    default = [timespan]::FromHours(24)
}

$script:DFCatalogSeenQueryLimit = 50

function Get-DFCatalogCacheRoot {
    <#
    .SYNOPSIS
        Returns the catalog cache root (<XDG cache>\dotforge\catalogs).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    Join-Path (Get-DFXdgPath Cache) 'dotforge/catalogs'
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

    $envelope = [ordered]@{
        timestamp = [datetime]::UtcNow.ToString('o')
        query     = $Query
        results   = @($Results)
    }

    Write-DFFileAtomic -Path $Path -Value ($envelope | ConvertTo-Json -Depth 6)
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

function Get-DFCatalogTtl {
    <#
    .SYNOPSIS
        Returns a provider's cache TTL: its own entry in $script:DFCatalogTtl, or the default.
    .PARAMETER Provider
        Provider name.
    .OUTPUTS
        System.TimeSpan.
    #>
    [CmdletBinding()]
    [OutputType([timespan])]
    param([Parameter(Mandatory)][string]$Provider)
    $script:DFCatalogTtl.ContainsKey($Provider) ? $script:DFCatalogTtl[$Provider] : $script:DFCatalogTtl.default
}

function Invoke-DFCacheFirst {
    <#
    .SYNOPSIS
        The cache-first algorithm shared by catalog searches and detail lookups.
    .DESCRIPTION
        Fresh cache hit: served from the cache. Stale hit: served from the
        cache while -OnStale schedules a background refresh, unless
        -StaleIsMiss, in which case it is treated as a miss. Miss or -Fresh:
        -Fetch runs inline; if it throws, any cached copy is served instead.
        A successful result is written back to the cache, except an empty one
        when -SkipEmpty (so a transient "nothing found" never poisons it).
        With no -Path (caching unavailable) every call fetches.
    .PARAMETER Path
        The cache file, or $null.
    .PARAMETER Ttl
        Age after which a cached entry is stale.
    .PARAMETER Query
        Stored in the cache envelope, so Update-DFPackageCache can re-warm it.
    .PARAMETER Fetch
        Scriptblock that returns the live result.
    .PARAMETER Rehydrate
        Scriptblock turning a Read-DFCatalogCacheFile result back into result objects.
    .PARAMETER OnStale
        Scriptblock run when a stale entry is served.
    .PARAMETER Label
        Used in the verbose message when -Fetch fails, e.g. "npm fetch for 'bat'".
    .PARAMETER Fresh
        Skip the cache and fetch.
    .PARAMETER StaleIsMiss
        Treat a stale entry as a miss.
    .PARAMETER SkipEmpty
        Don't cache, and return nothing for, a $null result.
    .OUTPUTS
        Whatever -Fetch or -Rehydrate return.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][timespan]$Ttl,
        [Parameter(Mandatory)][string]$Query,
        [Parameter(Mandatory)][scriptblock]$Fetch,
        [Parameter(Mandatory)][scriptblock]$Rehydrate,
        [scriptblock]$OnStale = {},
        [string]$Label = 'fetch',
        [switch]$Fresh,
        [switch]$StaleIsMiss,
        [switch]$SkipEmpty
    )
    $cached = $Path ? (Read-DFCatalogCacheFile -Path $Path -Ttl $Ttl) : $null
    if (-not $Fresh -and $cached -and -not ($cached.Stale -and $StaleIsMiss)) {
        if ($cached.Stale) { & $OnStale }
        return & $Rehydrate $cached
    }
    try {
        $result = & $Fetch
    } catch {
        Write-Verbose "DotForge: live $Label failed: $_"
        if ($cached) { return & $Rehydrate $cached }
        return
    }
    if ($SkipEmpty -and $null -eq $result) { return }
    if ($Path) { Write-DFCatalogCacheFile -Path $Path -Query $Query -Results @($result) }
    $result
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

        Pseudo-providers (e.g. 'github', 'github-readme') have no entry in
        $script:DFCatalogProviders, so a background re-warm job would look up
        the provider, find nothing, and no-op — leaving a stale entry stale
        forever while still wasting a ThreadJob. For those, a stale hit is
        treated as a MISS instead: the inline Fetch runs immediately (its
        failure path still falls back to the stale copy), and no background
        job is spawned.
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

    $cacheRoot = Get-DFCatalogCacheRoot
    $keyInfo = ConvertTo-DFCatalogQueryKey -Query $PackageId
    # A stale pseudo-provider entry ('github', ...) has no registered provider
    # to re-warm it in the background, so it is refetched inline instead.
    $refreshable = $script:DFCatalogProviders.ContainsKey($Provider)
    # Renamed so the blocks below, which run inside Invoke-DFCacheFirst, don't
    # resolve $Fetch to that function's own -Fetch parameter.
    $fetchDetail = $Fetch
    Invoke-DFCacheFirst -Path (Join-Path $cacheRoot "$Provider/details/$($keyInfo.Key).json") `
        -Ttl (Get-DFCatalogTtl $Provider) -Query $PackageId -Label "$Provider detail fetch for '$PackageId'" `
        -Fetch { & $fetchDetail $PackageId } `
        -Rehydrate { param($c) @($c.Data) | Select-Object -First 1 } `
        -OnStale { Start-DFCatalogRefreshJob -Provider $Provider -Query $PackageId -Kind detail } `
        -Fresh:$Fresh -StaleIsMiss:(-not $refreshable) -SkipEmpty
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

    foreach ($name in Get-DFCatalogName) {
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

    $cacheRoot = Get-DFCatalogCacheRoot
    $keyInfo = ConvertTo-DFCatalogQueryKey -Query $Query
    $normalized = $keyInfo.Normalized
    # Renamed so the block below, which runs inside Invoke-DFCacheFirst, doesn't
    # resolve $Fetch to that function's own -Fetch parameter.
    $fetchQuery = $Fetch
    Invoke-DFCacheFirst -Path (Join-Path $cacheRoot "$Provider/queries/$($keyInfo.Key).json") `
        -Ttl (Get-DFCatalogTtl $Provider) -Query $normalized -Label "$Provider fetch for '$normalized'" `
        -Fetch { @(& $fetchQuery $normalized) } `
        -Rehydrate { param($c) ConvertTo-DFToolSourceInfoFromCache -Provider $Provider -Cached $c } `
        -OnStale { Start-DFCatalogRefreshJob -Provider $Provider -Query $normalized } `
        -Fresh:$Fresh
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

    # -InputObject (not pipeline/-AsArray) so the array serializes as ONE array
    # instead of being wrapped in another level on every write.
    Write-DFFileAtomic -Path $file -Value (ConvertTo-Json -InputObject @($seen) -Depth 3)
}
