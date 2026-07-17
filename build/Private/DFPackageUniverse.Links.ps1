#Requires -Version 7.0

# Phase B (identity clustering) build helpers. Reads raw_packages produced by
# Phase A acquisition; derives cross-catalog link signals, scores them, and
# unions them into clusters. See
# docs/superpowers/specs/2026-07-16-package-universe-identity-clustering-design.md

function Get-DFPackageUniverseRepoKey {
    <#
    .SYNOPSIS
        Derives a normalized GitHub owner/repo key (lowercase) from a
        raw_packages row, or $null when none is discoverable.
    .PARAMETER Row
        A raw_packages-shaped object (source, homepage, extra JSON string).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Row
    )

    # Priority (per spec): the source-specific repo fields win over homepage,
    # because homepage is often a docs/landing page while ProjectSourceUrl /
    # checkver / autoupdate name the actual source repo. Homepage is the fallback.
    $candidates = [System.Collections.Generic.List[string]]::new()

    $extra = $null
    if ($Row.extra) { try { $extra = $Row.extra | ConvertFrom-Json } catch { $extra = $null } }
    if ($extra) {
        switch ($Row.source) {
            'choco' {
                # ProjectSourceUrl/ProjectUrl are the tool's own repo. NOT
                # PackageSourceUrl -- that is the shared chocolatey packaging repo.
                foreach ($key in 'ProjectSourceUrl', 'ProjectUrl') {
                    $prop = $extra.PSObject.Properties[$key]
                    if ($prop -and $prop.Value) { $candidates.Add([string]$prop.Value) }
                }
            }
            'scoop' {
                # checkver / autoupdate frequently name the real repo when homepage
                # is a vanity domain: checkver is a bare github url or { github: ... };
                # autoupdate is a nested object whose arch urls point at github
                # releases -- serialize it and let the github regex find the repo.
                $cv = $extra.PSObject.Properties['checkver']
                if ($cv -and $cv.Value) {
                    if ($cv.Value -is [string]) {
                        $candidates.Add($cv.Value)
                    } else {
                        $gh = $cv.Value.PSObject.Properties['github']
                        if ($gh -and $gh.Value) { $candidates.Add([string]$gh.Value) }
                    }
                }
                $au = $extra.PSObject.Properties['autoupdate']
                if ($au -and $au.Value) { $candidates.Add((ConvertTo-Json -Compress -Depth 8 -InputObject $au.Value)) }
            }
        }
    }

    if ($Row.homepage) { $candidates.Add([string]$Row.homepage) }

    foreach ($url in $candidates) {
        if ($url -match 'github\.com[/:]([^/#?\s]+)/([^/#?\s]+)') {
            return (("$($Matches[1])/$($Matches[2])") -replace '\.git$', '').ToLowerInvariant()
        }
    }
    $null
}

function ConvertTo-DFNormalizedName {
    <#
    .SYNOPSIS
        Canonical name key: lowercased, non-alphanumeric stripped. '' for empty.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][string]$Value)

    if (-not $Value) { return '' }
    ($Value.ToLowerInvariant() -replace '[^a-z0-9]', '')
}

function ConvertTo-DFNormalizedPublisher {
    <#
    .SYNOPSIS
        Canonical publisher key: lowercased, common corporate suffixes removed
        ('DWANGO Co., Ltd.' -> 'dwango'), then non-alphanumeric stripped. '' for
        empty -- scoop rows have no publisher, so they never match on this key.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][string]$Value)

    if (-not $Value) { return '' }
    $t = $Value.ToLowerInvariant()
    $t = $t -replace '\b(inc|ltd|llc|gmbh|corp|corporation|company|co|software|technologies|technology|team|project|limited|dmcc|ag|srl|sarl|oy|ab)\b', ''
    ($t -replace '[^a-z0-9]', '')
}

