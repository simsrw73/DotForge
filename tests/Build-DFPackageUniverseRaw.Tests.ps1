BeforeAll {
    Import-Module PSSQLite
    Import-Module powershell-yaml

    $script:ScriptPath = "$PSScriptRoot/../build/Build-DFPackageUniverseRaw.ps1"

    $script:DefaultLocaleManifestYaml = @'
PackageIdentifier: Microsoft.VisualStudioCode
PackageVersion: 1.105.0
PackageLocale: en-US
Publisher: Microsoft Corporation
PackageName: Microsoft Visual Studio Code
PackageUrl: https://code.visualstudio.com
License: Microsoft Software License
ShortDescription: A code editor.
Tags:
- developer-tools
- editor
ManifestType: defaultLocale
ManifestVersion: 1.10.0
'@

    $script:VersionManifestYaml = @'
PackageIdentifier: Microsoft.VisualStudioCode
PackageVersion: 1.105.0
DefaultLocale: en-US
ManifestType: version
ManifestVersion: 1.10.0
'@

    function New-FakeScoopFixture {
        param([string]$Root)
        $bucket = Join-Path $Root 'buckets/main/bucket'
        New-Item -ItemType Directory -Path $bucket -Force | Out-Null
        @{ version = '14.1.1'; description = 'Recursively search directories for a regex pattern'; homepage = 'https://github.com/BurntSushi/ripgrep'; license = 'MIT' } |
            ConvertTo-Json | Set-Content (Join-Path $bucket 'ripgrep.json')
    }

    function New-FakeWingetSnapshot {
        param([string]$Root)
        $dir = Join-Path $Root 'manifests/m/Microsoft/VisualStudioCode/1.105.0'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -Path (Join-Path $dir 'Microsoft.VisualStudioCode.yaml') -Value $script:VersionManifestYaml
        Set-Content -Path (Join-Path $dir 'Microsoft.VisualStudioCode.locale.en-US.yaml') -Value $script:DefaultLocaleManifestYaml
    }

    function New-FakeChocoEntry {
        param([string]$Id)
        [pscustomobject]@{
            properties = [pscustomobject]@{
                Id = $Id; Version = '1.0'; Description = "$Id description"
                ProjectUrl = "https://example.com/$Id"; Tags = 'cli tool'; LicenseUrl = "https://example.com/$Id/license"
            }
            author = [pscustomobject]@{ name = 'Someone' }
            title  = $Id
        }
    }

    # A stateful fetch closure matching the production seam contract:
    # param($Url) -> @{ Entries; NextUrl }. Pages are returned by call order;
    # NextUrl is a non-null sentinel for every page except the last, mirroring
    # the server's <link rel="next"> continuation (its absence = end of bucket).
    function New-FakeChocoFetch {
        param([object[]]$Pages)
        $counter = @{ Index = 0 }
        {
            param($Url)
            $i = $counter.Index
            $counter.Index++
            $entries = if ($i -lt $Pages.Count) { $Pages[$i] } else { @() }
            $next = if (($i + 1) -lt $Pages.Count) { "https://fake/next/page$($i + 1)" } else { $null }
            [pscustomobject]@{ Entries = @($entries); NextUrl = $next }
        }.GetNewClosure()
    }
}

