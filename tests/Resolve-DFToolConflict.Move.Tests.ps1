BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }

    # A user tool owna whose OWN_A moves its config from ~/.owna to
    # $XDG_CONFIG_HOME/owna, with a file in the old location.
    function Initialize-MoveCase {
        Set-DFTestXdg
        $script:DFToolDb = $null
        $script:DFToolRecordCache = @{}
        $script:FakeHome = Join-Path $TestDrive 'home'
        # TestDrive lasts for the whole Describe: start each test with no files.
        Remove-Item $script:FakeHome, (Join-Path $TestDrive 'xdg') -Recurse -Force -ErrorAction Ignore
        $script:UserTools = Join-Path $Env:XDG_CONFIG_HOME 'dotforge' 'tools'
        New-Item -ItemType Directory -Force $script:UserTools | Out-Null
        [Environment]::SetEnvironmentVariable('OWN_A', $null, 'Process')
        Write-MoveRecord @{ OWN_A = '${XDG_CONFIG_HOME}/owna' } @{ OWN_A = @('${HOME}/.owna') }
        $script:Old = ConvertTo-DFPath (Join-Path $script:FakeHome '.owna')
        $script:Target = ConvertTo-DFPath (Join-Path $Env:XDG_CONFIG_HOME 'owna')
        New-Item -ItemType Directory -Force $script:Old | Out-Null
        Set-Content (Join-Path $script:Old 'cfg') 'v=1'
    }
    function Write-MoveRecord([hashtable]$Vars, [hashtable]$Native) {
        @{ name = 'owna'; executable = 'Pester'; type = 'module'; xdg = @{ method = 'env'; vars = $Vars; native = $Native } } |
            ConvertTo-Json -Depth 6 | Set-Content (Join-Path $script:UserTools 'owna.json')
        $script:DFToolRecordCache = @{}
    }
    function Get-OwnaConflict {
        $script:Tool = (Import-DFToolDb -Name owna -Force)['owna']
        @((Find-DFToolConflict -Tool $script:Tool -Ownership @{}).Conflicts)
    }
}

Describe 'Move checks' {
    BeforeEach {
        Initialize-MoveCase
        Mock Get-DFNativeRoot { if ($Name -eq 'HOME') { $script:FakeHome } }
        $script:Conflicts = Get-OwnaConflict
    }
    AfterEach { Restore-DFTestXdg }

    It 'finds nothing wrong with a plain config' {
        Get-DFMoveProblem -Tool $script:Tool -Conflicts $script:Conflicts | Should -BeNullOrEmpty
    }
    It 'refuses when the target already has files' {
        New-Item -ItemType File -Force (Join-Path $script:Target 'x') | Out-Null
        Get-DFMoveProblem -Tool $script:Tool -Conflicts $script:Conflicts | Should -Match 'already has files'
    }
    It 'refuses while the tool runs' {
        $script:Tool.type = 'exe'
        $script:Tool.executable = 'owna.exe'
        Mock Get-Process { [pscustomobject]@{ Name = 'owna' } }
        Get-DFMoveProblem -Tool $script:Tool -Conflicts $script:Conflicts | Should -Match 'close owna'
    }
    It 'reports a file that names the old location, as file:line' {
        Set-Content (Join-Path $script:Old 'hooks.ps1') "x`n. $script:Old\hook.ps1"
        Get-DFMoveProblem -Tool $script:Tool -Conflicts $script:Conflicts | Should -Match 'hooks\.ps1:2'
    }
    It 'reports a ~ spelling with forward slashes' {
        Set-Content (Join-Path $script:Old 'rc') 'include ~/.owna/more'
        Get-DFMoveProblem -Tool $script:Tool -Conflicts $script:Conflicts | Should -Match 'rc:1'
    }
    It 'ignores binary files' {
        $bytes = [byte[]](0, 1) + [Text.Encoding]::UTF8.GetBytes($script:Old)
        [IO.File]::WriteAllBytes((Join-Path $script:Old 'bin.db'), $bytes)
        Get-DFMoveProblem -Tool $script:Tool -Conflicts $script:Conflicts | Should -BeNullOrEmpty
    }
    It 'reports an environment variable that names the old location' {
        $Env:DF_TEST_OLDREF = "x;$(Join-Path $script:Old 'bin')"
        try { Get-DFMoveProblem -Tool $script:Tool -Conflicts $script:Conflicts | Should -Match 'DF_TEST_OLDREF' }
        finally { Remove-Item Env:DF_TEST_OLDREF }
    }
    It 'refuses a location marked move false, giving its guide' {
        $script:Conflicts[0].Move = $false
        $script:Conflicts[0].Guide = 'Use the mover.'
        Get-DFMoveProblem -Tool $script:Tool -Conflicts $script:Conflicts | Should -Match 'Use the mover'
    }
    It 'refuses a location that holds a link (fnm keeps its default alias as one)' {
        $elsewhere = Join-Path $TestDrive 'elsewhere'
        New-Item -ItemType Directory -Force $elsewhere | Out-Null
        $type = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
        New-Item -ItemType $type -Path (Join-Path $script:Old 'default') -Target $elsewhere | Out-Null
        Get-DFMoveProblem -Tool $script:Tool -Conflicts $script:Conflicts | Should -Match 'link'
    }
    It 'refuses two old locations with content for one path' {
        $script:Conflicts[0].OldPaths = @($script:Conflicts[0].OldPaths) + (Join-Path $TestDrive 'other')
        Get-DFMoveProblem -Tool $script:Tool -Conflicts $script:Conflicts | Should -Match 'keep one'
    }
}

