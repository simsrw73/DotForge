BeforeAll {
    . "$PSScriptRoot/../Private/Test-DFCategoryDbSchema.ps1"
    . "$PSScriptRoot/../Private/Get-DFCategoryDb.ps1"

    function New-FixtureDbFile {
        param([string]$Path)
        @{
            schemaVersion = 1
            updated       = '2026-07-01'
            taxonomy      = @{ function = @('search', 'editor', 'file-viewing'); worksWith = @('text', 'filesystem') }
            tools         = [ordered]@{
                ripgrep = @{
                    function = @('search'); worksWith = @('text', 'filesystem'); interface = 'cli'
                    aliases = @('rg'); relatedTo = @('fd'); alternativeTo = @('grep')
                    ids = @{ scoop = 'main/ripgrep'; winget = 'BurntSushi.ripgrep.MSVC' }
                    popularity = 3
                }
                fd = @{
                    function = @('search'); worksWith = @('filesystem'); interface = 'cli'
                    ids = @{ scoop = 'fd' }   # bare name, as Tools/*.json stores it —
                    popularity = 2            # proves the bucket-stripping fallback below
                }
                bat = @{
                    function = @('file-viewing'); worksWith = @('text'); interface = 'cli'
                    alternativeTo = @('cat')
                    popularity = 2
                }
                micro = @{
                    function = @('editor'); worksWith = @('text'); interface = 'cli'
                    popularity = 1
                }
            }
        } | ConvertTo-Json -Depth 6 | Set-Content -Path $Path -Encoding UTF8
    }
}

