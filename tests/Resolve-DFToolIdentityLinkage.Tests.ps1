BeforeAll {
    # Resolve-DFToolIdentityCandidateRepo must be a real defined command before
    # `Mock` can intercept it below — Pester cannot mock a command that has
    # never existed in any scope.
    . "$PSScriptRoot/../Private/Resolve-DFToolIdentityCandidateRepo.ps1"
    . "$PSScriptRoot/../Private/Resolve-DFToolIdentityLinkage.ps1"
}

Describe 'Resolve-DFToolIdentityLinkage' {
    It 'links via repo when two or more candidates resolve to the same repo' {
        Mock Resolve-DFToolIdentityCandidateRepo {
            param($Source, $PackageId, [switch]$Fresh)
            [pscustomobject]@{ Repo = 'burntsushi/ripgrep'; Homepage = $null }
        }
        $packages = [pscustomobject]@{ scoop = 'ripgrep'; winget = 'BurntSushi.ripgrep.MSVC' }
        $result = Resolve-DFToolIdentityLinkage -ToolName ripgrep -Packages $packages
        $result.LinkedVia | Should -Be 'repo'
        $result.Repo | Should -Be 'https://github.com/burntsushi/ripgrep'
    }

    It 'does not claim the repo tier when only one candidate resolves a repo' {
        Mock Resolve-DFToolIdentityCandidateRepo {
            param($Source, $PackageId, [switch]$Fresh)
            if ($Source -eq 'scoop') { [pscustomobject]@{ Repo = 'burntsushi/ripgrep'; Homepage = $null } }
            else { [pscustomobject]@{ Repo = $null; Homepage = $null } }
        }
        $packages = [pscustomobject]@{ scoop = 'ripgrep'; winget = 'BurntSushi.ripgrep.MSVC' }
        $result = Resolve-DFToolIdentityLinkage -ToolName ripgrep -Packages $packages
        $result.LinkedVia | Should -Be 'curated'
    }

    It 'does not claim the repo tier when candidates disagree' {
        Mock Resolve-DFToolIdentityCandidateRepo {
            param($Source, $PackageId, [switch]$Fresh)
            if ($Source -eq 'scoop') { [pscustomobject]@{ Repo = 'owner-a/tool'; Homepage = $null } }
            else { [pscustomobject]@{ Repo = 'owner-b/tool'; Homepage = $null } }
        }
        $packages = [pscustomobject]@{ scoop = 'tool'; winget = 'Owner.Tool' }
        $result = Resolve-DFToolIdentityLinkage -ToolName tool -Packages $packages
        $result.LinkedVia | Should -Be 'curated'
    }

    It 'falls back to the homepage tier when no repo corroborates but homepages agree' {
        Mock Resolve-DFToolIdentityCandidateRepo {
            param($Source, $PackageId, [switch]$Fresh)
            [pscustomobject]@{ Repo = $null; Homepage = 'zed.dev' }
        }
        $packages = [pscustomobject]@{ scoop = 'extras/zed'; winget = 'Zed.Zed' }
        $result = Resolve-DFToolIdentityLinkage -ToolName zed -Packages $packages
        $result.LinkedVia | Should -Be 'homepage'
        $result.Repo | Should -BeNullOrEmpty
    }

    It 'defaults to curated when nothing automated corroborates' {
        Mock Resolve-DFToolIdentityCandidateRepo {
            param($Source, $PackageId, [switch]$Fresh)
            [pscustomobject]@{ Repo = $null; Homepage = $null }
        }
        $packages = [pscustomobject]@{ scoop = 'mystery'; winget = 'Some.Mystery' }
        $result = Resolve-DFToolIdentityLinkage -ToolName mystery -Packages $packages
        $result.LinkedVia | Should -Be 'curated'
        $result.Repo | Should -BeNullOrEmpty
    }

    It 'skips a null or empty package value without calling the resolver for it' {
        Mock Resolve-DFToolIdentityCandidateRepo {
            param($Source, $PackageId, [switch]$Fresh)
            [pscustomobject]@{ Repo = 'a/b'; Homepage = $null }
        }
        $packages = [pscustomobject]@{ scoop = 'thing'; winget = $null; choco = '' }
        $null = Resolve-DFToolIdentityLinkage -ToolName thing -Packages $packages
        Should -Invoke Resolve-DFToolIdentityCandidateRepo -Times 1 -Exactly
    }
}
