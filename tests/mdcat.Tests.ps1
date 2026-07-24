BeforeAll {
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/Invoke-DFFzf.ps1"
    . "$PSScriptRoot/../Public/Invoke-DFPicker.ps1"
    . "$PSScriptRoot/../Private/Test-DFToolSchema.ps1"
    . "$PSScriptRoot/../Private/ConvertTo-DFPath.ps1"
    . "$PSScriptRoot/../Private/Expand-DFXdgPath.ps1"
    . "$PSScriptRoot/../Private/Import-DFToolDb.ps1"
    . "$PSScriptRoot/../Private/Invoke-DFTopoSort.ps1"
    . "$PSScriptRoot/../Public/Get-DFTool.ps1"
    . "$PSScriptRoot/../Public/Find-DFTool.ps1"
    . "$PSScriptRoot/../Private/Get-DFCoreutilsShadowSet.ps1"
    . "$PSScriptRoot/../Public/Get-DFCommandConflict.ps1"
    . "$PSScriptRoot/../Private/Initialize-DFCompletionStack.ps1"
    . "$PSScriptRoot/../Private/Get-DFConfiguredTheme.ps1"
    . "$PSScriptRoot/../Public/Register-DFTool.ps1"

    $script:McatJson = Get-Content "$PSScriptRoot/../Tools/mdcat.json" -Raw | ConvertFrom-Json
}

Describe 'Tools/mdcat.json' {
    It 'declares the env XDG method' {
        $script:McatJson.xdg.method | Should -Be 'env'
    }
    It 'sets a catppuccin MDCAT_THEME default' {
        $script:McatJson.xdg.vars.MDCAT_THEME | Should -Be 'catppuccin-mocha'
    }
    It 'declares scoop and cargo packages' {
        $script:McatJson.packages.scoop | Should -Be 'mdcat'
        $script:McatJson.packages.cargo | Should -Be 'mdcat'
    }
}

Describe 'mdcat tool sidecar' -Skip:(-not (Get-Command mdcat.exe -ErrorAction Ignore)) {
    BeforeEach {
        $script:DFToolDb     = $null
        $script:SavedTheme   = $Env:MDCAT_THEME
        $Env:MDCAT_THEME     = $null
        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
        $script:RealTools = Join-Path $PSScriptRoot '../Tools'
    }
    AfterEach {
        $Env:MDCAT_THEME = $script:SavedTheme
        $script:DFToolDb = $null
        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
    }

    It 'sets MDCAT_THEME to the JSON default when no $DFConfig theme is set' {
        Register-DFTool -Name 'mdcat' -ToolsPath $script:RealTools
        $Env:MDCAT_THEME | Should -Be 'catppuccin-mocha'
    }

    It 'lets $DFConfig[MdcatTheme] override the theme' {
        $Global:DFConfig = @{ MdcatTheme = 'dracula' }
        Register-DFTool -Name 'mdcat' -ToolsPath $script:RealTools
        $Env:MDCAT_THEME | Should -Be 'dracula'
    }

    It 'maps the shared catppuccin family to catppuccin-mocha' {
        $Global:DFConfig = @{ Theme = 'catppuccin' }
        Register-DFTool -Name 'mdcat' -ToolsPath $script:RealTools
        $Env:MDCAT_THEME | Should -Be 'catppuccin-mocha'
    }

    It 'falls back to auto for an unsupported theme name' {
        $Global:DFConfig = @{ MdcatTheme = 'no-such-theme' }
        Register-DFTool -Name 'mdcat' -ToolsPath $script:RealTools -WarningAction SilentlyContinue
        $Env:MDCAT_THEME | Should -Be 'auto'
    }

    It 'tolerates $DFConfig being set to $null' {
        $Global:DFConfig = $null
        { Register-DFTool -Name 'mdcat' -ToolsPath $script:RealTools } | Should -Not -Throw
    }
}