Describe 'Get-DFCategoryDb' {
    BeforeEach {
        $script:FixturePath = Join-Path $TestDrive 'tool-categories.json'
        New-FixtureDbFile -Path $script:FixturePath
        $script:DFCategoryDb = $null
        $script:DFCategoryDbWarned = $false
    }
    AfterEach {
        $script:DFCategoryDb = $null
        $script:DFCategoryDbWarned = $false
    }

    It 'loads a valid fixture and exposes the raw taxonomy' {
        $db = Get-DFCategoryDb -Path $script:FixturePath
        $db.Raw.tools.ripgrep.function | Should -Contain 'search'
        $db.Raw.taxonomy.function | Should -Contain 'editor'
    }

    It 'builds a name index including aliases, lowercased' {
        $db = Get-DFCategoryDb -Path $script:FixturePath
        $db.NameIndex['ripgrep'] | Should -Be 'ripgrep'
        $db.NameIndex['rg'] | Should -Be 'ripgrep'
    }

    It 'builds an id index from each tool''s ids' {
        $db = Get-DFCategoryDb -Path $script:FixturePath
        $db.IdIndex['scoop:main/ripgrep'] | Should -Be 'ripgrep'
        $db.IdIndex['winget:burntsushi.ripgrep.msvc'] | Should -Be 'ripgrep'
    }

    It 'builds an inverted facet index' {
        $db = Get-DFCategoryDb -Path $script:FixturePath
        $db.FacetIndex['function:search'] | Should -Contain 'ripgrep'
        $db.FacetIndex['function:search'] | Should -Contain 'fd'
        $db.FacetIndex['worksWith:text'] | Should -Contain 'bat'
    }

    It 'caches the -Path load as a singleton until -Force' {
        # -Path always forces a fresh read itself (per spec) — singleton caching
        # is exercised through the no-arg call path, which -Path feeds via the
        # shipped-side override so this still validates real caching behavior.
        $db1 = Get-DFCategoryDb -Path $script:FixturePath
        $script:DFCategoryDb = $db1   # simulate what a no-Path call would have cached
        $db2 = Get-DFCategoryDb
        $db2 | Should -Be $db1
        $db3 = Get-DFCategoryDb -Force -Path $script:FixturePath
        $db3 | Should -Not -BeNullOrEmpty
    }

    It 'returns an empty-but-valid object when the shipped file is unreadable, and warns once' {
        Set-Content -Path $script:FixturePath -Value 'not json {{{' -Encoding UTF8
        $db = Get-DFCategoryDb -Path $script:FixturePath -WarningAction SilentlyContinue
        $db.Raw | Should -BeNullOrEmpty
        $db.NameIndex.Count | Should -Be 0
        $db.FacetIndex.Count | Should -Be 0
    }

    It 'a refreshed copy newer than shipped wins' {
        $script:SavedDataHome = $Env:XDG_DATA_HOME
        $Env:XDG_DATA_HOME = Join-Path $TestDrive 'data'
        try {
            New-Item -ItemType Directory -Path (Join-Path $Env:XDG_DATA_HOME 'dotforge') -Force | Out-Null
            $refreshedPath = Join-Path $Env:XDG_DATA_HOME 'dotforge/tool-categories.json'
            @{ schemaVersion = 1; updated = '2026-09-01'; taxonomy = @{ function = @('refreshed-value'); worksWith = @('text') }; tools = @{} } |
                ConvertTo-Json -Depth 6 | Set-Content $refreshedPath
            # Fixture ("shipped" stand-in via -Path) is dated 2026-07-01 (older).
            # NOTE: taxonomy.worksWith must be non-empty per Test-DFCategoryDbSchema
            # (Task 1) or this refreshed doc fails schema validation and falls back
            # to shipped, defeating the point of this test.
            $db = Get-DFCategoryDb -Path $script:FixturePath
            $db.Raw.taxonomy.function | Should -Contain 'refreshed-value'
        } finally { $Env:XDG_DATA_HOME = $script:SavedDataHome }
    }

    It 'a refreshed copy OLDER than shipped is ignored' {
        $script:SavedDataHome = $Env:XDG_DATA_HOME
        $Env:XDG_DATA_HOME = Join-Path $TestDrive 'data-old'
        try {
            New-Item -ItemType Directory -Path (Join-Path $Env:XDG_DATA_HOME 'dotforge') -Force | Out-Null
            $refreshedPath = Join-Path $Env:XDG_DATA_HOME 'dotforge/tool-categories.json'
            @{ schemaVersion = 1; updated = '2020-01-01'; taxonomy = @{ function = @('stale-value'); worksWith = @() }; tools = @{} } |
                ConvertTo-Json -Depth 6 | Set-Content $refreshedPath
            $db = Get-DFCategoryDb -Path $script:FixturePath   # fixture dated 2026-07-01, newer
            $db.Raw.taxonomy.function | Should -Not -Contain 'stale-value'
            $db.Raw.taxonomy.function | Should -Contain 'editor'   # the fixture's own real content
        } finally { $Env:XDG_DATA_HOME = $script:SavedDataHome }
    }

    It 'a refreshed copy with unparseable JSON falls back to shipped without throwing' {
        $script:SavedDataHome = $Env:XDG_DATA_HOME
        $Env:XDG_DATA_HOME = Join-Path $TestDrive 'data-corrupt'
        try {
            New-Item -ItemType Directory -Path (Join-Path $Env:XDG_DATA_HOME 'dotforge') -Force | Out-Null
            'not json {{{' | Set-Content (Join-Path $Env:XDG_DATA_HOME 'dotforge/tool-categories.json')
            { Get-DFCategoryDb -Path $script:FixturePath -WarningAction SilentlyContinue } | Should -Not -Throw
            $db = Get-DFCategoryDb -Path $script:FixturePath -WarningAction SilentlyContinue
            $db.Raw.taxonomy.function | Should -Contain 'editor'   # fell back to the fixture
        } finally { $Env:XDG_DATA_HOME = $script:SavedDataHome }
    }

    It 'a refreshed copy that parses but fails schema validation falls back to shipped' {
        # Distinct from the unparseable-JSON case above: this file IS valid
        # JSON with a valid, newer 'updated' date (so it gets selected as the
        # resolved path), but its tools entry uses an unknown function value
        # — a schema failure, not a parse failure.
        $script:SavedDataHome = $Env:XDG_DATA_HOME
        $Env:XDG_DATA_HOME = Join-Path $TestDrive 'data-schema-invalid'
        try {
            New-Item -ItemType Directory -Path (Join-Path $Env:XDG_DATA_HOME 'dotforge') -Force | Out-Null
            $refreshedPath = Join-Path $Env:XDG_DATA_HOME 'dotforge/tool-categories.json'
            @{
                schemaVersion = 1; updated = '2026-09-01'
                taxonomy = @{ function = @('search'); worksWith = @() }
                tools    = @{ broken = @{ function = @('not-a-real-function'); interface = 'cli' } }
            } | ConvertTo-Json -Depth 6 | Set-Content $refreshedPath

            $db = Get-DFCategoryDb -Path $script:FixturePath -WarningAction SilentlyContinue
            $db.Raw.taxonomy.function | Should -Contain 'editor'   # fell back to the fixture, not the newer-but-invalid refreshed copy
        } finally { $Env:XDG_DATA_HOME = $script:SavedDataHome }
    }
}

