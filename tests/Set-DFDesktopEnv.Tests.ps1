BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
}

# Writing the desktop variables records suggest, on request
# (docs/superpowers/specs/2026-10-26-desktop-variables-design.md).
Describe 'Set-DFDesktopEnv' -Skip:(-not $IsWindows) {
    BeforeEach {
        Set-DFTestXdg
        $script:DFToolDb = $null
        $script:DFToolRecordCache = @{}
        $script:UserTools = Join-Path $Env:XDG_CONFIG_HOME 'dotforge' 'tools'
        New-Item -ItemType Directory -Force $script:UserTools | Out-Null
        foreach ($name in 'deska', 'deskb') {
            @{ name = $name; executable = "$name.exe"
               xdg = @{ method = 'env'; vars = @{ DESK_A = '${XDG_CONFIG_HOME}/deska' }; native = @{ DESK_A = @() } }
               desktop = @('DESK_A') } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $script:UserTools "$name.json")
        }
        $script:Want = ConvertTo-DFPath (Join-Path $Env:XDG_CONFIG_HOME 'deska')
        # TestDrive lasts for the whole Describe: start each test with no state.
        Remove-Item -LiteralPath (Get-DFDesktopEnvStatePath) -Force -ErrorAction Ignore
        Mock Send-DFEnvironmentChange { }
        Mock Write-Host { }
        Mock Test-DFConflictPrompt { $false }
    }
    AfterEach {
        Remove-Item -LiteralPath (Get-DFDesktopEnvKey) -Recurse -Force -ErrorAction Ignore
        $script:DFToolDb = $null
        $script:DFToolRecordCache = @{}
        Restore-DFTestXdg
    }

    It 'writes a missing variable, broadcasts once and records it' {
        $result = @(Set-DFDesktopEnv -Name deska -Confirm:$false)
        $result.Action | Should -Be 'Set'
        Get-DFDesktopEnvValue -Name DESK_A | Should -Be $script:Want
        Should -Invoke Send-DFEnvironmentChange -Times 1 -Exactly
        (Read-DFDesktopEnvState)['DESK_A'].tool | Should -Be 'deska'
        (Read-DFDesktopEnvState)['DESK_A'].value | Should -Be $script:Want
    }
    It 'an equal value is AlreadySet, recorded, and not broadcast' {
        Set-DFDesktopEnvValue -Name DESK_A -Value $script:Want
        (Set-DFDesktopEnv -Name deska -Confirm:$false).Action | Should -Be 'AlreadySet'
        Should -Invoke Send-DFEnvironmentChange -Times 0 -Exactly
        (Read-DFDesktopEnvState)['DESK_A'].tool | Should -Be 'deska'
    }
    It 'a different value is kept, and reported, when it can''t ask' {
        Set-DFDesktopEnvValue -Name DESK_A -Value 'C:\theirs'
        $result = Set-DFDesktopEnv -Name deska -Confirm:$false
        $result.Action | Should -Be 'Kept'
        $result.Current | Should -Be 'C:\theirs'
        Get-DFDesktopEnvValue -Name DESK_A | Should -Be 'C:\theirs'
        (Read-DFDesktopEnvState).ContainsKey('DESK_A') | Should -BeFalse
        Should -Invoke Write-Host -ParameterFilter { "$Object" -match 'DESK_A' -and "$Object" -match 'theirs' }
    }
    It 'asks per differing variable in a console; R replaces' {
        Set-DFDesktopEnvValue -Name DESK_A -Value 'C:\theirs'
        Mock Test-DFConflictPrompt { $true }
        Mock Read-DFDesktopEnvChoice { 'R' }
        $ConfirmPreference = 'High'
        Mock Test-DFDesktopEnvShouldProcess { $true }
        (Set-DFDesktopEnv -Name deska).Action | Should -Be 'Replaced'
        Get-DFDesktopEnvValue -Name DESK_A | Should -Be $script:Want
        Should -Invoke Read-DFDesktopEnvChoice -Times 1 -Exactly
    }
    It '-Confirm:$false never asks, and keeps yours' {
        Set-DFDesktopEnvValue -Name DESK_A -Value 'C:\theirs'
        Mock Test-DFConflictPrompt { $true }
        Mock Read-DFDesktopEnvChoice { 'R' }
        (Set-DFDesktopEnv -Name deska -Confirm:$false).Action | Should -Be 'Kept'
        Should -Invoke Read-DFDesktopEnvChoice -Times 0 -Exactly
    }
    It '-WhatIf writes and records nothing' {
        $null = Set-DFDesktopEnv -Name deska -WhatIf
        Get-DFDesktopEnvValue -Name DESK_A | Should -BeNullOrEmpty
        (Read-DFDesktopEnvState).Count | Should -Be 0
        Should -Invoke Send-DFEnvironmentChange -Times 0 -Exactly
    }
    It 'a second tool declaring the same variable doesn''t take over its record' {
        $null = Set-DFDesktopEnv -Name deska -Confirm:$false
        (Set-DFDesktopEnv -Name deskb -Confirm:$false).Action | Should -Be 'AlreadySet'
        (Read-DFDesktopEnvState)['DESK_A'].tool | Should -Be 'deska'
    }
    It 'two tools in one run declaring the same variable: written once, the first one owns it' {
        $result = @(Set-DFDesktopEnv -Name deska, deskb -Confirm:$false)
        ($result | Where-Object Tool -eq deska).Action | Should -Be 'Set'
        ($result | Where-Object Tool -eq deskb).Action | Should -Be 'AlreadySet'
        (Read-DFDesktopEnvState)['DESK_A'].tool | Should -Be 'deska'
    }
    It 'two tools in one run wanting different values: the second keeps the first one''s' {
        @{ name = 'deskc'; executable = 'deskc.exe'
           env = @{ DESK_A = 'C:\other' }; desktop = @('DESK_A') } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $script:UserTools 'deskc.json')
        $result = @(Set-DFDesktopEnv -Name deska, deskc -Confirm:$false)
        ($result | Where-Object Tool -eq deskc).Action | Should -Be 'Kept'
        Get-DFDesktopEnvValue -Name DESK_A | Should -Be $script:Want
        (Read-DFDesktopEnvState)['DESK_A'].tool | Should -Be 'deska'
    }
    It 'writes nothing when the state file can''t be read' {
        $path = Get-DFDesktopEnvStatePath
        New-DFDirectory (Split-Path $path) | Out-Null
        Set-Content -LiteralPath $path '{ bad'
        { Set-DFDesktopEnv -Name deska -Confirm:$false -ErrorAction Stop 3>$null } | Should -Throw '*desktop-env.json*'
        Get-DFDesktopEnvValue -Name DESK_A | Should -BeNullOrEmpty
    }
    It 'without -Name, covers the session''s requested tools' {
        Mock Get-DFToolStatus { [pscustomobject]@{ Name = 'deska'; State = 'Missing' }; [pscustomobject]@{ Name = 'deskb'; State = 'Excluded' } }
        $result = @(Set-DFDesktopEnv -Confirm:$false)
        $result.Tool | Should -Be @('deska')
    }
    It 'without -Name and without a session, asks for -Name' {
        Mock Get-DFToolStatus { }
        { Set-DFDesktopEnv -Confirm:$false -ErrorAction Stop } | Should -Throw '*-Name*'
    }
    It 'errors for an unknown tool' {
        { Set-DFDesktopEnv -Name nosuch -Confirm:$false -ErrorAction Stop } | Should -Throw '*nosuch*'
    }
    It 'says it''s Windows-only off Windows, and writes nothing' {
        Mock Test-DFIsWindows { $false }
        $null = Set-DFDesktopEnv -Name deska -Confirm:$false
        Should -Invoke Write-Host -ParameterFilter { "$Object" -match 'Windows' }
        (Read-DFDesktopEnvState).Count | Should -Be 0
    }
}

