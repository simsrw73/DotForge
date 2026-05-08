BeforeAll {
    . "$PSScriptRoot/../Private/Invoke-DFFzf.ps1"
}

Describe 'Invoke-DFFzf' {
    BeforeEach {
        $script:SavedPicker = $Env:Picker
        $Env:Picker = $null
    }
    AfterEach { $Env:Picker = $script:SavedPicker }

    It 'defaults to fzf when $Env:Picker is not set' {
        Mock Get-Command { $null }
        { Invoke-DFFzf -InputItems @() -FzfArgs @() } | Should -Throw
        Should -Invoke Get-Command -ParameterFilter { $Name -eq 'fzf' }
    }

    It 'uses the picker named in $Env:Picker' {
        $Env:Picker = 'skim'
        Mock Get-Command { $null }
        { Invoke-DFFzf -InputItems @() -FzfArgs @() } | Should -Throw
        Should -Invoke Get-Command -ParameterFilter { $Name -eq 'skim' }
    }

    It 'errors with a helpful message when the picker is not on PATH' {
        Mock Get-Command { $null }
        { Invoke-DFFzf -InputItems @('item') -FzfArgs @() } |
            Should -Throw -ExpectedMessage "*not on PATH*"
    }
}