Describe 'Get-DFCategoryDbEntry' {
    BeforeEach { $script:Db = Get-DFCategoryDb -Path (Join-Path $TestDrive 'fixture.json') }
    BeforeAll { New-FixtureDbFile -Path (Join-Path $TestDrive 'fixture.json') }

    It 'resolves via DFTool name' {
        $info = [pscustomobject]@{ DFTool = 'ripgrep'; Name = 'irrelevant'; Sources = @() }
        (Get-DFCategoryDbEntry -Info $info -Database $script:Db).Key | Should -Be 'ripgrep'
    }

    It 'resolves via a source:packageId' {
        $src = [pscustomobject]@{ Source = 'winget'; PackageId = 'BurntSushi.ripgrep.MSVC' }
        $info = [pscustomobject]@{ DFTool = $null; Name = 'irrelevant'; Sources = @($src) }
        (Get-DFCategoryDbEntry -Info $info -Database $script:Db).Key | Should -Be 'ripgrep'
    }

    It 'resolves a bucket-qualified LIVE scoop id against a bare-name SEED id' {
        # Fixture's 'fd' entry stores ids.scoop = 'fd' (bare, matching Tools/*.json
        # convention); a live scoop hit reports the bucket-qualified 'extras/fd'.
        # A direct "scoop:extras/fd" lookup misses the index key "scoop:fd" — the
        # trailing-segment fallback must still resolve it.
        $src = [pscustomobject]@{ Source = 'scoop'; PackageId = 'extras/fd' }
        $info = [pscustomobject]@{ DFTool = $null; Name = 'irrelevant'; Sources = @($src) }
        (Get-DFCategoryDbEntry -Info $info -Database $script:Db).Key | Should -Be 'fd'
    }

    It 'resolves via plain name as a last resort' {
        $info = [pscustomobject]@{ DFTool = $null; Name = 'bat'; Sources = @() }
        (Get-DFCategoryDbEntry -Info $info -Database $script:Db).Key | Should -Be 'bat'
    }

    It 'returns $null for an unmapped tool' {
        $info = [pscustomobject]@{ DFTool = $null; Name = 'totally-unknown-tool'; Sources = @() }
        Get-DFCategoryDbEntry -Info $info -Database $script:Db | Should -BeNullOrEmpty
    }
}

Describe 'Get-DFCategoryRelatedTools' {
    BeforeAll {
        New-FixtureDbFile -Path (Join-Path $TestDrive 'fixture2.json')
        $script:Db = Get-DFCategoryDb -Path (Join-Path $TestDrive 'fixture2.json')
    }

    It 'lists curated relatedTo first' {
        (Get-DFCategoryRelatedTools -Database $script:Db -Key 'ripgrep') | Select-Object -First 1 | Should -Be 'fd'
    }

    It 'fills remaining slots with same-function tools by popularity, excluding self' {
        # 'fd' shares function 'search' with 'ripgrep'; ripgrep's own relatedTo already lists 'fd'
        # so the fill should not duplicate it, and must never include 'ripgrep' itself.
        $related = Get-DFCategoryRelatedTools -Database $script:Db -Key 'ripgrep'
        $related | Should -Not -Contain 'ripgrep'
        @($related | Where-Object { $_ -eq 'fd' }).Count | Should -Be 1
    }

    It 'caps at 6 and returns fewer when fewer are available' {
        $related = Get-DFCategoryRelatedTools -Database $script:Db -Key 'micro'
        $related.Count | Should -BeLessOrEqual 6
    }
}
