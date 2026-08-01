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
    . "$PSScriptRoot/../Private/Resolve-DFThemeName.ps1"
    . "$PSScriptRoot/../Public/Register-DFTool.ps1"

    $script:MdvJson = Get-Content "$PSScriptRoot/../Tools/mdv.json" -Raw | ConvertFrom-Json
}

Describe 'Tools/mdv.json' {
    It 'declares the env XDG method' {
        $script:MdvJson.xdg.method | Should -Be 'env'
    }
    It 'points MDV_CONFIG_PATH at the XDG mdv dir' {
        $script:MdvJson.xdg.vars.MDV_CONFIG_PATH | Should -Be '${XDG_CONFIG_HOME}/mdv'
    }
    It 'names catppuccin-mocha as the default theme' {
        $script:MdvJson.settings.theme | Should -Be 'catppuccin-mocha'
    }
    It 'declares a themeMap translating the canonical family to catppuccin' {
        $script:MdvJson.themeMap.'catppuccin-mocha' | Should -Be 'catppuccin'
    }
    It 'declares a cargo package' {
        $script:MdvJson.packages.cargo | Should -Be 'mdv'
    }
}

Describe 'mdv tool sidecar' -Skip:(-not (Get-Command mdv.exe -ErrorAction Ignore)) {
    BeforeEach {
        $script:DFToolDb        = $null
        $script:SavedConfigHome = $Env:XDG_CONFIG_HOME
        $script:SavedConfigPath = $Env:MDV_CONFIG_PATH
        $Env:XDG_CONFIG_HOME    = Join-Path $TestDrive 'config'
        # Clean up mdv config from previous tests to ensure fresh state
        $cfgDir = Join-Path $Env:XDG_CONFIG_HOME 'mdv'
        if (Test-Path $cfgDir) {
            Remove-Item -Recurse -Force $cfgDir
        }
        $Env:MDV_CONFIG_PATH    = $null
        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
        $script:RealTools = Join-Path $PSScriptRoot '../Tools'
    }
    AfterEach {
        $Env:XDG_CONFIG_HOME = $script:SavedConfigHome
        $Env:MDV_CONFIG_PATH = $script:SavedConfigPath
        $script:DFToolDb     = $null
        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
    }

    It 'sets MDV_CONFIG_PATH and creates the dir' {
        Register-DFTool -Name 'mdv' -ToolsPath $script:RealTools
        $Env:MDV_CONFIG_PATH | Should -Be (Join-Path $Env:XDG_CONFIG_HOME 'mdv')
        Test-Path $Env:MDV_CONFIG_PATH | Should -BeTrue
    }

    It 'seeds config.yaml with the catppuccin theme when absent' {
        Register-DFTool -Name 'mdv' -ToolsPath $script:RealTools
        $cfg = Join-Path $Env:XDG_CONFIG_HOME 'mdv' 'config.yaml'
        Test-Path $cfg | Should -BeTrue
        (Get-Content $cfg -Raw) | Should -Match 'theme:\s*"catppuccin"'
    }

    It 'does not overwrite an existing config.yaml' {
        $dir = Join-Path $Env:XDG_CONFIG_HOME 'mdv'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $cfg = Join-Path $dir 'config.yaml'
        'theme: "nord"   # user edit' | Set-Content $cfg
        Register-DFTool -Name 'mdv' -ToolsPath $script:RealTools
        (Get-Content $cfg -Raw) | Should -Match 'user edit'
    }

    It 'maps the catppuccin family down to mdv''s catppuccin theme' {
        $Global:DFConfig = @{ Theme = 'catppuccin-mocha' }
        Register-DFTool -Name 'mdv' -ToolsPath $script:RealTools
        $cfg = Join-Path $Env:XDG_CONFIG_HOME 'mdv' 'config.yaml'
        (Get-Content $cfg -Raw) | Should -Match 'theme:\s*"catppuccin"'
    }

    It 'tolerates $DFConfig being set to $null' {
        $Global:DFConfig = $null
        { Register-DFTool -Name 'mdv' -ToolsPath $script:RealTools } | Should -Not -Throw
    }
}

Describe 'Tools/carapace/specs/mdv.yaml' {
    BeforeAll {
        $script:SpecPath = "$PSScriptRoot/../Tools/carapace/specs/mdv.yaml"
        $script:Spec     = Get-Content $script:SpecPath -Raw
    }
    It 'exists and names the mdv command' {
        Test-Path $script:SpecPath | Should -BeTrue
        $script:Spec | Should -Match '(?m)^name:\s*mdv\b'
    }
    It 'declares the theme flag with catppuccin among its values' {
        $script:Spec | Should -Match '--theme'
        $script:Spec | Should -Match 'catppuccin'
    }
    It 'declares the config-file and pager flags' {
        $script:Spec | Should -Match '--config-file'
        $script:Spec | Should -Match '--pager'
    }
}
