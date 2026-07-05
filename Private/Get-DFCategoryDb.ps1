#Requires -Version 7.0

# Lazy-loaded, indexed category database for trifle discovery (-Category,
# -WorksWith, Get-DFCategoryList, the detail card's Category/Related/Alt-to
# sections). Ships as data/tool-categories.json; Update-DFCategoryDb can
# place a newer copy under $XDG_DATA_HOME/dotforge/. The db is an index into
# real catalog data — every consumer still resolves matches through the
# normal search-and-merge path, never trusting the db's own snapshot of
# versions/availability.

function Get-DFCategoryDb {
    <#
    .SYNOPSIS
        Loads (and indexes) the trifle category database. Lazy singleton;
        never throws — an unreadable file degrades to an empty, valid,
        harmless db object.
    .PARAMETER Path
        Override the shipped-side location (a test seam — lets a fixture
        stand in for the real shipped file). The refreshed-vs-shipped
        precedence check against $Env:XDG_DATA_HOME still runs normally
        against this override, so tests can exercise the full resolution
        algorithm without depending on the real data/tool-categories.json.
        Always forces a fresh, uncached read.
    .PARAMETER Force
        Reload from the resolved location, bypassing the singleton cache.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [string]$Path,
        [switch]$Force
    )

    if (-not $Path -and -not $Force -and $script:DFCategoryDb) {
        return $script:DFCategoryDb
    }

    $shippedPath = $Path ? $Path : (Join-Path $PSScriptRoot '../data/tool-categories.json')
    $resolvedPath = $shippedPath

    if ($Env:XDG_DATA_HOME) {
        $refreshedPath = Join-Path $Env:XDG_DATA_HOME 'dotforge/tool-categories.json'
        if (Test-Path $refreshedPath) {
            try {
                $shippedUpdated = (Test-Path $shippedPath) ? (Get-Content $shippedPath -Raw | ConvertFrom-Json).updated : $null
                $refreshedUpdated = (Get-Content $refreshedPath -Raw | ConvertFrom-Json).updated
                if (-not $shippedUpdated -or [datetime]$refreshedUpdated -gt [datetime]$shippedUpdated) {
                    $resolvedPath = $refreshedPath
                }
            } catch {
                Write-Verbose "DotForge: unreadable refreshed category db '$refreshedPath', using shipped: $_"
            }
        }
    }

    # Two-tier fallback: a resolved refreshed copy that turns out corrupt —
    # whether unparseable JSON or merely schema-invalid — always falls back
    # to the shipped copy before giving up. (An unparseable refreshed file
    # that fails even the earlier date-comparison read never gets selected
    # as $resolvedPath in the first place, so it's already excluded here;
    # this covers the remaining case: valid JSON, valid 'updated', but the
    # document itself fails schema validation.)
    $tryLoadCategoryDb = {
        param($p)
        if (-not (Test-Path $p)) { return $null }
        try {
            $doc = Get-Content $p -Raw | ConvertFrom-Json
            $errs = $null
            if (Test-DFCategoryDbSchema -Database $doc -Errors ([ref]$errs)) { return $doc }
            Write-Verbose "DotForge: category db at '$p' failed schema validation: $($errs -join '; ')"
            return $null
        } catch {
            Write-Verbose "DotForge: unreadable category db '$p': $_"
            return $null
        }
    }

    $usedRefreshed = ($resolvedPath -ne $shippedPath)
    $raw = & $tryLoadCategoryDb $resolvedPath
    if (-not $raw -and $usedRefreshed) {
        $raw = & $tryLoadCategoryDb $shippedPath
    }

    if (-not $raw -and -not $script:DFCategoryDbWarned) {
        Write-Warning 'DotForge: category database is unavailable — -Category/-WorksWith search and card discovery sections will be empty.'
        $script:DFCategoryDbWarned = $true
    }

    $nameIndex = @{}
    $idIndex = @{}
    $facetIndex = @{}

    if ($raw) {
        foreach ($prop in $raw.tools.PSObject.Properties) {
            $key = $prop.Name
            $entry = $prop.Value

            $nameIndex[$key.ToLowerInvariant()] = $key
            foreach ($alias in @($entry.aliases)) {
                if ($alias) { $nameIndex[([string]$alias).ToLowerInvariant()] = $key }
            }

            if ($entry.ids) {
                foreach ($idProp in $entry.ids.PSObject.Properties) {
                    $idIndex["$($idProp.Name):$($idProp.Value)".ToLowerInvariant()] = $key
                }
            }

            foreach ($f in @($entry.function)) {
                $facetKey = "function:$f"
                if (-not $facetIndex.ContainsKey($facetKey)) { $facetIndex[$facetKey] = [System.Collections.Generic.List[string]]::new() }
                $facetIndex[$facetKey].Add($key)
            }
            foreach ($w in @($entry.worksWith)) {
                $facetKey = "worksWith:$w"
                if (-not $facetIndex.ContainsKey($facetKey)) { $facetIndex[$facetKey] = [System.Collections.Generic.List[string]]::new() }
                $facetIndex[$facetKey].Add($key)
            }
        }
    }

    $db = [pscustomobject]@{
        Raw        = $raw
        NameIndex  = $nameIndex
        IdIndex    = $idIndex
        FacetIndex = $facetIndex
    }

    if (-not $Path) { $script:DFCategoryDb = $db }
    $db
}

