BeforeAll {
    . "$PSScriptRoot/../Private/Invoke-DFFzf.ps1"
    . "$PSScriptRoot/../Public/Invoke-DFPicker.ps1"
    . "$PSScriptRoot/../Public/DFHelpers.Environment.ps1"
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
