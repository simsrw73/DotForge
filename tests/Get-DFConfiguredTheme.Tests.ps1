BeforeAll {
    . "$PSScriptRoot/../Private/Get-DFConfiguredTheme.ps1"
}

Describe 'Get-DFConfiguredTheme' {
    AfterEach { Remove-Variable DFConfig -Scope Global -ErrorAction Ignore }

    It 'returns the per-tool key when set' {
        $Global:DFConfig = @{ MdvTheme = 'nord'; Theme = 'catppuccin' }
        Get-DFConfiguredTheme -ToolKey 'MdvTheme' -Default 'catppuccin' | Should -Be 'nord'
    }

    It 'falls back to the shared Theme key' {
        $Global:DFConfig = @{ Theme = 'catppuccin' }
        Get-DFConfiguredTheme -ToolKey 'MdvTheme' -Default 'terminal' | Should -Be 'catppuccin'
    }

    It 'falls back to the default when neither key is set' {
        $Global:DFConfig = @{ SkipTools = @('lsd') }
        Get-DFConfiguredTheme -ToolKey 'MdvTheme' -Default 'catppuccin' | Should -Be 'catppuccin'
    }

    It 'returns the default when $DFConfig is not defined' {
        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
        Get-DFConfiguredTheme -ToolKey 'MdvTheme' -Default 'catppuccin' | Should -Be 'catppuccin'
    }

    It 'tolerates $DFConfig being set to $null' {
        $Global:DFConfig = $null
        Get-DFConfiguredTheme -ToolKey 'MdvTheme' -Default 'catppuccin' | Should -Be 'catppuccin'
    }

    It 'returns $null when nothing is set and no default is given' {
        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
        Get-DFConfiguredTheme -ToolKey 'MdvTheme' | Should -BeNullOrEmpty
    }
}
