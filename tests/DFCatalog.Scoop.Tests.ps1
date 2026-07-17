BeforeAll {
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/DFCatalog.ps1"
    . "$PSScriptRoot/../Private/DFCatalog.Scoop.ps1"

    function New-FakeScoopRoot {
        param([string]$Root)
        $bucket = Join-Path $Root 'buckets/main/bucket'
        New-Item -ItemType Directory -Path $bucket -Force | Out-Null

        @{
            version     = '14.1.1'
            description = 'Recursively search directories for a regex pattern'
            homepage    = 'https://github.com/BurntSushi/ripgrep'
            license     = 'MIT'
        } | ConvertTo-Json | Set-Content (Join-Path $bucket 'ripgrep.json')

        @{
            version     = '10.2.0'
            description = 'A simple, fast alternative to find'
            homepage    = 'https://github.com/sharkdp/fd'
            license     = 'MIT'
        } | ConvertTo-Json | Set-Content (Join-Path $bucket 'fd.json')

        $git = Join-Path $Root 'buckets/main/.git'
        New-Item -ItemType Directory -Path (Join-Path $git 'refs/heads') -Force | Out-Null
        Set-Content (Join-Path $git 'HEAD') 'ref: refs/heads/master'
        Set-Content (Join-Path $git 'refs/heads/master') 'aaaa1111'

        $app = Join-Path $Root 'apps/ripgrep/current'
        New-Item -ItemType Directory -Path $app -Force | Out-Null
        @{ version = '14.1.0' } | ConvertTo-Json | Set-Content (Join-Path $app 'manifest.json')
    }
}

