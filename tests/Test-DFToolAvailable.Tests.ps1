BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
}

Describe 'Test-DFToolAvailable' {
    BeforeEach { $script:DFToolAvailability = @{} }

    It 'asks the PATH probe for an executable' {
        Mock Test-DFExecutableOnPath { $Name -eq 'ripgrep.exe' }
        Test-DFToolAvailable -Executable 'ripgrep.exe' | Should -BeTrue
        Test-DFToolAvailable -Executable 'nope.exe' | Should -BeFalse
    }

    It 'asks the module probe for -Type module' {
        Mock Test-DFExecutableOnPath { throw 'the PATH probe must not be used for module-type tools' }
        Mock Test-DFModuleOnPath { $Name -eq 'PSFzf' }
        Test-DFToolAvailable -Executable 'PSFzf' -Type 'module' | Should -BeTrue
    }

    It 'memoizes the result -- a second call does not probe again' {
        Mock Test-DFExecutableOnPath { $true }
        Test-DFToolAvailable -Executable 'ripgrep.exe' | Out-Null
        Test-DFToolAvailable -Executable 'ripgrep.exe' | Out-Null
        Should -Invoke Test-DFExecutableOnPath -Times 1 -Exactly
    }

    It 'memoizes exe and module availability separately for the same name' {
        Mock Test-DFExecutableOnPath { $true }
        Mock Test-DFModuleOnPath { $false }
        Test-DFToolAvailable -Executable 'foo' -Type 'exe' | Should -BeTrue
        Test-DFToolAvailable -Executable 'foo' -Type 'module' | Should -BeFalse
    }

    It 'does not remember "not installed": a tool put on PATH later (e.g. by fnm) is found on the next call' {
        $script:found = $false
        Mock Test-DFExecutableOnPath { $script:found }
        Test-DFToolAvailable -Executable 'npm.cmd' | Should -BeFalse
        $script:found = $true   # an earlier tool's companion just extended PATH
        Test-DFToolAvailable -Executable 'npm.cmd' | Should -BeTrue
    }

    It 're-probes when -Force is specified' {
        Mock Test-DFExecutableOnPath { $true }
        Test-DFToolAvailable -Executable 'ripgrep.exe' | Should -BeTrue
        Test-DFToolAvailable -Executable 'ripgrep.exe' -Force | Should -BeTrue
        Should -Invoke Test-DFExecutableOnPath -Times 2 -Exactly
    }
}

Describe 'Test-DFExecutableOnPath' {
    BeforeAll {
        $script:Bin = Join-Path $TestDrive 'bin'
        New-Item -ItemType Directory $script:Bin | Out-Null
        Set-Content (Join-Path $script:Bin 'tool.cmd') '@echo off'
        Set-Content (Join-Path $script:Bin 'plain.exe') ''
        $script:Path = "$(Join-Path $TestDrive 'missing');$script:Bin"
    }
    It 'finds a name with its extension' {
        Test-DFExecutableOnPath -Name 'plain.exe' -PathValue $script:Path -PathExt '.COM;.EXE;.CMD' | Should -BeTrue
    }
    It 'finds a bare name through PATHEXT (pipx is pipx.cmd from scoop, pipx.exe from pip)' {
        Test-DFExecutableOnPath -Name 'tool' -PathValue $script:Path -PathExt '.COM;.EXE;.CMD' | Should -BeTrue
    }
    It 'is false when no PATH folder has it, and skips folders that don''t exist' {
        Test-DFExecutableOnPath -Name 'absent.exe' -PathValue $script:Path -PathExt '.EXE' | Should -BeFalse
    }
    It 'agrees with Get-Command for every shipped tool on this machine' {
        $db = Import-DFToolDb -ToolsPath "$PSScriptRoot/../Tools" -Force
        foreach ($t in $db.Values | Where-Object type -ne 'module') {
            (Test-DFExecutableOnPath -Name $t.executable) | Should -Be ([bool](Get-Command $t.executable -CommandType Application -ErrorAction Ignore)) -Because $t.executable
        }
    }
}

Describe 'Test-DFModuleOnPath' {
    It 'finds a module folder under a PSModulePath root' {
        $root = Join-Path $TestDrive 'mods'
        New-Item -ItemType Directory (Join-Path $root 'MyMod') -Force | Out-Null
        Test-DFModuleOnPath -Name 'MyMod' -ModulePath "$(Join-Path $TestDrive 'none');$root" | Should -BeTrue
        Test-DFModuleOnPath -Name 'Other' -ModulePath $root | Should -BeFalse
    }
    It 'agrees with Get-Module -ListAvailable for every shipped module tool on this machine' {
        $db = Import-DFToolDb -ToolsPath "$PSScriptRoot/../Tools" -Force
        foreach ($t in $db.Values | Where-Object type -eq 'module') {
            (Test-DFModuleOnPath -Name $t.executable) | Should -Be ([bool](Get-Module -ListAvailable -Name $t.executable)) -Because $t.executable
        }
    }
}
