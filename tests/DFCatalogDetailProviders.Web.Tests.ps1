BeforeAll {
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/DFCatalog.Npm.ps1"
    . "$PSScriptRoot/../Private/DFCatalog.Pypi.ps1"
    . "$PSScriptRoot/../Private/DFCatalog.Crates.ps1"
    . "$PSScriptRoot/../Private/DFCatalog.ps1"
    . "$PSScriptRoot/../Private/Start-DFCatalogRefreshJob.ps1"
}

Describe 'web detail providers' {
    BeforeEach {
        $script:SavedXdgCache = $Env:XDG_CACHE_HOME
        $Env:XDG_CACHE_HOME = Join-Path $TestDrive 'cache'
    }
    AfterEach { $Env:XDG_CACHE_HOME = $script:SavedXdgCache }

    It 'npm: maps the registry doc (deps, maintainers, dist-tags, readme)' {
        Mock Invoke-RestMethod {
            [pscustomobject]@{
                name = 'left-pad'
                'dist-tags' = [pscustomobject]@{ latest = '1.3.0'; next = '2.0.0-rc1' }
                versions = [pscustomobject]@{
                    '1.3.0' = [pscustomobject]@{ dependencies = [pscustomobject]@{ lodash = '^4.17.0' } }
                }
                maintainers = @([pscustomobject]@{ name = 'alice' }, [pscustomobject]@{ name = 'bob' })
                repository = [pscustomobject]@{ url = 'git+https://github.com/left-pad/left-pad.git' }
                keywords = @('string', 'pad')
                readme = '# left-pad'
            }
        }
        $d = Get-DFCatalogNpmDetail -PackageId 'left-pad' -Fresh
        $d.Dependencies | Should -Be @('lodash@^4.17.0')
        $d.Maintainers | Should -Be @('alice', 'bob')
        $d.RepositoryUrl | Should -Be 'git+https://github.com/left-pad/left-pad.git'
        $d.Tags | Should -Be @('string', 'pad')
        $d.Readme | Should -Be '# left-pad'
        $d.InstallHint | Should -Be 'npm install -g left-pad'
        $d.Extra['dist-tags'] | Should -Contain 'latest: 1.3.0'
    }

    It 'pypi: maps the JSON API doc' {
        Mock Invoke-RestMethod {
            [pscustomobject]@{
                info = [pscustomobject]@{
                    name = 'httpie'; author = 'Jakub'; requires_python = '>=3.7'
                    keywords = 'http,cli'
                    project_urls = [pscustomobject]@{ Source = 'https://github.com/httpie/cli'; Documentation = 'https://httpie.io/docs' }
                    description = 'long readme'; description_content_type = 'text/markdown'
                }
            }
        }
        $d = Get-DFCatalogPypiDetail -PackageId 'httpie' -Fresh
        $d.Publisher | Should -Be 'Jakub'
        $d.Tags | Should -Be @('http', 'cli')
        $d.RepositoryUrl | Should -Be 'https://github.com/httpie/cli'
        $d.DocsUrl | Should -Be 'https://httpie.io/docs'
        $d.InstallHint | Should -Be 'pipx install httpie'
        $d.Extra['requires_python'] | Should -Be '>=3.7'
        $d.Extra['description_content_type'] | Should -Be 'text/markdown'
    }

    It 'crates: maps the crate doc (downloads, keywords, categories)' {
        Mock Invoke-RestMethod {
            [pscustomobject]@{
                crate = [pscustomobject]@{
                    name = 'ripgrep'; downloads = 1234567; recent_downloads = 54321
                    keywords = @('grep', 'search'); categories = @('command-line-utilities')
                    repository = 'https://github.com/BurntSushi/ripgrep'
                    documentation = 'https://docs.rs/ripgrep'
                }
            }
        }
        $d = Get-DFCatalogCratesDetail -PackageId 'ripgrep' -Fresh
        $d.Downloads | Should -Be 1234567
        $d.Tags | Should -Be @('grep', 'search', 'command-line-utilities')
        $d.RepositoryUrl | Should -Be 'https://github.com/BurntSushi/ripgrep'
        $d.DocsUrl | Should -Be 'https://docs.rs/ripgrep'
        $d.InstallHint | Should -Be 'cargo install ripgrep'
        $d.Extra['recent_downloads'] | Should -Be 54321
    }

    It 'registers Detail hooks on all three providers' {
        foreach ($p in 'npm', 'pypi', 'crates') {
            $script:DFCatalogProviders[$p].Detail | Should -Not -BeNullOrEmpty
        }
    }
}