function Get-DFPackageUniverseLinkKeys {
    <#
    .SYNOPSIS
        Derives every cross-catalog link key for one raw_packages row:
        Repo, Homepage, PubName, Name. Any of them may be $null when the row
        cannot supply that signal.
    .DESCRIPTION
        - Repo     : github owner/repo (strongest); see Get-DFPackageUniverseRepoKey.
        - Homepage : normalized non-github homepage WITH a path. A github homepage
                     is left to the repo tier; a bare domain is too weak (-> review).
        - PubName  : 'normpub|normname', only when a publisher is present. Scoop
                     rows have no publisher, so they never match on this key.
        - Name     : normalized name, gated to length >= 4 to drop the 'fd'/'air'
                     short-name collision class. Review-only downstream.
    .PARAMETER Row
        A raw_packages-shaped object.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Row
    )

    $name = ConvertTo-DFNormalizedName -Value $Row.name
    $pub = ConvertTo-DFNormalizedPublisher -Value $Row.publisher

    $homepage = $null
    if ($Row.homepage) {
        $norm = ConvertTo-DFNormalizedHomepage -Url ([string]$Row.homepage)
        if ($norm -and $norm -notmatch 'github\.com' -and $norm.Contains('/')) { $homepage = $norm }
    }

    [pscustomobject]@{
        Repo     = Get-DFPackageUniverseRepoKey -Row $Row
        Homepage = $homepage
        PubName  = if ($pub -and $name) { "$pub|$name" } else { $null }
        Name     = if ($name.Length -ge 4) { $name } else { $null }
    }
}

function Get-DFPackageUniverseKeyedRows {
    <#
    .SYNOPSIS
        Projects raw rows to { Row; Keys } items (link keys precomputed once).
        Shared by the edge builder and the family collector.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows)
    @(foreach ($r in $Rows) { [pscustomobject]@{ Row = $r; Keys = (Get-DFPackageUniverseLinkKeys -Row $r) } })
}

function Test-DFPackageUniverseFamily {
    <#
    .SYNOPSIS
        True when a repo/homepage group looks like a monorepo or vendor family:
        either at least -Threshold members carrying at least two distinct
        normalized names (the large heterogeneous case, e.g. nerd-fonts), OR
        every member comes from a single source and carries at least two
        distinct normalized names regardless of size (a small same-source
        vendor cluster, e.g. winget's OpenDsc.Lcm/Resources/Server -- distinct
        tools sharing one repo). Such a group is not one tool and must not be
        auto-merged. A CROSS-source group with distinct names (e.g. ripgrep's
        winget+choco+scoop cluster) is deliberately NOT covered by the
        single-source rule and still merges.
    #>
    [CmdletBinding()]
    param([object[]]$Members, [int]$Threshold)

    $members = @($Members)
    $names = @($members | ForEach-Object { ConvertTo-DFNormalizedName -Value $_.Row.name } | Where-Object { $_ } | Select-Object -Unique)
    if ($names.Count -lt 2) { return $false }
    $sources = @($members | ForEach-Object { $_.Row.source } | Select-Object -Unique)
    return ($members.Count -ge $Threshold) -or ($sources.Count -eq 1)
}

function Get-DFPackageUniverseFamilyGroups {
    <#
    .SYNOPSIS
        Repo/homepage groups classified as monorepos/vendor families (shared key,
        many distinct names). These are excluded from auto-clustering by
        Get-DFPackageUniverseLinkEdges and surfaced here for human review.
    .PARAMETER Rows
        raw_packages-shaped rows.
    .PARAMETER FamilySizeThreshold
        Minimum members for a heterogeneous shared-key group to count as a family.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Rows,

        [int]$FamilySizeThreshold = 5
    )

    $items = Get-DFPackageUniverseKeyedRows -Rows $Rows

    foreach ($tier in @('Repo', 'Homepage')) {
        $groups = $items | Where-Object { $_.Keys.$tier } | Group-Object { $_.Keys.$tier }
        foreach ($g in $groups) {
            $members = @($g.Group)
            if (Test-DFPackageUniverseFamily -Members $members -Threshold $FamilySizeThreshold) {
                [pscustomobject]@{
                    Tier    = $tier.ToLowerInvariant()
                    Key     = $g.Name
                    Size    = $members.Count
                    Members = @($members | ForEach-Object { $_.Row })
                }
            }
        }
    }
}

