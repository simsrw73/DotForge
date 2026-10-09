BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
}

Describe 'Remove-DFTestGlobal' {
    AfterEach {
        Remove-Item function:dftest_rg -ErrorAction Ignore
        Remove-Alias dftest_ra -Scope Global -Force -ErrorAction Ignore
    }

    It 'removes a global function and alias' {
        function global:dftest_rg { }
        Set-Alias -Name dftest_ra -Value Get-Date -Scope Global
        Remove-DFTestGlobal -Function dftest_rg -Alias dftest_ra
        Test-Path function:global:dftest_rg | Should -BeFalse
        Get-Alias -Name dftest_ra -Scope Global -ErrorAction Ignore | Should -BeNullOrEmpty -Because 'Test-Path alias:global:<n> is always false, so it cannot be the check'
    }

    It 'leaves a same-named function in the caller''s scope alone' {
        function global:dftest_rg { 'global' }
        function dftest_rg { 'local' }
        Remove-DFTestGlobal -Function dftest_rg
        Test-Path function:global:dftest_rg | Should -BeFalse
        dftest_rg | Should -Be 'local'
    }

    It 'ignores names that are not defined' {
        { Remove-DFTestGlobal -Function dftest_none -Alias dftest_none } | Should -Not -Throw
    }
}

Describe 'Test-file cleanup' {
    It 'never removes a global function or alias with a scope-qualified Remove-Item path' {
        # The provider ignores a global: qualifier, so such a removal does nothing and
        # the stub leaks into every later test file (delta's git tests saw an empty git).
        $hits = Get-ChildItem $PSScriptRoot -Filter '*.Tests.ps1' |
            Select-String -Pattern 'Remove-Item\b.*\b(function|alias):(global|script):' |
            ForEach-Object { "$($_.Filename):$($_.LineNumber)" }
        $hits | Should -BeNullOrEmpty -Because 'use Remove-DFTestGlobal (tests/TestSupport.ps1)'
    }
}

Describe 'Set-DFTestXdg / Restore-DFTestXdg' {
    BeforeAll {
        $script:Kinds = 'CONFIG', 'CACHE', 'DATA', 'STATE'
        function script:Get-XdgSnapshot {
            ($script:Kinds | ForEach-Object { [Environment]::GetEnvironmentVariable("XDG_$($_)_HOME") }) -join '|'
        }
    }

    It 'points all four homes under $TestDrive and restores the originals' {
        $before = Get-XdgSnapshot
        Set-DFTestXdg
        foreach ($k in $script:Kinds) {
            [Environment]::GetEnvironmentVariable("XDG_${k}_HOME") | Should -BeLike "$TestDrive*"
        }
        Restore-DFTestXdg
        Get-XdgSnapshot | Should -Be $before
    }

    It 'restores each level when nested (outer BeforeAll, inner BeforeEach)' {
        $before = Get-XdgSnapshot
        Set-DFTestXdg -Root (Join-Path $TestDrive 'outer')
        Set-DFTestXdg -Root (Join-Path $TestDrive 'inner')
        Restore-DFTestXdg
        $Env:XDG_CONFIG_HOME | Should -Be (Join-Path $TestDrive 'outer' 'config')
        Restore-DFTestXdg
        Get-XdgSnapshot | Should -Be $before
    }

    It 'throws on a Restore with no matching Set, instead of silently leaking' {
        { Restore-DFTestXdg } | Should -Throw '*without a matching Set-DFTestXdg*'
    }
}