function Get-DFCategoryDbEntry {
    <#
    .SYNOPSIS
        Resolves a merged DotForge.ToolInfo to its category-db entry, trying
        DFTool name, then each source:packageId, then plain name. Returns
        $null when the tool isn't in the seed db — a normal, expected case.
    .DESCRIPTION
        Scoop package ids are bucket-qualified at runtime (e.g. 'main/fd')
        but the seed data stores bare names ('fd', matching Tools/*.json's
        own convention) — so a scoop id lookup that misses on the full value
        retries with just the trailing segment after '/', mirroring the same
        bucket-stripping Find-DFPackage's resolveDFTool scriptblock uses.
    .PARAMETER Info
        A DotForge.ToolInfo (or any object with DFTool/Name/Sources shape).
    .PARAMETER Database
        The category db (defaults to Get-DFCategoryDb with no overrides).
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        $Info,

        $Database = (Get-DFCategoryDb)
    )

    if (-not $Database.Raw) { return $null }

    $key = $null
    if ($Info.DFTool) { $key = $Database.NameIndex[$Info.DFTool.ToLowerInvariant()] }
    if (-not $key) {
        foreach ($s in @($Info.Sources)) {
            $lookup = "$($s.Source):$($s.PackageId)".ToLowerInvariant()
            if ($Database.IdIndex.ContainsKey($lookup)) { $key = $Database.IdIndex[$lookup]; break }
            if ($s.Source -eq 'scoop' -and $s.PackageId -match '/') {
                $bareLookup = "scoop:$(($s.PackageId -split '/')[-1])".ToLowerInvariant()
                if ($Database.IdIndex.ContainsKey($bareLookup)) { $key = $Database.IdIndex[$bareLookup]; break }
            }
        }
    }
    if (-not $key -and $Info.Name) { $key = $Database.NameIndex[$Info.Name.ToLowerInvariant()] }
    if (-not $key) { return $null }

    [pscustomobject]@{ Key = $key; Entry = $Database.Raw.tools.$key }
}

function Get-DFCategoryRelatedTools {
    <#
    .SYNOPSIS
        Computes the "Related" list for one tool: its curated relatedTo
        entries first, then same-function tools by popularity descending,
        excluding itself, capped at 6, deduplicated.
    .PARAMETER Database
        The category db.
    .PARAMETER Key
        The tool key to compute relations for.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        $Database,

        [Parameter(Mandatory)]
        [string]$Key
    )

    if (-not $Database.Raw -or -not $Database.Raw.tools.$Key) { return @() }

    $entry = $Database.Raw.tools.$Key
    $related = [System.Collections.Generic.List[string]]::new()
    foreach ($r in @($entry.relatedTo)) { if ($r -and $r -ne $Key -and $r -notin $related) { $related.Add($r) } }

    if ($related.Count -lt 6) {
        $candidates = [System.Collections.Generic.List[string]]::new()
        foreach ($f in @($entry.function)) {
            foreach ($otherKey in @($Database.FacetIndex["function:$f"])) {
                if ($otherKey -ne $Key -and $otherKey -notin $related -and $otherKey -notin $candidates) {
                    $candidates.Add($otherKey)
                }
            }
        }
        $fill = @($candidates | Sort-Object `
            { -($Database.Raw.tools.$_.popularity ?? 0) }, { $_ } |
            Select-Object -First (6 - $related.Count))
        foreach ($f in $fill) { $related.Add($f) }
    }

    @($related | Select-Object -First 6)
}
