BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    $script:CompanionPath = Join-Path $PSScriptRoot '../Tools/moor.ps1'
}

Describe 'moor companion' {
    BeforeEach {
        $script:SavedMoor = $Env:MOOR
        Remove-Item Env:MOOR -ErrorAction Ignore
        Set-DFTestConfig $null
        $DFCurrentTool = [pscustomobject]@{ themeMap = $null }
    }
    AfterEach {
        if ($null -eq $script:SavedMoor) { Remove-Item Env:MOOR -ErrorAction Ignore } else { $Env:MOOR = $script:SavedMoor }
        Set-DFTestConfig $null
    }

    It 'sets MOOR to the configured style and quit-if-one-screen when unset' {
        Set-DFTestConfig @{ Theme = 'catppuccin-mocha' }
        . $script:CompanionPath
        $Env:MOOR | Should -Be '-style catppuccin-mocha -quit-if-one-screen'
    }

    It 'lets MoorTheme override the shared theme' {
        Set-DFTestConfig @{ Theme = 'catppuccin-mocha'; MoorTheme = 'dracula' }
        . $script:CompanionPath
        $Env:MOOR | Should -Be '-style dracula -quit-if-one-screen'
    }

    It 'leaves a MOOR the user set alone' {
        $Env:MOOR = '-no-linenumbers'
        . $script:CompanionPath
        $Env:MOOR | Should -Be '-no-linenumbers'
    }
}