function Get-DFPackageUniverseLinkEdges {
    <#
    .SYNOPSIS
        Builds the pairwise evidence graph from raw_packages rows: one edge per
        cross-catalog pair that shares a link key, tagged with method + confidence.
    .DESCRIPTION
        Tiers are applied strongest-first (repo 1.0 -> homepage 0.75 ->
        publisher-name 0.60 -> name-only 0.20); a pair that already has an edge
        from a stronger tier is not re-emitted by a weaker one, so name-only stays
        the recall-reaching, review-only tier without polluting already-linked
        pairs. In the publisher-name and name-only tiers a pair whose two members
        resolve to DIFFERENT github repos is emitted as a 'conflict' edge (0.30)
        instead -- the fork/collision case (e.g. air-verse/air vs posit-dev/air),
        routed to review rather than merged.
    .PARAMETER Rows
        raw_packages-shaped rows.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Rows,

        [int]$FamilySizeThreshold = 5
    )

    $items = Get-DFPackageUniverseKeyedRows -Rows $Rows

    $edges = [System.Collections.Generic.List[object]]::new()
    $linked = [System.Collections.Generic.HashSet[string]]::new()

    $tiers = @(
        [pscustomobject]@{ Key = 'Repo';     Method = 'repo';           Conf = 1.0;  Conflict = $false; Family = $true }
        [pscustomobject]@{ Key = 'Homepage'; Method = 'homepage';       Conf = 0.75; Conflict = $false; Family = $true }
        [pscustomobject]@{ Key = 'PubName';  Method = 'publisher-name'; Conf = 0.60; Conflict = $true;  Family = $false }
        [pscustomobject]@{ Key = 'Name';     Method = 'name-only';      Conf = 0.20; Conflict = $true;  Family = $false }
    )

    foreach ($tier in $tiers) {
        $keyName = $tier.Key
        $groups = $items | Where-Object { $_.Keys.$keyName } | Group-Object { $_.Keys.$keyName }
        foreach ($g in $groups) {
            $members = @($g.Group)
            if ($members.Count -lt 2) { continue }

            # Monorepo / vendor-family guard: a repo or homepage shared by many
            # distinctly-named packages (nerd-fonts, dot.net/core) is a family, not
            # one tool. Do not auto-merge it -- Get-DFPackageUniverseFamilyGroups
            # surfaces it for review instead.
            if ($tier.Family -and (Test-DFPackageUniverseFamily -Members $members -Threshold $FamilySizeThreshold)) { continue }

            for ($i = 0; $i -lt $members.Count; $i++) {
                for ($j = $i + 1; $j -lt $members.Count; $j++) {
                    $a = $members[$i]
                    $b = $members[$j]
                    $ka = "$($a.Row.source)|$($a.Row.package_id)"
                    $kb = "$($b.Row.source)|$($b.Row.package_id)"
                    $pairId = if ($ka -le $kb) { "$ka::$kb" } else { "$kb::$ka" }
                    if ($linked.Contains($pairId)) { continue }

                    $method = $tier.Method
                    $conf = $tier.Conf
                    if ($tier.Conflict) {
                        $ra = $a.Keys.Repo
                        $rb = $b.Keys.Repo
                        if ($ra -and $rb -and $ra -ne $rb) { $method = 'conflict'; $conf = 0.30 }
                    }

                    [void]$linked.Add($pairId)
                    $edges.Add([pscustomobject]@{
                        SourceA    = $a.Row.source
                        PackageIdA = $a.Row.package_id
                        SourceB    = $b.Row.source
                        PackageIdB = $b.Row.package_id
                        Method     = $method
                        Confidence = $conf
                        Evidence   = $g.Name
                    })
                }
            }
        }
    }

    $edges.ToArray()
}

