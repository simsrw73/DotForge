BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
}

# Handing a tool's config over to DotForge without moving anything (-Adopt),
# and clearing unfinished removals (-Done).
Describe 'Resolve-DFToolConflict' {
    BeforeEach {
        Set-DFTestXdg
        $script:DFToolDb = $null
        $script:DFToolRecordCache = @{}
        $script:FakeHome = Join-Path $TestDrive 'home'
        Remove-Item $script:FakeHome, (Join-Path $TestDrive 'xdg') -Recurse -Force -ErrorAction Ignore
        Mock Get-DFNativeRoot { if ($Name -eq 'HOME') { $script:FakeHome } }
        Mock Get-Process { }
        Mock Rename-DFOldCopy { }
        Mock Write-Host { }
        $script:UserTools = Join-Path $Env:XDG_CONFIG_HOME 'dotforge' 'tools'
        New-Item -ItemType Directory -Force $script:UserTools | Out-Null
        [Environment]::SetEnvironmentVariable('OWN_A', $null, 'Process')
        @{ name = 'owna'; executable = 'Pester'; type = 'module'
           xdg = @{ method = 'env'; vars = @{ OWN_A = '${XDG_CONFIG_HOME}/owna' }; native = @{ OWN_A = @('${HOME}/.owna') } } } |
            ConvertTo-Json -Depth 6 | Set-Content (Join-Path $script:UserTools 'owna.json')
        New-Item -ItemType File -Force (Join-Path $script:FakeHome '.owna' 'cfg') | Out-Null
    }
    AfterEach {
        $script:DFToolDb = $null
        $script:DFToolRecordCache = @{}
        Restore-DFTestXdg
    }

    It '-Adopt records ownership and moves nothing' {
        $result = Resolve-DFToolConflict owna -Adopt -Confirm:$false
        $result.Action | Should -Be 'Adopt'
        (Read-DFToolOwnership)['owna'].how | Should -Be 'adopt'
        Test-Path (Join-Path $script:FakeHome '.owna' 'cfg') | Should -BeTrue
    }
    It '-Adopt -WhatIf records nothing' {
        Resolve-DFToolConflict owna -Adopt -WhatIf | Out-Null
        (Read-DFToolOwnership).ContainsKey('owna') | Should -BeFalse
    }
    It 'says an owned tool is already owned and changes nothing' {
        Save-DFToolOwnership -Ownership @{ owna = [pscustomobject]@{ since = 'x'; how = 'clean' } }
        (Resolve-DFToolConflict owna -Adopt -Confirm:$false).Action | Should -Be 'AlreadyOwned'
        (Read-DFToolOwnership)['owna'].how | Should -Be 'clean'
    }
    It '-Done clears pending and keeps ownership' {
        Save-DFToolOwnership -Ownership @{ owna = [pscustomobject]@{ since = 'x'; how = 'move'; pending = @(@{ OldPath = 'p'; Target = 't'; Files = @() }) } }
        Resolve-DFToolConflict owna -Done -Confirm:$false | Out-Null
        $entry = (Read-DFToolOwnership)['owna']
        $entry.how | Should -Be 'move'
        $entry.PSObject.Properties['pending'] | Should -BeNullOrEmpty
    }
    It 'errors for an unknown tool' {
        { Resolve-DFToolConflict nosuch -Adopt -Confirm:$false -ErrorAction Stop 3>$null } | Should -Throw '*nosuch*'
    }
    It 'refuses when the ownership file is corrupt, and leaves it alone' {
        $path = Get-DFToolOwnershipPath
        New-DFDirectory (Split-Path $path) | Out-Null
        Set-Content $path '{ bad'
        { Resolve-DFToolConflict owna -Adopt -Confirm:$false -ErrorAction Stop 3>$null } | Should -Throw '*ownership*'
        Get-Content $path -Raw | Should -Match 'bad'
    }
}

# With no tool name: go through every tool waiting on the user.
Describe 'Resolve-DFToolConflict, guided' {
    BeforeEach {
        Set-DFTestXdg
        Remove-Item (Join-Path $TestDrive 'xdg') -Recurse -Force -ErrorAction Ignore
        Mock Write-Host { }
        $conflict = { param($Tool, $Target, [bool]$Move = $true, [bool]$InUse = $false)
            [pscustomobject]@{ Tool = $Tool; Key = 'K'; OldPaths = @("C:\old\$Tool"); Target = $Target; TargetHasContent = $InUse; Move = $Move; Guide = 'Do it by hand.' } }
        $script:Waiting = @(
            [pscustomobject]@{ Name = 'aa'; State = 'Conflict'; Detail = 'd'; Conflicts = @(& $conflict 'aa' 'C:\new\aa') }
            [pscustomobject]@{ Name = 'bb'; State = 'Conflict'; Detail = 'd'; Conflicts = @(& $conflict 'bb' 'C:\new\bb' -InUse $true) }
            [pscustomobject]@{ Name = 'cc'; State = 'Conflict'; Detail = 'd'; Conflicts = @(& $conflict 'cc' 'C:\new\cc' -Move $false) })
        Mock Get-DFToolStatus { $script:Waiting } -ParameterFilter { $Conflict }
        Mock Test-DFConflictPrompt { $true }
        Mock Import-DFToolDb { @{ $Name[0] = [pscustomobject]@{ name = $Name[0] } } }
        Mock Invoke-DFConflictMove { $Result.Action = 'Move'; $Result }
    }
    AfterEach { Restore-DFTestXdg }

    It 'offers each tool''s advised action as the default, and does what you pick' {
        Mock Read-DFConflictChoice { '' }     # Enter: take the default
        $results = @(Resolve-DFToolConflict)
        Should -Invoke Read-DFConflictChoice -Times 3 -Exactly
        Should -Invoke Read-DFConflictChoice -Times 1 -Exactly -ParameterFilter { $Default -eq 'Move' }
        Should -Invoke Read-DFConflictChoice -Times 1 -Exactly -ParameterFilter { $Default -eq 'Adopt' }
        Should -Invoke Read-DFConflictChoice -Times 1 -Exactly -ParameterFilter { $Default -eq 'Skip' }
        ($results | Where-Object Tool -eq 'aa').Action | Should -Be 'Move'
        (Read-DFToolOwnership)['bb'].how | Should -Be 'adopt'
        (Read-DFToolOwnership).ContainsKey('cc') | Should -BeFalse
    }
    It 'skips a tool you skip' {
        Mock Read-DFConflictChoice { 'S' }
        $null = Resolve-DFToolConflict
        (Read-DFToolOwnership).Count | Should -Be 0
        Should -Invoke Invoke-DFConflictMove -Times 0 -Exactly
    }
    It 'only lists the tools when it can''t ask' {
        Mock Test-DFConflictPrompt { $false }
        Mock Read-DFConflictChoice { 'A' }
        $null = Resolve-DFToolConflict
        Should -Invoke Read-DFConflictChoice -Times 0 -Exactly
        Should -Invoke Write-Host -ParameterFilter { "$Object" -match 'cc' }
        (Read-DFToolOwnership).Count | Should -Be 0
    }
    It 'says so when nothing is waiting' {
        Mock Get-DFToolStatus { } -ParameterFilter { $Conflict }
        Mock Read-DFConflictChoice { 'A' }
        $null = Resolve-DFToolConflict
        Should -Invoke Read-DFConflictChoice -Times 0 -Exactly
        Should -Invoke Write-Host -ParameterFilter { "$Object" -match 'No tools are waiting' }
    }
}
