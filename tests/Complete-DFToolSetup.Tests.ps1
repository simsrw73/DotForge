BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
}

Describe 'Complete-DFToolSetup' {
    BeforeEach {
        Set-DFTestXdg

    }

    AfterEach {
        Restore-DFTestXdg
    }

    It 'creates the state file and records actions for a new tool' {
        Complete-DFToolSetup -Name 'delta' -Actions @(
            @{ type = 'gitConfigInclude'; path = 'C:\fake\catppuccin.gitconfig' }
        )

        $stateFile = Join-Path $Env:XDG_STATE_HOME 'dotforge' 'setup-state.json'
        Test-Path $stateFile -PathType Leaf | Should -BeTrue

        $state = Get-DFToolSetupState
        $state.delta.actions[0].type | Should -Be 'gitConfigInclude'
        $state.delta.actions[0].path | Should -Be 'C:\fake\catppuccin.gitconfig'
    }

    It 'defaults Actions to an empty array when omitted' {
        Complete-DFToolSetup -Name 'mdv'
        $state = Get-DFToolSetupState
        @($state.mdv.actions).Count | Should -Be 0
    }

    It 'overwrites an existing entry for the same tool without touching others' {
        Complete-DFToolSetup -Name 'delta' -Actions @(@{ type = 'first' })
        Complete-DFToolSetup -Name 'mdv'    -Actions @()
        Complete-DFToolSetup -Name 'delta' -Actions @(@{ type = 'second' })

        $state = Get-DFToolSetupState
        @($state.delta.actions).Count | Should -Be 1
        $state.delta.actions[0].type  | Should -Be 'second'
        $state.PSObject.Properties['mdv'] | Should -Not -BeNullOrEmpty
    }

    It 'records ranAt as a recent, valid UTC timestamp' {
        Complete-DFToolSetup -Name 'delta'
        $state = Get-DFToolSetupState
        # ConvertFrom-Json may auto-parse the ISO-8601 string to [datetime] with
        # an unpredictable Kind -- cast (a no-op if already [datetime]) then
        # normalize to UTC before comparing, per this plan's Global Constraints.
        $ranAtUtc = ([datetime]$state.delta.ranAt).ToUniversalTime()
        $ranAtUtc | Should -BeGreaterThan ([datetime]::UtcNow.AddMinutes(-5))
        $ranAtUtc | Should -BeLessThan ([datetime]::UtcNow.AddMinutes(1))
    }
}
