BeforeAll {
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/ConvertTo-DFPath.ps1"
    . "$PSScriptRoot/../Private/DFCatalog.ps1"
    . "$PSScriptRoot/../Private/Start-DFCatalogRefreshJob.ps1"
    . "$PSScriptRoot/../Private/DFCatalog.Crates.ps1"
    . "$PSScriptRoot/../Private/DFCatalog.Npm.ps1"
    . "$PSScriptRoot/../Private/DFCatalog.Pypi.ps1"
    . "$PSScriptRoot/../Private/DFCatalog.Choco.ps1"
    . "$PSScriptRoot/../Private/DFCatalog.PSGallery.ps1"
}

Describe 'Search-DFCatalogQueryCache engine (via crates)' {
    BeforeEach {
        $script:SavedXdgCache = $Env:XDG_CACHE_HOME
        $Env:XDG_CACHE_HOME = Join-Path $TestDrive 'cache'
        Mock Start-DFCatalogRefreshJob { }
        Mock Invoke-RestMethod {
            [pscustomobject]@{
                crates = @([pscustomobject]@{
                    name = 'ripgrep'; max_version = '14.1.1'
                    description = 'line-oriented search'; homepage = 'https://rg.example'
                    repository = 'https://github.com/x'; updated_at = '2026-06-01T00:00:00Z'
                })
            }
        }
    }
    AfterEach {
        $Env:XDG_CACHE_HOME = $script:SavedXdgCache
        Remove-Item (Join-Path $TestDrive 'cache') -Recurse -Force -ErrorAction Ignore
    }

    It 'fetches live on a cache miss and writes the query cache' {
        $r = @(Search-DFCatalogCrates -Query 'ripgrep')
        $r.Count | Should -Be 1
        $r[0].PSObject.TypeNames[0] | Should -Be 'DotForge.ToolSourceInfo'
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly
        Get-ChildItem (Join-Path $Env:XDG_CACHE_HOME 'dotforge/catalogs/crates/queries') -Filter '*.json' |
            Should -Not -BeNullOrEmpty
    }

    It 'serves a fresh cache hit without any web call or refresh job' {
        $null = Search-DFCatalogCrates -Query 'ripgrep'
        $r = @(Search-DFCatalogCrates -Query 'ripgrep')
        $r.Count | Should -Be 1
        $r[0].Name | Should -Be 'ripgrep'
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly     # only the first call
        Should -Invoke Start-DFCatalogRefreshJob -Times 0 -Exactly
    }

    It 'serves a stale cache hit and kicks a background refresh instead of blocking' {
        $null = Search-DFCatalogCrates -Query 'ripgrep'
        # Age the envelope past the TTL.
        $file = Get-ChildItem (Join-Path $Env:XDG_CACHE_HOME 'dotforge/catalogs/crates/queries') -Filter '*.json' | Select-Object -First 1
        $envelope = Get-Content $file.FullName -Raw | ConvertFrom-Json
        $envelope.timestamp = [datetime]::UtcNow.AddDays(-3).ToString('o')
        $envelope | ConvertTo-Json -Depth 6 | Set-Content $file.FullName

        $r = @(Search-DFCatalogCrates -Query 'ripgrep')
        $r.Count | Should -Be 1
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly     # no inline re-fetch
        Should -Invoke Start-DFCatalogRefreshJob -Times 1 -Exactly
    }

    It 'fetches inline under -Fresh even with a valid cache' {
        $null = Search-DFCatalogCrates -Query 'ripgrep'
        $null = Search-DFCatalogCrates -Query 'ripgrep' -Fresh
        Should -Invoke Invoke-RestMethod -Times 2 -Exactly
        Should -Invoke Start-DFCatalogRefreshJob -Times 0 -Exactly
    }

    It 'falls back to the stale cache when the live fetch fails' {
        $null = Search-DFCatalogCrates -Query 'ripgrep'
        Mock Invoke-RestMethod { throw 'network down' }
        $r = @(Search-DFCatalogCrates -Query 'ripgrep' -Fresh)
        $r.Count | Should -Be 1
        $r[0].Name | Should -Be 'ripgrep'
    }
}

