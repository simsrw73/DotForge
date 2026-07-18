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
    }
}
