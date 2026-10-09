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
    It 'sets a catppuccin MDCAT_THEME default in the env block' {
        $script:McatJson.env.MDCAT_THEME | Should -Be 'catppuccin-mocha'
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

    It 'sets MDCAT_THEME to the JSON default when no $DFConfig theme is set' {
        Register-DFTool -Name 'mdcat' -ToolsPath $script:RealTools
        $Env:MDCAT_THEME | Should -Be 'catppuccin-mocha'
    }

    It 'lets $DFConfig[MdcatTheme] override the theme' {
        Set-DFTestConfig @{ MdcatTheme = 'dracula' }
        Register-DFTool -Name 'mdcat' -ToolsPath $script:RealTools
        $Env:MDCAT_THEME | Should -Be 'dracula'
    }

    It 'maps the shared catppuccin-mocha family to catppuccin-mocha' {
        Set-DFTestConfig @{ Theme = 'catppuccin-mocha' }
        Register-DFTool -Name 'mdcat' -ToolsPath $script:RealTools
        $Env:MDCAT_THEME | Should -Be 'catppuccin-mocha'
    }

    It 'falls back to auto for an unsupported theme name' {
        Set-DFTestConfig @{ MdcatTheme = 'no-such-theme' }
        Register-DFTool -Name 'mdcat' -ToolsPath $script:RealTools -WarningAction SilentlyContinue
        $Env:MDCAT_THEME | Should -Be 'auto'
    }

    It 'tolerates $DFConfig being set to $null' {
        Set-DFTestConfig $null
        { Register-DFTool -Name 'mdcat' -ToolsPath $script:RealTools } | Should -Not -Throw
    }
}