Describe 'Move' {
    BeforeEach {
        Initialize-MoveCase
        Mock Get-DFNativeRoot { if ($Name -eq 'HOME') { $script:FakeHome } }
        Mock Get-Process { }
        Mock Remove-DFItemToBin { }
        Mock Write-Host { }
    }
    AfterEach { Restore-DFTestXdg }

    It 'copies, records ownership and removes the old copy' {
        $result = Resolve-DFToolConflict owna -Move -Confirm:$false
        Get-Content (Join-Path $script:Target 'cfg') | Should -Be 'v=1'
        Should -Invoke Remove-DFItemToBin -Times 1 -Exactly -ParameterFilter { $Path -eq $script:Old }
        $entry = (Read-DFToolOwnership)['owna']
        $entry.how | Should -Be 'move'
        $entry.PSObject.Properties['pending'] | Should -BeNullOrEmpty
        $result.Moved | Should -Be @($script:Target)
        Test-Path "$script:Target.dotforge-staging" | Should -BeFalse
    }
    It 'moves a single file to a target with a different name' {
        Write-MoveRecord @{ OWN_A = '${XDG_CONFIG_HOME}/owna/owna.conf' } @{ OWN_A = @('${HOME}/.ownarc') }
        Remove-Item $script:Old -Recurse -Force
        Set-Content (Join-Path $script:FakeHome '.ownarc') 'v=2'
        Resolve-DFToolConflict owna -Move -Confirm:$false | Out-Null
        Get-Content (Join-Path $script:Target 'owna.conf') | Should -Be 'v=2'
    }
    It 'changes nothing when a check fails' {
        New-Item -ItemType File -Force (Join-Path $script:Target 'x') | Out-Null
        $result = Resolve-DFToolConflict owna -Move -Confirm:$false 3>$null
        $result.Problems | Should -Match 'already has files'
        (Read-DFToolOwnership).ContainsKey('owna') | Should -BeFalse
        Should -Invoke Remove-DFItemToBin -Times 0 -Exactly
    }
    It 'removes staging and records nothing when a copy does not verify' {
        Mock Get-FileHash { [pscustomobject]@{ Hash = [guid]::NewGuid().ToString() } }
        { Resolve-DFToolConflict owna -Move -Confirm:$false -ErrorAction Stop } | Should -Throw '*verify*'
        Test-Path $script:Target | Should -BeFalse
        Test-Path "$script:Target.dotforge-staging" | Should -BeFalse
        (Read-DFToolOwnership).ContainsKey('owna') | Should -BeFalse
        Get-Content (Join-Path $script:Old 'cfg') | Should -Be 'v=1'
    }
    It 'leaves no new location behind when a later copy fails' {
        Write-MoveRecord @{ OWN_A = '${XDG_CONFIG_HOME}/owna'; OWN_B = '${XDG_CONFIG_HOME}/ownb' } @{ OWN_A = @('${HOME}/.owna'); OWN_B = @('${HOME}/.ownb') }
        New-Item -ItemType Directory -Force (Join-Path $script:FakeHome '.ownb') | Out-Null
        Set-Content (Join-Path $script:FakeHome '.ownb' 'cfg') 'b'
        # A real hash, computed directly: calling Get-FileHash from its own mock recurses.
        Mock Get-FileHash { [pscustomobject]@{ Hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($LiteralPath))) } }
        Mock Get-FileHash { [pscustomobject]@{ Hash = [guid]::NewGuid().ToString() } } -ParameterFilter { $LiteralPath -like '*ownb*' }
        { Resolve-DFToolConflict owna -Move -Confirm:$false -ErrorAction Stop } | Should -Throw '*verify*'
        Test-Path $script:Target | Should -BeFalse
        Test-Path (Join-Path $Env:XDG_CONFIG_HOME 'ownb') | Should -BeFalse
        (Read-DFToolOwnership).ContainsKey('owna') | Should -BeFalse
    }
    It 'records an old copy that is in use as pending' {
        Mock Remove-DFItemToBin { throw 'in use' }
        $result = Resolve-DFToolConflict owna -Move -Confirm:$false 3>$null
        (Read-DFToolOwnership)['owna'].pending[0].OldPath | Should -Be $script:Old
        $result.Pending | Should -Be @($script:Old)
    }
    It 'copies and records nothing with -WhatIf' {
        Resolve-DFToolConflict owna -Move -WhatIf | Out-Null
        Test-Path $script:Target | Should -BeFalse
        (Read-DFToolOwnership).ContainsKey('owna') | Should -BeFalse
    }
}
