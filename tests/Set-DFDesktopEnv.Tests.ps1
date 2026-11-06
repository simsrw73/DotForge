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
        (Read-DFDesktopEnvState).Vars['DESK_A'].tool | Should -Be 'deska'
        (Read-DFDesktopEnvState).Vars['DESK_A'].value | Should -Be $script:Want
    }
    It 'an equal value is AlreadySet, not recorded, and not broadcast' {
        Set-DFDesktopEnvValue -Name DESK_A -Value $script:Want
        (Set-DFDesktopEnv -Name deska -Confirm:$false).Action | Should -Be 'AlreadySet'
        Should -Invoke Send-DFEnvironmentChange -Times 0 -Exactly
        (Read-DFDesktopEnvState).Vars.ContainsKey('DESK_A') | Should -BeFalse
    }
    It 'a different value is kept, and reported, when it can''t ask' {
        Set-DFDesktopEnvValue -Name DESK_A -Value 'C:\theirs'
        $result = Set-DFDesktopEnv -Name deska -Confirm:$false
        $result.Action | Should -Be 'Kept'
        $result.Current | Should -Be 'C:\theirs'
        Get-DFDesktopEnvValue -Name DESK_A | Should -Be 'C:\theirs'
        (Read-DFDesktopEnvState).Vars.ContainsKey('DESK_A') | Should -BeFalse
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
        (Read-DFDesktopEnvState).Vars.Count | Should -Be 0
        Should -Invoke Send-DFEnvironmentChange -Times 0 -Exactly
    }
    It 'a second tool declaring the same variable doesn''t take over its record' {
        $null = Set-DFDesktopEnv -Name deska -Confirm:$false
        (Set-DFDesktopEnv -Name deskb -Confirm:$false).Action | Should -Be 'AlreadySet'
        (Read-DFDesktopEnvState).Vars['DESK_A'].tool | Should -Be 'deska'
    }
    It 'two tools in one run declaring the same variable: written once, the first one owns it' {
        $result = @(Set-DFDesktopEnv -Name deska, deskb -Confirm:$false)
        ($result | Where-Object Tool -eq deska).Action | Should -Be 'Set'
        ($result | Where-Object Tool -eq deskb).Action | Should -Be 'AlreadySet'
        (Read-DFDesktopEnvState).Vars['DESK_A'].tool | Should -Be 'deska'
    }
    It 'two tools in one run wanting different values: the second keeps the first one''s' {
        @{ name = 'deskc'; executable = 'deskc.exe'
           env = @{ DESK_A = 'C:\other' }; desktop = @('DESK_A') } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $script:UserTools 'deskc.json')
        $result = @(Set-DFDesktopEnv -Name deska, deskc -Confirm:$false)
        ($result | Where-Object Tool -eq deskc).Action | Should -Be 'Kept'
        Get-DFDesktopEnvValue -Name DESK_A | Should -Be $script:Want
        (Read-DFDesktopEnvState).Vars['DESK_A'].tool | Should -Be 'deska'
    }
    It 'writes nothing when the record can''t be saved' {
        Mock Save-DFDesktopEnvState { throw 'disk full' }
        { Set-DFDesktopEnv -Name deska -Confirm:$false -ErrorAction Stop } | Should -Throw '*disk full*'
        Get-DFDesktopEnvValue -Name DESK_A | Should -BeNullOrEmpty
        Should -Invoke Send-DFEnvironmentChange -Times 0 -Exactly
    }
    It 'says once why it writes nothing when the state file can''t be read' {
        $path = Get-DFDesktopEnvStatePath
        New-DFDirectory (Split-Path $path) | Out-Null
        Set-Content -LiteralPath $path '{ bad'
        $warnings = @(Set-DFDesktopEnv -Name deska -Confirm:$false -ErrorAction SilentlyContinue 3>&1 | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
        $warnings.Count | Should -Be 0
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
        (Read-DFDesktopEnvState).Vars.Count | Should -Be 0
    }
}

