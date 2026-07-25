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
    . "$PSScriptRoot/../Public/Get-DFTool.ps1"
    . "$PSScriptRoot/../Public/Find-DFTool.ps1"
    . "$PSScriptRoot/../Private/Get-DFCoreutilsShadowSet.ps1"
    . "$PSScriptRoot/../Public/Get-DFCommandConflict.ps1"
    . "$PSScriptRoot/../Private/Initialize-DFCompletionStack.ps1"
    . "$PSScriptRoot/../Private/Get-DFConfiguredTheme.ps1"
    . "$PSScriptRoot/../Private/Resolve-DFThemeName.ps1"
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

Describe 'delta tool sidecar' {
    BeforeEach {
        $script:DFToolDb   = $null
        $script:SavedFeat  = $Env:DELTA_FEATURES
        $Env:DELTA_FEATURES = $null
        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
        Mock Get-Command { [PSCustomObject]@{ Path = 'C:\fake\delta.exe' } }
    }
    AfterEach {
        $Env:DELTA_FEATURES = $script:SavedFeat
        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
    }

    It 'sets DELTA_FEATURES to the canonical default when no theme is configured' {
        Register-DFTool -Name 'delta' -ToolsPath $script:RealTools
        $Env:DELTA_FEATURES | Should -Be 'catppuccin-mocha'
    }
    It 'follows the shared $DFConfig[Theme]' {
        $Global:DFConfig = @{ Theme = 'catppuccin-mocha' }
        Register-DFTool -Name 'delta' -ToolsPath $script:RealTools
        $Env:DELTA_FEATURES | Should -Be 'catppuccin-mocha'
    }
    It 'lets $DFConfig[DeltaTheme] override with a verbatim (non-canonical) name' {
        $Global:DFConfig = @{ DeltaTheme = 'my-custom-feature' }
        Register-DFTool -Name 'delta' -ToolsPath $script:RealTools
        $Env:DELTA_FEATURES | Should -Be 'my-custom-feature'
    }
}
