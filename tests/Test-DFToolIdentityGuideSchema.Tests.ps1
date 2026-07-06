BeforeAll {
    . "$PSScriptRoot/../Private/Test-DFToolIdentityGuideSchema.ps1"
}

Describe 'Test-DFToolIdentityGuideSchema' {
    BeforeEach {
        $script:ValidDb = [pscustomobject]@{
            schemaVersion = 1
            updated       = '2026-07-06'
            tools         = [pscustomobject]@{
                ripgrep = [pscustomobject]@{
                    repo      = 'https://github.com/BurntSushi/ripgrep'
                    packages  = [pscustomobject]@{ scoop = 'ripgrep'; winget = 'BurntSushi.ripgrep.MSVC' }
                    linkedVia = 'repo'
                }
                zed = [pscustomobject]@{
                    packages  = [pscustomobject]@{ winget = 'Zed.Zed'; scoop = 'extras/zed' }
                    linkedVia = 'curated'
                }
            }
        }
    }

    It 'accepts a valid document' {
        $errs = $null
        Test-DFToolIdentityGuideSchema -Database $script:ValidDb -Errors ([ref]$errs) | Should -BeTrue
        $errs | Should -BeNullOrEmpty
    }

    It 'rejects a missing schemaVersion' {
        $script:ValidDb.PSObject.Properties.Remove('schemaVersion')
        $errs = $null
        Test-DFToolIdentityGuideSchema -Database $script:ValidDb -Errors ([ref]$errs) | Should -BeFalse
        $errs -join ' ' | Should -Match 'schemaVersion'
    }

    It 'rejects a tool with an empty packages object' {
        $script:ValidDb.tools.zed.packages = [pscustomobject]@{}
        $errs = $null
        Test-DFToolIdentityGuideSchema -Database $script:ValidDb -Errors ([ref]$errs) | Should -BeFalse
        $errs -join ' ' | Should -Match 'packages'
    }

    It 'rejects a missing linkedVia' {
        $script:ValidDb.tools.zed.PSObject.Properties.Remove('linkedVia')
        $errs = $null
        Test-DFToolIdentityGuideSchema -Database $script:ValidDb -Errors ([ref]$errs) | Should -BeFalse
        $errs -join ' ' | Should -Match 'linkedVia'
    }

    It 'rejects an invalid linkedVia value' {
        $script:ValidDb.tools.zed.linkedVia = 'guessed'
        $errs = $null
        Test-DFToolIdentityGuideSchema -Database $script:ValidDb -Errors ([ref]$errs) | Should -BeFalse
        $errs -join ' ' | Should -Match 'linkedVia'
    }

    It 'rejects an empty-string repo when present' {
        $script:ValidDb.tools.ripgrep.repo = ''
        $errs = $null
        Test-DFToolIdentityGuideSchema -Database $script:ValidDb -Errors ([ref]$errs) | Should -BeFalse
        $errs -join ' ' | Should -Match 'repo'
    }

    It 'accepts a tool entry with no repo field at all' {
        $script:ValidDb.tools.zed.PSObject.Properties.Remove('repo')
        $errs = $null
        Test-DFToolIdentityGuideSchema -Database $script:ValidDb -Errors ([ref]$errs) | Should -BeTrue
    }

    It 'rejects a (source, packageId) pair claimed by two different tool keys' {
        $script:ValidDb.tools.zed.packages = [pscustomobject]@{ scoop = 'ripgrep' }   # collides with ripgrep's scoop:ripgrep
        $errs = $null
        Test-DFToolIdentityGuideSchema -Database $script:ValidDb -Errors ([ref]$errs) | Should -BeFalse
        $errs -join ' ' | Should -Match 'scoop:ripgrep'
    }

    It 'accumulates multiple errors in one pass' {
        $script:ValidDb.tools.zed.PSObject.Properties.Remove('linkedVia')
        $script:ValidDb.tools.zed.packages = [pscustomobject]@{}
        $errs = $null
        Test-DFToolIdentityGuideSchema -Database $script:ValidDb -Errors ([ref]$errs) | Should -BeFalse
        $errs.Count | Should -BeGreaterThan 1
    }
}
