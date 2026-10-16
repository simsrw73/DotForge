BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    $script:EzaJson = Get-Content "$PSScriptRoot/../Tools/eza.json" -Raw | ConvertFrom-Json
    # The aliases DotForge builds for eza when it wins listing: the role's words, eza's flags.
    $listing = (Get-DFRoleDb -Path "$PSScriptRoot/../data/roles.json")['listing']
    $record = Get-DFTestToolRecord 'eza'
    $script:EzaAliases = Get-DFRoleBehaviorAlias -RoleDefinition $listing -Block $record.roles.listing -Tool $record

    # eza declares these with an optional value (`--icons [<WHEN>]`). Written
    # bare, clap fills the empty slot from the next positional -- so a bare
    # occurrence anywhere in an alias's args can swallow a caller's path.
    # Binding the value with `=` leaves nothing for clap to fill.
    $script:OptionalValueFlags = @('--color', '--icons', '--hyperlink')
}

Describe 'Tools/eza.json' {
    It 'binds a value to every optional-value flag in alias <_>' -ForEach @('ls', 'll', 'la', 'tree') {
        # Regression (4d29177): appending a bare `--hyperlink` to each alias
        # made `ll .` fail with "invalid value '.' for '--hyperlink [<WHEN>]'".
        $aliasArgs = $script:EzaAliases.$_.args
        foreach ($flag in $script:OptionalValueFlags) {
            $aliasArgs | Should -Not -Contain $flag -Because "$flag must be written as ${flag}=<when> so it cannot consume a path"
        }
    }

    It 'passes a path through as a positional for alias <_>' -ForEach @('ls', 'll', 'la', 'tree') {
        # Guards the whole arg list, not just the known optional-value flags:
        # no arg may be left able to absorb the trailing path.
        $aliasArgs = @($script:EzaAliases.$_.args)
        $trailing = $aliasArgs[-1]
        $trailing | Should -Match '^--[a-z-]+(=.+)?$' -Because 'trailing args must be a bound flag or a pure boolean'
        $script:OptionalValueFlags | Should -Not -Contain $trailing -Because "a trailing bare $trailing would capture the caller's path"
    }

    It 'unquotes names with spaces in alias <_>' -ForEach @('ls', 'll', 'la', 'tree') {
        $script:EzaAliases.$_.args | Should -Contain '--no-quotes'
    }

    It 'does not emit hyperlinks in alias <_>' -ForEach @('ls', 'll', 'la', 'tree') {
        $script:EzaAliases.$_.args | Where-Object { $_ -match '^--hyperlink' } | Should -BeNullOrEmpty
    }
}

Describe 'eza theme' {
    BeforeAll {
        $script:RealTools = Join-Path $PSScriptRoot '../Tools'
    }
    BeforeEach {
        Reset-DFTestSession
        $script:DFToolDb = $null; $script:DFToolAvailability = @{}
        Set-DFTestXdg
        Set-DFTestConfig $null
        # A value from the developer's own DotForge shell would be kept (Set-DFEnv).
        $script:SavedConfigDir = $Env:EZA_CONFIG_DIR
        $Env:EZA_CONFIG_DIR = $null
        $script:SavedAppData = $Env:APPDATA
        $Env:APPDATA = Join-Path $TestDrive "appdata-$([guid]::NewGuid())"
    }
    AfterEach {
        $Env:EZA_CONFIG_DIR = $script:SavedConfigDir
        $Env:APPDATA = $script:SavedAppData
        Set-DFTestConfig $null
        Remove-DFTestGlobal -Function 'ls', 'll', 'la', 'tree', 'Select-File'
        Remove-Alias ff -Scope Global -Force -ErrorAction Ignore
        Restore-DFTestXdg
    }

    It 'resolves the theme to a bundled folder holding theme.yml: <Flavor>' -ForEach @(
        @{ Flavor = 'catppuccin-mocha' }, @{ Flavor = 'catppuccin-macchiato' }, @{ Flavor = 'catppuccin-frappe' }, @{ Flavor = 'catppuccin-latte' }
    ) {
        Set-DFTestConfig @{ Theme = $Flavor }
        $theme = Get-DFToolTheme -Tool (Get-DFTestToolRecord 'eza')
        Test-Path (Join-Path $theme.Value 'theme.yml') -PathType Leaf | Should -BeTrue
        Split-Path $theme.Value -Leaf | Should -Be $Flavor
    }

    It 'points EZA_CONFIG_DIR at the theme folder' -Skip:(-not (Get-Command eza.exe -ErrorAction Ignore)) {
        Register-DFTool -Name 'eza' -ToolsPath $script:RealTools 3>$null 6>$null
        Split-Path $Env:EZA_CONFIG_DIR -Leaf | Should -Be 'catppuccin-mocha'
    }

    It 'leaves your own %APPDATA%\eza\theme.yml in effect' -Skip:(-not (Get-Command eza.exe -ErrorAction Ignore)) {
        New-Item -ItemType Directory -Force (Join-Path $Env:APPDATA 'eza') | Out-Null
        'date: {foreground: "#ff0000"}' | Set-Content (Join-Path $Env:APPDATA 'eza' 'theme.yml')
        Register-DFTool -Name 'eza' -ToolsPath $script:RealTools 3>$null 6>$null
        $Env:EZA_CONFIG_DIR | Should -BeNullOrEmpty
        (Get-DFToolStatus -Name 'eza').Detail -join ';' | Should -Match 'theme.yml'
    }

    It 'colors dates with the theme, not eza''s default blue' -Skip:(-not (Get-Command eza.exe -ErrorAction Ignore)) {
        Register-DFTool -Name 'eza' -ToolsPath $script:RealTools 3>$null 6>$null
        $line = & eza.exe --long --color=always $PSScriptRoot 2>$null | Select-Object -First 1
        $line | Should -Match ([regex]::Escape("`e[38;2;249;226;175m"))
    }
}
