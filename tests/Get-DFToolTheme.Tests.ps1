BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    function New-ThemedTool([hashtable]$Theme, [string]$Folder) {
        $record = ConvertTo-DFToolRecord ([pscustomobject]@{ name = 'themed'; executable = 'themed.exe'; theme = [pscustomobject]$Theme })
        $record.folder = $Folder
        $record
    }
}

Describe 'Resolve-DFToolTheme' {
    BeforeEach { Reset-DFTestSession; Set-DFTestXdg; Set-DFTestConfig $null }
    AfterEach { Set-DFTestConfig $null; Restore-DFTestXdg }

    It 'returns $null for a tool without a theme block' {
        $plain = ConvertTo-DFToolRecord ([pscustomobject]@{ name = 'plain'; executable = 'plain.exe' })
        Resolve-DFToolTheme -Tool $plain | Should -BeNullOrEmpty
    }
    It 'uses the per-tool key first, and marks it explicit' {
        Set-DFTestConfig @{ ThemedTheme = 'nord'; Theme = 'dracula' }
        $t = Resolve-DFToolTheme -Tool (New-ThemedTool @{ key = 'ThemedTheme'; default = 'auto' })
        $t.Name | Should -Be 'nord'; $t.Explicit | Should -BeTrue
    }
    It 'then the shared Theme, not explicit' {
        Set-DFTestConfig @{ Theme = 'dracula' }
        $t = Resolve-DFToolTheme -Tool (New-ThemedTool @{ key = 'ThemedTheme'; default = 'auto' })
        $t.Name | Should -Be 'dracula'; $t.Explicit | Should -BeFalse
    }
    It 'then the default' {
        (Resolve-DFToolTheme -Tool (New-ThemedTool @{ key = 'ThemedTheme'; default = 'auto' })).Value | Should -Be 'auto'
    }
    It 'treats -Name as explicit' {
        $t = Resolve-DFToolTheme -Tool (New-ThemedTool @{ key = 'ThemedTheme'; default = 'auto' }) -Name 'nord'
        $t.Value | Should -Be 'nord'; $t.Explicit | Should -BeTrue
    }
    It 'translates through map' {
        $t = Resolve-DFToolTheme -Tool (New-ThemedTool @{ key = 'ThemedTheme'; default = 'catppuccin-mocha'; map = [pscustomobject]@{ 'catppuccin-mocha' = 'Catppuccin Mocha' } })
        $t.Native | Should -Be 'Catppuccin Mocha'; $t.Value | Should -Be 'Catppuccin Mocha'
    }
    It 'falls back with a warning when valid rejects the name' {
        $tool = New-ThemedTool @{ key = 'ThemedTheme'; default = 'bogus'; valid = @('auto', 'dark'); fallback = 'auto' }
        $t = Resolve-DFToolTheme -Tool $tool -WarningVariable w -WarningAction SilentlyContinue
        $t.Value | Should -Be 'auto'
        "$w" | Should -Match "themed theme 'bogus' not recognized — falling back to 'auto'"
    }
    It 'resolves files from the bundled folder' {
        New-Item -ItemType Directory -Path (Join-Path $TestDrive 'tools' 'themed') -Force | Out-Null
        Set-Content (Join-Path $TestDrive 'tools' 'themed' 'nord.json') '{}'
        $t = Resolve-DFToolTheme -Tool (New-ThemedTool @{ key = 'ThemedTheme'; default = 'nord'; files = 'themed' } (Join-Path $TestDrive 'tools'))
        $t.Value | Should -Be (Join-Path $TestDrive 'tools' 'themed' 'nord.json')
    }
    It 'prefers the user''s themes folder over the bundled one' {
        New-Item -ItemType Directory -Path (Join-Path $Env:XDG_CONFIG_HOME 'themed' 'themes') -Force | Out-Null
        Set-Content (Join-Path $Env:XDG_CONFIG_HOME 'themed' 'themes' 'nord.json') '{}'
        $t = Resolve-DFToolTheme -Tool (New-ThemedTool @{ key = 'ThemedTheme'; default = 'nord'; files = 'themed' } (Join-Path $TestDrive 'tools'))
        $t.Value | Should -Be (Join-Path $Env:XDG_CONFIG_HOME 'themed' 'themes' 'nord.json')
    }
    It 'leaves the value unset, without a warning, when files has no match and there is no valid list' {
        # eza and lsd read their theme from a folder; a theme with no folder is no theme to pass.
        $tool = New-ThemedTool @{ key = 'ThemedTheme'; default = 'dracula'; files = 'themed' } (Join-Path $TestDrive 'tools')
        $t = Resolve-DFToolTheme -Tool $tool -WarningVariable w
        $t.Value | Should -BeNullOrEmpty
        $t.Name | Should -Be 'dracula'
        "$w" | Should -BeNullOrEmpty
    }
    It 'uses a valid built-in name when no file matches' {
        $t = Resolve-DFToolTheme -Tool (New-ThemedTool @{ key = 'ThemedTheme'; default = 'dark'; files = 'themed'; valid = @('dark'); fallback = 'auto' } (Join-Path $TestDrive 'tools'))
        $t.Value | Should -Be 'dark'
    }
}

