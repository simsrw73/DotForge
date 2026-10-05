BeforeAll {
    . "$PSScriptRoot/../Private/Test-DFOutputPiped.ps1"
    . "$PSScriptRoot/../Private/Write-DFFileAtomic.ps1"
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/DFCatalog.Base.ps1"
    . "$PSScriptRoot/../Private/DFReleaseData.ps1"
    . "$PSScriptRoot/../Private/ConvertTo-DFPath.ps1"
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

        # Test-Path is mocked to $false here, so a theme-not-found warning can appear too.
        @($warnings | Where-Object { $_ -match 'PSReadLineEditMode' }) | Should -Not -BeNullOrEmpty
        (Get-PSReadLineOption).EditMode | Should -Be 'Windows'
    }
}