function Invoke-DFPackageUniverseLinkBuild {
    <#
    .SYNOPSIS
        The Phase B core: reads raw_packages from an open connection, derives the
        edge graph, applies the curation file, clusters, persists everything, and
        returns a reconciliation summary. The schema must already be initialized.
    .PARAMETER Connection
        An open PSSQLite connection to universe.db.
    .PARAMETER CurationPath
        Path to the curation .jsonc (may be missing -> no curation).
    .PARAMETER Threshold
        Minimum edge confidence that forms a cluster (default 0.60).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Connection,
        [string]$CurationPath,
        [double]$Threshold = 0.60,
        [int]$FamilySizeThreshold = 5
    )

    # PSSQLite returns [DBNull] for NULL columns; coerce to $null so downstream
    # truthiness checks and string casts behave.
    $raw = @(Invoke-SqliteQuery -SQLiteConnection $Connection -Query 'SELECT source, package_id, name, version, description, homepage, license, publisher, tags, extra FROM raw_packages')
    $rows = @(foreach ($r in $raw) {
        [pscustomobject]@{
            source     = $r.source
            package_id = $r.package_id
            name       = if ($r.name -is [DBNull]) { $null } else { $r.name }
            homepage   = if ($r.homepage -is [DBNull]) { $null } else { $r.homepage }
            publisher  = if ($r.publisher -is [DBNull]) { $null } else { $r.publisher }
            extra      = if ($r.extra -is [DBNull]) { $null } else { $r.extra }
        }
    })

    $edges = @(Get-DFPackageUniverseLinkEdges -Rows $rows -FamilySizeThreshold $FamilySizeThreshold)
    $families = @(Get-DFPackageUniverseFamilyGroups -Rows $rows -FamilySizeThreshold $FamilySizeThreshold)
    $curation = if ($CurationPath) { Import-DFPackageUniverseCuration -Path $CurationPath } else { [pscustomobject]@{ Same = @(); Different = @() } }
    $clusters = @(Invoke-DFPackageUniverseClustering -Edges $edges -CuratedSame $curation.Same -CuratedDifferent $curation.Different -Threshold $Threshold)

    Save-DFPackageUniverseLinks -Connection $Connection -Edges $edges -Clusters $clusters -Curation $curation -Families $families

    [pscustomobject]@{
        RowsRead = $rows.Count
        Edges    = $edges.Count
        Clusters = $clusters.Count
        Members  = [int](@($clusters | ForEach-Object { $_.Members.Count } | Measure-Object -Sum).Sum)
        Review   = @($edges | Where-Object { $_.Method -eq 'conflict' -or $_.Method -eq 'name-only' }).Count
        Families = $families.Count
    }
}

function Initialize-DFPackageUniverseLinksSchema {
    <#
    .SYNOPSIS
        Creates the Phase B (link stage) tables if missing, then clears this
        stage's own rows -- the four link tables plus pipeline_log stage='link'
        -- so each run rebuilds clusters as a reproducible view over raw_packages.
        Other phases' pipeline_log history is untouched.
    .PARAMETER DatabasePath
        Path to the shared universe.db.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DatabasePath
    )

    Invoke-SqliteQuery -DataSource $DatabasePath -Query @'
CREATE TABLE IF NOT EXISTS identity_links (
  id INTEGER PRIMARY KEY,
  source_a TEXT NOT NULL, package_id_a TEXT NOT NULL,
  source_b TEXT NOT NULL, package_id_b TEXT NOT NULL,
  method TEXT NOT NULL,
  confidence REAL NOT NULL,
  evidence TEXT,
  linked_at TEXT NOT NULL,
  UNIQUE(source_a, package_id_a, source_b, package_id_b, method)
);
CREATE TABLE IF NOT EXISTS identity_clusters (
  cluster_id INTEGER PRIMARY KEY,
  size INTEGER NOT NULL,
  methods TEXT NOT NULL,
  min_confidence REAL NOT NULL,
  has_curated INTEGER NOT NULL,
  needs_review INTEGER NOT NULL,
  created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS cluster_members (
  cluster_id INTEGER NOT NULL,
  source TEXT NOT NULL, package_id TEXT NOT NULL,
  join_method TEXT NOT NULL, join_confidence REAL NOT NULL,
  PRIMARY KEY(source, package_id)
);
CREATE TABLE IF NOT EXISTS curated_links (
  kind TEXT NOT NULL,
  group_id TEXT,
  source TEXT NOT NULL, package_id TEXT NOT NULL,
  note TEXT
);
'@

    foreach ($t in 'identity_links', 'identity_clusters', 'cluster_members', 'curated_links') {
        Invoke-SqliteQuery -DataSource $DatabasePath -Query "DELETE FROM $t;"
    }
    Invoke-SqliteQuery -DataSource $DatabasePath -Query "DELETE FROM pipeline_log WHERE stage = 'link';"
}