Describe 'Build-DFPackageUniverseRaw' {
    BeforeEach {
        $script:WorkDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:WorkDir -Force | Out-Null

        $script:ScoopRoot = Join-Path $script:WorkDir 'scoop'
        New-FakeScoopFixture -Root $script:ScoopRoot

        $script:WingetSnapshot = Join-Path $script:WorkDir 'winget-pkgs'
        New-FakeWingetSnapshot -Root $script:WingetSnapshot

        $script:DatabasePath = Join-Path $script:WorkDir 'universe.db'

        $script:ChocoFetch = New-FakeChocoFetch -Pages @(
            @((New-FakeChocoEntry -Id 'bat'), (New-FakeChocoEntry -Id 'fd')),
            @()
        )
        $script:ChocoSleep = { param($Milliseconds) }
    }

    It 'acquires from all three catalogs and writes raw_packages + pipeline_log' {
        & $script:ScriptPath -SkipScoopUpdate -DatabasePath $script:DatabasePath -ScoopRoot $script:ScoopRoot `
            -WingetPkgsSnapshot $script:WingetSnapshot `
            -ChocoFetchPage $script:ChocoFetch -ChocoSleep $script:ChocoSleep -ChocoDelayMinMs 0 -ChocoDelayMaxMs 1 | Out-Null

        $conn = New-SQLiteConnection -DataSource $script:DatabasePath
        try {
            $counts = @{}
            foreach ($row in Invoke-SqliteQuery -SQLiteConnection $conn -Query 'SELECT source, COUNT(*) as c FROM raw_packages GROUP BY source;') {
                $counts[$row.source] = [int]$row.c
            }
            $counts['scoop'] | Should -Be 1
            $counts['winget'] | Should -Be 1
            $counts['choco'] | Should -Be 2

            $scoopRow = Invoke-SqliteQuery -SQLiteConnection $conn -Query "SELECT * FROM raw_packages WHERE source='scoop';"
            $scoopRow.package_id | Should -Be 'main/ripgrep'

            $wingetRow = Invoke-SqliteQuery -SQLiteConnection $conn -Query "SELECT * FROM raw_packages WHERE source='winget';"
            $wingetRow.package_id | Should -Be 'Microsoft.VisualStudioCode'
            $wingetRow.homepage | Should -Be 'https://code.visualstudio.com'

            $chocoIds = @(Invoke-SqliteQuery -SQLiteConnection $conn -Query "SELECT package_id FROM raw_packages WHERE source='choco';").package_id
            $chocoIds | Should -Contain 'bat'
            $chocoIds | Should -Contain 'fd'
        } finally {
            $conn.Close()
        }
    }

    It 'runs the scoop bucket refresh (ScoopUpdate) before scoop acquisition by default' {
        $marker = Join-Path $script:WorkDir 'scoop-updated.marker'
        & $script:ScriptPath -DatabasePath $script:DatabasePath -ScoopRoot $script:ScoopRoot `
            -WingetPkgsSnapshot $script:WingetSnapshot `
            -ScoopUpdate ([scriptblock]::Create("Set-Content -Path '$marker' -Value ran")) `
            -ChocoFetchPage $script:ChocoFetch -ChocoSleep $script:ChocoSleep -ChocoDelayMinMs 0 -ChocoDelayMaxMs 1 | Out-Null

        Test-Path $marker | Should -BeTrue
    }

    It 'isolates a scoop failure: winget and choco still populate raw_packages, and an error is logged' {
        & $script:ScriptPath -SkipScoopUpdate -DatabasePath $script:DatabasePath `
            -ScoopFetchItems { param($ScoopRoot) throw 'scoop is down' } `
            -WingetPkgsSnapshot $script:WingetSnapshot `
            -ChocoFetchPage $script:ChocoFetch -ChocoSleep $script:ChocoSleep -ChocoDelayMinMs 0 -ChocoDelayMaxMs 1 | Out-Null

        $conn = New-SQLiteConnection -DataSource $script:DatabasePath
        try {
            $counts = @{}
            foreach ($row in Invoke-SqliteQuery -SQLiteConnection $conn -Query 'SELECT source, COUNT(*) as c FROM raw_packages GROUP BY source;') {
                $counts[$row.source] = [int]$row.c
            }
            $counts.ContainsKey('scoop') | Should -BeFalse
            $counts['winget'] | Should -Be 1
            $counts['choco'] | Should -Be 2

            $errorRows = @(Invoke-SqliteQuery -SQLiteConnection $conn -Query "SELECT * FROM pipeline_log WHERE stage='acquire' AND source='scoop' AND level='error';")
            $errorRows.Count | Should -Be 1
        } finally {
            $conn.Close()
        }
    }

    It 'walks the whole catalog unfiltered on every run -- never an incremental delta' {
        # Regression test for the 2026-07-15 redesign, at the script level. A
        # second run must issue the same unfiltered walk as the first: no
        # watermark, no LastUpdated clause. A date-filtered query would still
        # return correct data, just at ~16x the request cost, so nothing but an
        # explicit URL assertion catches this.
        & $script:ScriptPath -SkipScoopUpdate -DatabasePath $script:DatabasePath -ScoopRoot $script:ScoopRoot `
            -WingetPkgsSnapshot $script:WingetSnapshot `
            -ChocoFetchPage $script:ChocoFetch -ChocoSleep $script:ChocoSleep -ChocoDelayMinMs 0 -ChocoDelayMaxMs 1 | Out-Null

        $secondRunUrls = [System.Collections.Generic.List[string]]::new()
        $recordingFetch = {
            param($Url)
            $secondRunUrls.Add($Url)
            [pscustomobject]@{ Entries = @((New-FakeChocoEntry -Id 'bat'), (New-FakeChocoEntry -Id 'fd')); NextUrl = $null }
        }.GetNewClosure()

        & $script:ScriptPath -SkipScoopUpdate -DatabasePath $script:DatabasePath -ScoopRoot $script:ScoopRoot `
            -WingetPkgsSnapshot $script:WingetSnapshot `
            -ChocoFetchPage $recordingFetch -ChocoSleep $script:ChocoSleep -ChocoDelayMinMs 0 -ChocoDelayMaxMs 1 | Out-Null

        $firstUrl = [uri]::UnescapeDataString($secondRunUrls[0])
        $firstUrl | Should -Match '\$filter=IsLatestVersion'
        $firstUrl | Should -Not -Match 'LastUpdated'
        $firstUrl | Should -Not -Match 'Published'

        $conn = New-SQLiteConnection -DataSource $script:DatabasePath
        try {
            $chocoIds = @(Invoke-SqliteQuery -SQLiteConnection $conn -Query "SELECT package_id FROM raw_packages WHERE source='choco';").package_id
            $chocoIds | Should -Contain 'bat'
            $chocoIds | Should -Contain 'fd'
        } finally {
            $conn.Close()
        }
    }

    It 'prunes a choco package no longer present in a complete walk' {
        & $script:ScriptPath -SkipScoopUpdate -DatabasePath $script:DatabasePath -ScoopRoot $script:ScoopRoot `
            -WingetPkgsSnapshot $script:WingetSnapshot `
            -ChocoFetchPage $script:ChocoFetch -ChocoSleep $script:ChocoSleep -ChocoDelayMinMs 0 -ChocoDelayMaxMs 1 | Out-Null

        $shrunkFetch = New-FakeChocoFetch -Pages @(@((New-FakeChocoEntry -Id 'bat')), @())

        & $script:ScriptPath -SkipScoopUpdate -DatabasePath $script:DatabasePath -ScoopRoot $script:ScoopRoot `
            -WingetPkgsSnapshot $script:WingetSnapshot `
            -ChocoFetchPage $shrunkFetch -ChocoSleep $script:ChocoSleep -ChocoDelayMinMs 0 -ChocoDelayMaxMs 1 | Out-Null

        $conn = New-SQLiteConnection -DataSource $script:DatabasePath
        try {
            $chocoIds = @(Invoke-SqliteQuery -SQLiteConnection $conn -Query "SELECT package_id FROM raw_packages WHERE source='choco';").package_id
            $chocoIds | Should -Be @('bat')

            $pruneLog = @(Invoke-SqliteQuery -SQLiteConnection $conn -Query "SELECT * FROM pipeline_log WHERE source='choco' AND level='review' AND message LIKE '%pruned%';")
            $pruneLog.Count | Should -Be 1
        } finally {
            $conn.Close()
        }
    }

    It 'does NOT prune when the walk is incomplete -- keeps prior rows and says why' {
        # The dangerous case: a 429 half-way through must never be read as
        # "every package we did not reach was removed upstream".
        & $script:ScriptPath -SkipScoopUpdate -DatabasePath $script:DatabasePath -ScoopRoot $script:ScoopRoot `
            -WingetPkgsSnapshot $script:WingetSnapshot `
            -ChocoFetchPage $script:ChocoFetch -ChocoSleep $script:ChocoSleep -ChocoDelayMinMs 0 -ChocoDelayMaxMs 1 | Out-Null

        $rateLimitedFetch = { param($Url) throw [System.Exception]::new('Response status code does not indicate success: 429 (Too Many Requests).') }

        & $script:ScriptPath -SkipScoopUpdate -DatabasePath $script:DatabasePath -ScoopRoot $script:ScoopRoot `
            -WingetPkgsSnapshot $script:WingetSnapshot `
            -ChocoFetchPage $rateLimitedFetch -ChocoSleep $script:ChocoSleep -ChocoDelayMinMs 0 -ChocoDelayMaxMs 1 | Out-Null

        $conn = New-SQLiteConnection -DataSource $script:DatabasePath
        try {
            # Both rows from the first (complete) walk survive the aborted one.
            $chocoIds = @(Invoke-SqliteQuery -SQLiteConnection $conn -Query "SELECT package_id FROM raw_packages WHERE source='choco' ORDER BY package_id;").package_id
            $chocoIds | Should -Be @('bat', 'fd')

            $skipLog = @(Invoke-SqliteQuery -SQLiteConnection $conn -Query "SELECT * FROM pipeline_log WHERE source='choco' AND level='review' AND message LIKE '%skipped pruning%';")
            $skipLog.Count | Should -Be 1

            $rlLog = @(Invoke-SqliteQuery -SQLiteConnection $conn -Query "SELECT * FROM pipeline_log WHERE source='choco' AND level='error' AND message LIKE '%429%';")
            $rlLog.Count | Should -BeGreaterOrEqual 1
        } finally {
            $conn.Close()
        }
    }

    It 'keeps rows already flushed when a walk dies partway through' {
        # Per-page flushing: the walk fetches one good page, then the next
        # request fails outright. The first page's rows must still be in the db.
        # Entries are built out here, and the counter is a hashtable: a
        # .GetNewClosure() scriptblock runs in its own module scope, where
        # neither New-FakeChocoEntry nor a $script: counter from this scope
        # resolves.
        $firstPage = @((New-FakeChocoEntry -Id 'bat'))
        $state = @{ Calls = 0 }
        $dyingFetch = {
            param($Url)
            $state.Calls++
            if ($state.Calls -eq 1) {
                return [pscustomobject]@{ Entries = $firstPage; NextUrl = 'https://fake/next' }
            }
            throw 'network died mid-walk'
        }.GetNewClosure()

        & $script:ScriptPath -SkipScoopUpdate -DatabasePath $script:DatabasePath -ScoopRoot $script:ScoopRoot `
            -WingetPkgsSnapshot $script:WingetSnapshot `
            -ChocoFetchPage $dyingFetch -ChocoSleep $script:ChocoSleep -ChocoDelayMinMs 0 -ChocoDelayMaxMs 1 | Out-Null

        $conn = New-SQLiteConnection -DataSource $script:DatabasePath
        try {
            $chocoIds = @(Invoke-SqliteQuery -SQLiteConnection $conn -Query "SELECT package_id FROM raw_packages WHERE source='choco';").package_id
            $chocoIds | Should -Be @('bat')
        } finally {
            $conn.Close()
        }
    }

    It 'writes a verbose run-transcript log file' {
        & $script:ScriptPath -SkipScoopUpdate -DatabasePath $script:DatabasePath -ScoopRoot $script:ScoopRoot `
            -WingetPkgsSnapshot $script:WingetSnapshot `
            -ChocoFetchPage $script:ChocoFetch -ChocoSleep $script:ChocoSleep -ChocoDelayMinMs 0 -ChocoDelayMaxMs 1 | Out-Null

        $logFiles = @(Get-ChildItem -Path (Split-Path $script:DatabasePath -Parent) -Filter 'acquire-*.log')
        $logFiles.Count | Should -Be 1
        $content = Get-Content $logFiles[0].FullName -Raw
        $content | Should -Match 'run start'
        $content | Should -Match 'choco: request ok'      # per-request trace present
        $content | Should -Match 'run end'
    }

}
