BeforeDiscovery {
    # -Skip: expressions evaluate during discovery, before BeforeAll runs.
    $script:HasSqlite = Test-Path "$Env:SystemRoot\System32\winsqlite3.dll"
}

BeforeAll {
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/DFCatalog.ps1"
    . "$PSScriptRoot/../Private/Start-DFCatalogRefreshJob.ps1"
    . "$PSScriptRoot/../Private/Invoke-DFSqliteQuery.ps1"
    . "$PSScriptRoot/../Private/DFCatalog.Winget.ps1"

    $script:Fixture = Join-Path $PSScriptRoot 'fixtures/winget-index-v2.db'

    function New-FakeMsix {
        param([string]$Path)
        New-Item -ItemType Directory (Split-Path $Path) -Force | Out-Null
        if (Test-Path $Path) { Remove-Item $Path -Force }   # CreateFromDirectory cannot overwrite
        $staging = Join-Path ([System.IO.Path]::GetTempPath()) "df-msix-$(New-Guid)"
        New-Item -ItemType Directory (Join-Path $staging 'Public') -Force | Out-Null
        Copy-Item $script:Fixture (Join-Path $staging 'Public/index.db')
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::CreateFromDirectory($staging, $Path)
        Remove-Item $staging -Recurse -Force
    }
}

Describe 'DFCatalog.Winget' {
    BeforeEach {
        $script:SavedXdgCache = $Env:XDG_CACHE_HOME
        $Env:XDG_CACHE_HOME = Join-Path $TestDrive 'cache'
    }
    AfterEach {
        $Env:XDG_CACHE_HOME = $script:SavedXdgCache
        Remove-Item (Join-Path $TestDrive 'cache') -Recurse -Force -ErrorAction Ignore
    }

    Context 'index extraction' {
        It 'extracts Public/index.db from the msix and records metadata' -Skip:(-not $script:HasSqlite) {
            $msix = Join-Path $TestDrive 'winget/source.msix'
            New-FakeMsix -Path $msix
            Update-DFCatalogWingetIndex -MsixPath $msix

            $indexDb = Join-Path $Env:XDG_CACHE_HOME 'dotforge/catalogs/winget/index.db'
            Test-Path $indexDb | Should -BeTrue
            $meta = Get-Content (Join-Path $Env:XDG_CACHE_HOME 'dotforge/catalogs/winget/index.meta.json') -Raw | ConvertFrom-Json
            $meta.length | Should -Be (Get-Item $msix).Length
        }

        It 'skips re-extraction when the msix is unchanged' -Skip:(-not $script:HasSqlite) {
            $msix = Join-Path $TestDrive 'winget/source.msix'
            New-FakeMsix -Path $msix
            Update-DFCatalogWingetIndex -MsixPath $msix
            $indexDb = Join-Path $Env:XDG_CACHE_HOME 'dotforge/catalogs/winget/index.db'
            $stamp = (Get-Item $indexDb).LastWriteTimeUtc
            Start-Sleep -Milliseconds 50
            Update-DFCatalogWingetIndex -MsixPath $msix
            (Get-Item $indexDb).LastWriteTimeUtc | Should -Be $stamp
        }
    }

    Context 'Search-DFCatalogWinget (direct SQLite)' {
        It 'finds packages by exact id' -Skip:(-not $script:HasSqlite) {
            $r = @(Search-DFCatalogWinget -Query 'BurntSushi.ripgrep.MSVC' -IndexPath $script:Fixture)
            $r.Count | Should -Be 1
            $r[0].PSObject.TypeNames[0] | Should -Be 'DotForge.ToolSourceInfo'
            $r[0].Source | Should -Be 'winget'
            $r[0].PackageId | Should -Be 'BurntSushi.ripgrep.MSVC'
            $r[0].LatestVersion | Should -Be '15.1.0'
            $r[0].MatchKind | Should -Be 'exact-id'
        }

        It 'finds packages by moniker (command name)' -Skip:(-not $script:HasSqlite) {
            $r = @(Search-DFCatalogWinget -Query 'rg' -IndexPath $script:Fixture)
            $r.Count | Should -Be 1
            $r[0].PackageId | Should -Be 'BurntSushi.ripgrep.MSVC'
            $r[0].MatchKind | Should -Be 'exact-name'
        }

        It 'finds packages by keyword across id and name' -Skip:(-not $script:HasSqlite) {
            $r = @(Search-DFCatalogWinget -Query 'ripgrep' -IndexPath $script:Fixture)
            $r.Count | Should -Be 1
            $r[0].MatchKind | Should -Be 'keyword'
        }

        It 'returns nothing for no match' -Skip:(-not $script:HasSqlite) {
            @(Search-DFCatalogWinget -Query 'zzz-nonexistent' -IndexPath $script:Fixture) |
                Should -BeNullOrEmpty
        }
    }

    Context 'CLI fallback' {
        It 'parses winget.exe column output when SQLite is unavailable' {
            Mock Invoke-DFSqliteQuery { $null }
            Mock Invoke-DFCatalogWingetCli {
                @(
                    '   -',
                    '   \',
                    'Name          Id                       Version',
                    '-----------------------------------------------',
                    'RipGrep MSVC  BurntSushi.ripgrep.MSVC  15.1.0',
                    'fd            sharkdp.fd               10.2.0'
                )
            }
            $r = @(Search-DFCatalogWinget -Query 'ripgrep' -Fresh)
            $r.Count | Should -Be 2
            $r[0].Name | Should -Be 'RipGrep MSVC'
            $r[0].PackageId | Should -Be 'BurntSushi.ripgrep.MSVC'
            $r[0].LatestVersion | Should -Be '15.1.0'
            $r[1].PackageId | Should -Be 'sharkdp.fd'
        }
    }

    Context 'Get-DFCatalogWingetInstalled' {
        It 'maps the V1 installed.db join to installed items' {
            Mock Invoke-DFSqliteQuery {
                [pscustomobject]@{ pkg_id = 'BurntSushi.ripgrep.MSVC'; pkg_name = 'RipGrep MSVC'; pkg_version = '15.1.0' }
            }
            Mock Get-DFCatalogWingetInstalledDbPath { Join-Path $TestDrive 'installed.db' }
            $r = @(Get-DFCatalogWingetInstalled)
            $r.Count | Should -Be 1
            $r[0].Source | Should -Be 'winget'
            $r[0].PackageId | Should -Be 'BurntSushi.ripgrep.MSVC'
            $r[0].InstalledVersion | Should -Be '15.1.0'
        }

        It 'returns nothing when no installed.db exists' {
            Mock Get-DFCatalogWingetInstalledDbPath { $null }
            @(Get-DFCatalogWingetInstalled) | Should -BeNullOrEmpty
        }
    }

    Context 'provider registration' {
        It 'registers winget as a snapshot provider' {
            $script:DFCatalogProviders['winget'] | Should -Not -BeNullOrEmpty
            $script:DFCatalogProviders['winget'].Kind | Should -Be 'snapshot'
        }
    }
}
