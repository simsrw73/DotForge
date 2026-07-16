BeforeAll {
    Import-Module PSSQLite
    # ConvertTo-DFNormalizedHomepage is reused from the existing identity code.
    . "$PSScriptRoot/../Private/Resolve-DFToolIdentityCandidateRepo.ps1"
    . "$PSScriptRoot/../build/Private/DFPackageUniverse.Db.ps1"
    . "$PSScriptRoot/../build/Private/DFPackageUniverse.Links.ps1"

    # A raw_packages-shaped row. extra is a JSON string (as stored), source-specific.
    function New-RawRow {
        param(
            [string]$Source, [string]$PackageId, [string]$Name = 'tool',
            [string]$Publisher = $null, [string]$Homepage = $null, $Extra = $null
        )
        [pscustomobject]@{
            source = $Source; package_id = $PackageId; name = $Name; version = '1.0'
            description = 'd'; homepage = $Homepage; license = 'MIT'; publisher = $Publisher
            tags = $null; extra = ($Extra ? (ConvertTo-Json -Compress -Depth 8 -InputObject $Extra) : $null)
        }
    }

    function Edge($edges, $method) { @($edges | Where-Object { $_.Method -eq $method }) }

    function E($sa, $ia, $sb, $ib, $m, $c) {
        [pscustomobject]@{ SourceA = $sa; PackageIdA = $ia; SourceB = $sb; PackageIdB = $ib; Method = $m; Confidence = $c; Evidence = 'e' }
    }
    function Node($s, $p) { [pscustomobject]@{ source = $s; package_id = $p } }

    function Seed($db, $source, $packageId, $name, $homepage) {
        Invoke-SqliteQuery -DataSource $db -Query "INSERT INTO raw_packages (source, package_id, name, version, homepage, fetched_at) VALUES (@s, @p, @n, '1', @h, 'now')" -SqlParameters @{ s = $source; p = $packageId; n = $name; h = $homepage }
    }
}

