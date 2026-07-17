#Requires -Version 7.0

# Phase C (tool merge) build helpers. Flattens Phase B clusters + singletons
# into the master tools table, losslessly. See
# docs/superpowers/specs/2026-07-16-package-universe-tool-merge-design.md

function ConvertFrom-DFDbNull {
    <#
    .SYNOPSIS
        Coerces a PSSQLite [DBNull] cell to $null; passes any other value through.
    #>
    [CmdletBinding()]
    param($Value)
    if ($Value -is [DBNull]) { $null } else { $Value }
}

function ConvertTo-DFNormalizedLicense {
    <#
    .SYNOPSIS
        Canonical license identifier for single-answer conflict detection:
        lowercased, the word 'license' removed, non-alphanumeric stripped
        ('MIT' and 'MIT License' -> 'mit'). Returns $null for empties AND for
        URL-shaped values -- choco's license column holds LicenseUrl, not an
        SPDX id, so comparing it to winget's 'MIT' would false-conflict on every
        multi-source choco tool. URLs simply do not participate in the check.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][string]$Value)

    if (-not $Value) { return $null }
    if ($Value -match '^\s*https?://') { return $null }
    $t = ($Value.ToLowerInvariant() -replace '\blicense\b', '') -replace '[^a-z0-9]', ''
    if ($t -eq '') { return $null }
    $t
}

function Select-DFByPriority {
    <#
    .SYNOPSIS
        First non-empty value of $Field across $Members, scanning source names in
        $Order. Returns { Value; Source } ($null/$null when none supply it).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Members,
        [Parameter(Mandatory)][string[]]$Order,
        [Parameter(Mandatory)][string]$Field
    )
    foreach ($src in $Order) {
        foreach ($m in $Members) {
            if ($m.source -eq $src) {
                $v = ConvertFrom-DFDbNull $m.$Field
                if ($null -ne $v -and "$v".Trim() -ne '') {
                    return [pscustomobject]@{ Value = [string]$v; Source = $src }
                }
            }
        }
    }
    [pscustomobject]@{ Value = $null; Source = $null }
}

function Resolve-DFPackageUniverseToolRecord {
    <#
    .SYNOPSIS
        Reduces one group's member rows to the canonical parent tool record.
        Display scalars are per-field priority picks (winget>choco>scoop) with
        provenance; repo_url uses the Phase B repo authority (choco>scoop>winget);
        a post-normalization license disagreement sets NeedsReview.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][object[]]$Members)

    $display = @('winget', 'choco', 'scoop')
    $name = Select-DFByPriority -Members $Members -Order $display -Field 'name'
    $desc = Select-DFByPriority -Members $Members -Order $display -Field 'description'
    # Not named $home -- that's PowerShell's read-only automatic variable and
    # assigning to it throws SessionStateUnauthorizedAccessException.
    $hp = Select-DFByPriority -Members $Members -Order $display -Field 'homepage'
    $lic  = Select-DFByPriority -Members $Members -Order $display -Field 'license'

    # repo: choco ProjectSourceUrl is the strongest signal (Phase B priority),
    # then scoop checkver/autoupdate, then winget (homepage only).
    $repoUrl = $null
    foreach ($src in @('choco', 'scoop', 'winget')) {
        foreach ($m in $Members) {
            if ($m.source -eq $src) {
                $key = Get-DFPackageUniverseRepoKey -Row $m
                if ($key) { $repoUrl = "https://github.com/$key"; break }
            }
        }
        if ($repoUrl) { break }
    }

    # License single-answer conflict: compare only identifier-shaped licenses
    # (ConvertTo-DFNormalizedLicense drops URLs and empties).
    $norm = @($Members | ForEach-Object { ConvertTo-DFNormalizedLicense -Value (ConvertFrom-DFDbNull $_.license) } | Where-Object { $_ } | Select-Object -Unique)
    $reasons = [System.Collections.Generic.List[string]]::new()
    if ($norm.Count -gt 1) {
        $raw = @($Members | ForEach-Object { ConvertFrom-DFDbNull $_.license } | Where-Object { $_ -and $_ -notmatch '^\s*https?://' } | Select-Object -Unique)
        $reasons.Add("license-conflict: $($raw -join ' | ')")
    }

    $nameVal = if ($name.Value) { $name.Value } else { [string](@($Members)[0].package_id) }

    [pscustomobject]@{
        Name              = $nameVal
        NameSource        = $name.Source
        Description       = $desc.Value
        DescriptionSource = $desc.Source
        Homepage          = $hp.Value
        RepoUrl           = $repoUrl
        License           = $lic.Value
        SourceCount       = @($Members | ForEach-Object { $_.source } | Select-Object -Unique).Count
        NeedsReview       = ($reasons.Count -gt 0)
        ReviewReasons     = $reasons.ToArray()
    }
}

