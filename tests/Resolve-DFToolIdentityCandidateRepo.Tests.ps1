BeforeAll {
    . "$PSScriptRoot/../Private/DFCatalog.ps1"
    . "$PSScriptRoot/../Private/Get-DFGitHubRepoInfo.ps1"
    . "$PSScriptRoot/../Private/Resolve-DFToolIdentityCandidateRepo.ps1"
}

Describe 'ConvertTo-DFNormalizedHomepage' {
    It 'strips scheme, www, and trailing slash, and lowercases' {
        ConvertTo-DFNormalizedHomepage -Url 'https://www.Zed.dev/' | Should -Be 'zed.dev'
    }

    It 'normalizes differently-formatted urls for the same site identically' {
        (ConvertTo-DFNormalizedHomepage -Url 'http://zed.dev') |
            Should -Be (ConvertTo-DFNormalizedHomepage -Url 'https://www.zed.dev/')
    }

    It 'returns an empty string for null or empty input, without throwing' {
        ConvertTo-DFNormalizedHomepage -Url $null | Should -Be ''
        ConvertTo-DFNormalizedHomepage -Url '' | Should -Be ''
    }
}

Describe 'Resolve-DFToolIdentityCandidateRepo' {
    AfterEach { $script:DFCatalogProviders = $null }

    It 'resolves via detail-level RepositoryUrl when the repo is on GitHub' {
        Mock Get-DFCatalogDetail {
            New-DFToolSourceDetail -Source scoop -PackageId ripgrep -RepositoryUrl 'https://github.com/BurntSushi/ripgrep'
        }
        $result = Resolve-DFToolIdentityCandidateRepo -Source scoop -PackageId ripgrep
        $result.Repo | Should -Be 'burntsushi/ripgrep'
        $result.Homepage | Should -BeNullOrEmpty
    }

    It 'falls back to a live search''s Homepage when detail has no repo' {
        Mock Get-DFCatalogDetail { $null }
        $script:DFCatalogProviders = @{
            winget = @{
                Search = { param($Query, $Fresh)
                    New-DFToolSourceInfo -Source winget -PackageId 'Zed.Zed' -Name 'Zed' `
                        -Homepage 'https://github.com/zed-industries/zed' -MatchKind exact-id
                }
            }
        }
        $result = Resolve-DFToolIdentityCandidateRepo -Source winget -PackageId 'Zed.Zed'
        $result.Repo | Should -Be 'zed-industries/zed'
    }

    It 'falls back to the normalized homepage when neither detail nor search homepage is GitHub' {
        Mock Get-DFCatalogDetail { $null }
        $script:DFCatalogProviders = @{
            winget = @{
                Search = { param($Query, $Fresh)
                    New-DFToolSourceInfo -Source winget -PackageId 'Zed.Zed' -Name 'Zed' `
                        -Homepage 'https://zed.dev/' -MatchKind exact-id
                }
            }
        }
        $result = Resolve-DFToolIdentityCandidateRepo -Source winget -PackageId 'Zed.Zed'
        $result.Repo | Should -BeNullOrEmpty
        $result.Homepage | Should -Be 'zed.dev'
    }

    It 'never throws when Get-DFCatalogDetail throws' {
        Mock Get-DFCatalogDetail { throw 'network down' }
        $script:DFCatalogProviders = @{ scoop = @{ Search = { param($Query, $Fresh) } } }
        { Resolve-DFToolIdentityCandidateRepo -Source scoop -PackageId ripgrep } | Should -Not -Throw
    }

    It 'never throws when the provider Search throws, returning null fields' {
        Mock Get-DFCatalogDetail { $null }
        $script:DFCatalogProviders = @{ scoop = @{ Search = { param($Query, $Fresh) throw 'boom' } } }
        $result = Resolve-DFToolIdentityCandidateRepo -Source scoop -PackageId ripgrep
        $result.Repo | Should -BeNullOrEmpty
        $result.Homepage | Should -BeNullOrEmpty
    }

    It 'returns null fields (no throw) when no provider is registered for the source' {
        Mock Get-DFCatalogDetail { $null }
        $script:DFCatalogProviders = @{}
        $result = Resolve-DFToolIdentityCandidateRepo -Source scoop -PackageId ripgrep
        $result.Repo | Should -BeNullOrEmpty
        $result.Homepage | Should -BeNullOrEmpty
    }

    It 'only invokes Search when detail-level resolution already succeeded is false' {
        Mock Get-DFCatalogDetail {
            New-DFToolSourceDetail -Source scoop -PackageId ripgrep -RepositoryUrl 'https://github.com/BurntSushi/ripgrep'
        }
        $searchCalled = $false
        $script:DFCatalogProviders = @{ scoop = @{ Search = { param($Query, $Fresh) $script:searchCalled = $true } } }
        $null = Resolve-DFToolIdentityCandidateRepo -Source scoop -PackageId ripgrep
        $searchCalled | Should -BeFalse
    }
}
