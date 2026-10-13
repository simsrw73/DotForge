BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
}

Describe 'bat theme' {
    BeforeEach { Reset-DFTestSession; Set-DFTestConfig $null; Remove-Item Env:BAT_THEME -ErrorAction Ignore; $script:Bat = Get-DFTestToolRecord bat }
    AfterEach { Remove-Item Env:BAT_THEME -ErrorAction Ignore; Set-DFTestConfig $null }

    It 'has no companion and no top-level BAT_THEME' {
        Test-Path "$PSScriptRoot/../Tools/bat.ps1" | Should -BeFalse
        $script:Bat.env | Should -BeNullOrEmpty
    }
    It 'sets BAT_THEME to Catppuccin Mocha by default' {
        Set-DFToolThemeEnv -Tool $script:Bat -Theme (Resolve-DFToolTheme -Tool $script:Bat)
        $Env:BAT_THEME | Should -Be 'Catppuccin Mocha'
    }
    It 'follows the shared Theme key, translating to the native name' {
        Set-DFTestConfig @{ Theme = 'catppuccin-mocha' }
        Set-DFToolThemeEnv -Tool $script:Bat -Theme (Resolve-DFToolTheme -Tool $script:Bat)
        $Env:BAT_THEME | Should -Be 'Catppuccin Mocha'
    }
    It 'lets BatTheme override the shared Theme with a native name' {
        Set-DFTestConfig @{ Theme = 'catppuccin-mocha'; BatTheme = 'Dracula' }
        Set-DFToolThemeEnv -Tool $script:Bat -Theme (Resolve-DFToolTheme -Tool $script:Bat)
        $Env:BAT_THEME | Should -Be 'Dracula'
    }
    It 'keeps a BAT_THEME set outside DotForge unless BatTheme is set' {
        $Env:BAT_THEME = 'Nord'
        Set-DFToolThemeEnv -Tool $script:Bat -Theme (Resolve-DFToolTheme -Tool $script:Bat)
        $Env:BAT_THEME | Should -Be 'Nord'
    }
}
