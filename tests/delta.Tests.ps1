BeforeAll {
    . "$PSScriptRoot/../Public/Add-DFToPath.ps1"
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
    . "$PSScriptRoot/../Public/Register-DFTool.ps1"
    $script:RealTools = Join-Path $PSScriptRoot '../Tools'
}

Describe 'Tools/delta.json' {
    It 'no longer carries DELTA_FEATURES in its env block' {
        $j = Get-Content (Join-Path $script:RealTools 'delta.json') -Raw | ConvertFrom-Json
        $j.env.PSObject.Properties['DELTA_FEATURES'] | Should -BeNullOrEmpty
        $j.env.GIT_PAGER | Should -Be 'delta'
    }
}

Describe 'Tools/delta/catppuccin.gitconfig' {
    It 'exists and defines the catppuccin-mocha feature' {
        $path = Join-Path $script:RealTools 'delta' 'catppuccin.gitconfig'
        Test-Path $path | Should -BeTrue
        (Get-Content $path -Raw) | Should -Match '\[delta "catppuccin-mocha"\]'
    }
}

Describe 'delta tool sidecar' {
    BeforeEach {
        $script:DFToolDb   = $null
        $script:DFToolAvailability = @{}
        $script:SavedFeat  = $Env:DELTA_FEATURES
        $Env:DELTA_FEATURES = $null
        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
        Mock Get-Command { [PSCustomObject]@{ Path = 'C:\fake\delta.exe' } }

        $script:SavedConfigHome = $Env:XDG_CONFIG_HOME
        $script:SavedStateHome  = $Env:XDG_STATE_HOME
        $script:SavedGitConfigGlobal = $Env:GIT_CONFIG_GLOBAL
        $Env:XDG_CONFIG_HOME = Join-Path $TestDrive 'config'
        $Env:XDG_STATE_HOME  = Join-Path $TestDrive 'state'
        $Env:GIT_CONFIG_GLOBAL = Join-Path $TestDrive 'gitconfig'
        Remove-Item $Env:XDG_CONFIG_HOME, $Env:XDG_STATE_HOME, $Env:GIT_CONFIG_GLOBAL -Recurse -Force -ErrorAction Ignore
    }
    AfterEach {
        $Env:DELTA_FEATURES = $script:SavedFeat
        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
        $Env:XDG_CONFIG_HOME   = $script:SavedConfigHome
        $Env:XDG_STATE_HOME    = $script:SavedStateHome
        $Env:GIT_CONFIG_GLOBAL = $script:SavedGitConfigGlobal
    }

    It 'sets DELTA_FEATURES to the canonical default, additively (+), when no theme is configured' {
        Register-DFTool -Name 'delta' -ToolsPath $script:RealTools
        $Env:DELTA_FEATURES | Should -Be '+catppuccin-mocha'
    }
    It 'follows the shared $DFConfig[Theme]' {
        $Global:DFConfig = @{ Theme = 'catppuccin-mocha' }
        Register-DFTool -Name 'delta' -ToolsPath $script:RealTools
        $Env:DELTA_FEATURES | Should -Be '+catppuccin-mocha'
    }
    It 'lets $DFConfig[DeltaTheme] override with a verbatim (non-canonical) name, additively' {
        $Global:DFConfig = @{ DeltaTheme = 'my-custom-feature' }
        Register-DFTool -Name 'delta' -ToolsPath $script:RealTools
        $Env:DELTA_FEATURES | Should -Be '+my-custom-feature'
    }

    It 'deploys the bundled catppuccin theme file to $XDG_CONFIG_HOME/delta' {
        Register-DFTool -Name 'delta' -ToolsPath $script:RealTools
        $deployed = Join-Path $Env:XDG_CONFIG_HOME 'delta' 'catppuccin.gitconfig'
        Test-Path $deployed | Should -BeTrue
        (Get-Content $deployed -Raw) | Should -Match '\[delta "catppuccin-mocha"\]'
    }

    It 'adds exactly one include.path entry and records setup state on first registration' {
        Register-DFTool -Name 'delta' -ToolsPath $script:RealTools
        $deployed = Join-Path $Env:XDG_CONFIG_HOME 'delta' 'catppuccin.gitconfig'

        @(git config --global --get-all include.path) | Should -Contain $deployed
        (Get-DFToolSetupState).PSObject.Properties['delta'] | Should -Not -BeNullOrEmpty
        (Get-DFToolSetupState).delta.actions[0].path | Should -Be $deployed
    }

    It 'does not re-invoke git config on a second registration (state entry short-circuits it)' {
        Register-DFTool -Name 'delta' -ToolsPath $script:RealTools
        $deployed = Join-Path $Env:XDG_CONFIG_HOME 'delta' 'catppuccin.gitconfig'
        git config --global --unset-all include.path *>$null

        Register-DFTool -Name 'delta' -ToolsPath $script:RealTools

        @(git config --global --get-all include.path 2>$null) | Should -Not -Contain $deployed
    }

    It 'skips the git-config edit and setup state entirely when SkipSetup names delta' {
        $Global:DFConfig = @{ SkipSetup = @('delta') }
        Register-DFTool -Name 'delta' -ToolsPath $script:RealTools

        $Env:DELTA_FEATURES | Should -Be '+catppuccin-mocha'
        @(git config --global --get-all include.path 2>$null) | Should -BeNullOrEmpty
        (Get-DFToolSetupState).PSObject.Properties['delta'] | Should -BeNullOrEmpty
    }

    It 'prints a visible confirmation naming the removal command on first add' {
        $out = Register-DFTool -Name 'delta' -ToolsPath $script:RealTools 6>&1 | Out-String
        $out | Should -Match 'git config --global --unset-all include\.path'
    }
}
