BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    $script:CompanionPath = Join-Path $PSScriptRoot '../Tools/psreadline.ps1'
}

Describe 'psreadline completion configuration' {
    BeforeEach {
        $Global:DFCurrentTool = [pscustomobject]@{
            settings = [pscustomobject]@{
                editMode = 'Windows'
            }
        }
        $script:OriginalEditMode = (Get-PSReadLineOption).EditMode

        Mock Test-Path { $false }
    }

    AfterEach {
        Set-DFTestConfig $null
        Remove-Variable DFCurrentTool -Scope Global -ErrorAction Ignore
        Remove-DFTestGlobal -Function 'Select-PSReadLineTheme', 'Invoke-DFApplyPSReadLineTheme'
        Remove-Alias fprl -Scope Global -Force -ErrorAction Ignore
        Set-PSReadLineOption -EditMode $script:OriginalEditMode
    }

    It 'uses the configured Emacs edit mode instead of the JSON Windows default' {
        Set-DFTestConfig @{ PSReadLineEditMode = 'Emacs' }

        . $script:CompanionPath

        (Get-PSReadLineOption).EditMode | Should -Be 'Emacs'
    }

    It 'warns for an invalid edit mode and retains the record option' {
        Set-DFTestConfig @{ PSReadLineEditMode = 'Vi' }

        $warnings = . $script:CompanionPath 3>&1 |
            Where-Object { $_ -is [System.Management.Automation.WarningRecord] }

        # Test-Path is mocked to $false here, so a theme-not-found warning can appear too.
        @($warnings | Where-Object { $_ -match 'PSReadLineEditMode' }) | Should -Not -BeNullOrEmpty
        (Get-PSReadLineOption).EditMode | Should -Be 'Windows'
    }
}
