BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    Import-Module powershell-yaml -ErrorAction Stop
    $script:Pager = (Get-DFRoleDb -Path "$PSScriptRoot/../data/roles.json")['pager']
    function script:Get-OvPager {
        $tool = Get-DFTestToolRecord 'ov'
        (Get-DFRoleBehaviorEnv -RoleDefinition $script:Pager -Block $tool.roles.pager -Tool $tool)['PAGER']
    }
}

Describe 'ov' {
    BeforeEach {
        Reset-DFTestSession; Set-DFTestXdg
        Remove-Item $Env:XDG_CONFIG_HOME -Recurse -Force -ErrorAction Ignore
        Set-DFTestConfig $null
        Mock ConvertTo-DFToolExePathToken { 'ov' }
    }
    AfterEach { Set-DFTestConfig $null; Restore-DFTestXdg }

    It 'ov PAGER passes the theme''s config' {
        $cfg = Join-Path (Get-DFToolTheme -Tool (Get-DFTestToolRecord 'ov')).Value 'config.yaml'
        Get-OvPager | Should -Be "ov -F -X --config $cfg"
    }
    It 'ov with your own config passes no --config' {
        New-Item -ItemType File -Force (Join-Path $Env:XDG_CONFIG_HOME 'ov' 'config.yaml') | Out-Null
        Get-OvPager | Should -Be 'ov -F -X'
    }
    It 'ov with a theme it has no config for' {
        Set-DFTestConfig @{ Theme = 'dracula' }
        $tool = Get-DFTestToolRecord 'ov'
        $value = Get-DFRoleBehaviorEnv -RoleDefinition $script:Pager -Block $tool.roles.pager -Tool $tool -WarningVariable w
        $value['PAGER'] | Should -Be 'ov -F -X'
        "$w" | Should -BeNullOrEmpty
    }
    It 'follows OvTheme over the shared Theme' {
        Set-DFTestConfig @{ Theme = 'catppuccin-mocha'; OvTheme = 'catppuccin-latte' }
        Get-OvPager | Should -Match ([regex]::Escape((Join-Path 'catppuccin-latte' 'config.yaml')))
    }
    It 'ships a config per flavor that parses and uses the flavor''s colors: <Flavor>' -ForEach @(
        @{ Flavor = 'catppuccin-mocha'; Text = '#cdd6f4' }, @{ Flavor = 'catppuccin-macchiato'; Text = '#cad3f5' },
        @{ Flavor = 'catppuccin-frappe'; Text = '#c6d0f5' }, @{ Flavor = 'catppuccin-latte'; Text = '#4c4f69' }
    ) {
        $text = Get-Content (Join-Path $PSScriptRoot '..' 'Tools' 'ov' $Flavor 'config.yaml') -Raw
        { $text | ConvertFrom-Yaml } | Should -Not -Throw
        $text | Should -Match ([regex]::Escape($Text))
        $text | Should -Not -Match '(Foreground|Background): "(blue|lime|aqua|gray|red|yellow|white|fuchsia|crimson|lightsalmon|slateblue|darkgoldenrod|yellowgreen)"'
    }
    It 'ov accepts each bundled config' -Skip:(-not (Get-Command ov.exe -ErrorAction Ignore)) {
        foreach ($cfg in Get-ChildItem (Join-Path $PSScriptRoot '..' 'Tools' 'ov') -Recurse -Filter config.yaml) {
            & ov.exe --config $cfg.FullName --help *> $null
            $LASTEXITCODE | Should -Be 0 -Because $cfg.FullName
        }
    }
}
