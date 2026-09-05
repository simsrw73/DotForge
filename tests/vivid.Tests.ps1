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
    . "$PSScriptRoot/../Public/Register-DFTool.ps1"
}

Describe 'Tools/vivid.json' {
    BeforeAll {
        $script:VividJson = Get-Content "$PSScriptRoot/../Tools/vivid.json" -Raw | ConvertFrom-Json
    }

    It 'declares the default XDG method' {
        $script:VividJson.xdg.method | Should -Be 'default'
    }

    It 'declares scoop and winget package ids, and no choco' {
        $script:VividJson.packages.scoop  | Should -Be 'vivid'
        $script:VividJson.packages.winget | Should -Be 'sharkdp.vivid'
        $script:VividJson.packages.PSObject.Properties.Name | Should -Not -Contain 'choco'
    }

    It 'defaults the theme setting to catppuccin-mocha' {
        $script:VividJson.settings.theme | Should -Be 'catppuccin-mocha'
    }

    It 'declares a custom picker' {
        $script:VividJson.picker | Should -Be 'custom'
    }
}

Describe 'vivid tool sidecar' -Skip:(-not (Get-Command vivid.exe -ErrorAction Ignore)) {
    BeforeEach {
        $script:DFToolDb       = $null
        $script:SavedConfigHome = $Env:XDG_CONFIG_HOME
        $script:SavedCacheHome  = $Env:XDG_CACHE_HOME
        $Env:XDG_CONFIG_HOME    = Join-Path $TestDrive 'config'
        $Env:XDG_CACHE_HOME     = Join-Path $TestDrive 'cache'
        Remove-Item $Env:XDG_CACHE_HOME -Recurse -Force -ErrorAction Ignore

        $script:RealTools = Join-Path $PSScriptRoot '../Tools'
    }

    AfterEach {
        $Env:XDG_CONFIG_HOME = $script:SavedConfigHome
        $Env:XDG_CACHE_HOME  = $script:SavedCacheHome
        $script:DFToolDb     = $null

        [System.Environment]::SetEnvironmentVariable('LS_COLORS', $null, 'Process')
        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
        Remove-Item 'function:global:Invoke-DFApplyLSColorsTheme' -ErrorAction Ignore
        Remove-Item 'function:global:Select-LSColorsTheme' -ErrorAction Ignore
        Remove-Alias fls -Scope Global -Force -ErrorAction Ignore
    }

    It 'sets LS_COLORS to vivid catppuccin-mocha output by default' {
        Register-DFTool -Name 'vivid' -ToolsPath $script:RealTools
        $Env:LS_COLORS | Should -Not -BeNullOrEmpty
        $Env:LS_COLORS | Should -Match 'di=0;38;2;137;180;250'
    }

    It 'registers Invoke-DFApplyLSColorsTheme as a global function' {
        Register-DFTool -Name 'vivid' -ToolsPath $script:RealTools
        Test-Path 'function:global:Invoke-DFApplyLSColorsTheme' | Should -BeTrue
    }

    It 'registers Select-LSColorsTheme as a global function' {
        Register-DFTool -Name 'vivid' -ToolsPath $script:RealTools
        Test-Path 'function:global:Select-LSColorsTheme' | Should -BeTrue
    }

    It 'registers fls as an alias for Select-LSColorsTheme' {
        Register-DFTool -Name 'vivid' -ToolsPath $script:RealTools
        Get-Alias fls -ErrorAction Ignore | Should -Not -BeNullOrEmpty
    }

    It 'caches the generated value and reuses it for a matching theme name' {
        Register-DFTool -Name 'vivid' -ToolsPath $script:RealTools
        $cacheFile = Join-Path $Env:XDG_CACHE_HOME 'dotforge' 'ls-colors.txt'
        Set-Content -Path $cacheFile -Value 'SENTINEL-CACHED-VALUE' -Encoding UTF8

        Invoke-DFApplyLSColorsTheme -Name 'catppuccin-mocha'

        $Env:LS_COLORS | Should -Be 'SENTINEL-CACHED-VALUE'
    }

    It 'regenerates when the theme name differs from the cached key' {
        Register-DFTool -Name 'vivid' -ToolsPath $script:RealTools
        $cacheFile = Join-Path $Env:XDG_CACHE_HOME 'dotforge' 'ls-colors.txt'
        Set-Content -Path $cacheFile -Value 'SENTINEL-CACHED-VALUE' -Encoding UTF8

        Invoke-DFApplyLSColorsTheme -Name 'catppuccin-latte'

        $Env:LS_COLORS | Should -Not -Be 'SENTINEL-CACHED-VALUE'
        $Env:LS_COLORS | Should -Not -BeNullOrEmpty
    }

    It 'always regenerates when -Force is passed, even on a matching cache key' {
        Register-DFTool -Name 'vivid' -ToolsPath $script:RealTools
        $cacheFile = Join-Path $Env:XDG_CACHE_HOME 'dotforge' 'ls-colors.txt'
        Set-Content -Path $cacheFile -Value 'SENTINEL-CACHED-VALUE' -Encoding UTF8

        Invoke-DFApplyLSColorsTheme -Name 'catppuccin-mocha' -Force

        $Env:LS_COLORS | Should -Not -Be 'SENTINEL-CACHED-VALUE'
        $Env:LS_COLORS | Should -Match 'di=0;38;2;137;180;250'
    }

    It 'warns and leaves LS_COLORS unchanged for an unrecognized theme name' {
        Register-DFTool -Name 'vivid' -ToolsPath $script:RealTools
        [System.Environment]::SetEnvironmentVariable('LS_COLORS', 'PRE-EXISTING', 'Process')

        $warnings = Invoke-DFApplyLSColorsTheme -Name 'not-a-real-theme' 3>&1 |
            Where-Object { $_ -is [System.Management.Automation.WarningRecord] }

        $warnings | Where-Object { $_ -match "theme 'not-a-real-theme'" } | Should -Not -BeNullOrEmpty
        $Env:LS_COLORS | Should -Be 'PRE-EXISTING'
    }

    It 'follows the shared $DFConfig[Theme] key' {
        $Global:DFConfig = @{ Theme = 'catppuccin-latte' }
        Register-DFTool -Name 'vivid' -ToolsPath $script:RealTools
        $keyFile = Join-Path $Env:XDG_CACHE_HOME 'dotforge' 'ls-colors.key'
        (Get-Content $keyFile -Raw).Trim() | Should -Be 'catppuccin-latte'
    }

    It 'lets VividTheme override the shared Theme key' {
        $Global:DFConfig = @{ Theme = 'catppuccin-latte'; VividTheme = 'catppuccin-mocha' }
        Register-DFTool -Name 'vivid' -ToolsPath $script:RealTools
        $keyFile = Join-Path $Env:XDG_CACHE_HOME 'dotforge' 'ls-colors.key'
        (Get-Content $keyFile -Raw).Trim() | Should -Be 'catppuccin-mocha'
    }

    It 'warns and no-ops when $Env:XDG_CACHE_HOME is not set' {
        $Env:XDG_CACHE_HOME = $null
        $warnings = Register-DFTool -Name 'vivid' -ToolsPath $script:RealTools 3>&1 |
            Where-Object { $_ -is [System.Management.Automation.WarningRecord] }
        $warnings | Where-Object { $_ -match 'XDG_CACHE_HOME' } | Should -Not -BeNullOrEmpty
    }
}
