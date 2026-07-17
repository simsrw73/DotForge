#Requires -Version 7.0

# Chocolatey's community OData feed (community.chocolatey.org/api/v2) was
# live-tested directly on 2026-07-14 and again on 2026-07-15; several server
# behaviors here are undocumented or under-documented and were confirmed
# empirically rather than assumed — see
# docs/superpowers/specs/2026-07-13-package-universe-acquisition-design.md
# Acquisition Strategy -> Choco for the full writeup.
#
# THE STRATEGY IS ONE UNFILTERED WALK. Ask for $filter=IsLatestVersion and
# follow the server's <link rel="next"> $skiptoken continuation until a response
# has no next link. That is all. ~281 requests, ~40 entries/page, ~300ms each,
# for the whole ~11,202-package catalog. Do not add a date filter, $skip, or
# $top to "help" — each of those makes it dramatically worse. Specifically:
#
#   - $skip is unreliable on $filter-scoped queries: confirmed live that on a
#     Published-date-filtered query the server IGNORES $skip and re-returns the
#     first page. Skip-based paging terminates after ~2 requests (page 2
#     overlaps page 1 -> "no new"). This is what produced a 125-row "full"
#     crawl. $top is likewise not honored. Neither is sent.
#   - The hard 10,000-item cap (HTTP 406 "Traversing more than 10000 items is
#     no longer supported") applies to $skip ONLY, *not* to $skiptoken paging.
#     Confirmed live 2026-07-15: a single next-link walk ran 282 consecutive
#     pages (~11,280 underlying items, well past 10,000) with zero 406s. This
#     is why no partitioning exists here. An earlier revision of this file
#     carried year-seeded, recursively-bisecting date-range partitioning to
#     stay under that cap; it was deleted once the cap was shown not to apply.
#   - FILTERS ARE APPLIED AFTER PAGINATION. The server pages the underlying set
#     at ~40 items/page and applies the predicate to each page after selecting
#     it. A date-scoped query therefore walks the ENTIRE catalog to return its
#     handful of matches: the 2011 bucket cost 282 requests to yield 5 rows,
#     with nearly every page empty. Partitioning by date multiplies total cost
#     by the bucket count (~16 years x ~280 = ~4,480 requests) instead of
#     dividing it. It is also far harsher on the server: an uncached filtered
#     page took 89 SECONDS versus ~300ms unfiltered.
#   - This is also why there is no incremental sync. LastUpdated gt <watermark>
#     is a filter, so it would pay the same ~281-request full-catalog scan to
#     return a few changed rows — the same cost as a complete walk, for less
#     data and no removal detection. (OData's GetUpdates endpoint, the standard
#     incremental primitive, is disabled: 410 Gone. Moot now.)
#   - Rate limiting is ~20 requests/minute/IP; exceeding it returns HTTP 429
#     and earns a one-hour IP ban (doubling on repeat). A 429 therefore ABORTS
#     the whole walk immediately — retrying during a ban is futile and can
#     extend it. The walk keeps whatever it has and reports Complete=$false, so
#     the caller does NOT prune.
#   - Name-based partitioning (startswith/Id range/Id eq) is silently broken
#     (HTTP 200, zero rows) on this server — never used here.
#   - Authors is excluded from the OData payload's <m:properties> content
#     (feed customization maps it onto the Atom <author><name> element
#     instead) — read the author element, never properties.Authors. Reading
#     the wrong one is a silent empty column, not an error, which is exactly
#     why this file runs strict (see Get-DFXmlMember in Private/DFCatalog.ps1).
#   - An empty feed must be null-guarded: @($xml.feed.entry) yields @($null)
#     (Count 1) when a page has no entries. The fetch seam filters those out;
#     the walk defends again anyway.
#
# The $RequestBudget hashtable threaded through every function is the shared
# control-flow + observability channel for a whole choco run:
#   Used         - requests attempted so far
#   Max          - hard ceiling (runaway backstop; a real walk needs ~281)
#   Aborted      - $true once the walk must stop everything (429 or budget)
#   AbortReason  - human-readable reason, for logging
#   ErrorCount   - count of 'error'-level events (gates destructive pruning)

