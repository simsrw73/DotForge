BeforeAll {
    . "$PSScriptRoot/../Private/Get-DFConfiguredTheme.ps1"
    . "$PSScriptRoot/../Private/Resolve-DFThemeName.ps1"
    $script:CompanionPath = Join-Path $PSScriptRoot '../Tools/moor.ps1'
}

Describe 'moor companion' {
    BeforeEach {
        $script:SavedMoor = $Env:MOOR
        Remove-Item Env:MOOR -ErrorAction Ignore
        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
        $DFCurrentTool = [pscustomobject]@{ themeMap = $null }
    }
    AfterEach {
        if ($null -eq $script:SavedMoor) { Remove-Item Env:MOOR -ErrorAction Ignore } else { $Env:MOOR = $script:SavedMoor }
        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
    }

    It 'sets MOOR to the configured style and quit-if-one-screen when unset' {
        $Global:DFConfig = @{ Theme = 'catppuccin-mocha' }
        . $script:CompanionPath
        $Env:MOOR | Should -Be '-style catppuccin-mocha -quit-if-one-screen'
    }

    It 'lets MoorTheme override the shared theme' {
        $Global:DFConfig = @{ Theme = 'catppuccin-mocha'; MoorTheme = 'dracula' }
        . $script:CompanionPath
        $Env:MOOR | Should -Be '-style dracula -quit-if-one-screen'
    }

    It 'leaves a MOOR the user set alone' {
        $Env:MOOR = '-no-linenumbers'
        . $script:CompanionPath
        $Env:MOOR | Should -Be '-no-linenumbers'
    }
}
