BeforeAll {
    . "$PSScriptRoot/../Private/Invoke-DFFzf.ps1"
    . "$PSScriptRoot/../Public/Invoke-DFPicker.ps1"
    . "$PSScriptRoot/../Public/DFHelpers.Environment.ps1"
}

Describe 'Get-DFEnv' {
    It 'outputs KEY=VALUE lines for all env vars' {
        $Env:DF_TEST_ENV = 'testval'
        $result = Get-DFEnv
        Remove-Item Env:DF_TEST_ENV -ErrorAction Ignore
        $result | Should -Contain 'DF_TEST_ENV=testval'
    }

    It 'filters by -Pattern' {
        $Env:DF_AAA_VAR = 'aaa'
        $Env:DF_BBB_VAR = 'bbb'
        $result = Get-DFEnv 'DF_AAA*'
        Remove-Item Env:DF_AAA_VAR, Env:DF_BBB_VAR -ErrorAction Ignore
        $result | Should -Contain 'DF_AAA_VAR=aaa'
        $result | Should -Not -Contain 'DF_BBB_VAR=bbb'
    }

    It 'is aliased to env' {
        Get-Alias env | Should -Not -BeNullOrEmpty
    }
}

Describe 'Get-DFPath' {
    It 'returns one entry per PATH segment' {
        $saved = $Env:PATH
        $sep = [IO.Path]::PathSeparator
        $Env:PATH = "C:\foo${sep}C:\bar${sep}C:\baz"
        $result = path
        $Env:PATH = $saved
        $result | Should -Be @('C:\foo', 'C:\bar', 'C:\baz')
    }
}

Describe 'Select-DFEnvVar' {
    It 'outputs the value of the selected env var' {
        $Env:DF_TEST_VAR = 'test-value-123'
        Mock Invoke-DFFzf { "DF_TEST_VAR`ttest-value-123" }
        $result = fenv
        Remove-Item Env:DF_TEST_VAR -ErrorAction Ignore
        $result | Should -Be 'test-value-123'
    }

    It 'returns nothing when user cancels' {
        Mock Invoke-DFFzf { $null }
        fenv | Should -BeNullOrEmpty
    }
}

Describe 'Edit-DFProfile' {
    BeforeEach { $script:SavedEditor = $Env:EDITOR }
    AfterEach  { $Env:EDITOR = $script:SavedEditor }

    It 'emits a warning when $Env:EDITOR is not set' {
        $Env:EDITOR = $null
        ep -WarningVariable warns 3>$null
        $warns | Should -Not -BeNullOrEmpty
    }

    It 'does not emit a warning when $Env:EDITOR is set' {
        $Env:EDITOR = 'nonexistent-editor-xyz'
        try { ep -WarningVariable warns 3>$null } catch { }
        $warns | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-DFProfileReload' {
    It 'does not throw even when $PROFILE does not exist' {
        { reload } | Should -Not -Throw
    }
}