function Get-DFPackageUniverseToolTags {
    <#
    .SYNOPSIS
        Normalized (lowercase/trim) deduped union of every member's tags. Each
        catalog stores tags as a JSON array string in the tags column (winget and
        choco populate it; scoop leaves it NULL). First-seen order is preserved so
        the output is deterministic (idempotent runs).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Members)

    $out = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($m in $Members) {
        $raw = ConvertFrom-DFDbNull $m.tags
        if (-not $raw) { continue }
        $parsed = $null
        try { $parsed = $raw | ConvertFrom-Json } catch { $parsed = $null }
        if ($null -eq $parsed) { continue }
        foreach ($t in @($parsed)) {
            $norm = "$t".Trim().ToLowerInvariant()
            if ($norm -and $seen.Add($norm)) { $out.Add($norm) }
        }
    }
    $out.ToArray()
}

function Import-DFPackageUniverseCategoryRules {
    <#
    .SYNOPSIS
        Loads the version-controlled keyword->category rule file into
        { Category; Keywords[] } objects. JSONC: whole-line // comments and
        /* */ blocks are stripped (line comments anchored to line start so a
        '//' inside a value is safe). A missing file yields @().
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path $Path)) { return @() }
    $text = Get-Content -Raw -Path $Path
    $text = [regex]::Replace($text, '(?m)^\s*//.*$', '')
    $text = [regex]::Replace($text, '(?s)/\*.*?\*/', '')
    $doc = $text | ConvertFrom-Json

    $rulesProp = $doc.PSObject.Properties['rules']
    if (-not $rulesProp) { return @() }
    @(foreach ($r in @($rulesProp.Value)) {
        $kw = @(@($r.keywords) | ForEach-Object { "$_".Trim().ToLowerInvariant() } | Where-Object { $_ })
        [pscustomobject]@{ Category = [string]$r.category; Keywords = $kw }
    })
}

function Get-DFPackageUniverseCategoryTokens {
    <#
    .SYNOPSIS
        The match set for category derivation: the tool's tag union plus any
        winget Moniker (a strong single-word category hint), all lowercased.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Members,
        [AllowEmptyCollection()][string[]]$Tags = @()
    )
    $tokens = [System.Collections.Generic.List[string]]::new()
    foreach ($t in @($Tags)) { if ($t) { $tokens.Add("$t".Trim().ToLowerInvariant()) } }
    foreach ($m in $Members) {
        if ($m.source -eq 'winget') {
            $extra = ConvertFrom-DFDbNull $m.extra
            if ($extra) {
                $e = $null
                try { $e = $extra | ConvertFrom-Json } catch { $e = $null }
                if ($e) {
                    $mon = $e.PSObject.Properties['Moniker']
                    if ($mon -and $mon.Value) { $tokens.Add("$($mon.Value)".Trim().ToLowerInvariant()) }
                }
            }
        }
    }
    $tokens.ToArray()
}

function ConvertTo-DFPackageUniverseCategories {
    <#
    .SYNOPSIS
        Categories whose rule keywords intersect the token set. Deduped, rule
        order preserved (deterministic).
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][string[]]$Tokens = @(),
        [AllowEmptyCollection()][object[]]$Rules = @()
    )
    $set = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($t in @($Tokens)) { if ($t) { [void]$set.Add(("$t".Trim().ToLowerInvariant())) } }

    $out = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($rule in @($Rules)) {
        foreach ($kw in @($rule.Keywords)) {
            if ($set.Contains($kw)) {
                if ($seen.Add($rule.Category)) { $out.Add($rule.Category) }
                break
            }
        }
    }
    $out.ToArray()
}

function Get-DFPackageUniverseToolGroups {
    <#
    .SYNOPSIS
        Partitions raw_packages rows into per-tool groups: rows in cluster_members
        accumulate under their cluster_id; every other row is its own singleton
        group (ClusterId $null). Clustered groups (sorted by cluster_id) precede
        singletons (sorted by source|package_id) so tool_id assignment is
        deterministic and runs are idempotent. Every row appears in exactly one group.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ClusterMembers
    )

    $byKey = @{}
    foreach ($cm in $ClusterMembers) { $byKey["$($cm.source)|$($cm.package_id)"] = [int]$cm.cluster_id }

    $clustered = @{}
    $singletons = [System.Collections.Generic.List[object]]::new()
    foreach ($r in $Rows) {
        $k = "$($r.source)|$($r.package_id)"
        if ($byKey.ContainsKey($k)) {
            $cid = $byKey[$k]
            if (-not $clustered.ContainsKey($cid)) { $clustered[$cid] = [System.Collections.Generic.List[object]]::new() }
            $clustered[$cid].Add($r)
        } else {
            $singletons.Add($r)
        }
    }

    $groups = [System.Collections.Generic.List[object]]::new()
    foreach ($cid in ($clustered.Keys | Sort-Object)) {
        $groups.Add([pscustomobject]@{ ClusterId = $cid; Members = @($clustered[$cid]) })
    }
    foreach ($r in ($singletons | Sort-Object { "$($_.source)|$($_.package_id)" })) {
        $groups.Add([pscustomobject]@{ ClusterId = $null; Members = @($r) })
    }
    $groups.ToArray()
}