# Taking desktop variables back out: only what DotForge wrote, only while unchanged.
Describe 'Remove-DFDesktopEnv' -Skip:(-not $IsWindows) {
    BeforeEach {
        Set-DFTestXdg
        Remove-Item -LiteralPath (Get-DFDesktopEnvStatePath) -Force -ErrorAction Ignore
        Mock Send-DFEnvironmentChange { }
        Mock Write-Host { }
        Set-DFDesktopEnvValue -Name DESK_A -Value 'C:\one'
        Set-DFDesktopEnvValue -Name DESK_B -Value 'C:\two'
        Save-DFDesktopEnvState -State @{
            DESK_A = [pscustomobject]@{ tool = 'deska'; value = 'C:\one'; since = 'x' }
            DESK_B = [pscustomobject]@{ tool = 'deskb'; value = 'C:\two'; since = 'x' }
        }
    }
    AfterEach {
        Remove-Item -LiteralPath (Get-DFDesktopEnvKey) -Recurse -Force -ErrorAction Ignore
        Restore-DFTestXdg
    }

    It 'removes a variable DotForge wrote, and its record, broadcasting once' {
        $result = @(Remove-DFDesktopEnv -Name deska -Confirm:$false)
        $result.Action | Should -Be 'Removed'
        Get-DFDesktopEnvValue -Name DESK_A | Should -BeNullOrEmpty
        Get-DFDesktopEnvValue -Name DESK_B | Should -Be 'C:\two'
        @((Read-DFDesktopEnvState).Keys) | Should -Be @('DESK_B')
        Should -Invoke Send-DFEnvironmentChange -Times 1 -Exactly
    }
    It 'without -Name, removes every variable DotForge wrote' {
        $null = Remove-DFDesktopEnv -Confirm:$false
        Get-DFDesktopEnvValue -Name DESK_B | Should -BeNullOrEmpty
        (Read-DFDesktopEnvState).Count | Should -Be 0
    }
    It 'leaves a variable you changed since, says so, and forgets it' {
        Set-DFDesktopEnvValue -Name DESK_A -Value 'C:\mine'
        $result = Remove-DFDesktopEnv -Name deska -Confirm:$false
        $result.Action | Should -Be 'Changed'
        Get-DFDesktopEnvValue -Name DESK_A | Should -Be 'C:\mine'
        (Read-DFDesktopEnvState).ContainsKey('DESK_A') | Should -BeFalse
        Should -Invoke Write-Host -ParameterFilter { "$Object" -match 'DESK_A' -and "$Object" -match 'mine' }
        Should -Invoke Send-DFEnvironmentChange -Times 0 -Exactly
    }
    It '-WhatIf removes nothing' {
        $null = Remove-DFDesktopEnv -Name deska -WhatIf
        Get-DFDesktopEnvValue -Name DESK_A | Should -Be 'C:\one'
        (Read-DFDesktopEnvState).ContainsKey('DESK_A') | Should -BeTrue
    }
    It 'does nothing, and says why, when the state can''t be read' {
        Set-Content -LiteralPath (Get-DFDesktopEnvStatePath) '{ bad'
        { Remove-DFDesktopEnv -Name deska -Confirm:$false -ErrorAction Stop 3>$null } | Should -Throw '*desktop-env.json*'
        Get-DFDesktopEnvValue -Name DESK_A | Should -Be 'C:\one'
    }
}
