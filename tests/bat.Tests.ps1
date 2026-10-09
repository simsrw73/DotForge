BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
}

Describe 'Tools/bat.json' {
    BeforeAll {
        $script:BatJson = Get-Content "$PSScriptRoot/../Tools/bat.json" -Raw | ConvertFrom-Json
    }

    It 'defaults BAT_THEME to the native Catppuccin Mocha name' {
        $script:BatJson.env.BAT_THEME | Should -Be 'Catppuccin Mocha'
    }

    It 'declares a themeMap from canonical catppuccin-mocha to the native name' {
        $script:BatJson.themeMap.'catppuccin-mocha' | Should -Be 'Catppuccin Mocha'
    }
}

Describe 'bat tool sidecar' -Skip:(-not (Get-Command bat.exe -ErrorAction Ignore)) {
    BeforeEach {
        $script:DFToolDb       = $null
        $script:DFToolAvailability = @{}
        Set-DFTestXdg

        $script:RealTools       = Join-Path $PSScriptRoot '../Tools'
    }

    AfterEach {
        $script:DFToolDb     = $null
        [System.Environment]::SetEnvironmentVariable('BAT_THEME', $null, 'Process')
        Set-DFTestConfig $null
        Restore-DFTestXdg
    }

    It 'sets BAT_THEME to Catppuccin Mocha by default' {
        Register-DFTool -Name 'bat' -ToolsPath $script:RealTools
        $Env:BAT_THEME | Should -Be 'Catppuccin Mocha'
    }

    It 'follows the shared $DFConfig[Theme] key, translating to the native name' {
        Set-DFTestConfig @{ Theme = 'catppuccin-mocha' }
        Register-DFTool -Name 'bat' -ToolsPath $script:RealTools
        $Env:BAT_THEME | Should -Be 'Catppuccin Mocha'
    }

    It 'lets BatTheme override with a non-canonical native bat theme name' {
        Set-DFTestConfig @{ BatTheme = 'Dracula' }
        Register-DFTool -Name 'bat' -ToolsPath $script:RealTools
        $Env:BAT_THEME | Should -Be 'Dracula'
    }

    It 'lets BatTheme override the shared Theme key' {
        Set-DFTestConfig @{ Theme = 'catppuccin-mocha'; BatTheme = 'Dracula' }
        Register-DFTool -Name 'bat' -ToolsPath $script:RealTools
        $Env:BAT_THEME | Should -Be 'Dracula'
    }
}
