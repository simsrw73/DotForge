BeforeAll {
    Set-StrictMode -Version Latest
    Import-Module PSSQLite
    . "$PSScriptRoot/../build/Private/DFPackageUniverse.Links.ps1"  # Get-DFPackageUniverseRepoKey
    . "$PSScriptRoot/../build/Private/DFPackageUniverse.Merge.ps1"

    function New-MergeTestDb {
        $db = Join-Path ([System.IO.Path]::GetTempPath()) ("mergetest-" + [guid]::NewGuid().ToString('N') + ".db")
        Invoke-SqliteQuery -DataSource $db -Query @'
CREATE TABLE raw_packages (id INTEGER PRIMARY KEY, source TEXT, package_id TEXT, name TEXT, version TEXT, description TEXT, homepage TEXT, license TEXT, publisher TEXT, tags TEXT, extra TEXT, fetched_at TEXT, UNIQUE(source, package_id));
CREATE TABLE pipeline_log (id INTEGER PRIMARY KEY, stage TEXT, source TEXT, package_id TEXT, level TEXT, message TEXT, logged_at TEXT);
CREATE TABLE cluster_members (cluster_id INTEGER, source TEXT, package_id TEXT, join_method TEXT, join_confidence REAL, PRIMARY KEY(source, package_id));
'@
        Initialize-DFPackageUniverseToolsSchema -DatabasePath $db
        $db
    }

    function Add-RawRow {
        param($Db, $Source, $PackageId, $Name, $Description = 'd', $Homepage = $null, $License = 'MIT', $Publisher = $null, $Tags = $null, $Extra = $null)
        Invoke-SqliteQuery -DataSource $Db -Query @'
INSERT INTO raw_packages (source, package_id, name, version, description, homepage, license, publisher, tags, extra, fetched_at)
VALUES (@s, @p, @n, '1', @d, @h, @l, @pub, @t, @e, 'now');
'@ -SqlParameters @{ s = $Source; p = $PackageId; n = $Name; d = $Description; h = $Homepage; l = $License; pub = $Publisher; t = $Tags; e = $Extra }
    }
    function Add-ClusterMember {
        param($Db, $Cid, $Source, $PackageId)
        Invoke-SqliteQuery -DataSource $Db -Query "INSERT INTO cluster_members (cluster_id, source, package_id, join_method, join_confidence) VALUES (@c, @s, @p, 'repo', 1.0);" -SqlParameters @{ c = $Cid; s = $Source; p = $PackageId }
    }
}

