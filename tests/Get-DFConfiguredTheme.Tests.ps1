BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
}

Describe 'Get-DFConfiguredTheme' {
    AfterEach { Set-DFTestConfig $null }

    It 'returns the per-tool key when set' {
        Set-DFTestConfig @{ MdvTheme = 'nord'; Theme = 'catppuccin' }
        Get-DFConfiguredTheme -ToolKey 'MdvTheme' -Default 'catppuccin' | Should -Be 'nord'
    }

    It 'falls back to the shared Theme key' {
        Set-DFTestConfig @{ Theme = 'catppuccin' }
        Get-DFConfiguredTheme -ToolKey 'MdvTheme' -Default 'terminal' | Should -Be 'catppuccin'
    }

    It 'falls back to the default when neither key is set' {
        Set-DFTestConfig @{ SkipTools = @('lsd') }
        Get-DFConfiguredTheme -ToolKey 'MdvTheme' -Default 'catppuccin' | Should -Be 'catppuccin'
    }

    It 'returns the default when $DFConfig is not defined' {
        Set-DFTestConfig $null
        Get-DFConfiguredTheme -ToolKey 'MdvTheme' -Default 'catppuccin' | Should -Be 'catppuccin'
    }

    It 'tolerates $DFConfig being set to $null' {
        Set-DFTestConfig $null
        Get-DFConfiguredTheme -ToolKey 'MdvTheme' -Default 'catppuccin' | Should -Be 'catppuccin'
    }

    It 'returns $null when nothing is set and no default is given' {
        Set-DFTestConfig $null
        Get-DFConfiguredTheme -ToolKey 'MdvTheme' | Should -BeNullOrEmpty
    }
}
