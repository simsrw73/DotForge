BeforeAll {
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/Test-DFOutputPiped.ps1"
    . "$PSScriptRoot/../Private/Test-DFToolSchema.ps1"
    . "$PSScriptRoot/../Private/Import-DFToolDb.ps1"
    . "$PSScriptRoot/../Private/DFCatalog.ps1"
    . "$PSScriptRoot/../Private/Get-DFCatalogInstalled.ps1"
    . "$PSScriptRoot/../Private/Format-DFToolInfo.ps1"
    . "$PSScriptRoot/../Private/Start-DFCatalogRefreshJob.ps1"
    . "$PSScriptRoot/../Private/Get-DFGitHubRepoInfo.ps1"
    . "$PSScriptRoot/../Private/Get-DFPackageReadme.ps1"
    . "$PSScriptRoot/../Private/Resolve-DFCatalogQueryMerge.ps1"
    . "$PSScriptRoot/../Private/Invoke-DFPagerExe.ps1"
    . "$PSScriptRoot/../Public/DFHelpers.Pager.ps1"
    . "$PSScriptRoot/../Public/Find-DFPackage.ps1"
    . "$PSScriptRoot/../Private/Get-DFCategoryDb.ps1"
}

Describe 'Find-DFPackage' {
    BeforeEach {
        $script:SavedXdgCache = $Env:XDG_CACHE_HOME
        $Env:XDG_CACHE_HOME = Join-Path $TestDrive 'cache'
        $script:SavedPager = $Env:Pager
        $Env:Pager = $null
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
                Detail = { param($Id, $Fresh)
                    New-DFToolSourceDetail -Source 'scoop' -PackageId $Id `
                        -InstallHint "scoop install $Id" -Notes 'test note' }
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

        # Isolated, harmless default so the query-path detail-enrichment
        # block's unconditional Get-DFCategoryDb call never touches the real
        # shipped data/tool-categories.json. Tests that specifically exercise
        # category behavior override this with their own richer fixture.
        Mock Get-DFCategoryDb { [pscustomobject]@{ Raw = $null; FacetIndex = @{}; NameIndex = @{}; IdIndex = @{} } }
    }
    AfterEach {
        $Env:XDG_CACHE_HOME = $script:SavedXdgCache
        $Env:Pager = $script:SavedPager
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

    It 'orders exact matches before keyword matches' {
        # Provider emits the keyword hit FIRST — the exact match must still
        # come out on top of the merged results.
        $script:DFCatalogProviders['scoop'].Search = { param($Query, $Fresh)
            if ($Query -eq 'zed') {
                New-DFToolSourceInfo -Source 'scoop' -PackageId 'extras/zed-preview' -Name 'zed-preview' `
                    -Description 'zed editor preview channel' -LatestVersion '0.190.0' -MatchKind 'keyword'
                New-DFToolSourceInfo -Source 'scoop' -PackageId 'extras/zed' -Name 'zed' `
                    -Description 'code editor' -LatestVersion '0.189.0' -MatchKind 'exact-name'
            }
        }
        $r = @(Find-DFPackage zed)
        $r.Count | Should -Be 2
        $r[0].Name | Should -Be 'zed'
        $r[1].Name | Should -Be 'zed-preview'
    }

    It 'reports progress while searching catalogs' {
        Mock Write-Progress { }
        $null = Find-DFPackage ripgrep
        Should -Invoke Write-Progress -ParameterFilter { $Status -like '*scoop*' }
        Should -Invoke Write-Progress -ParameterFilter { $Completed }
    }

    It 'marks a PATH-only command as installed via PATH' {
        # No catalog reports it installed, but the executable is on PATH.
        Mock Get-DFCatalogInstalled { @{ Items = @(); IdentityMap = @{} } }
        Mock Get-Command { [pscustomobject]@{ Name = 'ripgrep.exe'; Version = [version]'14.1.0' } } -ParameterFilter { $Name -eq 'ripgrep' }
        $r = @(Find-DFPackage ripgrep)
        $r[0].Installed | Should -BeTrue
        $r[0].InstalledVia | Should -Be @('PATH')
    }

    It 'enriches the top exact match with Details' {
        $r = @(Find-DFPackage ripgrep)
        $r[0].Details | Should -Not -BeNullOrEmpty
        $r[0].Details['scoop'].InstallHint | Should -Be 'scoop install main/ripgrep'
    }

    It 'renders the DETAIL card interactively on an exact match even with other keyword hits' {
        Mock Test-DFOutputPiped { $false }
        $script:DFCatalogProviders['scoop'].Search = { param($Query, $Fresh)
            if ($Query -eq 'ripgrep') {
                New-DFToolSourceInfo -Source 'scoop' -PackageId 'main/ripgrep' -Name 'ripgrep' `
                    -Description 'search tool' -LatestVersion '14.1.1' -MatchKind 'exact-name'
                New-DFToolSourceInfo -Source 'scoop' -PackageId 'main/ripgrep-all' -Name 'ripgrep-all' `
                    -Description 'rga' -LatestVersion '1.0' -MatchKind 'keyword'
            }
        }
        $saved = $Env:NO_COLOR; $Env:NO_COLOR = '1'
        try {
            $out = (Find-DFPackage ripgrep) -join "`n"
            $out | Should -Match 'Install\s+scoop install main/ripgrep'
            $out | Should -Match '\+ 1 more matches — trifle ripgrep -All'
        } finally { $Env:NO_COLOR = $saved }
    }

    It '-All always renders the table, never the card' {
        Mock Test-DFOutputPiped { $false }
        $saved = $Env:NO_COLOR; $Env:NO_COLOR = '1'
        try {
            $out = (Find-DFPackage ripgrep -All) -join "`n"
            $out | Should -Match 'Name\s+'
            $out | Should -Not -Match 'Installed'
        } finally { $Env:NO_COLOR = $saved }
    }

    It 'resolves a qualified source:packageId query' {
        $r = @(Find-DFPackage scoop:main/ripgrep)
        $r.Count | Should -Be 1
        $r[0].Name | Should -Be 'ripgrep'
        $r[0].Details['scoop'] | Should -Not -BeNullOrEmpty
    }

    It 'passes the full scoped id (not the bare trailing segment) to a non-scoop qualified query' {
        $script:CapturedNpmQuery = $null
        $script:DFCatalogProviders['npm'] = @{
            Name = 'npm'; Kind = 'query-cache'
            Test = { $true }
            Search = { param($Query, $Fresh)
                $script:CapturedNpmQuery = $Query
                if ($Query -eq '@scope/tool') {
                    New-DFToolSourceInfo -Source 'npm' -PackageId '@scope/tool' -Name '@scope/tool' `
                        -LatestVersion '1.0.0' -MatchKind 'exact-id'
                }
            }
            GetInstalled = { }
            Refresh = { }
        }
        try {
            $r = @(Find-DFPackage npm:@scope/tool)
            $script:CapturedNpmQuery | Should -Be '@scope/tool'
            $r.Count | Should -Be 1
            $r[0].Sources[0].PackageId | Should -Be '@scope/tool'
        } finally { Remove-Variable -Name CapturedNpmQuery -Scope Script -ErrorAction Ignore }
    }

    It 'falls back to keyword search for an unknown qualified prefix' {
        { Find-DFPackage foo:bar } | Should -Not -Throw
    }

    It 'warns and falls back when a qualified id does not exist' {
        $w = $null
        $null = Find-DFPackage scoop:main/nope -WarningVariable w -WarningAction SilentlyContinue
        "$w" | Should -Match "No package 'main/nope' found in scoop"
    }

    It '-GitInfo attaches GitHub repo info' {
        Mock Get-DFGitHubRepoInfo { [pscustomobject]@{ PSTypeName = 'DotForge.RepoInfo'; Stars = 5 } }
        Mock Resolve-DFGitHubRepoUrl { [pscustomobject]@{ Owner = 'a'; Repo = 'b' } }
        $r = @(Find-DFPackage ripgrep -GitInfo)
        $r[0].GitHub.Stars | Should -Be 5
    }

    It '-Readme pages the readme after the card' {
        Mock Test-DFOutputPiped { $false }
        Mock Get-DFPackageReadme { @('# readme line') }
        $saved = $Env:NO_COLOR; $Env:NO_COLOR = '1'
        try {
            $out = (Find-DFPackage ripgrep -Readme) -join "`n"
            $out | Should -Match '# readme line'
        } finally { $Env:NO_COLOR = $saved }
    }

    It 'marks a failed detail fetch as null in Details' {
        $script:DFCatalogProviders['choco'].Detail = { param($Id, $Fresh) throw 'api down' }
        $r = @(Find-DFPackage ripgrep)
        $r[0].Details.Contains('choco') | Should -BeTrue
        $r[0].Details['choco'] | Should -BeNullOrEmpty
    }

    It 'attaches Category (Entry + Related) to the top exact match' {
        Mock Get-DFCategoryDb {
            [pscustomobject]@{
                Raw = [pscustomobject]@{
                    taxonomy = [pscustomobject]@{ function = @('search'); worksWith = @('text') }
                    tools    = [pscustomobject]@{
                        ripgrep = [pscustomobject]@{ function = @('search'); worksWith = @('text'); interface = 'cli'; alternativeTo = @('grep') }
                    }
                }
                FacetIndex = @{ 'function:search' = @('ripgrep') }
                NameIndex  = @{ 'ripgrep' = 'ripgrep' }
                IdIndex    = @{}
            }
        }
        $r = @(Find-DFPackage ripgrep)
        $r[0].Category.Entry.alternativeTo | Should -Contain 'grep'
    }

    It 'leaves Category $null when the tool is not in the seed db' {
        Mock Get-DFCategoryDb { [pscustomobject]@{ Raw = $null; FacetIndex = @{}; NameIndex = @{}; IdIndex = @{} } }
        $r = @(Find-DFPackage ripgrep)
        $r[0].Category | Should -BeNullOrEmpty
    }

    Context '-Category / -WorksWith facet search' {
        BeforeEach {
            $script:FakeDb = [pscustomobject]@{
                Raw = [pscustomobject]@{
                    taxonomy = [pscustomobject]@{ function = @('search', 'editor'); worksWith = @('text', 'filesystem') }
                    tools    = [pscustomobject]@{
                        ripgrep = [pscustomobject]@{
                            function = @('search'); worksWith = @('text', 'filesystem'); interface = 'cli'
                            ids = [pscustomobject]@{ scoop = 'ripgrep' }
                        }
                        micro = [pscustomobject]@{
                            function = @('editor'); worksWith = @('text'); interface = 'tui'
                        }
                    }
                }
                FacetIndex = @{
                    'function:search'   = @('ripgrep')
                    'function:editor'   = @('micro')
                    'worksWith:text'    = @('ripgrep', 'micro')
                    'worksWith:filesystem' = @('ripgrep')
                }
            }
            Mock Get-DFCategoryDb { $script:FakeDb }

            # 'micro' has no declared 'ids', so facet resolution falls back to
            # searching its bare db key — the fake scoop provider must be able
            # to answer that live, exactly as it already does for 'ripgrep'.
            $script:DFCatalogProviders['scoop'].Search = { param($Query, $Fresh)
                if ($Query -eq 'ripgrep') {
                    New-DFToolSourceInfo -Source 'scoop' -PackageId 'main/ripgrep' -Name 'ripgrep' `
                        -Description 'search tool' -LatestVersion '14.1.1' -Homepage 'https://rg.example' `
                        -License 'MIT' -MatchKind 'exact-name'
                } elseif ($Query -eq 'micro') {
                    New-DFToolSourceInfo -Source 'scoop' -PackageId 'main/micro' -Name 'micro' `
                        -Description 'terminal text editor' -LatestVersion '2.0.11' -MatchKind 'exact-name'
                }
            }
        }

        It 'resolves a -Category match through the real search-and-merge path' {
            Mock Test-DFOutputPiped { $true }
            $r = @(Find-DFPackage -Category search)
            $r.Count | Should -Be 1
            $r[0].Name | Should -Be 'ripgrep'
            $r[0].Installed | Should -BeTrue   # proves it went through live scoop search + installed overlay, not a db snapshot
        }

        It 'ORs multiple -Category values' {
            $r = @(Find-DFPackage -Category search,editor)
            @($r.Name) | Sort-Object | Should -Be @('micro', 'ripgrep')
        }

        It 'ANDs -Category and -WorksWith together' {
            $r = @(Find-DFPackage -Category search,editor -WorksWith filesystem)
            $r.Count | Should -Be 1
            $r[0].Name | Should -Be 'ripgrep'
        }

        It '-WorksWith alone ORs within the facet' {
            $r = @(Find-DFPackage -WorksWith text)
            @($r.Name) | Sort-Object | Should -Be @('micro', 'ripgrep')
        }

        It 'fails fast on an unknown facet value, naming it' {
            { Find-DFPackage -Category bogus-value -ErrorAction Stop } | Should -Throw '*bogus-value*'
        }

        It 'rejects -All combined with -Category (parameter-set level)' {
            { Find-DFPackage -Category search -All } | Should -Throw
        }

        It 'honors -Source, falling back to name search when the entry has no id in the allowed source' {
            # ripgrep's only id is scoop; restricting to -Source choco means no
            # id matches the allowed set, so it must fall back to a plain name
            # search scoped to choco (which the fake choco provider answers).
            $r = @(Find-DFPackage -Category search -Source choco)
            $r.Count | Should -Be 1
            $r[0].Sources[0].Source | Should -Be 'choco'
        }

        It 'skips a db entry whose ids resolve to nothing live (stale seed data)' {
            $script:FakeDb.Raw.tools | Add-Member -MemberType NoteProperty -Name 'ghost-tool' -Value ([pscustomobject]@{
                function = @('search'); interface = 'cli'; ids = [pscustomobject]@{ scoop = 'totally-nonexistent-package' }
            })
            $script:FakeDb.FacetIndex['function:search'] = @('ripgrep', 'ghost-tool')
            $r = @(Find-DFPackage -Category search)
            @($r.Name) | Should -Not -Contain 'ghost-tool'
        }

        It 'renders a table, never the detail card, even for a single exact-id facet match' {
            Mock Test-DFOutputPiped { $false }
            $saved = $Env:NO_COLOR; $Env:NO_COLOR = '1'
            try {
                $out = (Find-DFPackage -Category search) -join "`n"
                $out | Should -Match 'Name\s+'
                $out | Should -Not -Match 'Installed\s'
            } finally { $Env:NO_COLOR = $saved }
        }

        It 'reports a friendly message when nothing matches the facet' {
            Mock Test-DFOutputPiped { $false }
            $out = Find-DFPackage -Category editor -WorksWith filesystem
            ($out -join "`n") | Should -Match 'No packages found'
        }
    }
}
