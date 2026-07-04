BeforeAll {
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/DFCatalog.ps1"
    . "$PSScriptRoot/../Private/Start-DFCatalogRefreshJob.ps1"
    . "$PSScriptRoot/../Private/Get-DFGitHubRepoInfo.ps1"
    . "$PSScriptRoot/../Private/Get-DFPackageReadme.ps1"
}

Describe 'Get-DFPackageReadme' {
    BeforeEach {
        $script:SavedXdgCache = $Env:XDG_CACHE_HOME
        $Env:XDG_CACHE_HOME = Join-Path $TestDrive 'cache'
        # Clear the github-readme cache subdir to avoid stale data from earlier It blocks
        $githubReadmeCacheDir = Join-Path $Env:XDG_CACHE_HOME 'dotforge/catalogs/github-readme/details'
        if (Test-Path $githubReadmeCacheDir) {
            Remove-Item $githubReadmeCacheDir -Recurse -Force
        }
    }
    AfterEach { $Env:XDG_CACHE_HOME = $script:SavedXdgCache }

    It 'prefers the npm detail readme' {
        $info = [pscustomobject]@{
            Details  = [ordered]@{ npm = [pscustomobject]@{ RepositoryUrl = ''; Readme = "# Title`nBody" } }
            Homepage = ''
        }
        (Get-DFPackageReadme -Info $info) -join "`n" | Should -Be "# Title`nBody"
    }

    It 'falls back to the GitHub readme when npm has none' {
        Mock Invoke-DFGitHubApi { "# GH readme" } -ParameterFilter { $Accept -like '*raw*' }
        $info = [pscustomobject]@{
            Details  = $null
            Homepage = 'https://github.com/a/b'
        }
        (Get-DFPackageReadme -Info $info -Fresh) -join "`n" | Should -Be '# GH readme'
    }

    It 'falls back to the PyPI markdown description' {
        $extra = [ordered]@{ description = '# pypi desc'; description_content_type = 'text/markdown' }
        $info = [pscustomobject]@{
            Details  = [ordered]@{ pypi = [pscustomobject]@{ RepositoryUrl = ''; Readme = $null; Extra = $extra } }
            Homepage = 'https://example.org'
        }
        (Get-DFPackageReadme -Info $info) -join "`n" | Should -Be '# pypi desc'
    }

    It 'returns null when nothing resolves' {
        $info = [pscustomobject]@{ Details = $null; Homepage = 'https://example.org' }
        Get-DFPackageReadme -Info $info | Should -BeNullOrEmpty
    }

    It 'pypi fallback works on cache-rehydrated details (Extra is a PSCustomObject)' {
        # Simulate a warm-cache detail: round-trip through JSON like the cache engine does.
        $detail = [pscustomobject]@{
            RepositoryUrl = ''
            Readme        = $null
            Extra         = [ordered]@{ description = '# cached desc'; description_content_type = 'text/markdown' }
        } | ConvertTo-Json -Depth 4 | ConvertFrom-Json
        $info = [pscustomobject]@{
            Details  = [ordered]@{ pypi = $detail }
            Homepage = 'https://example.org'
        }
        (Get-DFPackageReadme -Info $info) -join "`n" | Should -Be '# cached desc'
    }
}
