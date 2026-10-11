BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
}

# Which tools' config DotForge owns, and whether a requested tool's old
# locations hold content DotForge would hide
# (docs/superpowers/specs/2026-10-11-config-ownership-design.md).
Describe 'Config ownership detection' {
    BeforeEach {
        Set-DFTestXdg
        $script:FakeHome = Join-Path $TestDrive 'home'
        $script:FakeApp = Join-Path $TestDrive 'appdata'
        # TestDrive lasts for the whole Describe: start each test with no files.
        Remove-Item $script:FakeHome, $script:FakeApp, (Join-Path $TestDrive 'xdg') -Recurse -Force -ErrorAction Ignore
        Mock Get-DFNativeRoot { switch ($Name) { 'HOME' { $script:FakeHome } 'APPDATA' { $script:FakeApp } default { $null } } }
        [Environment]::SetEnvironmentVariable('T_CONF', $null, 'Process')
        $script:Tool = ConvertTo-DFToolRecord ([pscustomobject]@{ name = 't'; executable = 't.exe'; xdg = [pscustomobject]@{
            method = 'env'; vars = [pscustomobject]@{ T_CONF = '${XDG_CONFIG_HOME}/t'; T_CACHE = '${XDG_CACHE_HOME}/t' }
            native = [pscustomobject]@{ T_CONF = @('${APPDATA}/t', '${HOME}/.t') } } })
    }
    AfterEach {
        [Environment]::SetEnvironmentVariable('T_CONF', $null, 'Process')
        Restore-DFTestXdg
    }

    It 'lists config, data and state variables, not caches' {
        (Get-DFToolRelocation -Tool $script:Tool).Key | Should -Be @('T_CONF')
    }
    It 'lists seed targets and native target keys' {
        $tool = ConvertTo-DFToolRecord ([pscustomobject]@{ name = 'w'; executable = 'w.exe'
            xdg = [pscustomobject]@{ method = 'wrapper'; native = [pscustomobject]@{ '${XDG_STATE_HOME}/w/history' = @('${HOME}/.w_history') } }
            setup = [pscustomobject]@{ seed = [pscustomobject]@{ '${XDG_CONFIG_HOME}/w/w.conf' = 'w/w.conf' } } })
        (Get-DFToolRelocation -Tool $tool).Key | Should -Be @('${XDG_CONFIG_HOME}/w/w.conf', '${XDG_STATE_HOME}/w/history')
    }
    It 'uses the target a setting names instead of the default (glow''s configFile)' {
        $tool = ConvertTo-DFToolRecord ([pscustomobject]@{ name = 'w'; executable = 'w.exe'
            settings = [pscustomobject]@{ configFile = (Join-Path $script:FakeHome '.w.yml') }
            xdg = [pscustomobject]@{ method = 'wrapper'; native = [pscustomobject]@{
                '${XDG_CONFIG_HOME}/w/w.yml' = [pscustomobject]@{ paths = @('${HOME}/.w.yml'); setting = 'configFile' } } } })
        Set-Content (Join-Path (New-Item -ItemType Directory -Force $script:FakeHome) '.w.yml') 'mine'
        (Get-DFToolRelocation -Tool $tool).Target | Should -Be (ConvertTo-DFPath (Join-Path $script:FakeHome '.w.yml'))
        (Find-DFToolConflict -Tool $tool -Ownership @{}).Conflicts | Should -BeNullOrEmpty
    }
    It 'finds no conflict when the old locations are absent' {
        (Find-DFToolConflict -Tool $script:Tool -Ownership @{}).Conflicts | Should -BeNullOrEmpty
    }
    It 'treats an empty old folder as nothing there' {
        New-Item -ItemType Directory -Force (Join-Path $script:FakeApp 't' 'sub') | Out-Null
        (Find-DFToolConflict -Tool $script:Tool -Ownership @{}).Conflicts | Should -BeNullOrEmpty
    }
    It 'reports a conflict when an old location has a file' {
        New-Item -ItemType File -Force (Join-Path $script:FakeApp 't' 'config') | Out-Null
        $conflicts = @((Find-DFToolConflict -Tool $script:Tool -Ownership @{}).Conflicts)
        $conflicts.Count | Should -Be 1
        $conflicts[0].OldPaths | Should -Be @(ConvertTo-DFPath (Join-Path $script:FakeApp 't'))
        $conflicts[0].Target | Should -Be (ConvertTo-DFPath (Join-Path $Env:XDG_CONFIG_HOME 't'))
        $conflicts[0].Move | Should -BeTrue
    }
    It 'reports a conflict even when the XDG location has content too' {
        New-Item -ItemType File -Force (Join-Path $script:FakeApp 't' 'config') | Out-Null
        New-Item -ItemType File -Force (Join-Path $Env:XDG_CONFIG_HOME 't' 'config') | Out-Null
        @((Find-DFToolConflict -Tool $script:Tool -Ownership @{}).Conflicts).Count | Should -Be 1
    }
    It 'skips an old path that is the target or inside it' {
        $tool = ConvertTo-DFToolRecord ([pscustomobject]@{ name = 't'; executable = 't.exe'; xdg = [pscustomobject]@{
            method = 'env'; vars = [pscustomobject]@{ T_CONF = '${XDG_CONFIG_HOME}/t' }
            native = [pscustomobject]@{ T_CONF = @('${XDG_CONFIG_HOME}/t', '${XDG_CONFIG_HOME}/t/inner') } } })
        New-Item -ItemType File -Force (Join-Path $Env:XDG_CONFIG_HOME 't' 'inner' 'x') | Out-Null
        (Find-DFToolConflict -Tool $tool -Ownership @{}).Conflicts | Should -BeNullOrEmpty
    }
    It 'makes no file-system checks for an owned tool' {
        Mock Test-DFPathHasContent { throw 'checked' }
        (Find-DFToolConflict -Tool $script:Tool -Ownership @{ t = [pscustomobject]@{ how = 'clean' } }).Conflicts | Should -BeNullOrEmpty
    }
    It 'skips a variable the user already set, and says the check is incomplete' {
        New-Item -ItemType File -Force (Join-Path $script:FakeApp 't' 'config') | Out-Null
        [Environment]::SetEnvironmentVariable('T_CONF', 'C:\mine', 'Process')
        $result = Find-DFToolConflict -Tool $script:Tool -Ownership @{}
        $result.Conflicts | Should -BeNullOrEmpty
        $result.Complete | Should -BeFalse
    }
    It 'expands an unset root to nothing, so that path is skipped' {
        Expand-DFNativePath '${LOCALAPPDATA}/t' | Should -BeNullOrEmpty
    }
    It 'expands a root and canonicalizes the path' {
        Expand-DFNativePath '${HOME}/.t/./x' | Should -Be (ConvertTo-DFPath (Join-Path $script:FakeHome '.t' 'x'))
    }
    It 'round-trips the ownership file' {
        Save-DFToolOwnership -Ownership @{ t = [pscustomobject]@{ since = 'x'; how = 'adopt' } }
        (Read-DFToolOwnership)['t'].how | Should -Be 'adopt'
    }
    It 'keeps entries another shell recorded after this one read the file' {
        Save-DFToolOwnership -Ownership @{ a = [pscustomobject]@{ since = 'x'; how = 'clean' } }
        $mine = Read-DFToolOwnership
        # Another shell adopts b meanwhile.
        Save-DFToolOwnership -Ownership @{ a = [pscustomobject]@{ since = 'x'; how = 'clean' }; b = [pscustomobject]@{ since = 'y'; how = 'adopt' } }
        $mine['c'] = [pscustomobject]@{ since = 'z'; how = 'clean' }
        Save-DFToolOwnership -Ownership $mine -Name c
        $now = Read-DFToolOwnership
        @($now.Keys | Sort-Object) | Should -Be @('a', 'b', 'c')
    }
    It 'removes an entry this shell dropped, and only that one' {
        Save-DFToolOwnership -Ownership @{ a = [pscustomobject]@{ how = 'clean' }; b = [pscustomobject]@{ how = 'adopt' } }
        $mine = Read-DFToolOwnership
        $mine.Remove('a')
        Save-DFToolOwnership -Ownership $mine -Name a
        @((Read-DFToolOwnership).Keys) | Should -Be @('b')
    }
    It 'reads a missing ownership file as empty' {
        (Read-DFToolOwnership).Count | Should -Be 0
    }
    It 'returns null when the ownership file cannot be read' {
        $path = Get-DFToolOwnershipPath
        New-DFDirectory (Split-Path $path) | Out-Null
        Set-Content $path '{ "t": { "how": "move" } }'
        Mock Get-Content { Write-Error 'The process cannot access the file because it is being used by another process.' }
        # Warns and returns null; never an error that stops a load, never an empty table that a save would write over the file.
        $ErrorActionPreference = 'Continue'   # a shell's default; the suite may run with Stop
        $result = Read-DFToolOwnership -WarningVariable warnings 2>$null 3>$null
        $null -eq $result | Should -BeTrue
        "$warnings" | Should -Match ownership
    }
    It 'returns null for a corrupt ownership file, warns, and leaves the file alone' {
        $path = Get-DFToolOwnershipPath
        New-DFDirectory (Split-Path $path) | Out-Null
        Set-Content $path '{ not json'
        Read-DFToolOwnership -WarningVariable warnings 3>$null | Should -BeNullOrEmpty
        "$warnings" | Should -Match 'ownership'
        Get-Content $path -Raw | Should -Match 'not json'
    }
}

Describe 'Get-DFNativeRoot outside the test suite' {
    It 'ignores a leftover DF_TEST_NATIVE_ROOT environment variable' {
        # A variable can outlive a test run in a live shell; only the test
        # loader's own script variable may redirect the roots.
        $savedEnv = $Env:DF_TEST_NATIVE_ROOT
        $savedVar = Get-Variable -Name DFTestNativeRoot -Scope Script -ValueOnly -ErrorAction Ignore
        try {
            $Env:DF_TEST_NATIVE_ROOT = Join-Path $TestDrive 'leaked'
            Remove-Variable -Name DFTestNativeRoot -Scope Script -ErrorAction Ignore
            Get-DFNativeRoot -Name HOME | Should -Be $HOME
        } finally {
            $Env:DF_TEST_NATIVE_ROOT = $savedEnv
            if ($null -ne $savedVar) { $script:DFTestNativeRoot = $savedVar }
        }
    }
}

Describe 'The test suite never looks in the real old config locations' {
    It 'points every native root under the test drive' {
        foreach ($name in 'HOME', 'APPDATA', 'LOCALAPPDATA') {
            Get-DFNativeRoot -Name $name | Should -BeLike "$TestDrive*"
        }
    }
}
