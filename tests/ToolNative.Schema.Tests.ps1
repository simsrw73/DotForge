BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    function New-NativeRecord($Native) {
        [pscustomobject]@{ name = 't'; executable = 't.exe'; xdg = [pscustomobject]@{
            method = 'env'; vars = [pscustomobject]@{ T_CONF = '${XDG_CONFIG_HOME}/t' }; native = $Native } }
    }
}

# xdg.native: a tool's own default locations for what DotForge relocates
# (docs/superpowers/specs/2026-10-11-config-ownership-design.md).
Describe 'xdg.native' {
    It 'normalizes a list to paths and no guide' {
        $entry = (ConvertTo-DFToolRecord (New-NativeRecord ([pscustomobject]@{ T_CONF = @('${HOME}/.t') }))).xdg.native.T_CONF
        $entry.paths | Should -Be @('${HOME}/.t')
        $entry.guide | Should -BeNullOrEmpty
        $entry.PSObject.Properties.Name | Should -Not -Contain 'move'
        $entry.PSObject.Properties.Name | Should -Not -Contain 'block'
    }
    It 'keeps an object entry''s guide' {
        $raw = [pscustomobject]@{ T_CONF = [pscustomobject]@{ paths = @('${HOME}/.t'); guide = 'do x' } }
        (ConvertTo-DFToolRecord (New-NativeRecord $raw)).xdg.native.T_CONF.guide | Should -Be 'do x'
    }
    It 'keeps the setting that can override the target' {
        $raw = [pscustomobject]@{ T_CONF = [pscustomobject]@{ paths = @('${HOME}/.t'); setting = 'configFile' } }
        (ConvertTo-DFToolRecord (New-NativeRecord $raw)).xdg.native.T_CONF.setting | Should -Be 'configFile'
        (Test-DFToolSchema (New-NativeRecord $raw)).Errors | Should -BeNullOrEmpty
    }
    It 'rejects a setting that is not text' {
        $raw = [pscustomobject]@{ T_CONF = [pscustomobject]@{ paths = @('${HOME}/.t'); setting = 3 } }
        (Test-DFToolSchema (New-NativeRecord $raw)).Errors | Should -Match 'setting'
    }
    It 'is null when absent' {
        (ConvertTo-DFToolRecord (New-NativeRecord $null)).xdg.native | Should -BeNullOrEmpty
    }
    It 'accepts an empty list (the default location is the XDG one)' {
        (Test-DFToolSchema (New-NativeRecord ([pscustomobject]@{ T_CONF = @() }))).Errors | Should -BeNullOrEmpty
    }
    It 'rejects a key that is neither a variable, a seed target nor an XDG template' {
        (Test-DFToolSchema (New-NativeRecord ([pscustomobject]@{ NOPE = @('${HOME}/.t') }))).Errors | Should -Match "xdg.native key 'NOPE'"
    }
    It 'rejects the retired move and block fields' {
        foreach ($field in 'move', 'block') {
            $raw = [pscustomobject]@{ T_CONF = [pscustomobject]@{ paths = @('${HOME}/.t'); $field = $false; guide = 'g' } }
            (Test-DFToolSchema (New-NativeRecord $raw)).Errors | Should -Match "xdg.native.T_CONF.$field was retired"
        }
    }
    It 'accepts an XDG target template as a key' {
        (Test-DFToolSchema (New-NativeRecord ([pscustomobject]@{ '${XDG_STATE_HOME}/t/history' = @('${APPDATA}/t/history') }))).Errors |
            Should -BeNullOrEmpty
    }
    It 'accepts a setup.seed target as a key' {
        $rec = New-NativeRecord ([pscustomobject]@{ '${XDG_CONFIG_HOME}/t/t.conf' = @('${HOME}/.trc') })
        $rec | Add-Member setup ([pscustomobject]@{ seed = [pscustomobject]@{ '${XDG_CONFIG_HOME}/t/t.conf' = 't/t.conf' } })
        (Test-DFToolSchema $rec).Errors | Should -BeNullOrEmpty
    }
}
