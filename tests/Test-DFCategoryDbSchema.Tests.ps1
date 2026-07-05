BeforeAll {
    . "$PSScriptRoot/../Private/Test-DFCategoryDbSchema.ps1"
}

Describe 'Test-DFCategoryDbSchema' {
    BeforeEach {
        $script:ValidDb = [pscustomobject]@{
            schemaVersion = 1
            updated       = '2026-07-05'
            taxonomy      = [pscustomobject]@{
                function  = @('search', 'editor')
                worksWith = @('text', 'filesystem')
            }
            tools = [pscustomobject]@{
                ripgrep = [pscustomobject]@{
                    function   = @('search')
                    worksWith  = @('text', 'filesystem')
                    interface  = 'cli'
                    popularity = 3
                }
            }
        }
    }

    It 'accepts a valid document' {
        $errs = $null
        Test-DFCategoryDbSchema -Database $script:ValidDb -Errors ([ref]$errs) | Should -BeTrue
        $errs | Should -BeNullOrEmpty
    }

    It 'rejects a missing schemaVersion' {
        $script:ValidDb.PSObject.Properties.Remove('schemaVersion')
        $errs = $null
        Test-DFCategoryDbSchema -Database $script:ValidDb -Errors ([ref]$errs) | Should -BeFalse
        $errs -join ' ' | Should -Match 'schemaVersion'
    }

    It 'rejects an unknown function value' {
        $script:ValidDb.tools.ripgrep.function = @('not-a-real-function')
        $errs = $null
        Test-DFCategoryDbSchema -Database $script:ValidDb -Errors ([ref]$errs) | Should -BeFalse
        $errs -join ' ' | Should -Match 'not-a-real-function'
    }

    It 'rejects an unknown worksWith value' {
        $script:ValidDb.tools.ripgrep.worksWith = @('not-a-real-facet')
        $errs = $null
        Test-DFCategoryDbSchema -Database $script:ValidDb -Errors ([ref]$errs) | Should -BeFalse
        $errs -join ' ' | Should -Match 'not-a-real-facet'
    }

    It 'rejects a missing interface' {
        $script:ValidDb.tools.ripgrep.PSObject.Properties.Remove('interface')
        $errs = $null
        Test-DFCategoryDbSchema -Database $script:ValidDb -Errors ([ref]$errs) | Should -BeFalse
        $errs -join ' ' | Should -Match 'interface'
    }

    It 'rejects an invalid interface value' {
        $script:ValidDb.tools.ripgrep.interface = 'web'
        $errs = $null
        Test-DFCategoryDbSchema -Database $script:ValidDb -Errors ([ref]$errs) | Should -BeFalse
        $errs -join ' ' | Should -Match 'interface'
    }

    It 'rejects an out-of-range popularity' {
        $script:ValidDb.tools.ripgrep.popularity = 7
        $errs = $null
        Test-DFCategoryDbSchema -Database $script:ValidDb -Errors ([ref]$errs) | Should -BeFalse
        $errs -join ' ' | Should -Match 'popularity'
    }

    It 'rejects a tool with an empty function array' {
        $script:ValidDb.tools.ripgrep.function = @()
        $errs = $null
        Test-DFCategoryDbSchema -Database $script:ValidDb -Errors ([ref]$errs) | Should -BeFalse
        $errs -join ' ' | Should -Match 'function'
    }

    It 'accumulates multiple errors in one pass' {
        $script:ValidDb.tools.ripgrep.function = @('bogus')
        $script:ValidDb.tools.ripgrep.PSObject.Properties.Remove('interface')
        $errs = $null
        Test-DFCategoryDbSchema -Database $script:ValidDb -Errors ([ref]$errs) | Should -BeFalse
        $errs.Count | Should -BeGreaterThan 1
    }
}
