BeforeAll {
    . "$PSScriptRoot/../Private/Get-DFConfiguredTheme.ps1"
    . "$PSScriptRoot/../Private/Resolve-DFThemeName.ps1"
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
        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
        Remove-Variable DFCurrentTool -Scope Global -ErrorAction Ignore
        Remove-Item 'function:global:Select-PSReadLineTheme' -ErrorAction Ignore
        Remove-Item 'function:global:Invoke-DFApplyPSReadLineTheme' -ErrorAction Ignore
        Remove-Alias fprl -Scope Global -Force -ErrorAction Ignore
        Set-PSReadLineOption -EditMode $script:OriginalEditMode
    }

    It 'uses the configured Emacs edit mode instead of the JSON Windows default' {
        $Global:DFConfig = @{ PSReadLineEditMode = 'Emacs' }

        . $script:CompanionPath

        (Get-PSReadLineOption).EditMode | Should -Be 'Emacs'
    }

    It 'warns for an invalid edit mode and retains the record option' {
        $Global:DFConfig = @{ PSReadLineEditMode = 'Vi' }

        $warnings = . $script:CompanionPath 3>&1 |
            Where-Object { $_ -is [System.Management.Automation.WarningRecord] }

        $warnings | Should -Match 'PSReadLineEditMode'
        (Get-PSReadLineOption).EditMode | Should -Be 'Windows'
    }
}