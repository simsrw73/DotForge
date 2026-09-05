BeforeAll {
    . "$PSScriptRoot/../Private/ConvertTo-DFPath.ps1"
    . "$PSScriptRoot/../Private/Expand-DFXdgPath.ps1"
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/Set-DFToolXdgConfig.ps1"
}

Describe 'Set-DFToolXdgConfig' {
    BeforeEach {
        $script:SavedConfigHome = $Env:XDG_CONFIG_HOME
        $script:SavedStateHome  = $Env:XDG_STATE_HOME
        $Env:XDG_CONFIG_HOME = Join-Path $TestDrive 'config'
        $Env:XDG_STATE_HOME  = Join-Path $TestDrive 'state'
        Remove-Item Env:\TESTXDG_CONFIG -ErrorAction Ignore
        Remove-Item Env:\TESTXDG_HIST -ErrorAction Ignore
    }
    AfterEach {
        $Env:XDG_CONFIG_HOME = $script:SavedConfigHome
        $Env:XDG_STATE_HOME  = $script:SavedStateHome
        Remove-Item Env:\TESTXDG_CONFIG -ErrorAction Ignore
        Remove-Item Env:\TESTXDG_HIST -ErrorAction Ignore
    }

    It 'method env: sets env vars and creates directories' {
        $tool = @'
{
  "name": "envtool",
  "xdg": {
    "method": "env",
    "vars": { "TESTXDG_CONFIG": "${XDG_CONFIG_HOME}/envtool/config.conf" },
    "dirs": ["${XDG_CONFIG_HOME}/envtool"]
  }
}
'@ | ConvertFrom-Json
        Set-DFToolXdgConfig -Tool $tool
        $Env:TESTXDG_CONFIG | Should -Be (Join-Path $Env:XDG_CONFIG_HOME 'envtool' 'config.conf')
        Test-Path (Join-Path $Env:XDG_CONFIG_HOME 'envtool') | Should -BeTrue
    }

    It 'method manual: warns, including instructions when present' {
        $tool = @'
{
  "name": "manualtool",
  "xdg": { "method": "manual", "instructions": "See docs/manualtool.md" }
}
'@ | ConvertFrom-Json
        Set-DFToolXdgConfig -Tool $tool -WarningVariable warns 3>$null
        $warns | Where-Object { $_ -match 'manualtool requires manual XDG configuration' -and $_ -match 'See docs/manualtool.md' } |
            Should -Not -BeNullOrEmpty
    }

    It 'method config: seeds default content only when the file is absent' {
        $tool = @'
{
  "name": "configtool",
  "xdg": {
    "method": "config",
    "config_path": "${XDG_CONFIG_HOME}/configtool/configtool.conf",
    "config_content": "default = true"
  }
}
'@ | ConvertFrom-Json
        Set-DFToolXdgConfig -Tool $tool
        $expected = Join-Path $Env:XDG_CONFIG_HOME 'configtool' 'configtool.conf'
        Get-Content $expected -Raw | Should -Be "default = true`r`n"

        Set-Content -Path $expected -Value 'user edited this' -NoNewline
        Set-DFToolXdgConfig -Tool $tool
        Get-Content $expected -Raw | Should -Be 'user edited this'
    }

    It 'method wrapper: no env/dir side effects (handled by companion)' {
        $tool = @'
{ "name": "wrappertool", "xdg": { "method": "wrapper" } }
'@ | ConvertFrom-Json
        { Set-DFToolXdgConfig -Tool $tool -Verbose } | Should -Not -Throw
    }

    It 'method default: no-op' {
        $tool = @'
{ "name": "defaulttool", "xdg": { "method": "default" } }
'@ | ConvertFrom-Json
        { Set-DFToolXdgConfig -Tool $tool } | Should -Not -Throw
    }

    It 'no xdg property at all: no-op, does not throw' {
        $tool = '{ "name": "noxdgtool" }' | ConvertFrom-Json
        { Set-DFToolXdgConfig -Tool $tool } | Should -Not -Throw
    }
}