function ConvertTo-DFPackageUniverseChocoRow {
    <#
    .SYNOPSIS
        Maps one raw choco OData Packages() entry to a raw_packages row.
    .DESCRIPTION
        Reuses ConvertFrom-DFCatalogODataEntry for id/name/description/version/
        homepage, then reads Tags/LicenseUrl off entry.properties and the
        publisher off the Atom author element (see file header).

        Every member read goes through Get-DFXmlMember/Get-DFXmlText
        (Private/DFCatalog.ps1) rather than a bare $entry.Foo: absent members
        are normal in this feed, and a bare read of an absent member throws
        under Set-StrictMode, which this build tooling runs.
    .PARAMETER Entry
        One raw OData entry (has a .properties member and, per the Atom
        syndication format, an .author.name) as returned by the fetch seam
        against the Packages() collection.
    .OUTPUTS
        pscustomobject shaped like a raw_packages row, or $null when the entry
        has no resolvable id.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Entry
    )

    $props = Get-DFXmlMember -Element $Entry -Name 'properties'

    $id = Get-DFXmlText -Element $props -Name 'Id'
    if (-not $id) { $id = Get-DFXmlText -Element $Entry -Name 'title' }
    if (-not $id) { return $null }

    $base = ConvertFrom-DFCatalogODataEntry -Source 'choco' -Query $id -Entry @($Entry) | Select-Object -First 1
    if (-not $base) { return $null }

    $tags = @((([string](Get-DFXmlText -Element $props -Name 'Tags')) -split '\s+') -ne '')

    # Publisher lives on the Atom <author><name>, never properties.Authors.
    $author = Get-DFXmlMember -Element $Entry -Name 'author'
    $publisher = [string](Get-DFXmlText -Element $author -Name 'name')

    # Full-fidelity capture: walk the <m:properties> child ELEMENT nodes
    # (LocalName -> InnerText) so only the real OData <d:...> fields are stored.
    # Iterating $props.PSObject.Properties instead sweeps in the whole XML-DOM API
    # on a live XmlElement (InnerXml, OuterXml, BaseURI, ChildNodes, d, m, ...) --
    # a gap the clean pscustomobject fakes could not surface, caught by a live
    # walk-page check on 2026-07-16. m:null elements are skipped (absent data).
    # Plus the Atom-only Summary/updated that feed customization keeps off
    # <m:properties>. Fields also promoted to typed columns are kept here too, so a
    # manual reviewer sees the complete raw record without cross-referencing.
    $metaNs = 'http://schemas.microsoft.com/ado/2007/08/dataservices/metadata'
    $extraMap = [ordered]@{}
    if ($props -and $props.PSObject.Properties['ChildNodes']) {
        foreach ($node in $props.ChildNodes) {
            if ($node.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
            if ($node.GetAttribute('null', $metaNs) -eq 'true') { continue }
            $extraMap[$node.LocalName] = $node.InnerText
        }
    }
    $summary = Get-DFXmlText -Element $Entry -Name 'summary'
    if ($null -ne $summary) { $extraMap['Summary'] = $summary }
    $lastUpdated = Get-DFXmlText -Element $Entry -Name 'updated'
    if ($null -ne $lastUpdated) { $extraMap['LastUpdated'] = $lastUpdated }

    [pscustomobject]@{
        source      = 'choco'
        package_id  = $base.PackageId
        name        = $base.Name
        version     = $base.LatestVersion
        description = $base.Description
        homepage    = $base.Homepage
        license     = [string](Get-DFXmlText -Element $props -Name 'LicenseUrl')
        publisher   = $publisher
        tags        = ($tags.Count -gt 0 ? (ConvertTo-Json -Compress -InputObject $tags) : $null)
        extra       = ($extraMap.Count -gt 0 ? (ConvertTo-Json -Compress -InputObject $extraMap) : $null)
        fetched_at  = [datetime]::UtcNow.ToString('o')
    }
}