function Save-DFPackageUniverseLinks {
    <#
    .SYNOPSIS
        Persists a clustering run: the full edge graph (identity_links), the
        computed clusters (identity_clusters + cluster_members), the curation
        mirror (curated_links), and review candidates (pipeline_log stage='link',
        level='review': every conflict/name-only edge and every needs_review
        cluster). Wrapped in one transaction.
    .PARAMETER Connection
        An open PSSQLite connection to the universe.db.
    .PARAMETER Edges
        All pairwise edges from Get-DFPackageUniverseLinkEdges.
    .PARAMETER Clusters
        Clusters from Invoke-DFPackageUniverseClustering.
    .PARAMETER Curation
        The { Same; Different } object from Import-DFPackageUniverseCuration.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Connection,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Edges,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Clusters,
        [Parameter(Mandatory)] $Curation,
        [AllowEmptyCollection()] [object[]]$Families = @()
    )

    $now = [datetime]::UtcNow.ToString('o')
    Invoke-SqliteQuery -SQLiteConnection $Connection -Query 'BEGIN TRANSACTION;'
    try {
        foreach ($e in $Edges) {
            Invoke-SqliteQuery -SQLiteConnection $Connection -Query @'
INSERT OR IGNORE INTO identity_links (source_a, package_id_a, source_b, package_id_b, method, confidence, evidence, linked_at)
VALUES (@sa, @ia, @sb, @ib, @m, @c, @ev, @at);
'@ -SqlParameters @{ sa = $e.SourceA; ia = $e.PackageIdA; sb = $e.SourceB; ib = $e.PackageIdB; m = $e.Method; c = $e.Confidence; ev = $e.Evidence; at = $now }

            if ($e.Method -eq 'conflict' -or $e.Method -eq 'name-only') {
                Invoke-SqliteQuery -SQLiteConnection $Connection -Query @'
INSERT INTO pipeline_log (stage, source, package_id, level, message, logged_at)
VALUES ('link', @src, @pid, 'review', @msg, @at);
'@ -SqlParameters @{ src = $e.SourceA; pid = $e.PackageIdA; msg = "$($e.Method) candidate vs $($e.SourceB):$($e.PackageIdB) ($($e.Evidence))"; at = $now }
            }
        }

        $cid = 0
        foreach ($cluster in $Clusters) {
            $cid++
            Invoke-SqliteQuery -SQLiteConnection $Connection -Query @'
INSERT INTO identity_clusters (cluster_id, size, methods, min_confidence, has_curated, needs_review, created_at)
VALUES (@id, @size, @methods, @minc, @cur, @rev, @at);
'@ -SqlParameters @{
                id = $cid; size = $cluster.Members.Count
                methods = (ConvertTo-Json -Compress -InputObject @($cluster.Methods))
                minc = $cluster.MinConfidence
                cur = [int][bool]$cluster.HasCurated
                rev = [int][bool]$cluster.NeedsReview
                at = $now
            }
            $joinMethod = (@($cluster.Methods) -join '+')
            foreach ($m in $cluster.Members) {
                Invoke-SqliteQuery -SQLiteConnection $Connection -Query @'
INSERT OR REPLACE INTO cluster_members (cluster_id, source, package_id, join_method, join_confidence)
VALUES (@id, @src, @pid, @jm, @jc);
'@ -SqlParameters @{ id = $cid; src = $m.source; pid = $m.package_id; jm = $joinMethod; jc = $cluster.MinConfidence }
            }

            if ($cluster.NeedsReview) {
                Invoke-SqliteQuery -SQLiteConnection $Connection -Query @'
INSERT INTO pipeline_log (stage, source, package_id, level, message, logged_at)
VALUES ('link', NULL, NULL, 'review', @msg, @at);
'@ -SqlParameters @{ msg = "cluster $cid needs review (size $($cluster.Members.Count), methods $joinMethod)"; at = $now }
            }
        }

        foreach ($grp in $Curation.Same) {
            $label = "same-$([guid]::NewGuid().ToString('N').Substring(0,8))"
            foreach ($m in $grp) {
                Invoke-SqliteQuery -SQLiteConnection $Connection -Query "INSERT INTO curated_links (kind, group_id, source, package_id, note) VALUES ('same', @g, @s, @p, NULL);" -SqlParameters @{ g = $label; s = $m.source; p = $m.package_id }
            }
        }
        foreach ($pair in $Curation.Different) {
            foreach ($m in $pair) {
                Invoke-SqliteQuery -SQLiteConnection $Connection -Query "INSERT INTO curated_links (kind, group_id, source, package_id, note) VALUES ('different', NULL, @s, @p, NULL);" -SqlParameters @{ s = $m.source; p = $m.package_id }
            }
        }

        foreach ($fam in $Families) {
            Invoke-SqliteQuery -SQLiteConnection $Connection -Query @'
INSERT INTO pipeline_log (stage, source, package_id, level, message, logged_at)
VALUES ('link', NULL, NULL, 'review', @msg, @at);
'@ -SqlParameters @{ msg = "family ($($fam.Tier)) not auto-merged: $($fam.Size) packages share $($fam.Key) (review -- monorepo/vendor?)"; at = $now }
        }

        Invoke-SqliteQuery -SQLiteConnection $Connection -Query 'COMMIT;'
    } catch {
        Invoke-SqliteQuery -SQLiteConnection $Connection -Query 'ROLLBACK;'
        throw
    }
}

