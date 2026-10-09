BeforeAll { . "$PSScriptRoot/../Private/Set-DFRoleEnv.ps1" }

Describe 'Set-DFRoleEnv' {
    BeforeEach {
        $global:DFRoleEnvState = $null
        $script:Saved = $Env:DF_TEST_PAGER
        Remove-Item Env:DF_TEST_PAGER -ErrorAction Ignore
        $script:Common = @{ Name = 'DF_TEST_PAGER'; Role = 'pager'; Winner = 'moar' }
    }
    AfterEach {
        Remove-Variable DFRoleEnvState -Scope Global -ErrorAction Ignore
        if ($null -eq $script:Saved) { Remove-Item Env:DF_TEST_PAGER -ErrorAction Ignore } else { $Env:DF_TEST_PAGER = $script:Saved }
    }

    It 'sets an unset variable for an auto-picked winner' {
        Set-DFRoleEnv @script:Common -Value 'moar' -Reason priority
        $Env:DF_TEST_PAGER | Should -Be 'moar'
    }

    It 'keeps a value set outside DotForge for an auto-picked winner, silently' {
        $Env:DF_TEST_PAGER = 'less'
        Set-DFRoleEnv @script:Common -Value 'moar' -Reason sole -WarningVariable w
        $Env:DF_TEST_PAGER | Should -Be 'less'
        $w | Should -BeNullOrEmpty
    }

    It 'replaces a value set outside DotForge for a Defaults winner, and warns with both settings' {
        $Env:DF_TEST_PAGER = 'less'
        Set-DFRoleEnv @script:Common -Value 'moar' -Reason Defaults -WarningVariable w -WarningAction SilentlyContinue
        $Env:DF_TEST_PAGER | Should -Be 'moar'
        "$w" | Should -Match "DF_TEST_PAGER was 'less' but \`$DFConfig.Defaults.pager is 'moar'; using moar"
        "$w" | Should -Match 'Remove one of the two settings'
    }

    It 'does not warn when the outside value already equals the winner value' {
        $Env:DF_TEST_PAGER = 'moar'
        Set-DFRoleEnv @script:Common -Value 'moar' -Reason Defaults -WarningVariable w
        $w | Should -BeNullOrEmpty
    }

    It 'replaces a value DotForge set earlier, for any reason' {
        Set-DFRoleEnv @script:Common -Value 'less' -Reason priority
        Set-DFRoleEnv @script:Common -Value 'moar' -Reason priority
        $Env:DF_TEST_PAGER | Should -Be 'moar'
    }

    It 'does not warn again on a second registration in the same session' {
        $Env:DF_TEST_PAGER = 'less'
        Set-DFRoleEnv @script:Common -Value 'moar' -Reason Defaults -WarningAction SilentlyContinue
        Set-DFRoleEnv @script:Common -Value 'moar' -Reason Defaults -WarningVariable w
        $w | Should -BeNullOrEmpty
    }

    It 'treats a value the user changed after DotForge set it as outside DotForge' {
        Set-DFRoleEnv @script:Common -Value 'moar' -Reason priority
        $Env:DF_TEST_PAGER = 'less'
        Set-DFRoleEnv @script:Common -Value 'moar' -Reason priority
        $Env:DF_TEST_PAGER | Should -Be 'less'
    }

    It 'warns about one conflict once per session, even when the profile re-sets the variable' {
        $Env:DF_TEST_PAGER = 'less'
        Set-DFRoleEnv @script:Common -Value 'moar' -Reason Defaults -WarningAction SilentlyContinue
        $Env:DF_TEST_PAGER = 'less'   # `. $PROFILE` runs the profile's own assignment again
        Set-DFRoleEnv @script:Common -Value 'moar' -Reason Defaults -WarningVariable w
        $w | Should -BeNullOrEmpty
        $Env:DF_TEST_PAGER | Should -Be 'moar'
    }

    It 'still warns about a different conflict in the same session' {
        $Env:DF_TEST_PAGER = 'less'
        Set-DFRoleEnv @script:Common -Value 'moar' -Reason Defaults -WarningAction SilentlyContinue
        $Env:DF_TEST_PAGER = 'more'
        Set-DFRoleEnv @script:Common -Value 'moar' -Reason Defaults -WarningVariable w -WarningAction SilentlyContinue
        "$w" | Should -Match "was 'more'"
    }

    It 'remembers what DotForge wrote across a module reload' {
        Set-DFRoleEnv @script:Common -Value 'less' -Reason priority
        Set-DFRoleEnv @script:Common -Value 'moar' -Reason priority
        $Env:DF_TEST_PAGER | Should -Be 'moar'
    }
}
