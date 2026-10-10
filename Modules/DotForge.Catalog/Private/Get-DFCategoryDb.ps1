#Requires -Version 7.2

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

    $readArgs = @{
        FileName           = 'tool-categories.json'
        Validator          = 'Test-DFCategoryDbSchema'
        Label              = 'category db'
        UnavailableMessage = 'category database is unavailable — -Category/-WorksWith search and card discovery sections will be empty.'
    }
    if ($Path) { $readArgs.ShippedPath = $Path }
    $raw = Read-DFReleaseData @readArgs

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
        own convention); Get-DFIdentityKeys supplies both keys, the same ones
        the catalog merge uses.
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
            $hit = @(Get-DFIdentityKeys -Source $s.Source -PackageId $s.PackageId) |
                Where-Object { $Database.IdIndex.ContainsKey($_) } | Select-Object -First 1
            if ($hit) { $key = $Database.IdIndex[$hit]; break }
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