Describe 'DFCatalog.Crates' {
    BeforeEach {
        $script:SavedXdgCache = $Env:XDG_CACHE_HOME
        $Env:XDG_CACHE_HOME = Join-Path $TestDrive 'cache'
    }
    AfterEach {
        $Env:XDG_CACHE_HOME = $script:SavedXdgCache
        Remove-Item (Join-Path $TestDrive 'cache') -Recurse -Force -ErrorAction Ignore
    }

    It 'sends a User-Agent header (crates.io requires one)' {
        Mock Invoke-RestMethod { [pscustomobject]@{ crates = @() } }
        $null = Search-DFCatalogCrates -Query 'ripgrep' -Fresh
        Should -Invoke Invoke-RestMethod -ParameterFilter { $Headers['User-Agent'] -match 'DotForge' }
    }

    It 'maps crate fields and match kinds' {
        Mock Invoke-RestMethod {
            [pscustomobject]@{
                crates = @(
                    [pscustomobject]@{ name = 'ripgrep'; max_version = '14.1.1'; description = 'search'; homepage = $null; repository = 'https://repo'; updated_at = '2026-06-01T00:00:00Z' },
                    [pscustomobject]@{ name = 'ripgrep-all'; max_version = '0.10.9'; description = 'rg for docs'; homepage = 'https://h'; repository = $null; updated_at = $null }
                )
            }
        }
        $r = @(Search-DFCatalogCrates -Query 'ripgrep' -Fresh)
        $r.Count | Should -Be 2
        $r[0].Source | Should -Be 'crates'
        $r[0].MatchKind | Should -Be 'exact-name'
        $r[0].LatestVersion | Should -Be '14.1.1'
        $r[0].Homepage | Should -Be 'https://repo'     # repository fallback
        $r[0].PublishedAt | Should -Not -BeNullOrEmpty
        $r[1].MatchKind | Should -Be 'keyword'
        $r[1].Homepage | Should -Be 'https://h'
    }

    It 'reads installed crates from .crates2.json' {
        $cargoHome = Join-Path $TestDrive 'cargo'
        New-Item -ItemType Directory $cargoHome -Force | Out-Null
        @{
            installs = @{
                'ripgrep 14.1.0 (registry+https://github.com/rust-lang/crates.io-index)' = @{ bins = @('rg.exe') }
                'fd-find 10.2.0 (registry+https://github.com/rust-lang/crates.io-index)' = @{ bins = @('fd.exe') }
            }
        } | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $cargoHome '.crates2.json')

        $r = @(Get-DFCatalogCratesInstalled -CargoHome $cargoHome) | Sort-Object Name
        $r.Count | Should -Be 2
        $r[0].Name | Should -Be 'fd-find'
        $r[0].InstalledVersion | Should -Be '10.2.0'
        $r[1].Name | Should -Be 'ripgrep'
    }
}

Describe 'DFCatalog.Npm' {
    BeforeEach {
        $script:SavedXdgCache = $Env:XDG_CACHE_HOME
        $Env:XDG_CACHE_HOME = Join-Path $TestDrive 'cache'
    }
    AfterEach {
        $Env:XDG_CACHE_HOME = $script:SavedXdgCache
        Remove-Item (Join-Path $TestDrive 'cache') -Recurse -Force -ErrorAction Ignore
    }

    It 'maps npm search results' {
        Mock Invoke-RestMethod {
            if ($Uri -match '/-/v1/search') {
                [pscustomobject]@{
                    objects = @([pscustomobject]@{
                        package = [pscustomobject]@{
                            name = 'prettier'; version = '3.3.0'; description = 'code formatter'
                            links = [pscustomobject]@{ homepage = 'https://prettier.io' }
                            date = '2026-05-01T00:00:00Z'
                        }
                    })
                }
            } else {
                throw [System.Net.Http.HttpRequestException]::new('404')
            }
        }
        $r = @(Search-DFCatalogNpm -Query 'prettier' -Fresh)
        $r.Count | Should -BeGreaterOrEqual 1
        $r[0].Source | Should -Be 'npm'
        $r[0].Name | Should -Be 'prettier'
        $r[0].LatestVersion | Should -Be '3.3.0'
        $r[0].Homepage | Should -Be 'https://prettier.io'
        $r[0].MatchKind | Should -Be 'exact-name'
    }

    It 'reads globally installed packages from the npm prefix' {
        $prefix = Join-Path $TestDrive 'npm-prefix'
        $mods = Join-Path $prefix 'node_modules/prettier'
        New-Item -ItemType Directory $mods -Force | Out-Null
        @{ name = 'prettier'; version = '3.2.0' } | ConvertTo-Json | Set-Content (Join-Path $mods 'package.json')

        $r = @(Get-DFCatalogNpmInstalled -NpmPrefix $prefix)
        $r.Count | Should -Be 1
        $r[0].Name | Should -Be 'prettier'
        $r[0].InstalledVersion | Should -Be '3.2.0'
    }
}