function Initialize-DFPackageUniverseToolsSchema {
    <#
    .SYNOPSIS
        Creates the Phase C (merge stage) tables if missing, then clears this
        stage's own rows -- the four tool tables plus pipeline_log stage='merge'
        -- so each run rebuilds the master tools table as a reproducible view
        over raw_packages + cluster_members. Other phases' log history is untouched.
    .PARAMETER DatabasePath
        Path to the shared universe.db.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DatabasePath
    )

    Invoke-SqliteQuery -DataSource $DatabasePath -Query @'
CREATE TABLE IF NOT EXISTS tools (
  tool_id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  name_source TEXT,
  description TEXT,
  description_source TEXT,
  homepage TEXT,
  repo_url TEXT,
  license TEXT,
  source_count INTEGER NOT NULL,
  cluster_id INTEGER,
  needs_review INTEGER NOT NULL,
  review_reasons TEXT,
  created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS tool_packages (
  tool_id INTEGER NOT NULL,
  source TEXT NOT NULL, package_id TEXT NOT NULL,
  name TEXT, version TEXT, description TEXT, homepage TEXT, license TEXT, publisher TEXT,
  extra TEXT,
  PRIMARY KEY(source, package_id)
);
CREATE TABLE IF NOT EXISTS tool_tags (
  tool_id INTEGER NOT NULL,
  tag TEXT NOT NULL,
  PRIMARY KEY(tool_id, tag)
);
CREATE TABLE IF NOT EXISTS tool_categories (
  tool_id INTEGER NOT NULL,
  category TEXT NOT NULL,
  PRIMARY KEY(tool_id, category)
);
'@

    foreach ($t in 'tools', 'tool_packages', 'tool_tags', 'tool_categories') {
        Invoke-SqliteQuery -DataSource $DatabasePath -Query "DELETE FROM $t;"
    }
    Invoke-SqliteQuery -DataSource $DatabasePath -Query "DELETE FROM pipeline_log WHERE stage = 'merge';"
}

function Save-DFPackageUniverseTools {
    <#
    .SYNOPSIS
        Persists a merge run in one transaction: the master tools rows (sequential
        tool_id), the lossless tool_packages children (every member's typed fields
        + verbatim extra), tool_tags, tool_categories, and a pipeline_log
        stage='merge' level='review' row per needs-review tool.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Connection,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Tools
    )

    $now = [datetime]::UtcNow.ToString('o')
    Invoke-SqliteQuery -SQLiteConnection $Connection -Query 'BEGIN TRANSACTION;'
    try {
        $tid = 0
        foreach ($tool in $Tools) {
            $tid++
            $rec = $tool.Record
            $rr = if (@($rec.ReviewReasons).Count -gt 0) { ConvertTo-Json -Compress -InputObject @($rec.ReviewReasons) } else { $null }
            Invoke-SqliteQuery -SQLiteConnection $Connection -Query @'
INSERT INTO tools (tool_id, name, name_source, description, description_source, homepage, repo_url, license, source_count, cluster_id, needs_review, review_reasons, created_at)
VALUES (@id, @name, @ns, @desc, @ds, @home, @repo, @lic, @sc, @cid, @rev, @rr, @at);
'@ -SqlParameters @{
                id = $tid; name = $rec.Name; ns = $rec.NameSource; desc = $rec.Description; ds = $rec.DescriptionSource
                home = $rec.Homepage; repo = $rec.RepoUrl; lic = $rec.License; sc = $rec.SourceCount
                cid = $tool.ClusterId; rev = [int][bool]$rec.NeedsReview; rr = $rr; at = $now
            }

            foreach ($m in $tool.Members) {
                Invoke-SqliteQuery -SQLiteConnection $Connection -Query @'
INSERT INTO tool_packages (tool_id, source, package_id, name, version, description, homepage, license, publisher, extra)
VALUES (@id, @src, @pid, @name, @ver, @desc, @home, @lic, @pub, @extra);
'@ -SqlParameters @{
                    id = $tid; src = $m.source; pid = $m.package_id; name = $m.name; ver = $m.version
                    desc = $m.description; home = $m.homepage; lic = $m.license; pub = $m.publisher; extra = $m.extra
                }
            }

            foreach ($tag in @($tool.Tags)) {
                Invoke-SqliteQuery -SQLiteConnection $Connection -Query 'INSERT OR IGNORE INTO tool_tags (tool_id, tag) VALUES (@id, @tag);' -SqlParameters @{ id = $tid; tag = $tag }
            }
            foreach ($cat in @($tool.Categories)) {
                Invoke-SqliteQuery -SQLiteConnection $Connection -Query 'INSERT OR IGNORE INTO tool_categories (tool_id, category) VALUES (@id, @cat);' -SqlParameters @{ id = $tid; cat = $cat }
            }

            if ($rec.NeedsReview) {
                Invoke-SqliteQuery -SQLiteConnection $Connection -Query @'
INSERT INTO pipeline_log (stage, source, package_id, level, message, logged_at)
VALUES ('merge', NULL, NULL, 'review', @msg, @at);
'@ -SqlParameters @{ msg = "tool $tid ($($rec.Name)) needs review: $(@($rec.ReviewReasons) -join '; ')"; at = $now }
            }
        }
        Invoke-SqliteQuery -SQLiteConnection $Connection -Query 'COMMIT;'
    } catch {
        Invoke-SqliteQuery -SQLiteConnection $Connection -Query 'ROLLBACK;'
        throw
    }
}

