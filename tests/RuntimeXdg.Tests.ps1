BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    $script:Tools = Join-Path $PSScriptRoot '..' 'Tools'
    $script:Vars = 'BUN_INSTALL', 'BUN_INSTALL_CACHE_DIR', 'PNPM_HOME', 'PYTHON_HISTORY', 'PIP_CONFIG_FILE', 'PIP_CACHE_DIR', 'PIPX_HOME', 'PIPX_BIN_DIR'
}

Describe 'bun, pnpm, python, pip and pipx under XDG' {
    BeforeEach {
        Set-DFTestXdg; Reset-DFTestSession; Set-DFTestConfig $null
        $script:FakeRoot = Join-Path $TestDrive 'roots'
        # TestDrive lasts for the whole Describe: start each test with no old files and no ownership record.
        Remove-Item $script:FakeRoot, (Join-Path $TestDrive 'xdg') -Recurse -Force -ErrorAction Ignore
        Set-DFTestXdg
        Mock Get-DFNativeRoot { Join-Path $script:FakeRoot $Name }
        Mock Test-DFToolAvailable { $true }
        Mock Write-DFConflictNotice { }
        Mock Add-DFToPath { }
        $script:Saved = @{}
        foreach ($v in $script:Vars) { $script:Saved[$v] = [Environment]::GetEnvironmentVariable($v, 'Process'); [Environment]::SetEnvironmentVariable($v, $null, 'Process') }
    }
    AfterEach {
        foreach ($v in $script:Vars) { [Environment]::SetEnvironmentVariable($v, $script:Saved[$v], 'Process') }
        Restore-DFTestXdg; Set-DFTestConfig $null
    }

    It 'sets each tool''s variables to its XDG folders' {
        Start-DFSession -Config @{ Tools = @('bun', 'pnpm', 'python', 'pip', 'pipx') } -ToolsPath $script:Tools 3>$null
        $Env:BUN_INSTALL | Should -Be (Join-Path $Env:XDG_DATA_HOME 'bun')
        $Env:BUN_INSTALL_CACHE_DIR | Should -Be (Join-Path $Env:XDG_CACHE_HOME 'bun' 'install' 'cache')
        $Env:PNPM_HOME | Should -Be (Join-Path $Env:XDG_DATA_HOME 'pnpm')
        $Env:PYTHON_HISTORY | Should -Be (Join-Path $Env:XDG_STATE_HOME 'python' 'history')
        $Env:PIP_CONFIG_FILE | Should -Be (Join-Path $Env:XDG_CONFIG_HOME 'pip' 'pip.ini')
        $Env:PIP_CACHE_DIR | Should -Be (Join-Path $Env:XDG_CACHE_HOME 'pip')
        $Env:PIPX_HOME | Should -Be (Join-Path $Env:XDG_DATA_HOME 'pipx')
        $Env:PIPX_BIN_DIR | Should -BeNullOrEmpty -Because 'pipx already puts its commands in ~/.local/bin'
    }
    It 'puts bun''s and pnpm''s global bin folders on PATH' {
        Start-DFSession -Config @{ Tools = @('bun', 'pnpm') } -ToolsPath $script:Tools 3>$null
        Should -Invoke Add-DFToPath -ParameterFilter { "$Dir" -eq (Join-Path $Env:XDG_DATA_HOME 'bun' 'bin') }
        Should -Invoke Add-DFToPath -ParameterFilter { "$Dir" -eq (Join-Path $Env:XDG_DATA_HOME 'pnpm') }
    }
    It 'keeps bun, python and pip active over old homes and history, with a note that says how to move them' {
        New-Item -ItemType File -Force (Join-Path $script:FakeRoot 'HOME' '.bun' 'install' 'cache' 'x') | Out-Null
        Set-Content (Join-Path $script:FakeRoot 'HOME' '.python_history') 'print(1)'
        New-Item -ItemType File -Force (Join-Path $script:FakeRoot 'LOCALAPPDATA' 'pipx' 'pipx' 'venvs' 'x') | Out-Null
        Start-DFSession -Config @{ Tools = @('bun', 'python', 'pip', 'pipx') } -ToolsPath $script:Tools 3>$null
        foreach ($name in 'bun', 'python', 'pip', 'pipx') { (Get-DFToolStatus $name).State | Should -Be 'Active' -Because "$name never waits on its old home" }
        (Get-DFToolStatus bun).Detail | Should -Match '\.bun'
        (Get-DFToolStatus python).Detail | Should -Match 'python_history'
    }
    It 'keeps a value you set yourself' {
        $Env:PIPX_HOME = Join-Path $TestDrive 'my-pipx'
        Start-DFSession -Config @{ Tools = @('pipx') } -ToolsPath $script:Tools 3>$null
        $Env:PIPX_HOME | Should -Be (Join-Path $TestDrive 'my-pipx')
    }
    It 'still waits on an existing pip.ini, which DotForge would hide' {
        New-Item -ItemType File -Force (Join-Path $script:FakeRoot 'APPDATA' 'pip' 'pip.ini') | Out-Null
        Start-DFSession -Config @{ Tools = @('python', 'pip') } -ToolsPath $script:Tools 3>$null
        (Get-DFToolStatus pip).State | Should -Be 'Conflict'
    }
}

Describe 'a native entry that does not block' {
    It 'normalizes block, defaulting to true, and the schema wants a boolean' {
        $native = ConvertTo-DFNativeMap ('{ "A": { "paths": ["${HOME}/.a"], "move": false, "guide": "g", "block": false }, "B": ["${HOME}/.b"] }' | ConvertFrom-Json)
        $native.A.block | Should -BeFalse
        $native.B.block | Should -BeTrue
        $bad = '{ "name": "t", "executable": "t.exe", "xdg": { "method": "env", "vars": { "A": "${XDG_DATA_HOME}/a" }, "native": { "A": { "paths": ["${HOME}/.a"], "move": false, "guide": "g", "block": "no" } } } }' | ConvertFrom-Json
        "$((Test-DFToolSchema -Tool $bad).Errors)" | Should -Match 'block'
    }
}
