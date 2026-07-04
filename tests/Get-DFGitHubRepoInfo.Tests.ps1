BeforeAll {
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/DFCatalog.ps1"
    . "$PSScriptRoot/../Private/Start-DFCatalogRefreshJob.ps1"
    . "$PSScriptRoot/../Private/Get-DFGitHubRepoInfo.ps1"
}

Describe 'Resolve-DFGitHubRepoUrl' {
    It 'extracts owner/repo from a Details RepositoryUrl (git+ and .git stripped)' {
        $info = [pscustomobject]@{
            Details  = [ordered]@{ npm = [pscustomobject]@{ RepositoryUrl = 'git+https://github.com/left-pad/left-pad.git#readme' } }
            Homepage = ''
        }
        $r = Resolve-DFGitHubRepoUrl -Info $info
        $r.Owner | Should -Be 'left-pad'
        $r.Repo | Should -Be 'left-pad'
    }
    It 'falls back to Homepage' {
        $info = [pscustomobject]@{ Details = $null; Homepage = 'https://github.com/BurntSushi/ripgrep' }
        (Resolve-DFGitHubRepoUrl -Info $info).Repo | Should -Be 'ripgrep'
    }
    It 'returns null for non-GitHub urls' {
        $info = [pscustomobject]@{ Details = $null; Homepage = 'https://zed.dev' }
        Resolve-DFGitHubRepoUrl -Info $info | Should -BeNullOrEmpty
    }
}

Describe 'Get-DFGitHubRepoInfo' {
    BeforeEach {
        $script:SavedXdgCache = $Env:XDG_CACHE_HOME
        $Env:XDG_CACHE_HOME = Join-Path $TestDrive 'cache'
        $githubCacheDir = Join-Path $Env:XDG_CACHE_HOME 'dotforge/catalogs/github/details'
        if (Test-Path $githubCacheDir) { Remove-Item $githubCacheDir -Recurse -Force }
        $script:DFGitHubCliOk = $null
    }
    AfterEach { $Env:XDG_CACHE_HOME = $script:SavedXdgCache; $script:DFGitHubCliOk = $null }

    It 'maps repo + latest release into DotForge.RepoInfo' {
        Mock Invoke-DFGitHubApi {
            param($Path)
            if ($Path -like '*/releases/latest') {
                [pscustomobject]@{ tag_name = 'v14.1.1'; published_at = '2026-06-01T00:00:00Z' }
            } else {
                [pscustomobject]@{
                    stargazers_count = 55000; open_issues_count = 120
                    pushed_at = '2026-07-01T12:00:00Z'; archived = $false
                    default_branch = 'master'; description = 'recursively searches'
                    license = [pscustomobject]@{ spdx_id = 'MIT' }
                }
            }
        }
        $r = Get-DFGitHubRepoInfo -Owner BurntSushi -Repo ripgrep -Fresh
        $r.PSObject.TypeNames[0] | Should -Be 'DotForge.RepoInfo'
        $r.Stars | Should -Be 55000
        $r.LatestRelease | Should -Be 'v14.1.1'
        $r.License | Should -Be 'MIT'
    }

    It 'tolerates a missing latest release (404)' {
        Mock Invoke-DFGitHubApi {
            param($Path)
            if ($Path -like '*/releases/latest') { throw '404' }
            [pscustomobject]@{ stargazers_count = 1; open_issues_count = 0; pushed_at = '2026-01-01T00:00:00Z'
                archived = $true; default_branch = 'main'; description = 'x'; license = $null }
        }
        $r = Get-DFGitHubRepoInfo -Owner a -Repo b -Fresh
        $r.LatestRelease | Should -BeNullOrEmpty
        $r.Archived | Should -BeTrue
    }

    It 'returns null when the repo fetch fails' {
        Mock Invoke-DFGitHubApi { throw 'rate limited' }
        Get-DFGitHubRepoInfo -Owner a -Repo b -Fresh | Should -BeNullOrEmpty
    }

    It 'serves the second call from cache' {
        Mock Invoke-DFGitHubApi {
            param($Path)
            if ($Path -like '*/releases/latest') { throw '404' }
            [pscustomobject]@{ stargazers_count = 9; open_issues_count = 0; pushed_at = '2026-01-01T00:00:00Z'
                archived = $false; default_branch = 'main'; description = 'x'; license = $null }
        }
        $null = Get-DFGitHubRepoInfo -Owner a -Repo b
        $r = Get-DFGitHubRepoInfo -Owner a -Repo b
        $r.Stars | Should -Be 9
        Should -Invoke Invoke-DFGitHubApi -Times 2 -Exactly   # repo + release, once each
    }
}

Describe 'Invoke-DFGitHubApi transport selection' {
    AfterEach { $script:DFGitHubCliOk = $null }
    It 'uses anonymous REST when gh is unavailable' {
        $script:DFGitHubCliOk = $false
        Mock Invoke-RestMethod { [pscustomobject]@{ ok = 1 } }
        (Invoke-DFGitHubApi -Path 'repos/a/b').ok | Should -Be 1
        Should -Invoke Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.github.com/repos/a/b' }
    }
}