Describe 'DFCatalog.Scoop' {
    BeforeEach {
        $script:SavedXdgCache = $Env:XDG_CACHE_HOME
        $Env:XDG_CACHE_HOME = Join-Path $TestDrive 'cache'
        $script:ScoopRoot = Join-Path $TestDrive 'scoop'
        New-FakeScoopRoot -Root $script:ScoopRoot
    }
    AfterEach {
        $Env:XDG_CACHE_HOME = $script:SavedXdgCache
        Remove-Item (Join-Path $TestDrive 'scoop'), (Join-Path $TestDrive 'cache') -Recurse -Force -ErrorAction Ignore
    }

    Context 'Update-DFCatalogScoopIndex' {
        It 'builds an index file from bucket JSONs' {
            Update-DFCatalogScoopIndex -ScoopRoot $script:ScoopRoot
            $index = Join-Path $Env:XDG_CACHE_HOME 'dotforge/catalogs/scoop/index.json'
            Test-Path $index | Should -BeTrue
            $data = (Get-Content $index -Raw | ConvertFrom-Json).results
            @($data).Count | Should -Be 2
            @($data).name | Should -Contain 'ripgrep'
            @($data).name | Should -Contain 'fd'
        }

        It 'records a fingerprint key file' {
            Update-DFCatalogScoopIndex -ScoopRoot $script:ScoopRoot
            $key = Join-Path $Env:XDG_CACHE_HOME 'dotforge/catalogs/scoop/index.key'
            (Get-Content $key -Raw).Trim() | Should -Match 'aaaa1111'
        }
    }

    Context 'Build-DFCatalogScoopIndexData -IncludeRaw' {
        It 'omits the raw manifest by default so the runtime index shape is unchanged' {
            $entry = @(Build-DFCatalogScoopIndexData -ScoopRoot $script:ScoopRoot | Where-Object name -eq 'ripgrep')[0]
            $entry.PSObject.Properties.Name | Should -Not -Contain 'raw'
        }

        It 'attaches the verbatim manifest json as raw when -IncludeRaw is set' {
            # A manifest whose real repo is only in checkver, not homepage --
            # exactly the signal Phase B needs and Phase A discarded.
            @{
                version  = '1.0'
                homepage = 'https://vanity.example/tool'
                license  = 'MIT'
                checkver = @{ github = 'https://github.com/acme/tool' }
            } | ConvertTo-Json | Set-Content (Join-Path $script:ScoopRoot 'buckets/main/bucket/tool.json')

            $entry = @(Build-DFCatalogScoopIndexData -ScoopRoot $script:ScoopRoot -IncludeRaw | Where-Object name -eq 'tool')[0]

            $entry.raw | Should -Not -BeNullOrEmpty
            ($entry.raw | ConvertFrom-Json).checkver.github | Should -Be 'https://github.com/acme/tool'
        }
    }

    Context 'Search-DFCatalogScoop' {
        It 'returns an exact-name match as DotForge.ToolSourceInfo' {
            $r = @(Search-DFCatalogScoop -Query 'ripgrep' -ScoopRoot $script:ScoopRoot)
            $r.Count | Should -Be 1
            $r[0].PSObject.TypeNames[0] | Should -Be 'DotForge.ToolSourceInfo'
            $r[0].Source | Should -Be 'scoop'
            $r[0].PackageId | Should -Be 'main/ripgrep'
            $r[0].LatestVersion | Should -Be '14.1.1'
            $r[0].Homepage | Should -Be 'https://github.com/BurntSushi/ripgrep'
            $r[0].License | Should -Be 'MIT'
            $r[0].MatchKind | Should -Be 'exact-name'
        }

        It 'matches keywords against name and description' {
            $r = @(Search-DFCatalogScoop -Query 'regex pattern' -ScoopRoot $script:ScoopRoot)
            $r.Count | Should -Be 1
            $r[0].Name | Should -Be 'ripgrep'
            $r[0].MatchKind | Should -Be 'keyword'
        }

        It 'returns nothing for no match' {
            @(Search-DFCatalogScoop -Query 'zzz-nonexistent' -ScoopRoot $script:ScoopRoot) |
                Should -BeNullOrEmpty
        }

        It 'rebuilds the index when the bucket git HEAD changes' {
            $null = Search-DFCatalogScoop -Query 'ripgrep' -ScoopRoot $script:ScoopRoot

            # New tool lands in the bucket; commit hash moves.
            @{ version = '1.0'; description = 'new tool' } | ConvertTo-Json |
                Set-Content (Join-Path $script:ScoopRoot 'buckets/main/bucket/newtool.json')
            Set-Content (Join-Path $script:ScoopRoot 'buckets/main/.git/refs/heads/master') 'bbbb2222'

            $r = @(Search-DFCatalogScoop -Query 'newtool' -ScoopRoot $script:ScoopRoot)
            $r.Count | Should -Be 1
        }

        It 'serves the cached index when the fingerprint is unchanged' {
            $null = Search-DFCatalogScoop -Query 'ripgrep' -ScoopRoot $script:ScoopRoot

            # Bucket file appears WITHOUT a commit-hash change (e.g. mid-git-operation):
            # the cached index must still be used.
            @{ version = '1.0'; description = 'sneaky' } | ConvertTo-Json |
                Set-Content (Join-Path $script:ScoopRoot 'buckets/main/bucket/sneaky.json')

            @(Search-DFCatalogScoop -Query 'sneaky' -ScoopRoot $script:ScoopRoot) |
                Should -BeNullOrEmpty
        }

        It 'works without XDG_CACHE_HOME by building in memory' {
            $Env:XDG_CACHE_HOME = $null
            $r = @(Search-DFCatalogScoop -Query 'ripgrep' -ScoopRoot $script:ScoopRoot -WarningAction SilentlyContinue)
            $r.Count | Should -Be 1
        }
    }

    Context 'Get-DFCatalogScoopInstalled' {
        It 'reads installed apps and versions from the apps dir' {
            $r = @(Get-DFCatalogScoopInstalled -ScoopRoot $script:ScoopRoot)
            $r.Count | Should -Be 1
            $r[0].Name | Should -Be 'ripgrep'
            $r[0].InstalledVersion | Should -Be '14.1.0'
            $r[0].Source | Should -Be 'scoop'
        }

        It 'returns nothing when the apps dir is missing' {
            @(Get-DFCatalogScoopInstalled -ScoopRoot (Join-Path $TestDrive 'no-such')) |
                Should -BeNullOrEmpty
        }
    }

    Context 'provider registration' {
        It 'registers scoop as a snapshot provider' {
            $script:DFCatalogProviders['scoop'] | Should -Not -BeNullOrEmpty
            $script:DFCatalogProviders['scoop'].Kind | Should -Be 'snapshot'
            $script:DFCatalogProviders['scoop'].Name | Should -Be 'scoop'
        }
    }
}

Describe 'Get-DFCatalogScoopRoot' {
    It 'prefers $Env:SCOOP when set' {
        $saved = $Env:SCOOP
        $Env:SCOOP = 'C:\custom\scoop'
        try { Get-DFCatalogScoopRoot | Should -Be 'C:\custom\scoop' }
        finally { $Env:SCOOP = $saved }
    }
}
