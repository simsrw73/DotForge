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
    . "$PSScriptRoot/../Private/Get-DFCachedCommandOutput.ps1"
    . "$PSScriptRoot/../Private/Invoke-DFToolCompanion.ps1"
    . "$PSScriptRoot/../Public/Register-DFTool.ps1"

    $script:McatJson = Get-Content "$PSScriptRoot/../Tools/mdcat.json" -Raw | ConvertFrom-Json
}

Describe 'Tools/mdcat.json' {
    It 'declares the default XDG method (mdcat is XDG-native)' {
        $script:McatJson.xdg.method | Should -Be 'default'
    }
    It 'sets a catppuccin MDCAT_THEME default in the env block' {
        $script:McatJson.env.MDCAT_THEME | Should -Be 'catppuccin-mocha'
    }
    It 'declares scoop and cargo packages' {
        $script:McatJson.packages.scoop | Should -Be 'mdcat'
        $script:McatJson.packages.cargo | Should -Be 'mdcat'
    }
}

Describe 'mdcat tool sidecar' -Skip:(-not (Get-Command mdcat.exe -ErrorAction Ignore)) {
    BeforeEach {
        $script:DFToolDb     = $null
        $script:DFToolAvailability = @{}
        $script:SavedTheme   = $Env:MDCAT_THEME
        $script:SavedCacheHome = $Env:XDG_CACHE_HOME
        $Env:MDCAT_THEME     = $null
        $Env:XDG_CACHE_HOME  = Join-Path $TestDrive 'cache'
        Remove-Item $Env:XDG_CACHE_HOME -Recurse -Force -ErrorAction Ignore
        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
        $script:RealTools = Join-Path $PSScriptRoot '../Tools'
    }
    AfterEach {
        $Env:MDCAT_THEME = $script:SavedTheme
        $Env:XDG_CACHE_HOME = $script:SavedCacheHome
        $script:DFToolDb = $null
        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
    }

    It 'caches the real completion script, and does not regenerate it on a second registration' {
        # Genuinely calls the real mdcat binary -- see carapace.Tests.ps1 for why
        # a function/Mock stand-in would defeat this test (no fingerprintable
        # .Source for Get-DFCachedCommandOutput to key the cache on).
        Register-DFTool -Name 'mdcat' -ToolsPath $script:RealTools
        $cacheFile = Join-Path $Env:XDG_CACHE_HOME 'dotforge' 'mdcat-completions.txt'
        Test-Path $cacheFile | Should -BeTrue
        $writtenAfterFirst = (Get-Item $cacheFile).LastWriteTimeUtc

        Start-Sleep -Milliseconds 50
        Register-DFTool -Name 'mdcat' -ToolsPath $script:RealTools

        (Get-Item $cacheFile).LastWriteTimeUtc | Should -Be $writtenAfterFirst
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

    It 'maps the shared catppuccin-mocha family to catppuccin-mocha' {
        $Global:DFConfig = @{ Theme = 'catppuccin-mocha' }
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
