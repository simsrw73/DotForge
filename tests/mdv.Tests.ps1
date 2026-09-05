BeforeAll {
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/Invoke-DFFzf.ps1"
    . "$PSScriptRoot/../Public/Invoke-DFPicker.ps1"
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
    . "$PSScriptRoot/../Private/New-DFToolPickerFunction.ps1"
    . "$PSScriptRoot/../Private/Get-DFToolSetupState.ps1"
    . "$PSScriptRoot/../Public/Complete-DFToolSetup.ps1"
    . "$PSScriptRoot/../Private/Invoke-DFToolCompanion.ps1"
    . "$PSScriptRoot/../Private/Start-DFModulePrewarm.ps1"
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
        $script:DFToolAvailability = @{}
        $script:SavedConfigHome = $Env:XDG_CONFIG_HOME
        $script:SavedConfigPath = $Env:MDV_CONFIG_PATH
        $script:SavedStateHome  = $Env:XDG_STATE_HOME
        $Env:XDG_CONFIG_HOME    = Join-Path $TestDrive 'config'
        $Env:XDG_STATE_HOME     = Join-Path $TestDrive 'state'
        # Clean up mdv config/state from previous tests to ensure fresh state
        Remove-Item (Join-Path $Env:XDG_CONFIG_HOME 'mdv') -Recurse -Force -ErrorAction Ignore
        Remove-Item $Env:XDG_STATE_HOME -Recurse -Force -ErrorAction Ignore
        $Env:MDV_CONFIG_PATH    = $null
        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
        $script:RealTools = Join-Path $PSScriptRoot '../Tools'
    }
    AfterEach {
        $Env:XDG_CONFIG_HOME = $script:SavedConfigHome
        $Env:MDV_CONFIG_PATH = $script:SavedConfigPath
        $Env:XDG_STATE_HOME  = $script:SavedStateHome
        $script:DFToolDb     = $null
        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
    }

    It 'sets MDV_CONFIG_PATH and creates the dir' {
        Register-DFTool -Name 'mdv' -ToolsPath $script:RealTools
        $Env:MDV_CONFIG_PATH | Should -Be (Join-Path $Env:XDG_CONFIG_HOME 'mdv')
        Test-Path $Env:MDV_CONFIG_PATH | Should -BeTrue
    }

    It 'seeds config.yaml with the catppuccin theme on first registration' {
        Register-DFTool -Name 'mdv' -ToolsPath $script:RealTools
        $cfg = Join-Path $Env:XDG_CONFIG_HOME 'mdv' 'config.yaml'
        Test-Path $cfg | Should -BeTrue
        (Get-Content $cfg -Raw) | Should -Match 'theme:\s*"catppuccin"'
    }

    It 'records setup state on first registration' {
        Register-DFTool -Name 'mdv' -ToolsPath $script:RealTools
        (Get-DFToolSetupState).PSObject.Properties['mdv'] | Should -Not -BeNullOrEmpty
    }

    It 'does not overwrite an existing config.yaml, but still records setup state' {
        $dir = Join-Path $Env:XDG_CONFIG_HOME 'mdv'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $cfg = Join-Path $dir 'config.yaml'
        'theme: "nord"   # user edit' | Set-Content $cfg
        Register-DFTool -Name 'mdv' -ToolsPath $script:RealTools
        (Get-Content $cfg -Raw) | Should -Match 'user edit'
        (Get-DFToolSetupState).PSObject.Properties['mdv'] | Should -Not -BeNullOrEmpty
    }

    It 'does not reseed config.yaml after the user deletes it post-setup (closes the presence-check bug)' {
        Register-DFTool -Name 'mdv' -ToolsPath $script:RealTools
        $cfg = Join-Path $Env:XDG_CONFIG_HOME 'mdv' 'config.yaml'
        Test-Path $cfg | Should -BeTrue
        Remove-Item $cfg -Force

        Register-DFTool -Name 'mdv' -ToolsPath $script:RealTools

        Test-Path $cfg | Should -BeFalse
    }

    It 'skips config seeding entirely when SkipSetup names mdv' {
        $Global:DFConfig = @{ SkipSetup = @('mdv') }
        Register-DFTool -Name 'mdv' -ToolsPath $script:RealTools
        $cfg = Join-Path $Env:XDG_CONFIG_HOME 'mdv' 'config.yaml'
        Test-Path $cfg | Should -BeFalse
        (Get-DFToolSetupState).PSObject.Properties['mdv'] | Should -BeNullOrEmpty
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