function Get-DFPackageUniverseChocoRetryAfterSeconds {
    <#
    .SYNOPSIS
        Best-effort extraction of a Retry-After hint (seconds) from a thrown
        HTTP error, for logging only. Returns $null when unavailable.
    .PARAMETER ErrorRecord
        The caught ErrorRecord.
    .OUTPUTS
        [int] seconds, or $null.
    #>
    [CmdletBinding()]
    param($ErrorRecord)

    try {
        $exception = Get-DFXmlMember -Element $ErrorRecord -Name 'Exception'
        $resp = Get-DFXmlMember -Element $exception -Name 'Response'
        if (-not $resp) { return $null }
        $headers = Get-DFXmlMember -Element $resp -Name 'Headers'
        $retryAfter = Get-DFXmlMember -Element $headers -Name 'RetryAfter'
        if (-not $retryAfter) { return $null }
        $delta = Get-DFXmlMember -Element $retryAfter -Name 'Delta'
        if ($delta) { return [int]$delta.TotalSeconds }
        $date = Get-DFXmlMember -Element $retryAfter -Name 'Date'
        if ($date) { return [int]([datetimeoffset]$date - [datetimeoffset]::UtcNow).TotalSeconds }
    } catch { }
    $null
}

function Build-DFPackageUniverseChocoRequestUrl {
    <#
    .SYNOPSIS
        Builds the FIRST-page request URL for the choco walk. Subsequent pages
        are NOT built here — they come from the server's own <link rel="next">
        continuation (see file header).
    .DESCRIPTION
        The filter is IsLatestVersion and nothing else. No Published /
        LastUpdated clause, no $skip, no $top: each of those is either ignored
        by the server or triggers the post-pagination full-catalog scan
        documented in the file header. This function takes no filter parameter
        precisely so a date clause cannot be threaded back in by accident.
    .OUTPUTS
        [string] the initial request URL.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    "https://community.chocolatey.org/api/v2/Packages()?`$filter=$([uri]::EscapeDataString('IsLatestVersion'))"
}

function ConvertFrom-DFPackageUniverseChocoFeedXml {
    <#
    .SYNOPSIS
        Parses one Atom/OData feed response into the fetch seam's contract:
        @{ Entries; NextUrl }.
    .DESCRIPTION
        Lives here rather than inline in Build-DFPackageUniverseRaw.ps1's
        default -ChocoFetchPage so it is unit-testable. It previously was
        inline, which meant the *production* fetch path had no test coverage at
        all (every test injects a fake seam in its place) — and that is exactly
        how it shipped a bug that would fire on the last page of every walk.

        THE LAST PAGE IS THE EDGE CASE. The final feed carries no
        <link rel="next"> — that absence is the end-of-walk signal — so the
        natural `($xml.feed.link | Where-Object { $_.rel -eq 'next' }).href`
        reads .href off nothing, which throws under strict mode. The walk would
        catch that as a transient error, retry it 3x, and report a FAILED walk
        at the precise moment it had actually succeeded: Complete=$false, prune
        skipped. An empty feed similarly makes $xml.feed.entry throw. Both go
        through Get-DFXmlMember, which returns $null instead.
    .PARAMETER Xml
        The parsed response body.
    .OUTPUTS
        pscustomobject with Entries (array, possibly empty) and NextUrl
        ($null at the end of the result set).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [xml]$Xml
    )

    $feed = Get-DFXmlMember -Element $Xml -Name 'feed'
    $links = @(@(Get-DFXmlMember -Element $feed -Name 'link') | Where-Object { $_ })
    $nextLink = $links | Where-Object { (Get-DFXmlMember -Element $_ -Name 'rel') -eq 'next' } | Select-Object -First 1
    $next = if ($nextLink) { [string](Get-DFXmlMember -Element $nextLink -Name 'href') } else { $null }

    [pscustomobject]@{
        # Null-guarded: an empty feed yields @($null) (Count 1), not @().
        Entries = @(@(Get-DFXmlMember -Element $feed -Name 'entry') | Where-Object { $_ })
        NextUrl = if ($next) { $next -replace '^http://', 'https://' } else { $null }
    }
}

function Invoke-DFPackageUniverseChocoLiveFetch {
    <#
    .SYNOPSIS
        The real (network) choco page fetcher: the production default behind
        Build-DFPackageUniverseRaw.ps1's -ChocoFetchPage seam.
    .DESCRIPTION
        Uses Invoke-WebRequest, not Invoke-RestMethod, so the feed-level
        <link rel="next"> continuation survives — Invoke-RestMethod
        deserializes only the entries and discards the next link, which is the
        one thing this walk navigates by. $skip/$top are never sent (the server
        ignores both; see file header).
    .PARAMETER Url
        The page URL: the initial walk URL, or a server-provided next-link.
    .PARAMETER TimeoutSec
        Per-request timeout.
    .OUTPUTS
        pscustomobject with Entries and NextUrl.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Url,

        [int]$TimeoutSec = 20
    )

    $resp = Invoke-WebRequest -Uri $Url -TimeoutSec $TimeoutSec
    ConvertFrom-DFPackageUniverseChocoFeedXml -Xml ([xml]$resp.Content)
}

