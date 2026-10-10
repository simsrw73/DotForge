#Requires -Version 7.0

function Resolve-DFCatalogQueryMerge {
    <#
    .SYNOPSIS
        Core catalog search-and-merge: fans a query out across every
        provider, overlays installed state, groups hits into one row per
        tool (via the Tools/*.json identity map), sorts by match quality,
        and applies the PATH fallback.
    .DESCRIPTION
        Shared by Find-DFPackage's ordinary query path and its
        -Category/-WorksWith facet search — both need "resolve this
        text/name to accurate, live ToolInfo results," and this is the one
        place that logic lives.
    .PARAMETER QueryText
        The query text (already qualified-id-stripped, if applicable).
    .PARAMETER Source
        Restrict to these catalogs.
    .PARAMETER Fresh
        Block on live catalog fetches instead of serving cached data.
    .PARAMETER RecordSeenQuery
        Whether to record QueryText in the seen-queries LRU (the
        Update-DFPackageCache re-warm list). Default $true, matching
        Find-DFPackage's existing single-query behavior. Facet-search callers
        pass $false to avoid polluting the LRU with N synthetic per-tool
        lookups for one facet search.
    .PARAMETER InstalledInfo
        A Get-DFCatalogInstalled result to annotate hits with. Default: take a
        fresh snapshot. A caller merging several queries (facet search) takes
        one snapshot and passes it to each, since a snapshot enumerates every
        catalog's installed packages in parallel runspaces.
    .PARAMETER IdentityGuide
        A Get-DFToolIdentityGuide result. Default: load it (cached per session).
    .OUTPUTS
        [object[]] — sorted DotForge.ToolInfo array, PATH fallback applied.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [string]$QueryText,

        [string[]]$Source,

        [switch]$Fresh,

        [bool]$RecordSeenQuery = $true,

        [hashtable]$InstalledInfo,

        [object]$IdentityGuide
    )

    $normalized = (ConvertTo-DFCatalogQueryKey -Query $QueryText).Normalized
    $providers = @(Get-DFCatalogProvider -Source $Source)

    # Fan out across catalogs (canonical order), then overlay installed state
    # from a live installed snapshot (taken here unless the caller passed one).
    # First runs can spend a while on index builds and live fetches, so keep the
    # user informed via the progress stream (renders as a status line; never
    # pollutes stdout).
    $progressId = 47
    try {
        $hits = [System.Collections.Generic.List[object]]::new()
        for ($i = 0; $i -lt $providers.Count; $i++) {
            $provider = $providers[$i]
            Write-Progress -Id $progressId -Activity 'trifle' `
                -Status "Searching $($provider.Name) catalog… (first run may build local indexes)" `
                -PercentComplete ([int](100 * $i / ($providers.Count + 1)))
            foreach ($hit in @(& $provider.Search $QueryText $Fresh.IsPresent)) {
                if ($hit) { $hits.Add($hit) }
            }
        }

        Write-Progress -Id $progressId -Activity 'trifle' `
            -Status 'Reading installed packages…' `
            -PercentComplete ([int](100 * $providers.Count / ($providers.Count + 1)))
        if (-not $InstalledInfo) { $InstalledInfo = Get-DFCatalogInstalled }
        $installedInfo = $InstalledInfo
    } finally {
        Write-Progress -Id $progressId -Activity 'trifle' -Completed
    }
    $installedBySource = @{}
    foreach ($item in $installedInfo.Items) {
        if (-not $installedBySource.ContainsKey($item.Source)) { $installedBySource[$item.Source] = @{} }
        foreach ($key in @($item.Name, $item.PackageId)) {
            if ($key) { $installedBySource[$item.Source][([string]$key).ToLowerInvariant()] = $item.InstalledVersion }
        }
    }
    foreach ($hit in $hits) {
        $map = $installedBySource[$hit.Source]
        if (-not $map) { continue }
        foreach ($key in @($hit.Name, $hit.PackageId)) {
            $lookup = ([string]$key).ToLowerInvariant()
            if ($map.ContainsKey($lookup)) {
                $hit.Installed = $true
                $hit.InstalledVersion = $map[$lookup]
                break
            }
        }
    }

    if ($RecordSeenQuery) { Add-DFCatalogSeenQuery -Query $QueryText }

    # Merge per-catalog hits into one row per tool: an identity link — either
    # the live Tools/*.json packages map, or the precomputed tool-identity
    # guide (data/tool-identities.json) — collapses hits under the DotForge
    # tool name even when catalogs name the package differently. On a
    # (source, packageId) conflict between the two, Tools/*.json wins (it's
    # checked first and short-circuits). Bare name-string matching across
    # DIFFERENT catalog sources is never used as a grouping key — two
    # unlinked same-named hits from different sources render as separate
    # rows, on purpose: a shared display name is not proof of shared
    # identity (see docs/superpowers/specs/2026-07-06-trifle-tool-identity-guide-design.md).
    $identityGuide = $IdentityGuide ?? (Get-DFToolIdentityGuide)

    $resolveDFTool = {
        param($Hit)
        $keys = @(Get-DFIdentityKeys -Source $Hit.Source -PackageId $Hit.PackageId)
        foreach ($k in $keys) { if ($installedInfo.IdentityMap[$k]) { return $installedInfo.IdentityMap[$k] } }
        foreach ($k in $keys) { if ($identityGuide.IdIndex[$k]) { return $identityGuide.IdIndex[$k] } }
    }

    $groups = [ordered]@{}
    $dfNames = @{}
    foreach ($hit in $hits) {
        $dfName = & $resolveDFTool $hit
        # No identity link: group by source-qualified name, never bare name
        # alone — two different catalogs' same-named packages must never
        # merge without a genuine identity link backing them.
        $key = $dfName ? "df:$dfName" : "$($hit.Source):$($hit.Name.ToLowerInvariant())"
        if (-not $groups.Contains($key)) {
            $groups[$key] = [System.Collections.Generic.List[object]]::new()
            if ($dfName) { $dfNames[$key] = $dfName }
        }
        $groups[$key].Add($hit)
    }

    $merged = @(foreach ($entry in $groups.GetEnumerator()) {
        $sources = @($entry.Value)
        $dfTool = $dfNames[$entry.Key]
        $latest = [ordered]@{}
        foreach ($s in $sources) { if ($s.LatestVersion) { $latest[$s.Source] = $s.LatestVersion } }

        $installedSources = @($sources | Where-Object Installed)
        $matchKind = if ($sources.MatchKind -contains 'exact-id') { 'exact-id' }
                     elseif ($sources.MatchKind -contains 'exact-name') { 'exact-name' }
                     else { 'keyword' }

        New-DFToolInfo -Name ($dfTool ? $dfTool : $sources[0].Name) `
            -Description (@($sources.Description) -ne '' -ne $null | Select-Object -First 1) `
            -Installed:($installedSources.Count -gt 0) `
            -InstalledVia @($installedSources.Source) `
            -InstalledVersion (@($installedSources.InstalledVersion) | Select-Object -First 1) `
            -Sources $sources `
            -Latest $latest `
            -Homepage (@($sources.Homepage) -ne '' -ne $null | Select-Object -First 1) `
            -License (@($sources.License) -ne '' -ne $null | Select-Object -First 1) `
            -DFTool $dfTool `
            -MatchKind $matchKind `
            -CacheAge (@($sources.CacheAgeMinutes | Measure-Object -Maximum).Maximum)
    })

    # Best matches first: exact package-id, then exact name/moniker, then
    # keyword hits; installed tools win ties, then alphabetical.
    $matchRank = @{ 'exact-id' = 0; 'exact-name' = 1; 'keyword' = 2 }
    $merged = @($merged | Sort-Object `
        { $matchRank[$_.MatchKind] }, { -not $_.Installed }, Name)

    # PATH fallback: the command exists locally but no catalog claims it.
    if ($normalized -notmatch ' ') {
        $pathCommand = Get-Command -Name $normalized -ErrorAction Ignore | Select-Object -First 1
        if ($pathCommand) {
            foreach ($info in $merged) {
                if (-not $info.Installed -and $info.MatchKind -in 'exact-id', 'exact-name') {
                    $info.Installed = $true
                    $info.InstalledVia = @('PATH')
                    if ($pathCommand.Version) { $info.InstalledVersion = [string]$pathCommand.Version }
                }
            }
        }
    }

    $merged
}

function Find-DFCatalogFacet {
    <#
    .SYNOPSIS
        Resolves a category search (Find-DFPackage -Category/-WorksWith) to merged, live catalog rows.
    .DESCRIPTION
        Validates the terms against the category database's taxonomy (an
        unknown term is a terminating error), ORs values within a facet, ANDs
        -Category with -WorksWith, then resolves each matching tool through the
        normal search-and-merge path, so installed state and versions are live.
        A tool whose database ids no longer resolve in any catalog is skipped.
        One installed snapshot and identity guide serve the whole search.
    .PARAMETER Database
        Get-DFCategoryDb result (must have Raw).
    .PARAMETER Category
        Function-facet terms.
    .PARAMETER WorksWith
        Works-with-facet terms.
    .PARAMETER Source
        Restrict to these catalogs.
    .PARAMETER Fresh
        Block on live catalog fetches.
    .OUTPUTS
        DotForge.ToolInfo[], sorted by name.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Database,
        [string[]]$Category,
        [string[]]$WorksWith,
        [string[]]$Source,
        [switch]$Fresh
    )
    $db = $Database
        $validateFacet = {
            param($Values, $FacetName, $Vocab)
            $bad = @($Values | Where-Object { $_ -notin $Vocab })
            if ($bad) {
                Write-Error "DotForge: unknown $FacetName value(s): $($bad -join ', '). Run Get-DFCategoryList -Facet $FacetName to see valid terms." -ErrorAction Stop
            }
        }
        if ($Category) { & $validateFacet $Category 'function' @($db.Raw.taxonomy.function) }
        if ($WorksWith) { & $validateFacet $WorksWith 'worksWith' @($db.Raw.taxonomy.worksWith) }

        $unionFacet = {
            param($Values, $Prefix)
            if (-not $Values) { return $null }
            $union = [System.Collections.Generic.HashSet[string]]::new()
            foreach ($v in $Values) { foreach ($k in @($db.FacetIndex["${Prefix}:$v"])) { $null = $union.Add($k) } }
            $union
        }
        $catMatch = & $unionFacet $Category 'function'
        $wwMatch = & $unionFacet $WorksWith 'worksWith'
        $matchedKeys =
            if ($catMatch -and $wwMatch) { @($catMatch | Where-Object { $wwMatch.Contains($_) }) }
            elseif ($catMatch) { @($catMatch) }
            else { @($wwMatch) }

        $canonicalOrder = Get-DFCatalogName
        $allowedSources = $Source ? $Source : $canonicalOrder

        # One installed snapshot and identity guide for the whole facet search,
        # not one per matched tool.
        $installedInfo = Get-DFCatalogInstalled
        $identityGuide = Get-DFToolIdentityGuide
        $merged = [System.Collections.Generic.List[object]]::new()
        foreach ($key in ($matchedKeys | Sort-Object -Unique)) {
            $entry = $db.Raw.tools.$key
            $probeQueryText = $key
            $probeSource = $Source
            if ($entry.ids) {
                foreach ($src in $canonicalOrder) {
                    if ($src -notin $allowedSources) { continue }
                    $idProp = $entry.ids.PSObject.Properties[$src]
                    if ($idProp) { $probeQueryText = $idProp.Value; $probeSource = @($src); break }
                }
            }

            # A db entry whose ids no longer resolve against any live catalog
            # (renamed/removed upstream) is silently skipped — stale seed
            # data, not a search failure.
            $hits = @(Resolve-DFCatalogQueryMerge -QueryText $probeQueryText -Source $probeSource -Fresh:$Fresh -RecordSeenQuery $false `
                -InstalledInfo $installedInfo -IdentityGuide $identityGuide)
            if ($hits) { $merged.Add($hits[0]) }
        }
    @($merged | Sort-Object Name)
}
