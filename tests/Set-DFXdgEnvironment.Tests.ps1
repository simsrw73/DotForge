BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
}

Describe 'Set-DFXdgEnvironment' {
    BeforeEach {
        Set-DFTestXdg
        $script:SavedBin = $Env:XDG_BIN_HOME
        $Env:XDG_BIN_HOME = Join-Path $TestDrive 'xdg' 'bin'
    }
    AfterEach {
        Restore-DFTestXdg
        $Env:XDG_BIN_HOME = $script:SavedBin
    }

    It 'exports all five folders and creates them' {
        Set-DFXdgEnvironment
        foreach ($k in 'CONFIG', 'DATA', 'STATE', 'CACHE', 'BIN') {
            $v = [Environment]::GetEnvironmentVariable("XDG_${k}_HOME")
            $v | Should -BeLike "$TestDrive*"
            Test-Path $v -PathType Container | Should -BeTrue
        }
    }
    It 'keeps a value the user set' {
        $mine = Join-Path $TestDrive 'mine'
        $Env:XDG_CONFIG_HOME = $mine
        Set-DFXdgEnvironment
        $Env:XDG_CONFIG_HOME | Should -Be $mine
    }
    It 'fills in the XDG default for an unset folder, without creating it outside the test folder' {
        Remove-Item Env:XDG_DATA_HOME
        Mock New-DFDirectory { }
        Set-DFXdgEnvironment
        $Env:XDG_DATA_HOME | Should -Be (Join-Path $HOME '.local' 'share')
    }
    It 'canonicalizes a ~-rooted value the user set' {
        $Env:XDG_CACHE_HOME = '~/df-xdg-test-cache'
        Mock New-DFDirectory { }
        Set-DFXdgEnvironment
        $Env:XDG_CACHE_HOME | Should -Be (Join-Path $HOME 'df-xdg-test-cache')
    }
    It 'is idempotent' {
        Set-DFXdgEnvironment
        { Set-DFXdgEnvironment } | Should -Not -Throw
    }
}
