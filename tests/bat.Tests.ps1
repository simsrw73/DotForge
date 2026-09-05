BeforeAll {
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/Test-DFToolSchema.ps1"
    . "$PSScriptRoot/../Private/ConvertTo-DFPath.ps1"
    . "$PSScriptRoot/../Private/Expand-DFXdgPath.ps1"
    . "$PSScriptRoot/../Private/Import-DFToolDb.ps1"
    . "$PSScriptRoot/../Private/Invoke-DFTopoSort.ps1"
    . "$PSScriptRoot/../Private/Test-DFToolAvailable.ps1"
    . "$PSScriptRoot/../Public/Get-DFTool.ps1"
    . "$PSScriptRoot/../Public/Find-DFTool.ps1"
    . "$PSScriptRoot/../Private/Get-DFCoreutilsShadowSet.ps1"
    . "$PSScriptRoot/../Public/Get-DFCommandConflict.ps1"
    . "$PSScriptRoot/../Private/Initialize-DFCompletionStack.ps1"
    . "$PSScriptRoot/../Private/Get-DFConfiguredTheme.ps1"
    . "$PSScriptRoot/../Private/Resolve-DFThemeName.ps1"
    . "$PSScriptRoot/../Private/Set-DFToolXdgConfig.ps1"
    . "$PSScriptRoot/../Private/Register-DFToolAliases.ps1"
    . "$PSScriptRoot/../Public/Register-DFTool.ps1"
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
        $script:SavedConfigHome = $Env:XDG_CONFIG_HOME
        $Env:XDG_CONFIG_HOME    = Join-Path $TestDrive 'config'
        $script:RealTools       = Join-Path $PSScriptRoot '../Tools'
    }

    AfterEach {
        $Env:XDG_CONFIG_HOME = $script:SavedConfigHome
        $script:DFToolDb     = $null
        [System.Environment]::SetEnvironmentVariable('BAT_THEME', $null, 'Process')
        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
    }

    It 'sets BAT_THEME to Catppuccin Mocha by default' {
        Register-DFTool -Name 'bat' -ToolsPath $script:RealTools
        $Env:BAT_THEME | Should -Be 'Catppuccin Mocha'
    }

    It 'follows the shared $DFConfig[Theme] key, translating to the native name' {
        $Global:DFConfig = @{ Theme = 'catppuccin-mocha' }
        Register-DFTool -Name 'bat' -ToolsPath $script:RealTools
        $Env:BAT_THEME | Should -Be 'Catppuccin Mocha'
    }

    It 'lets BatTheme override with a non-canonical native bat theme name' {
        $Global:DFConfig = @{ BatTheme = 'Dracula' }
        Register-DFTool -Name 'bat' -ToolsPath $script:RealTools
        $Env:BAT_THEME | Should -Be 'Dracula'
    }

    It 'lets BatTheme override the shared Theme key' {
        $Global:DFConfig = @{ Theme = 'catppuccin-mocha'; BatTheme = 'Dracula' }
        Register-DFTool -Name 'bat' -ToolsPath $script:RealTools
        $Env:BAT_THEME | Should -Be 'Dracula'
    }
}
