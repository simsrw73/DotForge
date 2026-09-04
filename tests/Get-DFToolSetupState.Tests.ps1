BeforeAll {
    . "$PSScriptRoot/../Private/Get-DFToolSetupState.ps1"
}

Describe 'Get-DFToolSetupState' {
    BeforeEach {
        $script:SavedStateHome = $Env:XDG_STATE_HOME
        $Env:XDG_STATE_HOME = Join-Path $TestDrive 'state'
    }

    AfterEach {
        $Env:XDG_STATE_HOME = $script:SavedStateHome
    }

    It 'returns an empty object when the state file does not exist' {
        $state = Get-DFToolSetupState
        @($state.PSObject.Properties).Count | Should -Be 0
    }

    It 'returns an empty object when $Env:XDG_STATE_HOME is not set' {
        $Env:XDG_STATE_HOME = $null
        { Get-DFToolSetupState } | Should -Not -Throw
        $state = Get-DFToolSetupState
        @($state.PSObject.Properties).Count | Should -Be 0
    }

    It 'returns an empty object when the state file is corrupt JSON' {
        $stateDir = Join-Path $Env:XDG_STATE_HOME 'dotforge'
        New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
        Set-Content -Path (Join-Path $stateDir 'setup-state.json') -Value '{ not valid json' -Encoding UTF8

        $state = Get-DFToolSetupState
        @($state.PSObject.Properties).Count | Should -Be 0
    }

    It 'parses an existing state file' {
        $stateDir = Join-Path $Env:XDG_STATE_HOME 'dotforge'
        New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
        @'
{ "delta": { "ranAt": "2026-09-04T10:22:00Z", "actions": [] } }
'@ | Set-Content -Path (Join-Path $stateDir 'setup-state.json') -Encoding UTF8

        $state = Get-DFToolSetupState
        $state.PSObject.Properties['delta'] | Should -Not -BeNullOrEmpty
        ([datetime]$state.delta.ranAt).ToUniversalTime() | Should -Be ([datetime]'2026-09-04T10:22:00Z').ToUniversalTime()
    }
}