function Import-DFPackageUniverseCuration {
    <#
    .SYNOPSIS
        Loads the version-controlled curation file (human-verified identities)
        into { Same; Different } for Invoke-DFPackageUniverseClustering.
    .DESCRIPTION
        Same = array of confirmed-same groups (each an array of {source,
        package_id}); Different = array of confirmed-different pairs. JSONC:
        whole-line // comments and /* */ blocks are stripped. The line-comment
        strip is anchored to line start so a '//' inside a value (a URL, a
        'bucket/name' id) is never corrupted. A missing file yields empties, so
        clustering runs cleanly before any curation exists.
    .PARAMETER Path
        Path to the curation .jsonc file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path $Path)) { return [pscustomobject]@{ Same = @(); Different = @() } }

    $text = Get-Content -Raw -Path $Path
    $text = [regex]::Replace($text, '(?m)^\s*//.*$', '')
    $text = [regex]::Replace($text, '(?s)/\*.*?\*/', '')
    $doc = $text | ConvertFrom-Json

    $sameProp = $doc.PSObject.Properties['same']
    $diffProp = $doc.PSObject.Properties['different']

    $same = @(if ($sameProp) { foreach ($g in @($sameProp.Value)) { , @($g.members) } })
    $different = @(if ($diffProp) { foreach ($p in @($diffProp.Value)) { , @($p.members) } })

    [pscustomobject]@{ Same = $same; Different = $different }
}