function Invoke-DFPackageUniverseChocoPageWithRetry {
    <#
    .SYNOPSIS
        Fetches one choco OData page by URL, with status-aware handling.
    .DESCRIPTION
        Status handling:
          - HTTP 429 (rate limited): recognized immediately, never retried,
            and reported as RateLimited — sets RequestBudget.Aborted so the
            whole walk stops. Retrying during an hour-long ban is futile and
            can extend it.
          - HTTP 406 (item cap): recognized immediately and never retried.
            Under $skiptoken paging this should be UNREACHABLE (confirmed live
            2026-07-15 — see file header), so it is reported as CapHit and
            treated by the walk as a hard error worth investigating, not as a
            routine signal to partition. If this ever fires, the server's
            behavior has changed and the design's central assumption needs
            re-testing.
          - any other failure: 3-retry exponential backoff (1s/2s/4s), then
            logged as an error and reported as a soft failure (Ok=$false).

        The fetch is driven by explicit URLs (the initial URL, then each
        response's server-provided next-link), NOT by $skip.
    .PARAMETER FetchPage
        Scriptblock: param($Url) -> pscustomobject @{ Entries = @(...);
        NextUrl = <string|$null> }. NextUrl is the server's next-link ($null
        at the end of the result set).
    .PARAMETER Url
        The request URL for this page.
    .PARAMETER Log
        Scriptblock: param($Level, $PackageId, $Message) -> structured log
        (error/warning/review) that reaches pipeline_log.
    .PARAMETER Sleep
        Scriptblock: param($Milliseconds) -> pauses. Injectable so tests
        exercise backoff without real waits.
    .PARAMETER RequestBudget
        Mutable shared hashtable (see file header). Incremented once per real
        request attempt; the walk stops once Used reaches Max.
    .PARAMETER Trace
        Optional scriptblock: param($Message) -> verbose file-log line.
    .OUTPUTS
        pscustomobject with Ok, Entries, NextUrl, CapHit, BudgetExhausted,
        RateLimited.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock]$FetchPage,

        [Parameter(Mandatory)]
        [string]$Url,

        [Parameter(Mandatory)]
        [scriptblock]$Log,

        [Parameter(Mandatory)]
        [scriptblock]$Sleep,

        [Parameter(Mandatory)]
        [hashtable]$RequestBudget,

        [scriptblock]$Trace = { }
    )

    $delaysMs = 1000, 2000, 4000
    for ($attempt = 0; $attempt -le $delaysMs.Count; $attempt++) {
        if ($RequestBudget.Used -ge $RequestBudget.Max) {
            $RequestBudget.Aborted = $true
            $RequestBudget.AbortReason = "request budget ($($RequestBudget.Max)) exhausted"
            return [pscustomobject]@{ Ok = $false; Entries = @(); NextUrl = $null; CapHit = $false; BudgetExhausted = $true; RateLimited = $false }
        }
        $RequestBudget.Used++

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $page = & $FetchPage $Url
            $sw.Stop()
            # Null-guard: an empty feed yields @($null) (Count 1), not @().
            $entries = @(@(Get-DFXmlMember -Element $page -Name 'Entries') | Where-Object { $_ })
            $nextUrl = Get-DFXmlMember -Element $page -Name 'NextUrl'
            & $Trace "request ok: $($entries.Count) entries in $($sw.ElapsedMilliseconds)ms (budget $($RequestBudget.Used)/$($RequestBudget.Max)) url=[$Url]"
            return [pscustomobject]@{ Ok = $true; Entries = $entries; NextUrl = $nextUrl; CapHit = $false; BudgetExhausted = $false; RateLimited = $false }
        } catch {
            $sw.Stop()
            $statusCode = $null
            $exception = $_.Exception
            if ($exception.PSObject.Properties.Match('Response').Count -gt 0 -and $exception.Response) {
                try { $statusCode = [int]$exception.Response.StatusCode } catch { }
            }
            if (-not $statusCode) {
                if ($exception.Message -match '\b429\b') { $statusCode = 429 }
                elseif ($exception.Message -match '\b406\b') { $statusCode = 406 }
            }

            if ($statusCode -eq 406) {
                & $Trace "request cap-hit (406) after $($sw.ElapsedMilliseconds)ms url=[$Url]"
                return [pscustomobject]@{ Ok = $false; Entries = @(); NextUrl = $null; CapHit = $true; BudgetExhausted = $false; RateLimited = $false }
            }

            if ($statusCode -eq 429) {
                $retryAfter = Get-DFPackageUniverseChocoRetryAfterSeconds -ErrorRecord $_
                $retryNote = if ($null -ne $retryAfter) { " (Retry-After: ${retryAfter}s)" } else { '' }
                $RequestBudget.Aborted = $true
                $RequestBudget.AbortReason = "rate limited (HTTP 429)$retryNote"
                $RequestBudget.ErrorCount++
                & $Trace "request RATE-LIMITED (429)$retryNote url=[$Url] -- aborting choco walk"
                & $Log 'error' $null "choco: HTTP 429 rate limit hit$retryNote; aborting the choco walk to avoid a longer ban (url=$Url)"
                return [pscustomobject]@{ Ok = $false; Entries = @(); NextUrl = $null; CapHit = $false; BudgetExhausted = $false; RateLimited = $true }
            }

            if ($attempt -eq $delaysMs.Count) {
                $RequestBudget.ErrorCount++
                & $Trace "request FAILED (gave up after $($delaysMs.Count) retries) url=[$Url]: $_"
                & $Log 'error' $null "choco: page failed after $($delaysMs.Count) retries (url=$Url): $_"
                return [pscustomobject]@{ Ok = $false; Entries = @(); NextUrl = $null; CapHit = $false; BudgetExhausted = $false; RateLimited = $false }
            }

            & $Trace "request error (attempt $($attempt + 1), will retry after $($delaysMs[$attempt])ms) url=[$Url]: $_"
            & $Sleep $delaysMs[$attempt]
        }
    }
}

