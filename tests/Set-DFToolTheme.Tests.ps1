BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
}

Describe 'Set-DFToolTheme' {
    BeforeEach {
        Reset-DFTestSession; Set-DFTestXdg; Set-DFTestConfig $null
        Mock Test-DFExecutableOnPath { $true }
        $script:DFToolAvailability = @{}
        $script:Tools = Join-Path $TestDrive 'settools'
        New-Item -ItemType Directory -Path $script:Tools -Force | Out-Null
        '{ "name": "themed", "executable": "themed.exe", "theme": { "key": "ThemedTheme", "default": "nord", "valid": ["nord", "dark", "auto"], "fallback": "auto", "env": { "THEMED_THEME": "{theme}" } } }' |
            Set-Content (Join-Path $script:Tools 'themed.json')
        '{ "name": "coded", "executable": "coded.exe", "theme": { "key": "CodedTheme", "default": "nord", "command": "Select-CodedTheme" } }' |
            Set-Content (Join-Path $script:Tools 'coded.json')
        '{ "name": "seeded", "executable": "seeded.exe", "theme": { "key": "SeededTheme", "default": "nord" } }' |
            Set-Content (Join-Path $script:Tools 'seeded.json')
        '{ "name": "applied", "executable": "applied.exe", "theme": { "key": "AppliedTheme", "default": "catppuccin-mocha", "map": { "catppuccin-latte": "latte_native", "catppuccin-mocha": "mocha_native" }, "valid": ["latte_native", "mocha_native"], "fallback": "mocha_native", "apply": "Invoke-TestApply" } }' |
            Set-Content (Join-Path $script:Tools 'applied.json')
        $script:Applied = @()
        function global:Invoke-TestApply { param([string]$Name) $script:Applied += $Name }
        Remove-Item Env:THEMED_THEME -ErrorAction Ignore
    }
    AfterEach { Remove-Item Env:THEMED_THEME -ErrorAction Ignore; Remove-DFTestGlobal -Function Invoke-TestApply; Set-DFTestConfig $null; Restore-DFTestXdg }

    It 'calls the theme''s apply function with the native name' {
        Register-DFTool -Name 'applied' -ToolsPath $script:Tools
        $script:Applied = @()
        (Set-DFToolTheme -Name 'applied' -Theme 'catppuccin-latte').Value | Should -Be 'latte_native'
        $script:Applied | Should -Be @('latte_native')
    }
    It 'falls back with a warning for an unknown theme, and still applies the fallback' {
        Register-DFTool -Name 'applied' -ToolsPath $script:Tools
        $script:Applied = @()
        $null = Set-DFToolTheme -Name 'applied' -Theme 'no-such' 3>&1
        $script:Applied | Should -Be @('mocha_native')
    }

    It 'switches the theme and re-applies theme.env' {
        Register-DFTool -Name 'themed' -ToolsPath $script:Tools
        (Set-DFToolTheme -Name 'themed' -Theme 'dark').Value | Should -Be 'dark'
        $Env:THEMED_THEME | Should -Be 'dark'
        Get-DFSessionThemeValue -Name 'themed' | Should -Be 'dark'
    }
    It 'overrides a value set outside DotForge' {
        Register-DFTool -Name 'themed' -ToolsPath $script:Tools
        $Env:THEMED_THEME = 'mine'
        Set-DFToolTheme -Name 'themed' -Theme 'dark' -WarningAction SilentlyContinue | Out-Null
        $Env:THEMED_THEME | Should -Be 'dark'
    }
    It 'falls back with a warning for an unknown theme' {
        Register-DFTool -Name 'themed' -ToolsPath $script:Tools
        (Set-DFToolTheme -Name 'themed' -Theme 'bogus' -WarningAction SilentlyContinue).Value | Should -Be 'auto'
        $Env:THEMED_THEME | Should -Be 'auto'
    }
    It 'errors, without throwing, for a tool that is not active' {
        { Set-DFToolTheme -Name 'themed' -Theme 'dark' -ErrorAction SilentlyContinue -ErrorVariable e } | Should -Not -Throw
        Set-DFToolTheme -Name 'themed' -Theme 'dark' -ErrorAction SilentlyContinue -ErrorVariable e
        "$e" | Should -Match "themed isn't active"
    }
    It 'points at the companion''s command for a code-applied theme' {
        Register-DFTool -Name 'coded' -ToolsPath $script:Tools
        Set-DFToolTheme -Name 'coded' -Theme 'dark' -ErrorAction SilentlyContinue -ErrorVariable e
        "$e" | Should -Match 'Select-CodedTheme'
    }
    It 'says a setup-only theme cannot be switched live' {
        Register-DFTool -Name 'seeded' -ToolsPath $script:Tools
        Set-DFToolTheme -Name 'seeded' -Theme 'dark' -ErrorAction SilentlyContinue -ErrorVariable e
        "$e" | Should -Match "can't be switched live"
    }
}
