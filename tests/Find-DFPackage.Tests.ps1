BeforeAll {
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/Test-DFOutputPiped.ps1"
    . "$PSScriptRoot/../Private/Test-DFToolSchema.ps1"
    . "$PSScriptRoot/../Private/Import-DFToolDb.ps1"
    . "$PSScriptRoot/../Private/DFCatalog.ps1"
    . "$PSScriptRoot/../Private/Get-DFCatalogInstalled.ps1"
    . "$PSScriptRoot/../Private/Format-DFToolInfo.ps1"
    . "$PSScriptRoot/../Public/Find-DFPackage.ps1"
}

Describe 'Find-DFPackage' {
    BeforeEach {
        $script:SavedXdgCache = $Env:XDG_CACHE_HOME
        $Env:XDG_CACHE_HOME = Join-Path $TestDrive 'cache'
        $script:SavedProviders = $script:DFCatalogProviders

        # Isolated fake providers — no disk, no network.
        $script:DFCatalogProviders = @{
            scoop = @{
                Name = 'scoop'; Kind = 'snapshot'
                Test = { $true }
                Search = { param($Query, $Fresh)
                    if ($Query -eq 'ripgrep') {
                        New-DFToolSourceInfo -Source 'scoop' -PackageId 'main/ripgrep' -Name 'ripgrep' `
                            -Description 'search tool' -LatestVersion '14.1.1' -Homepage 'https://rg.example' `
                            -License 'MIT' -MatchKind 'exact-name'
                    }
                }
                GetInstalled = {
                    [pscustomobject]@{ Source = 'scoop'; Name = 'ripgrep'; PackageId = 'ripgrep'; InstalledVersion = '14.1.0' }
                }
                Refresh = { }
            }
            choco = @{
                Name = 'choco'; Kind = 'query-cache'
                Test = { $true }
                Search = { param($Query, $Fresh)
                    if ($Query -eq 'ripgrep') {
                        New-DFToolSourceInfo -Source 'choco' -PackageId 'ripgrep' -Name 'ripgrep' `
                            -LatestVersion '14.1.0' -MatchKind 'exact-name'
                    }
                }
                GetInstalled = { }
                Refresh = { }
            }
        }
        $script:DFCatalogAvailability = @{}
        Mock Test-DFOutputPiped { $true }   # default: object output
    }
    AfterEach {
        $Env:XDG_CACHE_HOME = $script:SavedXdgCache
        $script:DFCatalogProviders = $script:SavedProviders
        $script:DFCatalogAvailability = @{}
    }

    It 'merges hits from multiple catalogs into one DotForge.ToolInfo' {
        $r = @(Find-DFPackage ripgrep)
        $r.Count | Should -Be 1
        $r[0].PSObject.TypeNames[0] | Should -Be 'DotForge.ToolInfo'
        $r[0].Name | Should -Be 'ripgrep'
        $r[0].Sources.Count | Should -Be 2
        $r[0].Latest['scoop'] | Should -Be '14.1.1'
        $r[0].Latest['choco'] | Should -Be '14.1.0'
    }

    It 'marks installed state from the owning catalog' {
        $r = @(Find-DFPackage ripgrep)
        $r[0].Installed | Should -BeTrue
        $r[0].InstalledVia | Should -Be @('scoop')
        $r[0].InstalledVersion | Should -Be '14.1.0'
        ($r[0].Sources | Where-Object Source -eq 'scoop').Installed | Should -BeTrue
    }

    It 'fills description and homepage from the first source that has them' {
        $r = @(Find-DFPackage ripgrep)
        $r[0].Description | Should -Be 'search tool'
        $r[0].Homepage | Should -Be 'https://rg.example'
        $r[0].License | Should -Be 'MIT'
    }

    It 'accepts multi-word queries via remaining arguments' {
        { Find-DFPackage static site generator } | Should -Not -Throw
    }

    It 'filters providers with -Source' {
        $r = @(Find-DFPackage ripgrep -Source choco)
        $r[0].Sources.Count | Should -Be 1
        $r[0].Sources[0].Source | Should -Be 'choco'
    }

    It 'records the query in seen-queries' {
        $null = Find-DFPackage ripgrep
        Test-Path (Join-Path $Env:XDG_CACHE_HOME 'dotforge/catalogs/seen-queries.json') | Should -BeTrue
    }

    It 'returns raw objects when piped even without -AsObject' {
        $r = Find-DFPackage ripgrep | ForEach-Object { $_ }
        $r.PSObject.TypeNames[0] | Should -Be 'DotForge.ToolInfo'
    }

    It 'renders an info card for a confident single match when interactive' {
        Mock Test-DFOutputPiped { $false }
        $saved = $Env:NO_COLOR; $Env:NO_COLOR = '1'
        try {
            $out = Find-DFPackage ripgrep
            ($out -join "`n") | Should -Match 'Installed'
            ($out -join "`n") | Should -Match 'main/ripgrep'
            $out | Should -BeOfType [string]
        } finally { $Env:NO_COLOR = $saved }
    }

    It 'honors -AsObject even when interactive' {
        Mock Test-DFOutputPiped { $false }
        $r = @(Find-DFPackage ripgrep -AsObject)
        $r[0].PSObject.TypeNames[0] | Should -Be 'DotForge.ToolInfo'
    }

    It 'reports when nothing matches' {
        Mock Test-DFOutputPiped { $false }
        $out = Find-DFPackage zzz-nonexistent
        ($out -join "`n") | Should -Match 'No packages found'
    }

    It 'is aliased to trifle' {
        Get-Alias trifle -ErrorAction Ignore | Should -Not -BeNullOrEmpty
    }

    It 'unifies differently-named packages via the Tools/*.json identity map' {
        $script:DFCatalogProviders['winget'] = @{
            Name = 'winget'; Kind = 'snapshot'; Test = { $true }
            Search = { param($Query, $Fresh)
                if ($Query -eq 'ripgrep') {
                    New-DFToolSourceInfo -Source 'winget' -PackageId 'BurntSushi.ripgrep.MSVC' `
                        -Name 'BurntSushi.ripgrep.MSVC' -LatestVersion '14.1.1' -MatchKind 'exact-name'
                }
            }
            GetInstalled = { }
            Refresh = { }
        }
        Mock Get-DFCatalogInstalled {
            @{
                Items       = @([pscustomobject]@{ Source = 'scoop'; Name = 'ripgrep'; PackageId = 'ripgrep'; InstalledVersion = '14.1.0' })
                IdentityMap = @{
                    'scoop:main/ripgrep'                = 'ripgrep'
                    'scoop:ripgrep'                     = 'ripgrep'
                    'winget:burntsushi.ripgrep.msvc'    = 'ripgrep'
                    'choco:ripgrep'                     = 'ripgrep'
                }
            }
        }
        $r = @(Find-DFPackage ripgrep)
        $r.Count | Should -Be 1
        $r[0].Name | Should -Be 'ripgrep'
        $r[0].DFTool | Should -Be 'ripgrep'
        $r[0].Sources.Source | Should -Contain 'winget'
        $r[0].Sources.Source | Should -Contain 'scoop'
    }

    It 'merges name-matched hits into the identity-mapped group (no duplicate rows)' {
        # scoop is identity-mapped to DF tool 'ripgrep'; choco has no identity
        # entry but the same package name — they must land in ONE merged row.
        Mock Get-DFCatalogInstalled {
            @{
                Items       = @()
                IdentityMap = @{ 'scoop:main/ripgrep' = 'ripgrep'; 'scoop:ripgrep' = 'ripgrep' }
            }
        }
        $r = @(Find-DFPackage ripgrep)
        $r.Count | Should -Be 1
        $r[0].DFTool | Should -Be 'ripgrep'
        $r[0].Sources.Source | Should -Contain 'scoop'
        $r[0].Sources.Source | Should -Contain 'choco'
    }

    It 'marks a PATH-only command as installed via PATH' {
        # No catalog reports it installed, but the executable is on PATH.
        Mock Get-DFCatalogInstalled { @{ Items = @(); IdentityMap = @{} } }
        Mock Get-Command { [pscustomobject]@{ Name = 'ripgrep.exe'; Version = [version]'14.1.0' } } -ParameterFilter { $Name -eq 'ripgrep' }
        $r = @(Find-DFPackage ripgrep)
        $r[0].Installed | Should -BeTrue
        $r[0].InstalledVia | Should -Be @('PATH')
    }
}
