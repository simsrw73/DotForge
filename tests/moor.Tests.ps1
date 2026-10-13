BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
}

Describe 'moor theme' {
    BeforeEach {
        Reset-DFTestSession; Set-DFTestConfig $null
        $script:SavedMoor = $Env:MOOR; Remove-Item Env:MOOR -ErrorAction Ignore
        $script:Moor = Get-DFTestToolRecord moor
    }
    AfterEach {
        if ($null -eq $script:SavedMoor) { Remove-Item Env:MOOR -ErrorAction Ignore } else { $Env:MOOR = $script:SavedMoor }
        Set-DFTestConfig $null
    }

    It 'sets MOOR to the configured style and quit-if-one-screen when unset' {
        Set-DFTestConfig @{ Theme = 'catppuccin-mocha' }
        Set-DFToolThemeEnv -Tool $script:Moor -Theme (Resolve-DFToolTheme -Tool $script:Moor)
        $Env:MOOR | Should -Be '-style catppuccin-mocha -quit-if-one-screen'
    }
    It 'lets MoorTheme override the shared theme' {
        Set-DFTestConfig @{ Theme = 'catppuccin-mocha'; MoorTheme = 'dracula' }
        Set-DFToolThemeEnv -Tool $script:Moor -Theme (Resolve-DFToolTheme -Tool $script:Moor) -WarningAction SilentlyContinue
        $Env:MOOR | Should -Be '-style dracula -quit-if-one-screen'
    }
    It 'leaves a MOOR the user set alone' {
        $Env:MOOR = '-no-linenumbers'
        Set-DFToolThemeEnv -Tool $script:Moor -Theme (Resolve-DFToolTheme -Tool $script:Moor)
        $Env:MOOR | Should -Be '-no-linenumbers'
    }
}
