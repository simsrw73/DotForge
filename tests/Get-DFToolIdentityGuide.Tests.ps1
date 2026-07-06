BeforeAll {
    . "$PSScriptRoot/../Private/Test-DFToolIdentityGuideSchema.ps1"
    . "$PSScriptRoot/../Private/Get-DFToolIdentityGuide.ps1"

    function New-FixtureGuideFile {
        param([string]$Path, [string]$Updated = '2026-07-01')
        @{
            schemaVersion = 1
            updated       = $Updated
            tools         = [ordered]@{
                ripgrep = @{
                    repo = 'https://github.com/BurntSushi/ripgrep'
                    packages = @{ scoop = 'ripgrep'; winget = 'BurntSushi.ripgrep.MSVC' }
                    linkedVia = 'repo'
                }
                fd = @{
                    packages = @{ scoop = 'fd' }   # bare name, matching Tools/*.json convention
                    linkedVia = 'curated'
                }
            }
        } | ConvertTo-Json -Depth 6 | Set-Content -Path $Path -Encoding UTF8
    }
}

Describe 'Get-DFToolIdentityGuide' {
    BeforeEach {
        $script:FixturePath = Join-Path $TestDrive 'tool-identities.json'
        New-FixtureGuideFile -Path $script:FixturePath
        $script:DFToolIdentityGuide = $null
        $script:DFToolIdentityGuideWarned = $false
    }
    AfterEach {
        $script:DFToolIdentityGuide = $null
        $script:DFToolIdentityGuideWarned = $false
    }

    It 'loads a valid fixture' {
        $guide = Get-DFToolIdentityGuide -Path $script:FixturePath
        $guide.Raw.tools.ripgrep.repo | Should -Be 'https://github.com/BurntSushi/ripgrep'
    }

    It 'builds an id index from each tool''s packages' {
        $guide = Get-DFToolIdentityGuide -Path $script:FixturePath
        $guide.IdIndex['scoop:ripgrep'] | Should -Be 'ripgrep'
        $guide.IdIndex['winget:burntsushi.ripgrep.msvc'] | Should -Be 'ripgrep'
        $guide.IdIndex['scoop:fd'] | Should -Be 'fd'
    }

    It 'caches the -Path load as a singleton until -Force' {
        $guide1 = Get-DFToolIdentityGuide -Path $script:FixturePath
        $script:DFToolIdentityGuide = $guide1
        $guide2 = Get-DFToolIdentityGuide
        $guide2 | Should -Be $guide1
        $guide3 = Get-DFToolIdentityGuide -Force -Path $script:FixturePath
        $guide3 | Should -Not -BeNullOrEmpty
    }

    It 'returns an empty-but-valid object when the shipped file is unreadable, and warns once' {
        Set-Content -Path $script:FixturePath -Value 'not json {{{' -Encoding UTF8
        $guide = Get-DFToolIdentityGuide -Path $script:FixturePath -WarningAction SilentlyContinue
        $guide.Raw | Should -BeNullOrEmpty
        $guide.IdIndex.Count | Should -Be 0
    }

    It 'a refreshed copy newer than shipped wins' {
        $script:SavedDataHome = $Env:XDG_DATA_HOME
        $Env:XDG_DATA_HOME = Join-Path $TestDrive 'data'
        try {
            New-Item -ItemType Directory -Path (Join-Path $Env:XDG_DATA_HOME 'dotforge') -Force | Out-Null
            $refreshedPath = Join-Path $Env:XDG_DATA_HOME 'dotforge/tool-identities.json'
            @{ schemaVersion = 1; updated = '2026-09-01'; tools = @{ zed = @{ packages = @{ winget = 'Zed.Zed' }; linkedVia = 'curated' } } } |
                ConvertTo-Json -Depth 6 | Set-Content $refreshedPath
            $guide = Get-DFToolIdentityGuide -Path $script:FixturePath
            $guide.IdIndex.ContainsKey('winget:zed.zed') | Should -BeTrue
        } finally { $Env:XDG_DATA_HOME = $script:SavedDataHome }
    }

    It 'a refreshed copy OLDER than shipped is ignored' {
        $script:SavedDataHome = $Env:XDG_DATA_HOME
        $Env:XDG_DATA_HOME = Join-Path $TestDrive 'data-old'
        try {
            New-Item -ItemType Directory -Path (Join-Path $Env:XDG_DATA_HOME 'dotforge') -Force | Out-Null
            $refreshedPath = Join-Path $Env:XDG_DATA_HOME 'dotforge/tool-identities.json'
            @{ schemaVersion = 1; updated = '2020-01-01'; tools = @{ stale = @{ packages = @{ winget = 'Stale.Tool' }; linkedVia = 'curated' } } } |
                ConvertTo-Json -Depth 6 | Set-Content $refreshedPath
            $guide = Get-DFToolIdentityGuide -Path $script:FixturePath   # fixture dated 2026-07-01, newer
            $guide.IdIndex.ContainsKey('winget:stale.tool') | Should -BeFalse
            $guide.IdIndex.ContainsKey('scoop:ripgrep') | Should -BeTrue   # the fixture's own real content
        } finally { $Env:XDG_DATA_HOME = $script:SavedDataHome }
    }

    It 'a refreshed copy that fails schema validation falls back to shipped' {
        $script:SavedDataHome = $Env:XDG_DATA_HOME
        $Env:XDG_DATA_HOME = Join-Path $TestDrive 'data-invalid'
        try {
            New-Item -ItemType Directory -Path (Join-Path $Env:XDG_DATA_HOME 'dotforge') -Force | Out-Null
            $refreshedPath = Join-Path $Env:XDG_DATA_HOME 'dotforge/tool-identities.json'
            @{ schemaVersion = 1; updated = '2026-09-01'; tools = @{ broken = @{ packages = @{}; linkedVia = 'curated' } } } |
                ConvertTo-Json -Depth 6 | Set-Content $refreshedPath
            $guide = Get-DFToolIdentityGuide -Path $script:FixturePath -WarningAction SilentlyContinue
            $guide.IdIndex.ContainsKey('scoop:ripgrep') | Should -BeTrue   # fell back to the fixture
        } finally { $Env:XDG_DATA_HOME = $script:SavedDataHome }
    }
}
