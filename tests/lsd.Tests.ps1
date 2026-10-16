BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    $script:LsdJson = Get-Content "$PSScriptRoot/../Tools/lsd.json" -Raw | ConvertFrom-Json
    # The aliases DotForge builds for lsd when it wins listing: the role's words, lsd's flags.
    $listing = (Get-DFRoleDb -Path "$PSScriptRoot/../data/roles.json")['listing']
    $record = Get-DFTestToolRecord 'lsd'
    $script:LsdAliases = Get-DFRoleBehaviorAlias -RoleDefinition $listing -Block $record.roles.listing -Tool $record
}

Describe 'Tools/lsd.json' {
    It 'unquotes names with spaces in alias <_>' -ForEach @('ls', 'll', 'la', 'tree') {
        # lsd's spelling of eza's --no-quotes.
        $script:LsdAliases.$_.args | Should -Contain '--literal'
    }

    It 'does not emit hyperlinks in alias <_>' -ForEach @('ls', 'll', 'la', 'tree') {
        $script:LsdAliases.$_.args | Where-Object { $_ -match '^--hyperlink' } | Should -BeNullOrEmpty
    }

    It 'wraps lsd to pass your --config-file last, only when your XDG config exists' {
        $script:LsdJson.xdg.method | Should -Be 'wrapper'
        $script:LsdJson.wrapper.args[-1].ifFile | Should -Be '${XDG_CONFIG_HOME}/lsd/config.yaml'
        $script:LsdJson.wrapper.args[-1].args | Should -Be @('--config-file', '{file}')
    }
}

Describe 'lsd theme' {
    BeforeAll { $script:RealTools = Join-Path $PSScriptRoot '../Tools' }
    BeforeEach {
        Reset-DFTestSession
        $script:DFToolDb = $null; $script:DFToolAvailability = @{}
        Set-DFTestXdg
        # TestDrive lives for the whole Describe: a config one test writes must not leak into the next.
        Remove-Item $Env:XDG_CONFIG_HOME -Recurse -Force -ErrorAction Ignore
        Set-DFTestConfig $null
        Mock Test-DFToolAvailable { $true }
        Mock Write-DFConflictNotice { }
        # The "executable": the wrapper calls lsd.exe by name, so this stand-in records its arguments.
        Set-Item function:global:lsd.exe -Value { "args=$($args -join '|')" }
    }
    AfterEach {
        Set-DFTestConfig $null
        Remove-DFTestGlobal -Function 'lsd.exe', 'lsd', 'ls', 'll', 'la', 'tree', 'Select-File'
        Remove-Alias ff -Scope Global -Force -ErrorAction Ignore
        Restore-DFTestXdg
    }

    It 'resolves the theme to a bundled folder holding config.yaml and colors.yaml: <Flavor>' -ForEach @(
        @{ Flavor = 'catppuccin-mocha' }, @{ Flavor = 'catppuccin-macchiato' }, @{ Flavor = 'catppuccin-frappe' }, @{ Flavor = 'catppuccin-latte' }
    ) {
        Set-DFTestConfig @{ Theme = $Flavor }
        $value = (Get-DFToolTheme -Tool (Get-DFTestToolRecord 'lsd')).Value
        Split-Path $value -Leaf | Should -Be $Flavor
        Test-Path (Join-Path $value 'config.yaml') -PathType Leaf | Should -BeTrue
        Test-Path (Join-Path $value 'colors.yaml') -PathType Leaf | Should -BeTrue
    }

    It 'passes the theme''s config when you have no lsd config' {
        Register-DFTool -Name 'lsd' -ToolsPath $script:RealTools 3>$null 6>$null
        $expected = Join-Path (Get-DFToolTheme -Tool (Get-DFTestToolRecord 'lsd')).Value 'config.yaml'
        lsd | Should -Be "args=--config-file|$expected"
    }

    It 'passes your own config last, so it wins over the theme''s' {
        $own = Join-Path $Env:XDG_CONFIG_HOME 'lsd' 'config.yaml'
        New-Item -ItemType File -Force $own | Out-Null
        Register-DFTool -Name 'lsd' -ToolsPath $script:RealTools 3>$null 6>$null
        (lsd) -split '\|' | Select-Object -Last 2 | Should -Be @('--config-file', (ConvertTo-DFPath $own))
    }

    It 'passes no theme config for a theme without an lsd folder' {
        Set-DFTestConfig @{ Theme = 'dracula' }
        Register-DFTool -Name 'lsd' -ToolsPath $script:RealTools 3>$null 6>$null
        lsd | Should -Be 'args='
    }
}
