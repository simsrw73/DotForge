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

# desktopPath: folders desktop apps need on the Windows user PATH
# (docs/superpowers/specs/2026-11-03-desktop-path-design.md).
Describe 'desktopPath (schema)' {
    It 'accepts a list of { path, commands }' {
        Get-Errs @{ desktopPath = @([pscustomobject]@{ path = '${XDG_DATA_HOME}/t/bin'; commands = @('t') }) } | Should -BeNullOrEmpty
        Get-Errs @{ desktopPath = @([pscustomobject]@{ path = '${XDG_DATA_HOME}/t/bin' }) } | Should -BeNullOrEmpty
    }
    It 'rejects a non-list, a missing path or non-string commands' {
        Get-Errs @{ desktopPath = 'x' } | Should -Match 'desktopPath must be a list of \{ path, commands \} objects'
        Get-Errs @{ desktopPath = @([pscustomobject]@{ commands = @('t') }) } | Should -Match 'desktopPath must be a list of \{ path, commands \} objects'
        Get-Errs @{ desktopPath = @([pscustomobject]@{ path = 'p'; commands = @(1) }) } | Should -Match 'desktopPath must be a list of \{ path, commands \} objects'
    }
    It 'desktop can''t name Path' {
        Get-Errs @{ env = [pscustomobject]@{ Path = 'x' }; desktop = @('PATH') } | Should -Match "desktop can't name Path; use desktopPath"
    }
    It 'normalizes to an empty list, and commands to an empty list' {
        Set-StrictMode -Version Latest
        $bare = ConvertTo-DFToolRecord ([pscustomobject]@{ name = 'b'; executable = 'b.exe' })
        @($bare.desktopPath).Count | Should -Be 0
        $rec = ConvertTo-DFToolRecord ([pscustomobject]@{ name = 'w'; executable = 'w.exe'; desktopPath = @([pscustomobject]@{ path = 'p' }) })
        $rec.desktopPath[0].commands.Count | Should -Be 0
        $rec.desktopPath[0].path | Should -Be 'p'
    }
    It 'gives no typo warning for desktopPath' {
        $tool = [pscustomobject]@{ name = 't'; executable = 't.exe'; desktopPath = @([pscustomobject]@{ path = 'p' }) }
        $warnings = @(Test-DFToolSchema -Tool $tool).Warnings
        ($warnings -join "`n") | Should -Not -Match 'desktopPath'
    }
}