Describe 'DFPackageUniverse.Merge' {
    Context 'ConvertFrom-DFDbNull' {
        It 'maps DBNull to null and passes other values through' {
            ConvertFrom-DFDbNull ([DBNull]::Value) | Should -BeNullOrEmpty
            ConvertFrom-DFDbNull 'hello' | Should -Be 'hello'
        }
    }

    Context 'ConvertTo-DFNormalizedLicense' {
        It 'folds MIT and MIT License to the same identifier' {
            (ConvertTo-DFNormalizedLicense 'MIT') | Should -Be (ConvertTo-DFNormalizedLicense 'MIT License')
        }
        It 'treats a license URL as null (choco stores LicenseUrl, not an SPDX id)' {
            ConvertTo-DFNormalizedLicense 'https://github.com/x/y/blob/main/LICENSE' | Should -BeNullOrEmpty
        }
        It 'returns null for empty input' {
            ConvertTo-DFNormalizedLicense '' | Should -BeNullOrEmpty
        }
        It 'distinguishes genuinely different licenses' {
            (ConvertTo-DFNormalizedLicense 'Apache-2.0') | Should -Not -Be (ConvertTo-DFNormalizedLicense 'MIT')
        }
        It 'folds the -only SPDX modifier' {
            (ConvertTo-DFNormalizedLicense 'GPL-3.0-only') | Should -Be (ConvertTo-DFNormalizedLicense 'GPL-3.0')
        }
        It 'folds the -or-later SPDX modifier' {
            (ConvertTo-DFNormalizedLicense 'GPL-3.0-or-later') | Should -Be (ConvertTo-DFNormalizedLicense 'GPL-3.0')
        }
        It 'folds the + SPDX modifier' {
            (ConvertTo-DFNormalizedLicense 'GPL-3.0+') | Should -Be (ConvertTo-DFNormalizedLicense 'GPL-3.0')
        }
        It 'keeps LGPL distinct from GPL (regression: must not over-collapse)' {
            (ConvertTo-DFNormalizedLicense 'LGPL-3.0-only') | Should -Not -Be (ConvertTo-DFNormalizedLicense 'GPL-3.0')
        }
    }

    Context 'Resolve-DFPackageUniverseToolRecord' {
        BeforeAll {
            # Pester 5.8.0 does not carry a function defined directly in a
            # Context body (outside a hook) into Run-phase It scope; wrapping
            # in BeforeAll is the idiomatic fix. Body/behavior unchanged.
            function M {
                param($Source, $PackageId, $Name = $null, $Description = $null, $Homepage = $null, $License = $null, $Publisher = $null, $Extra = $null)
                [pscustomobject]@{
                    source = $Source; package_id = $PackageId; name = $Name; version = '1'
                    description = $Description; homepage = $Homepage; license = $License
                    publisher = $Publisher; tags = $null; extra = $Extra
                }
            }
        }

        It 'prefers the winget friendly name over choco and scoop' {
            $members = @(
                (M -Source 'scoop'  -PackageId 'main/bat' -Name 'bat')
                (M -Source 'winget' -PackageId 'sharkdp.bat' -Name 'bat')
                (M -Source 'choco'  -PackageId 'bat' -Name 'Bat')
            )
            $rec = Resolve-DFPackageUniverseToolRecord -Members $members
            $rec.Name | Should -Be 'bat'
            $rec.NameSource | Should -Be 'winget'
            $rec.SourceCount | Should -Be 3
        }

        It 'picks the richer winget description over a terse scoop one' {
            $members = @(
                (M -Source 'scoop'  -PackageId 'main/x' -Name 'x' -Description 'short')
                (M -Source 'winget' -PackageId 'A.X' -Name 'x' -Description 'A full description of what X does.')
            )
            $rec = Resolve-DFPackageUniverseToolRecord -Members $members
            $rec.Description | Should -Be 'A full description of what X does.'
            $rec.DescriptionSource | Should -Be 'winget'
        }

        It 'derives repo_url from choco ProjectSourceUrl' {
            $extra = ConvertTo-Json -Compress @{ ProjectSourceUrl = 'https://github.com/sharkdp/bat' }
            $members = @( (M -Source 'choco' -PackageId 'bat' -Name 'bat' -Extra $extra) )
            $rec = Resolve-DFPackageUniverseToolRecord -Members $members
            $rec.RepoUrl | Should -Be 'https://github.com/sharkdp/bat'
        }

        It 'flags a genuine license conflict but not MIT vs MIT License' {
            $conflict = Resolve-DFPackageUniverseToolRecord -Members @(
                (M -Source 'winget' -PackageId 'A.X' -Name 'x' -License 'MIT')
                (M -Source 'choco'  -PackageId 'x'   -Name 'x' -License 'Apache-2.0')
            )
            $conflict.NeedsReview | Should -BeTrue
            $conflict.ReviewReasons[0] | Should -Match 'license-conflict'

            $ok = Resolve-DFPackageUniverseToolRecord -Members @(
                (M -Source 'winget' -PackageId 'A.X' -Name 'x' -License 'MIT')
                (M -Source 'choco'  -PackageId 'x'   -Name 'x' -License 'MIT License')
            )
            $ok.NeedsReview | Should -BeFalse
        }

        It 'does not flag winget MIT against a choco license URL' {
            $rec = Resolve-DFPackageUniverseToolRecord -Members @(
                (M -Source 'winget' -PackageId 'A.X' -Name 'x' -License 'MIT')
                (M -Source 'choco'  -PackageId 'x'   -Name 'x' -License 'https://opensource.org/licenses/MIT')
            )
            $rec.NeedsReview | Should -BeFalse
        }

        It 'falls back to package_id when no member has a name (NOT NULL guard)' {
            $rec = Resolve-DFPackageUniverseToolRecord -Members @( (M -Source 'scoop' -PackageId 'main/thing') )
            $rec.Name | Should -Be 'main/thing'
        }

        It 'rejects an empty member collection (a tool always has at least one package)' {
            { Resolve-DFPackageUniverseToolRecord -Members @() } | Should -Throw
        }
    }

    Context 'Get-DFPackageUniverseToolTags' {
        It 'unions and normalizes tags across members, deduping' {
            $members = @(
                [pscustomobject]@{ source = 'winget'; package_id = 'A.X'; tags = (ConvertTo-Json -Compress @('Cat', 'Viewer')) }
                [pscustomobject]@{ source = 'choco';  package_id = 'x';   tags = (ConvertTo-Json -Compress @('cat', 'less')) }
                [pscustomobject]@{ source = 'scoop';  package_id = 'main/x'; tags = $null }
            )
            $tags = Get-DFPackageUniverseToolTags -Members $members
            $tags | Should -Contain 'cat'
            $tags | Should -Contain 'viewer'
            $tags | Should -Contain 'less'
            @($tags | Where-Object { $_ -eq 'cat' }).Count | Should -Be 1
        }

        It 'does not throw under strict on a DBNull tags cell' {
            $members = @([pscustomobject]@{ source = 'scoop'; package_id = 'main/x'; tags = [DBNull]::Value })
            { Get-DFPackageUniverseToolTags -Members $members } | Should -Not -Throw
            @(Get-DFPackageUniverseToolTags -Members $members).Count | Should -Be 0
        }
    }

    Context 'categories' {
        BeforeAll {
            $script:rulesFile = Join-Path ([System.IO.Path]::GetTempPath()) ("catrules-" + [guid]::NewGuid().ToString('N') + ".jsonc")
            @'
{
  // keyword -> category rules (first-pass)
  "schemaVersion": 1,
  "rules": [
    { "category": "viewer", "keywords": ["cat", "pager", "viewer"] },
    { "category": "search", "keywords": ["search", "grep", "find"] }
  ]
}
'@ | Set-Content -Path $script:rulesFile -Encoding utf8
        }
        AfterAll { Remove-Item -Path $script:rulesFile -ErrorAction Ignore }

        It 'loads rules, ignoring comments' {
            $rules = Import-DFPackageUniverseCategoryRules -Path $script:rulesFile
            @($rules).Count | Should -Be 2
            $rules[0].Category | Should -Be 'viewer'
            $rules[0].Keywords | Should -Contain 'cat'
        }

        It 'returns empty for a missing rules file' {
            @(Import-DFPackageUniverseCategoryRules -Path 'C:\nope\missing.jsonc').Count | Should -Be 0
        }

        It 'returns empty for an empty/all-comment rules file' {
            $script:commentOnlyFile = Join-Path ([System.IO.Path]::GetTempPath()) ("catrules-comments-" + [guid]::NewGuid().ToString('N') + ".jsonc")
            try {
                @'
// this file intentionally has no JSON, only comments
/*
  placeholder for future rules
*/
'@ | Set-Content -Path $script:commentOnlyFile -Encoding utf8

                @(Import-DFPackageUniverseCategoryRules -Path $script:commentOnlyFile).Count | Should -Be 0
            } finally { Remove-Item -Path $script:commentOnlyFile -ErrorAction Ignore }
        }

        It 'includes a winget Moniker in the token set' {
            $members = @([pscustomobject]@{ source = 'winget'; package_id = 'A.X'; extra = (ConvertTo-Json -Compress @{ Moniker = 'grep' }) })
            $tokens = Get-DFPackageUniverseCategoryTokens -Members $members -Tags @('viewer')
            $tokens | Should -Contain 'grep'
            $tokens | Should -Contain 'viewer'
        }

        It 'maps tokens to categories via the rules, deduped' {
            $rules = Import-DFPackageUniverseCategoryRules -Path $script:rulesFile
            $cats = ConvertTo-DFPackageUniverseCategories -Tokens @('cat', 'grep') -Rules $rules
            $cats | Should -Contain 'viewer'
            $cats | Should -Contain 'search'
            @($cats).Count | Should -Be 2
        }

        It 'yields no category for unmatched tokens' {
            $rules = Import-DFPackageUniverseCategoryRules -Path $script:rulesFile
            @(ConvertTo-DFPackageUniverseCategories -Tokens @('zzz') -Rules $rules).Count | Should -Be 0
        }
    }

    Context 'Get-DFPackageUniverseToolGroups' {
        BeforeAll {
            # Pester 5.8.0 does not carry a function defined directly in a
            # Context body (outside a hook) into Run-phase It scope; wrapping
            # in BeforeAll is the idiomatic fix. Body/behavior unchanged.
            # PowerShell ships a built-in alias 'r' -> Invoke-History, and alias
            # resolution wins over a same-named function -- remove it first so
            # calls to R() actually hit our helper instead of Invoke-History.
            Remove-Item -Path Alias:r -Force -ErrorAction Ignore
            function R($s, $p) { [pscustomobject]@{ source = $s; package_id = $p } }
            function CM($cid, $s, $p) { [pscustomobject]@{ cluster_id = $cid; source = $s; package_id = $p } }
        }

        AfterAll { Set-Alias -Name r -Value Invoke-History -Scope Global -ErrorAction Ignore }

        It 'groups clustered rows together and makes each unclustered row a singleton' {
            $rows = @( (R 'scoop' 'main/bat'), (R 'winget' 'sharkdp.bat'), (R 'choco' 'solo') )
            $members = @( (CM 1 'scoop' 'main/bat'), (CM 1 'winget' 'sharkdp.bat') )
            $groups = Get-DFPackageUniverseToolGroups -Rows $rows -ClusterMembers $members

            @($groups).Count | Should -Be 2
            $groups[0].ClusterId | Should -Be 1
            @($groups[0].Members).Count | Should -Be 2
            $groups[1].ClusterId | Should -BeNullOrEmpty
            $groups[1].Members[0].package_id | Should -Be 'solo'
        }

        It 'accounts for every row exactly once' {
            $rows = @( (R 'scoop' 'a'), (R 'winget' 'b'), (R 'choco' 'c') )
            $members = @( (CM 7 'scoop' 'a'), (CM 7 'winget' 'b') )
            $groups = Get-DFPackageUniverseToolGroups -Rows $rows -ClusterMembers $members
            $total = (@($groups | ForEach-Object { $_.Members.Count } | Measure-Object -Sum).Sum)
            $total | Should -Be 3
        }

        It 'orders clustered groups by cluster_id ascending then singletons by source|package_id ascending, regardless of input order' {
            # Rows are fed with cluster 5 before cluster 2, and singleton
            # "zzz|last" before singleton "aaa|first" -- the opposite of the
            # required output order -- so a missing/reversed Sort-Object would
            # surface as a failing assertion below rather than passing by luck.
            $rows = @(
                (R 'winget' 'foo.bar')   # cluster 5 member
                (R 'scoop'  'main/foo')  # cluster 5 member
                (R 'zzz'    'last')      # singleton, key "zzz|last"
                (R 'winget' 'baz.qux')   # cluster 2 member
                (R 'choco'  'baz')       # cluster 2 member
                (R 'aaa'    'first')     # singleton, key "aaa|first"
            )
            $members = @(
                (CM 5 'winget' 'foo.bar')
                (CM 5 'scoop'  'main/foo')
                (CM 2 'winget' 'baz.qux')
                (CM 2 'choco'  'baz')
            )
            $groups = Get-DFPackageUniverseToolGroups -Rows $rows -ClusterMembers $members

            @($groups).Count | Should -Be 4

            $groups[0].ClusterId | Should -Be 2
            @($groups[0].Members).Count | Should -Be 2

            $groups[1].ClusterId | Should -Be 5
            @($groups[1].Members).Count | Should -Be 2

            $groups[2].ClusterId | Should -BeNullOrEmpty
            $groups[2].Members[0].source | Should -Be 'aaa'
            $groups[2].Members[0].package_id | Should -Be 'first'

            $groups[3].ClusterId | Should -BeNullOrEmpty
            $groups[3].Members[0].source | Should -Be 'zzz'
            $groups[3].Members[0].package_id | Should -Be 'last'
        }
    }

    Context 'Initialize-DFPackageUniverseToolsSchema' {
        It 'creates the four tables and clears only stage=merge log rows' {
            $db = Join-Path ([System.IO.Path]::GetTempPath()) ("schematest-" + [guid]::NewGuid().ToString('N') + ".db")
            try {
                Invoke-SqliteQuery -DataSource $db -Query 'CREATE TABLE pipeline_log (id INTEGER PRIMARY KEY, stage TEXT, source TEXT, package_id TEXT, level TEXT, message TEXT, logged_at TEXT);'
                Invoke-SqliteQuery -DataSource $db -Query "INSERT INTO pipeline_log (stage, level, message, logged_at) VALUES ('link', 'review', 'keep me', 'now'), ('merge', 'review', 'drop me', 'now');"

                Initialize-DFPackageUniverseToolsSchema -DatabasePath $db

                $tables = @(Invoke-SqliteQuery -DataSource $db -Query "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name").name
                $tables | Should -Contain 'tools'
                $tables | Should -Contain 'tool_packages'
                $tables | Should -Contain 'tool_tags'
                $tables | Should -Contain 'tool_categories'

                $logs = @(Invoke-SqliteQuery -DataSource $db -Query 'SELECT stage FROM pipeline_log')
                @($logs).Count | Should -Be 1
                $logs[0].stage | Should -Be 'link'
            } finally { Remove-Item -Path $db -ErrorAction Ignore }
        }
    }

    Context 'Save-DFPackageUniverseTools' {
        It 'writes the parent, packages, tags, categories, and a review log row' {
            $db = New-MergeTestDb
            try {
                $tool = [pscustomobject]@{
                    ClusterId = 1
                    Record = [pscustomobject]@{
                        Name = 'bat'; NameSource = 'winget'; Description = 'A cat clone'; DescriptionSource = 'winget'
                        Homepage = 'https://github.com/sharkdp/bat'; RepoUrl = 'https://github.com/sharkdp/bat'
                        License = 'MIT'; SourceCount = 2; NeedsReview = $true; ReviewReasons = @('license-conflict: MIT | Apache-2.0')
                    }
                    Members = @(
                        [pscustomobject]@{ source = 'winget'; package_id = 'sharkdp.bat'; name = 'bat'; version = '0.24'; description = 'A cat clone'; homepage = 'h'; license = 'MIT'; publisher = 'sharkdp'; extra = '{"a":1}' }
                        [pscustomobject]@{ source = 'choco'; package_id = 'bat'; name = 'Bat'; version = '0.24.0'; description = 'd'; homepage = 'h'; license = 'https://x/LICENSE'; publisher = 'p'; extra = $null }
                    )
                    Tags = @('cat', 'viewer')
                    Categories = @('viewer')
                }
                $conn = New-SQLiteConnection -DataSource $db
                try { Save-DFPackageUniverseTools -Connection $conn -Tools @($tool) } finally { $conn.Close() }

                (Invoke-SqliteQuery -DataSource $db -Query 'SELECT COUNT(*) n FROM tools').n | Should -Be 1
                (Invoke-SqliteQuery -DataSource $db -Query 'SELECT name, name_source, needs_review FROM tools').name | Should -Be 'bat'
                (Invoke-SqliteQuery -DataSource $db -Query 'SELECT needs_review FROM tools').needs_review | Should -Be 1
                (Invoke-SqliteQuery -DataSource $db -Query 'SELECT COUNT(*) n FROM tool_packages').n | Should -Be 2
                (Invoke-SqliteQuery -DataSource $db -Query "SELECT extra FROM tool_packages WHERE source='winget'").extra | Should -Be '{"a":1}'
                (Invoke-SqliteQuery -DataSource $db -Query 'SELECT COUNT(*) n FROM tool_tags').n | Should -Be 2
                (Invoke-SqliteQuery -DataSource $db -Query 'SELECT COUNT(*) n FROM tool_categories').n | Should -Be 1
                (Invoke-SqliteQuery -DataSource $db -Query "SELECT COUNT(*) n FROM pipeline_log WHERE stage='merge' AND level='review'").n | Should -Be 1
                (Invoke-SqliteQuery -DataSource $db -Query 'SELECT review_reasons FROM tools').review_reasons | Should -Be '["license-conflict: MIT | Apache-2.0"]'
            } finally { Remove-Item -Path $db -ErrorAction Ignore }
        }
    }

    Context 'Invoke-DFPackageUniverseToolMerge' {
        It 'merges a 3-catalog cluster into one tool and keeps a singleton separate (no data lost)' {
            $db = New-MergeTestDb
            try {
                $batExtra = ConvertTo-Json -Compress @{ ProjectSourceUrl = 'https://github.com/sharkdp/bat' }
                Add-RawRow -Db $db -Source 'scoop'  -PackageId 'main/bat'    -Name 'bat' -Description 'short' -Tags (ConvertTo-Json -Compress @('cat'))
                Add-RawRow -Db $db -Source 'winget' -PackageId 'sharkdp.bat' -Name 'bat' -Description 'A cat(1) clone with wings.' -Tags (ConvertTo-Json -Compress @('cat', 'less'))
                Add-RawRow -Db $db -Source 'choco'  -PackageId 'bat'         -Name 'Bat' -License 'https://x/LICENSE' -Extra $batExtra
                Add-RawRow -Db $db -Source 'scoop'  -PackageId 'main/solo'   -Name 'solo'
                Add-ClusterMember -Db $db -Cid 1 -Source 'scoop'  -PackageId 'main/bat'
                Add-ClusterMember -Db $db -Cid 1 -Source 'winget' -PackageId 'sharkdp.bat'
                Add-ClusterMember -Db $db -Cid 1 -Source 'choco'  -PackageId 'bat'

                $conn = New-SQLiteConnection -DataSource $db
                try { $summary = Invoke-DFPackageUniverseToolMerge -Connection $conn -CategoryRulesPath $null } finally { $conn.Close() }

                $summary.RowsRead | Should -Be 4
                $summary.Tools | Should -Be 2
                $summary.Packages | Should -Be 4     # no data lost: every package accounted for
                $summary.Singletons | Should -Be 1

                $bat = Invoke-SqliteQuery -DataSource $db -Query "SELECT * FROM tools WHERE cluster_id = 1"
                $bat.name | Should -Be 'bat'
                $bat.name_source | Should -Be 'winget'
                $bat.description_source | Should -Be 'winget'
                $bat.repo_url | Should -Be 'https://github.com/sharkdp/bat'
                $bat.source_count | Should -Be 3

                (Invoke-SqliteQuery -DataSource $db -Query "SELECT COUNT(*) n FROM tool_packages WHERE tool_id = $($bat.tool_id)").n | Should -Be 3
                $tags = @(Invoke-SqliteQuery -DataSource $db -Query "SELECT tag FROM tool_tags WHERE tool_id = $($bat.tool_id)").tag
                $tags | Should -Contain 'cat'
                $tags | Should -Contain 'less'

                # Core contract: sum of children equals the input row count.
                (Invoke-SqliteQuery -DataSource $db -Query 'SELECT COUNT(*) n FROM tool_packages').n | Should -Be 4
            } finally { Remove-Item -Path $db -ErrorAction Ignore }
        }

        It 'is idempotent: a second run reproduces identical row counts' {
            $db = New-MergeTestDb
            try {
                Add-RawRow -Db $db -Source 'winget' -PackageId 'A.X' -Name 'x' -Tags (ConvertTo-Json -Compress @('grep'))
                Add-RawRow -Db $db -Source 'scoop'  -PackageId 'main/y' -Name 'y'
                foreach ($i in 1..2) {
                    $conn = New-SQLiteConnection -DataSource $db
                    try { Invoke-DFPackageUniverseToolMerge -Connection $conn -CategoryRulesPath $null | Out-Null } finally { $conn.Close() }
                    Initialize-DFPackageUniverseToolsSchema -DatabasePath $db  # truncate before re-run, as the orchestrator does
                }
                # Final populated run (schema was just truncated):
                $conn = New-SQLiteConnection -DataSource $db
                try { $s = Invoke-DFPackageUniverseToolMerge -Connection $conn -CategoryRulesPath $null } finally { $conn.Close() }
                $s.Tools | Should -Be 2
                (Invoke-SqliteQuery -DataSource $db -Query 'SELECT COUNT(*) n FROM tool_packages').n | Should -Be 2
            } finally { Remove-Item -Path $db -ErrorAction Ignore }
        }
    }

    Context 'Build-DFPackageUniverseTools.ps1' {
        It 'runs end-to-end against a prepared DB and returns a summary' {
            $db = New-MergeTestDb
            try {
                Add-RawRow -Db $db -Source 'winget' -PackageId 'A.X' -Name 'x'
                Add-RawRow -Db $db -Source 'scoop'  -PackageId 'main/y' -Name 'y'
                $summary = & "$PSScriptRoot/../build/Build-DFPackageUniverseTools.ps1" -DatabasePath $db -CategoryRulesPath $null 6>$null
                $summary.Tools | Should -Be 2
                $summary.Packages | Should -Be 2
            } finally { Remove-Item -Path $db -ErrorAction Ignore }
        }

        It 'throws a helpful error when cluster_members is missing (Phase B not run)' {
            $db = Join-Path ([System.IO.Path]::GetTempPath()) ("nob-" + [guid]::NewGuid().ToString('N') + ".db")
            try {
                Invoke-SqliteQuery -DataSource $db -Query 'CREATE TABLE raw_packages (id INTEGER PRIMARY KEY, source TEXT, package_id TEXT, fetched_at TEXT); CREATE TABLE pipeline_log (id INTEGER PRIMARY KEY, stage TEXT, source TEXT, package_id TEXT, level TEXT, message TEXT, logged_at TEXT);'
                { & "$PSScriptRoot/../build/Build-DFPackageUniverseTools.ps1" -DatabasePath $db -CategoryRulesPath $null 6>$null } | Should -Throw '*cluster_members*'
            } finally { Remove-Item -Path $db -ErrorAction Ignore }
        }
    }
}
