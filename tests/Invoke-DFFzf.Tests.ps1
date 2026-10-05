BeforeAll {
    . "$PSScriptRoot/../Private/Test-DFOutputPiped.ps1"
    . "$PSScriptRoot/../Private/Write-DFFileAtomic.ps1"
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/DFCatalog.Base.ps1"
    . "$PSScriptRoot/../Private/DFReleaseData.ps1"
    . "$PSScriptRoot/../Private/ConvertTo-DFPath.ps1"
    . "$PSScriptRoot/../Private/Get-DFConfiguredTheme.ps1"
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