Describe 'DFCatalog.Pypi' {
    BeforeEach {
        $script:SavedXdgCache = $Env:XDG_CACHE_HOME
        $Env:XDG_CACHE_HOME = Join-Path $TestDrive 'cache'
    }
    AfterEach {
        $Env:XDG_CACHE_HOME = $script:SavedXdgCache
        Remove-Item (Join-Path $TestDrive 'cache') -Recurse -Force -ErrorAction Ignore
    }

    It 'maps the PyPI JSON API for exact names' {
        Mock Invoke-RestMethod {
            [pscustomobject]@{
                info = [pscustomobject]@{
                    name = 'httpie'; version = '3.2.2'; summary = 'CLI HTTP client'
                    home_page = 'https://httpie.io'; license = 'BSD'
                }
            }
        }
        $r = @(Search-DFCatalogPypi -Query 'httpie' -Fresh)
        $r.Count | Should -Be 1
        $r[0].Source | Should -Be 'pypi'
        $r[0].LatestVersion | Should -Be '3.2.2'
        $r[0].Description | Should -Be 'CLI HTTP client'
        $r[0].MatchKind | Should -Be 'exact-name'
    }

    It 'returns nothing for multi-word queries (no PyPI search API)' {
        Mock Invoke-RestMethod { throw 'should not be called' }
        @(Search-DFCatalogPypi -Query 'http client tool' -Fresh) | Should -BeNullOrEmpty
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
    }
}

Describe 'OData providers (choco / psgallery)' {
    BeforeAll {
        $script:ODataFixture = [xml]@'
<feed xmlns="http://www.w3.org/2005/Atom"
      xmlns:d="http://schemas.microsoft.com/ado/2007/08/dataservices"
      xmlns:m="http://schemas.microsoft.com/ado/2007/08/dataservices/metadata">
  <entry>
    <title type="text">ripgrep</title>
    <m:properties>
      <d:Version>14.1.0</d:Version>
      <d:Description>Line-oriented search tool.</d:Description>
      <d:ProjectUrl>https://github.com/BurntSushi/ripgrep</d:ProjectUrl>
      <d:Published m:type="Edm.DateTime">2026-06-01T00:00:00</d:Published>
    </m:properties>
  </entry>
</feed>
'@
    }
    BeforeEach {
        $script:SavedXdgCache = $Env:XDG_CACHE_HOME
        $Env:XDG_CACHE_HOME = Join-Path $TestDrive 'cache'
    }
    AfterEach {
        $Env:XDG_CACHE_HOME = $script:SavedXdgCache
        Remove-Item (Join-Path $TestDrive 'cache') -Recurse -Force -ErrorAction Ignore
    }

    It 'maps OData entries for choco' {
        Mock Invoke-RestMethod { $script:ODataFixture.feed.entry }
        $r = @(Search-DFCatalogChoco -Query 'ripgrep' -Fresh)
        $r.Count | Should -Be 1
        $r[0].Source | Should -Be 'choco'
        $r[0].Name | Should -Be 'ripgrep'
        $r[0].LatestVersion | Should -Be '14.1.0'
        $r[0].Homepage | Should -Be 'https://github.com/BurntSushi/ripgrep'
        $r[0].PublishedAt | Should -Not -BeNullOrEmpty
        $r[0].MatchKind | Should -Be 'exact-name'
    }

    It 'maps OData entries for psgallery' {
        Mock Invoke-RestMethod { $script:ODataFixture.feed.entry }
        $r = @(Search-DFCatalogPSGallery -Query 'ripgrep' -Fresh)
        $r.Count | Should -Be 1
        $r[0].Source | Should -Be 'psgallery'
    }

    It 'reads choco-installed packages from lib nuspecs' {
        $lib = Join-Path $TestDrive 'choco/lib/ripgrep'
        New-Item -ItemType Directory $lib -Force | Out-Null
        @'
<?xml version="1.0"?>
<package xmlns="http://schemas.microsoft.com/packaging/2015/06/nuspec.xsd">
  <metadata><id>ripgrep</id><version>14.1.0</version></metadata>
</package>
'@ | Set-Content (Join-Path $lib 'ripgrep.nuspec')

        $r = @(Get-DFCatalogChocoInstalled -ChocolateyInstall (Join-Path $TestDrive 'choco'))
        $r.Count | Should -Be 1
        $r[0].Name | Should -Be 'ripgrep'
        $r[0].InstalledVersion | Should -Be '14.1.0'
    }
}

Describe 'web provider registration' {
    It 'registers all five query-cache providers' {
        foreach ($name in 'choco', 'npm', 'pypi', 'crates', 'psgallery') {
            $script:DFCatalogProviders[$name] | Should -Not -BeNullOrEmpty -Because $name
            $script:DFCatalogProviders[$name].Kind | Should -Be 'query-cache' -Because $name
        }
    }
}