Describe 'DFPackageUniverse.Links' {
    Context 'Get-DFPackageUniverseRepoKey' {
        It 'derives owner/repo from a github homepage, lowercased' {
            $row = New-RawRow -Source 'scoop' -PackageId 'main/ripgrep' -Homepage 'https://github.com/BurntSushi/ripgrep'
            Get-DFPackageUniverseRepoKey -Row $row | Should -Be 'burntsushi/ripgrep'
        }

        It 'strips a trailing .git and any path/query/fragment' {
            $row = New-RawRow -Source 'winget' -PackageId 'X.Y' -Homepage 'https://github.com/Owner/Repo.git#readme'
            Get-DFPackageUniverseRepoKey -Row $row | Should -Be 'owner/repo'
        }

        It 'returns $null for a non-github homepage with no repo in extra' {
            $row = New-RawRow -Source 'winget' -PackageId 'X.Y' -Homepage 'https://vendor.example/product'
            Get-DFPackageUniverseRepoKey -Row $row | Should -BeNullOrEmpty
        }

        It 'recovers the repo from choco ProjectSourceUrl when homepage is a vanity domain' {
            $row = New-RawRow -Source 'choco' -PackageId 'tool' -Homepage 'https://vanity.example/tool' -Extra @{
                ProjectUrl = 'https://vanity.example/tool'; ProjectSourceUrl = 'https://github.com/acme/tool'
            }
            Get-DFPackageUniverseRepoKey -Row $row | Should -Be 'acme/tool'
        }

        It 'does NOT treat choco PackageSourceUrl (the packaging repo) as the tool repo' {
            # PackageSourceUrl points at the chocolatey packaging repo, shared by
            # thousands of packages -- using it would fuse them all (trifle zed at scale).
            $row = New-RawRow -Source 'choco' -PackageId 'tool' -Homepage 'https://vanity.example/tool' -Extra @{
                PackageSourceUrl = 'https://github.com/chocolatey-community/chocolatey-packages'
            }
            Get-DFPackageUniverseRepoKey -Row $row | Should -BeNullOrEmpty
        }

        It 'recovers the repo from a scoop checkver.github object when homepage is a vanity domain' {
            $row = New-RawRow -Source 'scoop' -PackageId 'main/tool' -Homepage 'https://vanity.example/tool' -Extra @{
                version = '1.0'; homepage = 'https://vanity.example/tool'
                checkver = @{ github = 'https://github.com/acme/tool' }
            }
            Get-DFPackageUniverseRepoKey -Row $row | Should -Be 'acme/tool'
        }

        It 'does not throw under strict mode on a row with null homepage and null extra' {
            Set-StrictMode -Version Latest
            $row = New-RawRow -Source 'winget' -PackageId 'X.Y'
            { Get-DFPackageUniverseRepoKey -Row $row } | Should -Not -Throw
            Get-DFPackageUniverseRepoKey -Row $row | Should -BeNullOrEmpty
        }
    }

    Context 'normalization' {
        It 'ConvertTo-DFNormalizedName lowercases and strips non-alphanumeric' {
            ConvertTo-DFNormalizedName -Value 'WMI Explorer' | Should -Be 'wmiexplorer'
            ConvertTo-DFNormalizedName -Value '7-Zip' | Should -Be '7zip'
        }

        It 'ConvertTo-DFNormalizedName returns empty string for null or empty input' {
            ConvertTo-DFNormalizedName -Value $null | Should -Be ''
            ConvertTo-DFNormalizedName -Value '' | Should -Be ''
        }

        It 'ConvertTo-DFNormalizedPublisher strips corporate suffixes and punctuation' {
            ConvertTo-DFNormalizedPublisher -Value 'DWANGO Co., Ltd.' | Should -Be 'dwango'
            ConvertTo-DFNormalizedPublisher -Value '3CX Software DMCC' | Should -Be '3cx'
            ConvertTo-DFNormalizedPublisher -Value 'Vinay Pamnani'     | Should -Be 'vinaypamnani'
        }

        It 'ConvertTo-DFNormalizedPublisher returns empty for null (scoop rows have no publisher)' {
            ConvertTo-DFNormalizedPublisher -Value $null | Should -Be ''
        }
    }

    Context 'Get-DFPackageUniverseLinkKeys' {
        It 'returns a repo key and no homepage key for a github homepage' {
            $row = New-RawRow -Source 'scoop' -PackageId 'main/ripgrep' -Name 'ripgrep' -Homepage 'https://github.com/BurntSushi/ripgrep'
            $keys = Get-DFPackageUniverseLinkKeys -Row $row
            $keys.Repo     | Should -Be 'burntsushi/ripgrep'
            $keys.Homepage | Should -BeNullOrEmpty
            $keys.Name     | Should -Be 'ripgrep'
        }

        It 'returns a normalized homepage key (scheme/www/trailing-slash stripped) for a non-github vanity url with a path' {
            $row = New-RawRow -Source 'winget' -PackageId 'V.P' -Name 'Product' -Publisher 'Vendor' -Homepage 'https://www.Vendor.com/Product/'
            $keys = Get-DFPackageUniverseLinkKeys -Row $row
            $keys.Homepage | Should -Be 'vendor.com/product'
            $keys.Repo     | Should -BeNullOrEmpty
        }

        It 'emits no homepage key for a bare-domain homepage (too weak; left to review)' {
            $row = New-RawRow -Source 'winget' -PackageId 'V.P' -Name 'Product' -Homepage 'https://vendor.com'
            (Get-DFPackageUniverseLinkKeys -Row $row).Homepage | Should -BeNullOrEmpty
        }

        It 'builds a publisher-name key only when a publisher is present (scoop has none)' {
            $wg = New-RawRow -Source 'winget' -PackageId 'V.P' -Name 'Tool' -Publisher 'Acme'
            (Get-DFPackageUniverseLinkKeys -Row $wg).PubName | Should -Be 'acme|tool'
            $sc = New-RawRow -Source 'scoop' -PackageId 'main/tool' -Name 'Tool'
            (Get-DFPackageUniverseLinkKeys -Row $sc).PubName | Should -BeNullOrEmpty
        }

        It 'gates the name-only key to names of length >= 4' {
            (Get-DFPackageUniverseLinkKeys -Row (New-RawRow -Source 'choco' -PackageId 'fd' -Name 'fd')).Name | Should -BeNullOrEmpty
            (Get-DFPackageUniverseLinkKeys -Row (New-RawRow -Source 'choco' -PackageId 'ripgrep' -Name 'ripgrep')).Name | Should -Be 'ripgrep'
        }
    }

    Context 'Get-DFPackageUniverseLinkEdges' {
        It 'emits a repo edge (confidence 1.0) between two catalogs sharing a github repo' {
            $rows = @(
                New-RawRow -Source 'scoop'  -PackageId 'main/ripgrep'      -Name 'ripgrep' -Homepage 'https://github.com/BurntSushi/ripgrep'
                New-RawRow -Source 'winget' -PackageId 'BurntSushi.ripgrep' -Name 'ripgrep' -Homepage 'https://github.com/BurntSushi/ripgrep'
            )
            $repo = Edge (Get-DFPackageUniverseLinkEdges -Rows $rows) 'repo'
            $repo.Count | Should -Be 1
            $repo[0].Confidence | Should -Be 1.0
            $repo[0].Evidence | Should -Be 'burntsushi/ripgrep'
        }

        It 'emits a homepage edge (0.75) for a shared normalized non-github homepage' {
            $rows = @(
                New-RawRow -Source 'scoop'  -PackageId 'main/tool' -Name 'Tool' -Homepage 'https://vendor.example/tool'
                New-RawRow -Source 'choco'  -PackageId 'tool'      -Name 'Tool' -Homepage 'https://vendor.example/tool/'
            )
            $hp = Edge (Get-DFPackageUniverseLinkEdges -Rows $rows) 'homepage'
            $hp.Count | Should -Be 1
            $hp[0].Confidence | Should -Be 0.75
        }

        It 'emits a publisher-name edge (0.60) when pub+name agree and repos do not conflict' {
            $rows = @(
                New-RawRow -Source 'winget' -PackageId 'Acme.Tool' -Name 'Tool' -Publisher 'Acme'
                New-RawRow -Source 'choco'  -PackageId 'tool'      -Name 'Tool' -Publisher 'Acme Inc'
            )
            $edges = Get-DFPackageUniverseLinkEdges -Rows $rows
            (Edge $edges 'publisher-name').Count | Should -Be 1
            (Edge $edges 'publisher-name')[0].Confidence | Should -Be 0.60
        }

        It 'downgrades a publisher-name group to a conflict edge (0.30) when members resolve to different repos' {
            $rows = @(
                New-RawRow -Source 'winget' -PackageId 'lucasg.Dependencies' -Name 'Dependencies' -Publisher 'lucasg' -Homepage 'https://github.com/himeshsameera/dependencies'
                New-RawRow -Source 'choco'  -PackageId 'dependencies'        -Name 'Dependencies' -Publisher 'lucasg' -Homepage 'https://github.com/lucasg/dependencies'
            )
            $edges = Get-DFPackageUniverseLinkEdges -Rows $rows
            (Edge $edges 'publisher-name').Count | Should -Be 0
            (Edge $edges 'conflict').Count | Should -Be 1
            (Edge $edges 'conflict')[0].Confidence | Should -Be 0.30
        }

        It 'emits a name-only edge (0.20) for a shared name when nothing else links or conflicts' {
            $rows = @(
                New-RawRow -Source 'scoop' -PackageId 'main/7zip' -Name '7zip'
                New-RawRow -Source 'choco' -PackageId '7zip'      -Name '7zip'
            )
            $edges = Get-DFPackageUniverseLinkEdges -Rows $rows
            (Edge $edges 'name-only').Count | Should -Be 1
            (Edge $edges 'name-only')[0].Confidence | Should -Be 0.20
        }

        It 'downgrades a name-only group to conflict (0.30) when members resolve to different repos (cemu emulators)' {
            # 'cemu' (len 4) collides two different projects: the Wii-U emulator
            # and the calculator emulator. Different repos -> conflict, not merge.
            $rows = @(
                New-RawRow -Source 'scoop'  -PackageId 'main/cemu'            -Name 'cemu' -Homepage 'https://github.com/cemu-project/cemu'
                New-RawRow -Source 'winget' -PackageId 'CE-Programming.CEmu'   -Name 'CEmu' -Homepage 'https://github.com/ce-programming/cemu'
            )
            $edges = Get-DFPackageUniverseLinkEdges -Rows $rows
            (Edge $edges 'name-only').Count | Should -Be 0
            (Edge $edges 'conflict').Count | Should -Be 1
        }

        It 'emits no edges for a single unmatched row' {
            $rows = @(New-RawRow -Source 'scoop' -PackageId 'main/solo' -Name 'solo' -Homepage 'https://github.com/x/solo')
            @(Get-DFPackageUniverseLinkEdges -Rows $rows).Count | Should -Be 0
        }

        It 'does not auto-merge a monorepo family: many distinctly-named packages sharing one repo emit no repo edges' {
            $rows = @(1..6 | ForEach-Object {
                    New-RawRow -Source 'scoop' -PackageId "nerd-fonts/Font$_" -Name "Font$_-NF" -Homepage 'https://github.com/ryanoasis/nerd-fonts'
                })
            (Edge (Get-DFPackageUniverseLinkEdges -Rows $rows) 'repo').Count | Should -Be 0
        }

        It 'still clusters a small same-repo variant group below the family size threshold (ripgrep GNU/MSVC)' {
            $rows = @(
                New-RawRow -Source 'scoop'  -PackageId 'main/ripgrep'          -Name 'ripgrep'      -Homepage 'https://github.com/BurntSushi/ripgrep'
                New-RawRow -Source 'winget' -PackageId 'BurntSushi.ripgrep.MSVC' -Name 'RipGrep MSVC' -Homepage 'https://github.com/BurntSushi/ripgrep'
                New-RawRow -Source 'choco'  -PackageId 'ripgrep'               -Name 'ripgrep'      -Homepage 'https://github.com/BurntSushi/ripgrep'
            )
            (Edge (Get-DFPackageUniverseLinkEdges -Rows $rows) 'repo').Count | Should -BeGreaterThan 0
        }
    }

    Context 'Get-DFPackageUniverseFamilyGroups' {
        It 'surfaces a monorepo (shared repo, many distinct names) for review' {
            $rows = @(1..6 | ForEach-Object {
                    New-RawRow -Source 'scoop' -PackageId "nerd-fonts/Font$_" -Name "Font$_-NF" -Homepage 'https://github.com/ryanoasis/nerd-fonts'
                })
            $fam = @(Get-DFPackageUniverseFamilyGroups -Rows $rows)
            $fam.Count   | Should -Be 1
            $fam[0].Tier | Should -Be 'repo'
            $fam[0].Key  | Should -Be 'ryanoasis/nerd-fonts'
            $fam[0].Size | Should -Be 6
        }

        It 'surfaces a shared-homepage vendor family (distinct names, one url) for review' {
            $rows = @(1..6 | ForEach-Object {
                    New-RawRow -Source 'winget' -PackageId "V.P$_" -Name "Product$_" -Homepage 'https://dot.net/core'
                })
            $fam = @(Get-DFPackageUniverseFamilyGroups -Rows $rows)
            $fam.Count   | Should -Be 1
            $fam[0].Tier | Should -Be 'homepage'
        }

        It 'does not flag a small variant group as a family' {
            $rows = @(
                New-RawRow -Source 'scoop'  -PackageId 'main/ripgrep'          -Name 'ripgrep'      -Homepage 'https://github.com/BurntSushi/ripgrep'
                New-RawRow -Source 'choco'  -PackageId 'ripgrep'               -Name 'ripgrep'      -Homepage 'https://github.com/BurntSushi/ripgrep'
            )
            @(Get-DFPackageUniverseFamilyGroups -Rows $rows).Count | Should -Be 0
        }
    }

    Context 'Invoke-DFPackageUniverseClustering' {
        It 'merges nodes connected by above-threshold edges into one cluster' {
            $edges = @(
                (E 'scoop' 'a' 'winget' 'b' 'repo' 1.0)
                (E 'winget' 'b' 'choco' 'c' 'repo' 1.0)
            )
            $clusters = @(Invoke-DFPackageUniverseClustering -Edges $edges)
            $clusters.Count | Should -Be 1
            $clusters[0].Members.Count | Should -Be 3
            $clusters[0].MinConfidence | Should -Be 1.0
        }

        It 'does not cluster on a below-threshold edge (name-only 0.20)' {
            $edges = @((E 'scoop' 'a' 'choco' 'b' 'name-only' 0.20))
            @(Invoke-DFPackageUniverseClustering -Edges $edges).Count | Should -Be 0
        }

        It 'force-merges a curated confirmed-same group even without any edges' {
            $clusters = @(Invoke-DFPackageUniverseClustering -Edges @() -CuratedSame @(, @((Node 'scoop' 'a'), (Node 'choco' 'b'))))
            $clusters.Count | Should -Be 1
            $clusters[0].Members.Count | Should -Be 2
            $clusters[0].HasCurated | Should -BeTrue
        }

        It 'blocks a merge forbidden by a curated cannot-link pair' {
            $edges = @((E 'scoop' 'air' 'winget' 'air' 'repo' 1.0))
            $clusters = @(Invoke-DFPackageUniverseClustering -Edges $edges -CuratedDifferent @(, @((Node 'scoop' 'air'), (Node 'winget' 'air'))))
            @($clusters | Where-Object { $_.Members.Count -ge 2 }).Count | Should -Be 0
        }

        It 'flags a cluster needsReview when a conflict edge touches it' {
            $edges = @(
                (E 'scoop' 'a' 'winget' 'b' 'repo' 1.0)
                (E 'winget' 'b' 'choco' 'c' 'conflict' 0.30)
            )
            $clusters = @(Invoke-DFPackageUniverseClustering -Edges $edges)
            $clusters[0].NeedsReview | Should -BeTrue
        }
    }

    Context 'Import-DFPackageUniverseCuration' {
        It 'parses same-groups and different-pairs from a JSONC file with comments' {
            $path = Join-Path $TestDrive 'cur.jsonc'
            Set-Content -Path $path -Encoding UTF8 -Value @'
{
  // curated cross-catalog identities
  "schemaVersion": 1,
  "same": [
    { "id": "bat", "members": [
      { "source": "scoop",  "package_id": "bat" },
      { "source": "winget", "package_id": "sharkdp.bat" }
    ] }
  ],
  "different": [
    { "note": "R formatter vs Go reloader", "members": [
      { "source": "scoop",  "package_id": "main/air" },
      { "source": "winget", "package_id": "Posit.Air" }
    ] }
  ]
}
'@
            $cur = Import-DFPackageUniverseCuration -Path $path
            $cur.Same.Count      | Should -Be 1
            $cur.Same[0].Count   | Should -Be 2
            $cur.Same[0][0].source | Should -Be 'scoop'
            $cur.Same[0][1].package_id | Should -Be 'sharkdp.bat'
            $cur.Different.Count    | Should -Be 1
            $cur.Different[0].Count | Should -Be 2
        }

        It 'does not corrupt a package_id containing a slash (line-comment strip is anchored)' {
            $path = Join-Path $TestDrive 'slash.jsonc'
            Set-Content -Path $path -Encoding UTF8 -Value @'
{ "same": [ { "members": [
  { "source": "scoop", "package_id": "main/7zip" },
  { "source": "choco", "package_id": "7zip" }
] } ], "different": [] }
'@
            (Import-DFPackageUniverseCuration -Path $path).Same[0][0].package_id | Should -Be 'main/7zip'
        }

        It 'returns empty same/different for a missing file' {
            $cur = Import-DFPackageUniverseCuration -Path (Join-Path $TestDrive 'nope.jsonc')
            $cur.Same.Count      | Should -Be 0
            $cur.Different.Count | Should -Be 0
        }
    }

    Context 'Links DB layer' {
        BeforeEach {
            $script:Db = Join-Path $TestDrive "links-$([guid]::NewGuid().ToString('N')).db"
            Initialize-DFPackageUniverseDb -DatabasePath $script:Db | Out-Null
            Initialize-DFPackageUniverseLinksSchema -DatabasePath $script:Db
        }

        It 'creates the four link tables' {
            $tables = @((Invoke-SqliteQuery -DataSource $script:Db -Query "SELECT name FROM sqlite_master WHERE type='table'").name)
            foreach ($t in 'identity_links', 'identity_clusters', 'cluster_members', 'curated_links') { $tables | Should -Contain $t }
        }

        It 'persists edges, clusters, members, the curated mirror, and review-log rows' {
            $edges = @(
                (E 'scoop' 'a' 'winget' 'b' 'repo' 1.0)
                (E 'scoop' 'x' 'choco' 'y' 'name-only' 0.20)
            )
            $clusters = @(Invoke-DFPackageUniverseClustering -Edges $edges)
            $curation = [pscustomobject]@{ Same = @(); Different = @(, @((Node 'scoop' 'air'), (Node 'winget' 'air'))) }

            $conn = New-SQLiteConnection -DataSource $script:Db
            try { Save-DFPackageUniverseLinks -Connection $conn -Edges $edges -Clusters $clusters -Curation $curation }
            finally { $conn.Close() }

            (Invoke-SqliteQuery -DataSource $script:Db -Query "SELECT COUNT(*) c FROM identity_links").c    | Should -Be 2
            (Invoke-SqliteQuery -DataSource $script:Db -Query "SELECT COUNT(*) c FROM identity_clusters").c | Should -Be 1
            (Invoke-SqliteQuery -DataSource $script:Db -Query "SELECT COUNT(*) c FROM cluster_members").c   | Should -Be 2
            (Invoke-SqliteQuery -DataSource $script:Db -Query "SELECT COUNT(*) c FROM curated_links WHERE kind='different'").c | Should -Be 2
            (Invoke-SqliteQuery -DataSource $script:Db -Query "SELECT COUNT(*) c FROM pipeline_log WHERE stage='link' AND level='review'").c | Should -BeGreaterThan 0
        }

        It 're-running the schema init clears prior link rows (per-run truncation)' {
            $e = @((E 'scoop' 'a' 'winget' 'b' 'repo' 1.0))
            $conn = New-SQLiteConnection -DataSource $script:Db
            try { Save-DFPackageUniverseLinks -Connection $conn -Edges $e -Clusters @(Invoke-DFPackageUniverseClustering -Edges $e) -Curation ([pscustomobject]@{ Same = @(); Different = @() }) }
            finally { $conn.Close() }
            Initialize-DFPackageUniverseLinksSchema -DatabasePath $script:Db
            (Invoke-SqliteQuery -DataSource $script:Db -Query "SELECT COUNT(*) c FROM identity_links").c | Should -Be 0
        }
    }

    Context 'Invoke-DFPackageUniverseLinkBuild (end-to-end)' {
        BeforeEach {
            $script:Db = Join-Path $TestDrive "e2e-$([guid]::NewGuid().ToString('N')).db"
            Initialize-DFPackageUniverseDb -DatabasePath $script:Db | Out-Null
            Initialize-DFPackageUniverseLinksSchema -DatabasePath $script:Db
        }

        It 'clusters the bat ground-truth trio (scoop/winget/choco) via a shared repo' {
            Seed $script:Db 'scoop'  'bat'         'bat' 'https://github.com/sharkdp/bat'
            Seed $script:Db 'winget' 'sharkdp.bat' 'bat' 'https://github.com/sharkdp/bat'
            Seed $script:Db 'choco'  'bat'         'bat' 'https://github.com/sharkdp/bat'

            $conn = New-SQLiteConnection -DataSource $script:Db
            try { $summary = Invoke-DFPackageUniverseLinkBuild -Connection $conn -CurationPath (Join-Path $TestDrive 'none.jsonc') }
            finally { $conn.Close() }

            $summary.RowsRead | Should -Be 3
            (Invoke-SqliteQuery -DataSource $script:Db -Query "SELECT COUNT(DISTINCT cluster_id) c FROM cluster_members").c | Should -Be 1
            (Invoke-SqliteQuery -DataSource $script:Db -Query "SELECT COUNT(*) c FROM cluster_members").c | Should -Be 3
        }

        It 'keeps a curated confirmed-different pair split even when a repo signal would merge them' {
            # Two 'air' packages pointing at the SAME repo would merge by repo (1.0);
            # a curated 'different' cannot-link must keep them apart.
            Seed $script:Db 'scoop'  'main/air'  'air' 'https://github.com/air-verse/air'
            Seed $script:Db 'winget' 'Posit.Air' 'air' 'https://github.com/air-verse/air'
            $cur = Join-Path $TestDrive 'cur.jsonc'
            Set-Content -Path $cur -Encoding UTF8 -Value '{ "same": [], "different": [ { "members": [ {"source":"scoop","package_id":"main/air"}, {"source":"winget","package_id":"Posit.Air"} ] } ] }'

            $conn = New-SQLiteConnection -DataSource $script:Db
            try { Invoke-DFPackageUniverseLinkBuild -Connection $conn -CurationPath $cur }
            finally { $conn.Close() }

            (Invoke-SqliteQuery -DataSource $script:Db -Query "SELECT COUNT(*) c FROM cluster_members").c | Should -Be 0
        }

        It 'flags a monorepo family for review instead of clustering it' {
            1..6 | ForEach-Object { Seed $script:Db 'scoop' "nerd-fonts/Font$_" "Font$_-NF" 'https://github.com/ryanoasis/nerd-fonts' }

            $conn = New-SQLiteConnection -DataSource $script:Db
            try { $s = Invoke-DFPackageUniverseLinkBuild -Connection $conn -CurationPath (Join-Path $TestDrive 'none.jsonc') }
            finally { $conn.Close() }

            (Invoke-SqliteQuery -DataSource $script:Db -Query "SELECT COUNT(*) c FROM cluster_members").c | Should -Be 0
            (Invoke-SqliteQuery -DataSource $script:Db -Query "SELECT COUNT(*) c FROM pipeline_log WHERE stage='link' AND level='review' AND message LIKE '%family%'").c | Should -BeGreaterThan 0
            $s.Families | Should -Be 1
        }
    }
}