function Get-DFPackageUniverseChocoRows {
    <#
    .SYNOPSIS
        Entry point for choco acquisition: one unfiltered walk of the whole
        catalog, following the server's next-link continuation to exhaustion.
    .DESCRIPTION
        See the file header for why this is a single unfiltered walk rather
        than a partitioned or incremental crawl.

        Rows are handed to -WriteRows once per page rather than only at the
        end. This matters: an interrupted run on 2026-07-15 lost every row it
        had collected (~430 requests' worth) because nothing was written until
        the walk finished. Per-page flushing plus upsert semantics means an
        interrupted walk leaves behind everything it already fetched.

        Completeness is reported, never assumed. Complete=$true only when the
        walk ended on a missing next link — the server's definitive
        end-of-catalog signal. A 429, an exhausted budget, a failed page, or an
        unexpected 406 all yield Complete=$false, and the caller MUST NOT prune
        on an incomplete walk: "the run stopped early" is not "these packages
        were removed upstream".
    .PARAMETER FetchPage
        Scriptblock: param($Url) -> @{ Entries; NextUrl }.
    .PARAMETER Sleep
        Scriptblock: param($Milliseconds) -> pauses.
    .PARAMETER Log
        Scriptblock: param($Level, $PackageId, $Message).
    .PARAMETER WriteRows
        Scriptblock: param($Rows) -> persists one page's rows. Called once per
        page with that page's new rows. Defaults to a no-op (tests that only
        inspect the returned Rows need not supply one).
    .PARAMETER DelayMinMs
        Lower bound of the randomized/jittered inter-request pacing.
    .PARAMETER DelayMaxMs
        Upper bound of the randomized/jittered inter-request pacing.
    .PARAMETER MaxRequests
        Runaway backstop on total requests. A complete walk needs ~281.
    .PARAMETER Trace
        Optional scriptblock: param($Message) -> verbose file-log line.
    .OUTPUTS
        pscustomobject with Rows, SeenIds, Complete, ErrorCount, AbortReason,
        RequestsUsed and PageCount.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock]$FetchPage,

        [Parameter(Mandatory)]
        [scriptblock]$Sleep,

        [Parameter(Mandatory)]
        [scriptblock]$Log,

        [scriptblock]$WriteRows = { },

        [int]$DelayMinMs = 2500,

        [int]$DelayMaxMs = 6500,

        [int]$MaxRequests = 500,

        [scriptblock]$Trace = { }
    )

    $requestBudget = @{ Used = 0; Max = $MaxRequests; Aborted = $false; AbortReason = $null; ErrorCount = 0 }
    # Dedup is a defensive safety net only (the server has been observed to
    # re-deliver a last entry in edge cases). It is NOT the termination signal:
    # treating "no new ids on this page" as end-of-walk is exactly the bug that
    # produced a 125-row full crawl. Termination is the absence of a next link.
    $seenIds = [System.Collections.Generic.HashSet[string]]::new()
    $rows = [System.Collections.Generic.List[object]]::new()
    $completedNaturally = $false
    $pageNo = 0
    $url = Build-DFPackageUniverseChocoRequestUrl

    & $Trace "choco mode: single unfiltered walk (IsLatestVersion, next-link continuation); max requests=$MaxRequests"

    while ($url) {
        $pageNo++
        $result = Invoke-DFPackageUniverseChocoPageWithRetry -FetchPage $FetchPage -Url $url -Log $Log -Sleep $Sleep -RequestBudget $requestBudget -Trace $Trace

        if ($result.RateLimited) {
            & $Trace "walk aborted (rate limited) after $($rows.Count) rows over $pageNo page(s)"
            break
        }
        if ($result.BudgetExhausted) {
            & $Log 'error' $null "choco: request budget ($($requestBudget.Max)) exhausted mid-walk; stopping with partial data and skipping the prune"
            & $Trace "walk aborted (budget exhausted) after $($rows.Count) rows over $pageNo page(s)"
            break
        }
        if ($result.CapHit) {
            # Should be unreachable under skiptoken paging (see file header).
            $requestBudget.ErrorCount++
            & $Log 'error' $null "choco: unexpected HTTP 406 item cap during skiptoken paging at page $pageNo. This contradicts the 2026-07-15 live finding that the 10,000-item cap does not apply to next-link continuation; the server's behavior may have changed and the walk strategy needs re-testing."
            & $Trace "walk aborted (UNEXPECTED 406 cap-hit) at page $pageNo after $($rows.Count) rows"
            break
        }
        if (-not $result.Ok) {
            & $Trace "walk aborted (page failed) at page $pageNo after $($rows.Count) rows"
            break
        }

        $pageRows = [System.Collections.Generic.List[object]]::new()
        foreach ($entry in @($result.Entries)) {
            if (-not $entry) { continue }
            try {
                $row = ConvertTo-DFPackageUniverseChocoRow -Entry $entry
            } catch {
                & $Log 'warning' $null "unmappable choco entry: $_"
                continue
            }
            if (-not $row -or -not $row.package_id) { continue }
            if ($seenIds.Add($row.package_id)) {
                $pageRows.Add($row)
                $rows.Add($row)
            }
        }

        if ($pageRows.Count -gt 0) { & $WriteRows $pageRows }
        & $Trace "  page ${pageNo}: $(@($result.Entries).Count) entries, $($pageRows.Count) new, $($rows.Count) total"

        $url = $result.NextUrl
        if (-not $url) {
            $completedNaturally = $true
            & $Trace "walk end (no next link): $($rows.Count) rows over $pageNo page(s)"
            break
        }

        $delay = if ($DelayMaxMs -gt $DelayMinMs) { Get-Random -Minimum $DelayMinMs -Maximum $DelayMaxMs } else { $DelayMinMs }
        & $Sleep $delay
    }

    $complete = $completedNaturally -and -not $requestBudget.Aborted
    & $Trace "choco walk finished: rows=$($rows.Count) complete=$complete errors=$($requestBudget.ErrorCount) requestsUsed=$($requestBudget.Used)/$($requestBudget.Max)$(if ($requestBudget.AbortReason) { " abortReason=$($requestBudget.AbortReason)" })"

    [pscustomobject]@{
        Rows         = $rows
        SeenIds      = $seenIds
        Complete     = $complete
        ErrorCount   = $requestBudget.ErrorCount
        AbortReason  = $requestBudget.AbortReason
        RequestsUsed = $requestBudget.Used
        PageCount    = $pageNo
    }
}
