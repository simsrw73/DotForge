BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }

    $script:McatJson = Get-Content "$PSScriptRoot/../Tools/mdcat.json" -Raw | ConvertFrom-Json
}

Describe 'Tools/mdcat.json' {
    BeforeEach { Reset-DFTestSession }
    It 'declares the default XDG method (mdcat is XDG-native)' {
        $script:McatJson.xdg.method | Should -Be 'default'
    }
    It 'declares a catppuccin MDCAT_THEME default in the theme block' {
        $script:McatJson.theme.default | Should -Be 'catppuccin-mocha'
        $script:McatJson.theme.env.MDCAT_THEME | Should -Be '{theme}'
    }
    It 'declares scoop and crates (cargo) packages' {
        $script:McatJson.packages.scoop | Should -Be 'mdcat'
        $script:McatJson.packages.crates | Should -Be 'mdcat'
    }
}

Describe 'mdcat tool sidecar' -Skip:(-not (Get-Command mdcat.exe -ErrorAction Ignore)) {
    BeforeEach { Reset-DFTestSession;
        $script:DFToolDb     = $null
        $script:DFToolAvailability = @{}
        $script:SavedTheme   = $Env:MDCAT_THEME
        Set-DFTestXdg
        $Env:MDCAT_THEME     = $null

        Remove-Item $Env:XDG_CACHE_HOME -Recurse -Force -ErrorAction Ignore
        Set-DFTestConfig $null
        $script:RealTools = Join-Path $PSScriptRoot '../Tools'
    }
    AfterEach {
        $Env:MDCAT_THEME = $script:SavedTheme
        $script:DFToolDb = $null
        Set-DFTestConfig $null
        Restore-DFTestXdg
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
}

Describe 'mdcat theme' {
    BeforeEach { Reset-DFTestSession; Set-DFTestConfig $null; Remove-Item Env:MDCAT_THEME -ErrorAction Ignore; $script:Mdcat = Get-DFTestToolRecord mdcat }
    AfterEach { Remove-Item Env:MDCAT_THEME -ErrorAction Ignore; Set-DFTestConfig $null }

    It 'defaults to catppuccin-mocha' {
        Set-DFToolThemeEnv -Tool $script:Mdcat -Theme (Resolve-DFToolTheme -Tool $script:Mdcat)
        $Env:MDCAT_THEME | Should -Be 'catppuccin-mocha'
    }
    It 'lets MdcatTheme override' {
        Set-DFTestConfig @{ MdcatTheme = 'nord' }
        Set-DFToolThemeEnv -Tool $script:Mdcat -Theme (Resolve-DFToolTheme -Tool $script:Mdcat)
        $Env:MDCAT_THEME | Should -Be 'nord'
    }
    It 'follows the shared Theme key' {
        Set-DFTestConfig @{ Theme = 'catppuccin-mocha' }
        Set-DFToolThemeEnv -Tool $script:Mdcat -Theme (Resolve-DFToolTheme -Tool $script:Mdcat)
        $Env:MDCAT_THEME | Should -Be 'catppuccin-mocha'
    }
    It 'falls back to auto with a warning for an unsupported theme' {
        Set-DFTestConfig @{ MdcatTheme = 'bogus' }
        $w = & { $theme = Resolve-DFToolTheme -Tool $script:Mdcat; Set-DFToolThemeEnv -Tool $script:Mdcat -Theme $theme } 3>&1 | Out-String
        $Env:MDCAT_THEME | Should -Be 'auto'
        $w | Should -Match "mdcat theme 'bogus' not recognized — falling back to 'auto'"
    }
    It 'tolerates a null config' {
        Set-DFTestConfig $null
        Set-DFToolThemeEnv -Tool $script:Mdcat -Theme (Resolve-DFToolTheme -Tool $script:Mdcat)
        $Env:MDCAT_THEME | Should -Be 'catppuccin-mocha'
    }
}
