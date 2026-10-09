BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
}

Describe 'Test-DFToolAvailable' {
    BeforeEach { $script:DFToolAvailability = @{} }

    It 'returns $true when Get-Command finds the executable' {
        Mock Get-Command { [PSCustomObject]@{ Name = 'ripgrep.exe' } }
        Test-DFToolAvailable -Executable 'ripgrep.exe' | Should -BeTrue
    }

    It 'returns $false when Get-Command does not find the executable' {
        Mock Get-Command { $null }
        Test-DFToolAvailable -Executable 'ripgrep.exe' | Should -BeFalse
    }

    It 'checks Get-Module instead of Get-Command for -Type module' {
        Mock Get-Command { throw 'Get-Command should not be called for module-type tools' }
        Mock Get-Module { [PSCustomObject]@{ Name = 'PSFzf' } }
        Test-DFToolAvailable -Executable 'PSFzf' -Type 'module' | Should -BeTrue
    }

    It 'memoizes the result -- a second call does not re-invoke Get-Command' {
        Mock Get-Command { [PSCustomObject]@{ Name = 'ripgrep.exe' } } -Verifiable
        Test-DFToolAvailable -Executable 'ripgrep.exe' | Out-Null
        Test-DFToolAvailable -Executable 'ripgrep.exe' | Out-Null
        Should -Invoke Get-Command -Times 1 -Exactly
    }

    It 'memoizes exe and module availability separately for the same name' {
        Mock Get-Command { [PSCustomObject]@{ Name = 'foo' } }
        Mock Get-Module { $null }
        Test-DFToolAvailable -Executable 'foo' -Type 'exe' | Should -BeTrue
        Test-DFToolAvailable -Executable 'foo' -Type 'module' | Should -BeFalse
    }

    It 'does not remember "not installed": a tool put on PATH later (e.g. by fnm) is found on the next call' {
        $script:found = $false
        Mock Get-Command { if ($script:found) { [pscustomobject]@{ Path = 'C:\x\npm.cmd' } } }
        Test-DFToolAvailable -Executable 'npm.cmd' | Should -BeFalse
        $script:found = $true   # an earlier tool's companion just extended PATH
        Test-DFToolAvailable -Executable 'npm.cmd' | Should -BeTrue
    }

    It 're-probes when -Force is specified' {
        Mock Get-Command { $null }
        Test-DFToolAvailable -Executable 'ripgrep.exe' | Should -BeFalse
        Mock Get-Command { [PSCustomObject]@{ Name = 'ripgrep.exe' } }
        Test-DFToolAvailable -Executable 'ripgrep.exe' -Force | Should -BeTrue
    }
}