function Invoke-DFPackageUniverseToolMerge {
    <#
    .SYNOPSIS
        The Phase C core: reads raw_packages + cluster_members from an open
        connection, groups them into tools (clusters + singletons), resolves each
        tool's canonical record/tags/categories, persists everything, and returns
        a reconciliation summary. The schema must already be initialized. Asserts
        the no-data-lost contract (grouped packages == raw_packages count).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Connection,
        [string]$CategoryRulesPath
    )

    $raw = @(Invoke-SqliteQuery -SQLiteConnection $Connection -Query 'SELECT source, package_id, name, version, description, homepage, license, publisher, tags, extra FROM raw_packages')
    $rows = @(foreach ($r in $raw) {
        [pscustomobject]@{
            source      = $r.source
            package_id  = $r.package_id
            name        = ConvertFrom-DFDbNull $r.name
            version     = ConvertFrom-DFDbNull $r.version
            description = ConvertFrom-DFDbNull $r.description
            homepage    = ConvertFrom-DFDbNull $r.homepage
            license     = ConvertFrom-DFDbNull $r.license
            publisher   = ConvertFrom-DFDbNull $r.publisher
            tags        = ConvertFrom-DFDbNull $r.tags
            extra       = ConvertFrom-DFDbNull $r.extra
        }
    })

    $members = @(Invoke-SqliteQuery -SQLiteConnection $Connection -Query 'SELECT cluster_id, source, package_id FROM cluster_members')
    $groups = @(Get-DFPackageUniverseToolGroups -Rows $rows -ClusterMembers $members)

    $grouped = [int](@($groups | ForEach-Object { $_.Members.Count } | Measure-Object -Sum).Sum)
    if ($grouped -ne $rows.Count) {
        throw "Phase C reconciliation failed: $grouped packages grouped but raw_packages has $($rows.Count)"
    }

    $rules = @(if ($CategoryRulesPath) { Import-DFPackageUniverseCategoryRules -Path $CategoryRulesPath } else { @() })

    $tools = @(foreach ($g in $groups) {
        $ms = @($g.Members)
        $record = Resolve-DFPackageUniverseToolRecord -Members $ms
        $tags = @(Get-DFPackageUniverseToolTags -Members $ms)
        $tokens = @(Get-DFPackageUniverseCategoryTokens -Members $ms -Tags $tags)
        $cats = @(ConvertTo-DFPackageUniverseCategories -Tokens $tokens -Rules $rules)
        [pscustomobject]@{ Record = $record; Members = $ms; Tags = $tags; Categories = $cats; ClusterId = $g.ClusterId }
    })

    Save-DFPackageUniverseTools -Connection $Connection -Tools $tools

    [pscustomobject]@{
        RowsRead   = $rows.Count
        Tools      = $tools.Count
        Packages   = $grouped
        Singletons = @($tools | Where-Object { $_.Record.SourceCount -eq 1 }).Count
        Tags       = [int](@($tools | ForEach-Object { $_.Tags.Count } | Measure-Object -Sum).Sum)
        Categories = [int](@($tools | ForEach-Object { $_.Categories.Count } | Measure-Object -Sum).Sum)
        Review     = @($tools | Where-Object { $_.Record.NeedsReview }).Count
    }
}
