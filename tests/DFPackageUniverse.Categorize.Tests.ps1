BeforeAll {
    Set-StrictMode -Version Latest
    Import-Module PSSQLite
    . "$PSScriptRoot/../build/Private/DFPackageUniverse.Merge.ps1"       # ConvertFrom-DFDbNull
    . "$PSScriptRoot/../build/Private/DFPackageUniverse.Categorize.ps1"
}

Describe 'DFPackageUniverse.Categorize' {
    Context 'Resolve-DFPackageUniverseRepo' {
        It 'resolves a GitHub homepage' {
            $r = Resolve-DFPackageUniverseRepo -Homepage 'https://github.com/sharkdp/bat'
            $r.Host | Should -Be 'github.com'; $r.Owner | Should -Be 'sharkdp'; $r.Repo | Should -Be 'bat'
            $r.Url | Should -Be 'https://github.com/sharkdp/bat'
        }
        It 'resolves a GitLab homepage and strips .git' {
            (Resolve-DFPackageUniverseRepo -Homepage 'https://gitlab.com/Owner/Repo.git').Url | Should -Be 'https://gitlab.com/owner/repo'
        }
        It 'resolves a Codeberg homepage' {
            (Resolve-DFPackageUniverseRepo -Homepage 'https://codeberg.org/a/b/').Url | Should -Be 'https://codeberg.org/a/b'
        }
        It 'prefers choco ProjectSourceUrl in extra over a non-repo homepage' {
            $extra = ConvertTo-Json -Compress @{ ProjectSourceUrl = 'https://gitlab.com/x/y' }
            (Resolve-DFPackageUniverseRepo -Homepage 'https://vanity.example/tool' -Extra $extra).Url | Should -Be 'https://gitlab.com/x/y'
        }
        It 'returns null for a non-repo homepage with no repo in extra' {
            Resolve-DFPackageUniverseRepo -Homepage 'https://vanity.example/tool' | Should -BeNullOrEmpty
        }
        It 'does not throw under strict on null inputs' {
            { Resolve-DFPackageUniverseRepo -Homepage $null -Extra $null } | Should -Not -Throw
        }
        It 'returns null for a forge subdomain that is not a repo path' {
            Resolve-DFPackageUniverseRepo -Homepage 'https://docs.github.com/en/get-started' | Should -BeNullOrEmpty
        }
        It 'returns null for a gist subdomain' {
            Resolve-DFPackageUniverseRepo -Homepage 'https://gist.github.com/user/abc123' | Should -BeNullOrEmpty
        }
        It 'resolves a Bitbucket homepage' {
            (Resolve-DFPackageUniverseRepo -Homepage 'https://bitbucket.org/team/proj').Url | Should -Be 'https://bitbucket.org/team/proj'
        }
        It 'resolves a git.sr.ht homepage' {
            (Resolve-DFPackageUniverseRepo -Homepage 'https://git.sr.ht/~user/repo').Url | Should -Be 'https://git.sr.ht/~user/repo'
        }
        It 'resolves a mixed-case host' {
            (Resolve-DFPackageUniverseRepo -Homepage 'https://GitHub.com/sharkdp/bat').Url | Should -Be 'https://github.com/sharkdp/bat'
        }
        It 'recovers the repo from a scoop autoupdate blob with an embedded github release url' {
            $extra = ConvertTo-Json -Compress -Depth 8 @{ autoupdate = @{ architecture = @{ '64bit' = @{ url = 'https://github.com/acme/tool/releases/download/v$version/tool.zip' } } } }
            (Resolve-DFPackageUniverseRepo -Homepage 'https://vanity.example/tool' -Extra $extra).Url | Should -Be 'https://github.com/acme/tool'
        }
    }
}