function Invoke-DFPackageUniverseClustering {
    <#
    .SYNOPSIS
        Clusters raw packages by constrained union-find over the edge graph.
    .DESCRIPTION
        Curated confirmed-same groups are unioned first (method 'curated', 1.0).
        Automatic edges are then applied in descending confidence, but only those
        at or above -Threshold union -- name-only (0.20) and conflict (0.30) never
        cluster. A union that would place both members of a curated confirmed-
        different (cannot-link) pair in one component is skipped and the touched
        components flagged for review. Returns one object per resulting cluster of
        size >= 2: Members, Methods, MinConfidence, HasCurated, NeedsReview.
    .PARAMETER Edges
        Pairwise edges from Get-DFPackageUniverseLinkEdges.
    .PARAMETER CuratedSame
        Array of groups; each group an array of {source, package_id} to force-merge.
    .PARAMETER CuratedDifferent
        Array of pairs; each pair an array of two {source, package_id} that must
        never share a cluster (cannot-link).
    .PARAMETER Threshold
        Minimum edge confidence that forms a cluster (default 0.60).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Edges,

        [object[]]$CuratedSame = @(),
        [object[]]$CuratedDifferent = @(),
        [double]$Threshold = 0.60
    )

    $parent = @{}
    $info = @{}

    function Add-DFNode {
        param($Src, $PkgId)
        $id = "$Src|$PkgId"
        if (-not $parent.ContainsKey($id)) {
            $parent[$id] = $id
            $info[$id] = [pscustomobject]@{ source = $Src; package_id = $PkgId }
        }
        $id
    }

    function Find-DFRoot {
        param($Id)
        $root = $Id
        while ($parent[$root] -ne $root) { $root = $parent[$root] }
        $cur = $Id
        while ($parent[$cur] -ne $root) { $next = $parent[$cur]; $parent[$cur] = $root; $cur = $next }
        $root
    }

    # Register every node up front (curated members and edge endpoints).
    foreach ($grp in $CuratedSame) { foreach ($m in $grp) { [void](Add-DFNode -Src $m.source -PkgId $m.package_id) } }
    foreach ($p in $CuratedDifferent) { foreach ($m in $p) { [void](Add-DFNode -Src $m.source -PkgId $m.package_id) } }
    foreach ($e in $Edges) {
        [void](Add-DFNode -Src $e.SourceA -PkgId $e.PackageIdA)
        [void](Add-DFNode -Src $e.SourceB -PkgId $e.PackageIdB)
    }

    # Cannot-link pairs as node-id tuples.
    $cannotLink = @(foreach ($p in $CuratedDifferent) {
        , @("$($p[0].source)|$($p[0].package_id)", "$($p[1].source)|$($p[1].package_id)")
    })

    $reviewRoots = [System.Collections.Generic.HashSet[string]]::new()
    # Applied cluster-forming links, for per-cluster method/confidence aggregation.
    $applied = [System.Collections.Generic.List[object]]::new()

    # Would unioning components of $ida and $idb violate a cannot-link pair?
    function Test-DFCannotLink {
        param($IdA, $IdB)
        $ra = Find-DFRoot $IdA
        $rb = Find-DFRoot $IdB
        foreach ($cl in $cannotLink) {
            $rx = Find-DFRoot $cl[0]
            $ry = Find-DFRoot $cl[1]
            if (($ra -eq $rx -and $rb -eq $ry) -or ($ra -eq $ry -and $rb -eq $rx)) { return $true }
        }
        $false
    }

    function Join-DFNodes {
        param($IdA, $IdB, $Method, $Confidence)
        if (Test-DFCannotLink -IdA $IdA -IdB $IdB) {
            [void]$reviewRoots.Add((Find-DFRoot $IdA))
            [void]$reviewRoots.Add((Find-DFRoot $IdB))
            return
        }
        $ra = Find-DFRoot $IdA
        $rb = Find-DFRoot $IdB
        if ($ra -ne $rb) { $parent[$ra] = $rb }
        $applied.Add([pscustomobject]@{ Id = $IdB; Method = $Method; Confidence = $Confidence })
    }

    # 1) Seed curated confirmed-same.
    foreach ($grp in $CuratedSame) {
        $ids = @(foreach ($m in $grp) { "$($m.source)|$($m.package_id)" })
        for ($i = 1; $i -lt $ids.Count; $i++) { Join-DFNodes -IdA $ids[0] -IdB $ids[$i] -Method 'curated' -Confidence 1.0 }
    }

    # 2) Apply automatic edges, strongest first; only >= threshold cluster.
    foreach ($e in ($Edges | Sort-Object -Property Confidence -Descending)) {
        if ($e.Confidence -lt $Threshold) { continue }
        Join-DFNodes -IdA "$($e.SourceA)|$($e.PackageIdA)" -IdB "$($e.SourceB)|$($e.PackageIdB)" -Method $e.Method -Confidence $e.Confidence
    }

    # 3) Conflict/sub-threshold edges flag any cluster they touch for review.
    foreach ($e in $Edges) {
        if ($e.Method -eq 'conflict') {
            [void]$reviewRoots.Add((Find-DFRoot "$($e.SourceA)|$($e.PackageIdA)"))
            [void]$reviewRoots.Add((Find-DFRoot "$($e.SourceB)|$($e.PackageIdB)"))
        }
    }

    # 4) Aggregate applied links per final root.
    $byRoot = @{}
    foreach ($a in $applied) {
        $r = Find-DFRoot $a.Id
        if (-not $byRoot.ContainsKey($r)) { $byRoot[$r] = [pscustomobject]@{ Methods = [System.Collections.Generic.HashSet[string]]::new(); MinConf = [double]::PositiveInfinity } }
        [void]$byRoot[$r].Methods.Add($a.Method)
        if ($a.Confidence -lt $byRoot[$r].MinConf) { $byRoot[$r].MinConf = $a.Confidence }
    }

    # 5) Materialize clusters of size >= 2. Snapshot keys: Find-DFRoot path-
    # compresses (mutates $parent), which would break live key enumeration.
    $membersByRoot = @{}
    foreach ($id in @($parent.Keys)) {
        $r = Find-DFRoot $id
        if (-not $membersByRoot.ContainsKey($r)) { $membersByRoot[$r] = [System.Collections.Generic.List[object]]::new() }
        $membersByRoot[$r].Add($info[$id])
    }

    foreach ($r in $membersByRoot.Keys) {
        $members = $membersByRoot[$r]
        if ($members.Count -lt 2) { continue }
        $agg = $byRoot[$r]
        [pscustomobject]@{
            Members       = @($members)
            Methods       = @($agg.Methods)
            MinConfidence = $agg.MinConf
            HasCurated    = [bool]($agg.Methods.Contains('curated'))
            NeedsReview   = [bool]$reviewRoots.Contains($r)
        }
    }
}
