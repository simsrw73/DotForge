BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    function script:Get-Errs([hashtable]$Extra) {
        $t = [pscustomobject](@{ name = 't'; executable = 't.exe' } + $Extra)
        (Test-DFToolSchema -Tool $t).Errors
    }
}

# desktop: the variables a record suggests for the Windows user environment
# (docs/superpowers/specs/2026-10-26-desktop-variables-design.md).
Describe 'desktop (schema)' {
    It 'accepts variables the record defines in xdg.vars or env' {
        Get-Errs @{
            xdg     = [pscustomobject]@{ method = 'env'; vars = [pscustomobject]@{ FOO = '${XDG_CONFIG_HOME}/t' }; native = [pscustomobject]@{ FOO = @() } }
            env     = [pscustomobject]@{ BAR = 'plain' }
            desktop = @('FOO', 'BAR')
        } | Should -BeNullOrEmpty
    }
    It 'rejects a variable the record doesn''t define' {
        Get-Errs @{ env = [pscustomobject]@{ BAR = 'plain' }; desktop = @('NOPE') } | Should -Match 'desktop.*NOPE'
    }
    It 'requires a list of names' {
        Get-Errs @{ env = [pscustomobject]@{ BAR = 'plain' }; desktop = 'BAR' } | Should -Match 'desktop must be a list'
        Get-Errs @{ env = [pscustomobject]@{ BAR = 'plain' }; desktop = @(1) } | Should -Match 'desktop must be a list'
    }
    It 'normalizes to an empty list when absent' {
        Set-StrictMode -Version Latest
        $bare = ConvertTo-DFToolRecord ([pscustomobject]@{ name = 'b'; executable = 'b.exe' })
        @($bare.desktop).Count | Should -Be 0
        $with = ConvertTo-DFToolRecord ([pscustomobject]@{ name = 'w'; executable = 'w.exe'; env = [pscustomobject]@{ BAR = 'x' }; desktop = @('BAR') })
        @($with.desktop) | Should -Be @('BAR')
    }
}