# Adding the folders records declare to the user Path, on request
# (docs/superpowers/specs/2026-11-03-desktop-path-design.md, Set-DFDesktopEnv).
Describe 'Set-DFDesktopEnv Path entries' -Skip:(-not $IsWindows) {
    BeforeEach {
        Set-DFTestXdg
        $script:DFToolDb = $null
        $script:DFToolRecordCache = @{}
        Remove-Item Env:DESK_DIR -ErrorAction Ignore
        $script:UserTools = Join-Path $Env:XDG_CONFIG_HOME 'dotforge' 'tools'
        New-Item -ItemType Directory -Force $script:UserTools | Out-Null
        # Writes deska/deskb: DESK_DIR is the variable the Path entry lives under; -Desktop names desktop variables.
        $script:WriteDesk = {
            param([string[]]$Desktop = @())
            foreach ($name in 'deska', 'deskb') {
                @{ name = $name; executable = "$name.exe"
                   xdg = @{ method = 'env'; vars = @{ DESK_A = '${XDG_CONFIG_HOME}/deska'; DESK_DIR = '${XDG_DATA_HOME}/deska' }
                            native = @{ DESK_A = @(); DESK_DIR = @() } }
                   desktop = $Desktop
                   desktopPath = @(@{ path = '${XDG_DATA_HOME}/deska/current'; commands = @('deska') }) } |
                    ConvertTo-Json -Depth 6 | Set-Content (Join-Path $script:UserTools "$name.json")
            }
            $script:DFToolDb = $null
            $script:DFToolRecordCache = @{}
        }
        & $script:WriteDesk
        $script:Folder = ConvertTo-DFPath (Join-Path $Env:XDG_DATA_HOME 'deska' 'current')
        New-Item -ItemType Directory -Force $script:Folder | Out-Null
        $script:Other = ConvertTo-DFPath (Join-Path $TestDrive 'other')
        Remove-Item -LiteralPath (Get-DFDesktopEnvStatePath) -Force -ErrorAction Ignore
        Mock Get-DFSystemPathValue { '' }
        Mock Send-DFEnvironmentChange { }
        Mock Write-Host { }
        Mock Test-DFConflictPrompt { $false }
    }
    AfterEach {
        Remove-Item -LiteralPath (Get-DFDesktopEnvKey) -Recurse -Force -ErrorAction Ignore
        Remove-Item -LiteralPath $script:Other -Recurse -Force -ErrorAction Ignore
        Remove-Item Env:DESK_DIR -ErrorAction Ignore
        $script:DFToolDb = $null
        $script:DFToolRecordCache = @{}
        Restore-DFTestXdg
    }

    It 'adds a missing folder at the end, records it, broadcasts once' {
        Set-DFUserPathValue -Value 'C:\x'
        $result = @(Set-DFDesktopEnv -Name deska -Confirm:$false)
        $result.Kind | Should -Be 'Path'
        $result.Name | Should -Be 'Path'
        $result.Value | Should -Be $script:Folder
        $result.Action | Should -Be 'Set'
        Get-DFUserPathValue | Should -Be ('C:\x;' + $script:Folder)
        (Read-DFDesktopEnvState).Path[$script:Folder].tool | Should -Be 'deska'
        Should -Invoke Send-DFEnvironmentChange -Times 1 -Exactly
        # With a variable set in the same run, still one broadcast.
        Set-DFUserPathValue -Value 'C:\x'
        Remove-Item -LiteralPath (Get-DFDesktopEnvStatePath) -Force
        & $script:WriteDesk -Desktop 'DESK_A'
        $result = @(Set-DFDesktopEnv -Name deska -Confirm:$false)
        ($result | Where-Object Kind -eq 'Variable').Action | Should -Be 'Set'
        ($result | Where-Object Kind -eq 'Path').Action | Should -Be 'Set'
        Get-DFUserPathValue | Should -Be ('C:\x;' + $script:Folder)
        Should -Invoke Send-DFEnvironmentChange -Times 2 -Exactly
    }
    It 'a differently written existing entry is AlreadySet and not recorded' {
        $written = 'C:\x;' + $script:Folder.ToUpper() + '\'
        Set-DFUserPathValue -Value $written
        $result = Set-DFDesktopEnv -Name deska -Confirm:$false
        $result.Action | Should -Be 'AlreadySet'
        $result.Current | Should -Be ($script:Folder.ToUpper() + '\')
        Get-DFUserPathValue | Should -Be $written
        (Read-DFDesktopEnvState).Path.Count | Should -Be 0
        Should -Invoke Send-DFEnvironmentChange -Times 0 -Exactly
    }
    It 'another user copy, asked: B puts it before, A at the end, S skips' {
        New-Item -ItemType Directory -Force $script:Other | Out-Null
        Set-Content (Join-Path $script:Other 'deska.cmd') '@echo off'
        Mock Test-DFConflictPrompt { $true }
        Mock Test-DFDesktopEnvShouldProcess { $true }
        $ConfirmPreference = 'High'
        $expected = @{ B = "C:\x;$($script:Folder);$($script:Other)"; A = "C:\x;$($script:Other);$($script:Folder)"; S = "C:\x;$($script:Other)" }
        foreach ($answer in 'B', 'A', 'S') {
            Set-DFUserPathValue -Value "C:\x;$($script:Other)"
            Remove-Item -LiteralPath (Get-DFDesktopEnvStatePath) -Force -ErrorAction Ignore
            $script:PathAnswer = $answer
            Mock Read-DFDesktopPathChoice { $script:PathAnswer }
            $result = Set-DFDesktopEnv -Name deska
            Get-DFUserPathValue | Should -Be $expected[$answer] -Because "the answer was $answer"
            $result.Shadowed.Path | Should -Be $script:Other
            $result.Shadowed.Scope | Should -Be 'User'
            if ($answer -eq 'S') {
                $result.Action | Should -Be 'Skipped'
                (Read-DFDesktopEnvState).Path.Count | Should -Be 0
            } else {
                $result.Action | Should -Be 'Set'
                (Read-DFDesktopEnvState).Path[$script:Folder].tool | Should -Be 'deska'
            }
        }
    }
    It 'the prompt names each other folder once and offers B only for user copies' {
        Mock Read-Host { '' }
        $user = [pscustomobject]@{ Command = 'deska'; Path = 'C:\o'; Scope = 'User'; Index = 0 }
        Read-DFDesktopPathChoice -Tool deska -Other @($user) | Should -Be 'A'
        Should -Invoke Read-Host -Times 1 -Exactly -ParameterFilter { $Prompt -match '\[B\]efore it, \[A\]fter it or \[S\]kip \(Enter: After\)' }
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { "$Object" -eq '  deska is also at C:\o (user Path).' }

        $system = [pscustomobject]@{ Command = 'deska'; Path = 'C:\sys'; Scope = 'System'; Index = -1 }
        Read-DFDesktopPathChoice -Tool deska -Other @($system, $user) | Should -Be 'A'
        Should -Invoke Read-Host -Times 1 -Exactly -ParameterFilter { $Prompt -match '\[A\]dd deska''s folder anyway or \[S\]kip \(Enter: Add\)' }
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { "$Object" -match 'C:\\sys \(system Path\), which desktop apps find first' }
        Mock Read-Host { 'b' }
        Read-DFDesktopPathChoice -Tool deska -Other @($system) | Should -Be 'A'

        # Two commands in one other folder: one line names both (calls so far never mention deskx).
        $second = [pscustomobject]@{ Command = 'deskx'; Path = 'C:\o'; Scope = 'User'; Index = 0 }
        Mock Read-Host { 'S' }
        Read-DFDesktopPathChoice -Tool deska -Other @($user, $second) | Should -Be 'S'
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { "$Object" -match 'deskx' }
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { "$Object" -eq '  deska, deskx are also at C:\o (user Path).' }
    }
    It 'unattended, another copy: appended and said so' {
        New-Item -ItemType Directory -Force $script:Other | Out-Null
        Set-Content (Join-Path $script:Other 'deska.cmd') '@echo off'
        Set-DFUserPathValue -Value "C:\x;$($script:Other)"
        Mock Test-DFConflictPrompt { $true }
        Mock Read-DFDesktopPathChoice { 'B' }
        $result = Set-DFDesktopEnv -Name deska -Confirm:$false
        $result.Action | Should -Be 'Set'
        Get-DFUserPathValue | Should -Be "C:\x;$($script:Other);$($script:Folder)"
        Should -Invoke Write-Host -ParameterFilter { "$Object" -match 'Added .* at the end of the user Path; deska at .* comes first' }
        Should -Invoke Read-DFDesktopPathChoice -Times 0 -Exactly
    }
    It 'the guard skips and says why' {
        Set-DFUserPathValue -Value 'C:\x'
        Set-DFDesktopEnvValue -Name DESK_DIR -Value 'C:\theirs'
        $result = Set-DFDesktopEnv -Name deska -Confirm:$false
        $result.Action | Should -Be 'Skipped'
        Get-DFUserPathValue | Should -Be 'C:\x'
        (Read-DFDesktopEnvState).Path.Count | Should -Be 0
        Should -Invoke Write-Host -ParameterFilter { "$Object" -match "Skipped deska's Path entry: DESK_DIR is C:\\theirs for desktop apps" }
        Should -Invoke Send-DFEnvironmentChange -Times 0 -Exactly
    }
    It 'a variable kept in the same run trips the guard; one replaced doesn''t' {
        & $script:WriteDesk -Desktop 'DESK_DIR'
        Mock Test-DFConflictPrompt { $true }
        Mock Test-DFDesktopEnvShouldProcess { $true }
        $ConfirmPreference = 'High'
        foreach ($case in @(@{ Answer = 'K'; Path = 'Skipped' }, @{ Answer = 'R'; Path = 'Set' })) {
            Set-DFUserPathValue -Value 'C:\x'
            Set-DFDesktopEnvValue -Name DESK_DIR -Value 'C:\theirs'
            Remove-Item -LiteralPath (Get-DFDesktopEnvStatePath) -Force -ErrorAction Ignore
            $answer = $case.Answer
            $script:VarAnswer = $answer
            Mock Read-DFDesktopEnvChoice { $script:VarAnswer }
            $result = @(Set-DFDesktopEnv -Name deska)
            ($result | Where-Object Kind -eq 'Path').Action | Should -Be $case.Path -Because "the variable answer was $answer"
        }
        Get-DFUserPathValue | Should -Be ('C:\x;' + $script:Folder)
    }
    It 'two tools declaring the same folder: added once, the first owns it' {
        Set-DFUserPathValue -Value 'C:\x'
        $result = @(Set-DFDesktopEnv -Name deska, deskb -Confirm:$false)
        ($result | Where-Object Tool -eq deska).Action | Should -Be 'Set'
        ($result | Where-Object Tool -eq deskb).Action | Should -Be 'AlreadySet'
        Get-DFUserPathValue | Should -Be ('C:\x;' + $script:Folder)
        (Read-DFDesktopEnvState).Path[$script:Folder].tool | Should -Be 'deska'
        (Read-DFDesktopEnvState).Path.Count | Should -Be 1
    }
    It 'a folder that doesn''t exist yet is still added' {
        Remove-Item -LiteralPath $script:Folder -Recurse -Force
        Set-DFUserPathValue -Value 'C:\x'
        (Set-DFDesktopEnv -Name deska -Confirm:$false).Action | Should -Be 'Set'
        Get-DFUserPathValue | Should -Be ('C:\x;' + $script:Folder)
    }
    It '-WhatIf asks nothing and writes nothing' {
        New-Item -ItemType Directory -Force $script:Other | Out-Null
        Set-Content (Join-Path $script:Other 'deska.cmd') '@echo off'
        Set-DFUserPathValue -Value "C:\x;$($script:Other)"
        Mock Test-DFConflictPrompt { $true }
        Mock Read-DFDesktopPathChoice { 'B' }
        $null = Set-DFDesktopEnv -Name deska -WhatIf
        Should -Invoke Read-DFDesktopPathChoice -Times 0 -Exactly
        Get-DFUserPathValue | Should -Be "C:\x;$($script:Other)"
        (Read-DFDesktopEnvState).Path.Count | Should -Be 0
        Should -Invoke Send-DFEnvironmentChange -Times 0 -Exactly
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
        Save-DFDesktopEnvState -State ([pscustomobject]@{ Vars = @{
            DESK_A = [pscustomobject]@{ tool = 'deska'; value = 'C:\one'; since = 'x' }
            DESK_B = [pscustomobject]@{ tool = 'deskb'; value = 'C:\two'; since = 'x' }
        }; Path = @{} })
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
        @((Read-DFDesktopEnvState).Vars.Keys) | Should -Be @('DESK_B')
        Should -Invoke Send-DFEnvironmentChange -Times 1 -Exactly
    }
    It 'without -Name, removes every variable DotForge wrote' {
        $null = Remove-DFDesktopEnv -Confirm:$false
        Get-DFDesktopEnvValue -Name DESK_B | Should -BeNullOrEmpty
        (Read-DFDesktopEnvState).Vars.Count | Should -Be 0
    }
    It 'leaves a variable you changed since, says so, and forgets it' {
        Set-DFDesktopEnvValue -Name DESK_A -Value 'C:\mine'
        $result = Remove-DFDesktopEnv -Name deska -Confirm:$false
        $result.Action | Should -Be 'Changed'
        Get-DFDesktopEnvValue -Name DESK_A | Should -Be 'C:\mine'
        (Read-DFDesktopEnvState).Vars.ContainsKey('DESK_A') | Should -BeFalse
        Should -Invoke Write-Host -ParameterFilter { "$Object" -match 'DESK_A' -and "$Object" -match 'mine' }
        Should -Invoke Send-DFEnvironmentChange -Times 0 -Exactly
    }
    It '-WhatIf removes nothing' {
        $null = Remove-DFDesktopEnv -Name deska -WhatIf
        Get-DFDesktopEnvValue -Name DESK_A | Should -Be 'C:\one'
        (Read-DFDesktopEnvState).Vars.ContainsKey('DESK_A') | Should -BeTrue
    }
    It 'does nothing, and says why, when the state can''t be read' {
        Set-Content -LiteralPath (Get-DFDesktopEnvStatePath) '{ bad'
        { Remove-DFDesktopEnv -Name deska -Confirm:$false -ErrorAction Stop 3>$null } | Should -Throw '*desktop-env.json*'
        Get-DFDesktopEnvValue -Name DESK_A | Should -Be 'C:\one'
    }
}
