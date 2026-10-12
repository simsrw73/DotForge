BeforeAll { . "$PSScriptRoot/../Private/Set-DFEnv.ps1" }

Describe 'Set-DFEnv' {
    BeforeEach {
        $global:DFEnvState = $null
        $script:Saved = $Env:DF_TEST_PAGER
        Remove-Item Env:DF_TEST_PAGER -ErrorAction Ignore
        $script:Common = @{ Name = 'DF_TEST_PAGER'; Tool = 'moar' }
        $script:Defaults = "`$DFConfig.Defaults.pager is 'moar'; using moar"
    }
    AfterEach {
        Remove-Variable DFEnvState -Scope Global -ErrorAction Ignore
        if ($null -eq $script:Saved) { Remove-Item Env:DF_TEST_PAGER -ErrorAction Ignore } else { $Env:DF_TEST_PAGER = $script:Saved }
    }

    It 'sets an unset variable' {
        Set-DFEnv @script:Common -Value 'moar'
        $Env:DF_TEST_PAGER | Should -Be 'moar'
    }

    It 'keeps a value set outside DotForge when the choice is not explicit, silently' {
        $Env:DF_TEST_PAGER = 'less'
        Set-DFEnv @script:Common -Value 'moar' -WarningVariable w
        $Env:DF_TEST_PAGER | Should -Be 'less'
        $w | Should -BeNullOrEmpty
    }

    It 'notes the kept value for the tool' {
        $Env:DF_TEST_PAGER = 'less'
        Set-DFEnv @script:Common -Value 'moar'
        Get-DFEnvKeptNote -Tool 'moar' | Should -Be "DF_TEST_PAGER kept as set outside DotForge ('less'); DotForge wanted 'moar'"
    }

    It 'drops the note once the variable is written' {
        $Env:DF_TEST_PAGER = 'less'
        Set-DFEnv @script:Common -Value 'moar'
        Remove-Item Env:DF_TEST_PAGER
        Set-DFEnv @script:Common -Value 'moar'
        Get-DFEnvKeptNote -Tool 'moar' | Should -BeNullOrEmpty
    }

    It 'clears a tool''s notes' {
        $Env:DF_TEST_PAGER = 'less'
        Set-DFEnv @script:Common -Value 'moar'
        Clear-DFEnvKeptNote -Tool 'moar'
        Get-DFEnvKeptNote -Tool 'moar' | Should -BeNullOrEmpty
    }

    It 'shortens long values in notes' {
        $Env:DF_TEST_PAGER = 'x' * 100
        Set-DFEnv @script:Common -Value 'moar'
        Get-DFEnvKeptNote -Tool 'moar' | Should -Match "\('x{57}\.\.\.'\)"
    }

    It 'replaces a value set outside DotForge for an explicit choice, and warns with both settings' {
        $Env:DF_TEST_PAGER = 'less'
        Set-DFEnv @script:Common -Value 'moar' -ExplicitReason $script:Defaults -WarningVariable w -WarningAction SilentlyContinue
        $Env:DF_TEST_PAGER | Should -Be 'moar'
        "$w" | Should -Match "DF_TEST_PAGER was 'less' but \`$DFConfig.Defaults.pager is 'moar'; using moar"
        "$w" | Should -Match 'Remove one of the two settings'
    }

    It 'does not warn when the outside value already equals the new value' {
        $Env:DF_TEST_PAGER = 'moar'
        Set-DFEnv @script:Common -Value 'moar' -ExplicitReason $script:Defaults -WarningVariable w
        $w | Should -BeNullOrEmpty
    }

    It 'replaces a value DotForge set earlier' {
        Set-DFEnv @script:Common -Value 'less'
        Set-DFEnv @script:Common -Value 'moar'
        $Env:DF_TEST_PAGER | Should -Be 'moar'
    }

    It 'does not warn again on a second registration in the same session' {
        $Env:DF_TEST_PAGER = 'less'
        Set-DFEnv @script:Common -Value 'moar' -ExplicitReason $script:Defaults -WarningAction SilentlyContinue
        Set-DFEnv @script:Common -Value 'moar' -ExplicitReason $script:Defaults -WarningVariable w
        $w | Should -BeNullOrEmpty
    }

    It 'treats a value the user changed after DotForge set it as outside DotForge' {
        Set-DFEnv @script:Common -Value 'moar'
        $Env:DF_TEST_PAGER = 'less'
        Set-DFEnv @script:Common -Value 'moar'
        $Env:DF_TEST_PAGER | Should -Be 'less'
    }

    It 'warns about one conflict once per session, even when the profile re-sets the variable' {
        $Env:DF_TEST_PAGER = 'less'
        Set-DFEnv @script:Common -Value 'moar' -ExplicitReason $script:Defaults -WarningAction SilentlyContinue
        $Env:DF_TEST_PAGER = 'less'   # `. $PROFILE` runs the profile's own assignment again
        Set-DFEnv @script:Common -Value 'moar' -ExplicitReason $script:Defaults -WarningVariable w
        $w | Should -BeNullOrEmpty
        $Env:DF_TEST_PAGER | Should -Be 'moar'
    }

    It 'still warns about a different conflict in the same session' {
        $Env:DF_TEST_PAGER = 'less'
        Set-DFEnv @script:Common -Value 'moar' -ExplicitReason $script:Defaults -WarningAction SilentlyContinue
        $Env:DF_TEST_PAGER = 'more'
        Set-DFEnv @script:Common -Value 'moar' -ExplicitReason $script:Defaults -WarningVariable w -WarningAction SilentlyContinue
        "$w" | Should -Match "was 'more'"
    }

    It 'remembers what DotForge wrote across a module reload' {
        Set-DFEnv @script:Common -Value 'less'
        . "$PSScriptRoot/../Private/Set-DFEnv.ps1"   # Import-Module -Force re-runs the file; the global survives
        Set-DFEnv @script:Common -Value 'moar'
        $Env:DF_TEST_PAGER | Should -Be 'moar'
    }
}