Describe 'Set-DFToolThemeEnv' {
    BeforeEach { Reset-DFTestSession; Remove-Item Env:THEMED_THEME -ErrorAction Ignore }
    AfterEach { Remove-Item Env:THEMED_THEME -ErrorAction Ignore }

    It 'writes each env template with {theme} replaced' {
        $tool = New-ThemedTool @{ key = 'ThemedTheme'; default = 'nord'; env = [pscustomobject]@{ THEMED_THEME = '+{theme}' } }
        Set-DFToolThemeEnv -Tool $tool -Theme (Resolve-DFToolTheme -Tool $tool)
        $Env:THEMED_THEME | Should -Be '+nord'
    }
    It 'writes nothing when the theme resolves to no value' {
        $Env:THEMED_THEME = 'keep'
        $tool = New-ThemedTool @{ key = 'ThemedTheme'; default = 'bogus'; valid = @('a'); env = [pscustomobject]@{ THEMED_THEME = '{theme}' } }
        Set-DFToolThemeEnv -Tool $tool -Theme (Resolve-DFToolTheme -Tool $tool 3>$null)
        $Env:THEMED_THEME | Should -Be 'keep'
    }
    It 'keeps an outside value for an implicit theme' {
        $Env:THEMED_THEME = 'mine'
        $tool = New-ThemedTool @{ key = 'ThemedTheme'; default = 'nord'; env = [pscustomobject]@{ THEMED_THEME = '{theme}' } }
        Set-DFToolThemeEnv -Tool $tool -Theme (Resolve-DFToolTheme -Tool $tool)
        $Env:THEMED_THEME | Should -Be 'mine'
    }
    It 'overrides an outside value for an explicit theme, naming the config key' {
        $Env:THEMED_THEME = 'mine'
        Set-DFTestConfig @{ ThemedTheme = 'nord' }
        $tool = New-ThemedTool @{ key = 'ThemedTheme'; env = [pscustomobject]@{ THEMED_THEME = '{theme}' } }
        Set-DFToolThemeEnv -Tool $tool -Theme (Resolve-DFToolTheme -Tool $tool) -WarningVariable w -WarningAction SilentlyContinue
        $Env:THEMED_THEME | Should -Be 'nord'
        "$w" | Should -Match "THEMED_THEME was 'mine' but \`$DFConfig.ThemedTheme is 'nord'"
        Set-DFTestConfig $null
    }
}

Describe 'theme during registration' {
    BeforeEach {
        Reset-DFTestSession; Set-DFTestXdg; Set-DFTestConfig $null
        Mock Test-DFExecutableOnPath { $true }
        $script:DFToolAvailability = @{}
        $script:Tools = Join-Path $TestDrive 'regtools'
        New-Item -ItemType Directory -Path $script:Tools -Force | Out-Null
        '{ "name": "themed", "executable": "themed.exe", "theme": { "key": "ThemedTheme", "default": "nord", "env": { "THEMED_THEME": "{theme}" } } }' |
            Set-Content (Join-Path $script:Tools 'themed.json')
        Remove-Item Env:THEMED_THEME -ErrorAction Ignore
    }
    AfterEach { Remove-Item Env:THEMED_THEME -ErrorAction Ignore; Set-DFTestConfig $null; Restore-DFTestXdg }

    It 'applies theme.env and caches the theme for the session' {
        Register-DFTool -Name 'themed' -ToolsPath $script:Tools
        $Env:THEMED_THEME | Should -Be 'nord'
        Get-DFSessionThemeValue -Name 'themed' | Should -Be 'nord'
    }
    It 're-resolves on re-registration' {
        Register-DFTool -Name 'themed' -ToolsPath $script:Tools
        Set-DFTestConfig @{ ThemedTheme = 'dracula' }
        Reset-DFTestSession
        $global:DFEnvState = @{ Written = @{ THEMED_THEME = 'nord' }; Warned = @{}; Kept = @{} }
        Register-DFTool -Name 'themed' -ToolsPath $script:Tools
        $Env:THEMED_THEME | Should -Be 'dracula'
    }
}

Describe 'code-applied themes' {
    It '<_> declares its theme with a command and no env' -ForEach @('fzf', 'psreadline', 'vivid') {
        $record = Get-DFTestToolRecord $_
        $record.theme.command | Should -Not -BeNullOrEmpty
        $record.theme.env | Should -BeNullOrEmpty
    }
    It '<_> companion no longer resolves the theme chain itself' -ForEach @('fzf', 'psreadline', 'vivid', 'mdv.setup') {
        Get-Content "$PSScriptRoot/../Tools/$_.ps1" -Raw | Should -Not -Match 'Get-DFConfiguredTheme|Resolve-DFThemeName'
    }
}
