BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
}

# Keeping a tool's existing data when the XDG location holds content too (-Adopt): the XDG copy is
# set aside, never deleted, and the XDG location linked to the existing data.
Describe 'Resolve-DFToolConflict' {
    BeforeEach {
        Set-DFTestXdg
        $script:DFToolDb = $null
        $script:DFToolRecordCache = @{}
        $script:FakeHome = Join-Path $TestDrive 'home'
        Remove-Item $script:FakeHome, (Join-Path $TestDrive 'xdg') -Recurse -Force -ErrorAction Ignore
        Mock Get-DFNativeRoot { if ($Name -eq 'HOME') { $script:FakeHome } }
        Mock Write-Host { }
        $script:UserTools = Join-Path $Env:XDG_CONFIG_HOME 'dotforge' 'tools'
        New-Item -ItemType Directory -Force $script:UserTools | Out-Null
        [Environment]::SetEnvironmentVariable('OWN_A', $null, 'Process')
        @{ name = 'owna'; executable = 'Pester'; type = 'module'
           xdg = @{ method = 'env'; vars = @{ OWN_A = '${XDG_CONFIG_HOME}/owna' }; native = @{ OWN_A = @('${HOME}/.owna') } } } |
            ConvertTo-Json -Depth 6 | Set-Content (Join-Path $script:UserTools 'owna.json')
        New-Item -ItemType File -Force (Join-Path $script:FakeHome '.owna' 'cfg') | Out-Null
        Set-Content (Join-Path $Env:XDG_CONFIG_HOME 'owna' 'cfg') 'xdg copy' -Force -ErrorAction Ignore
        if (-not (Test-Path (Join-Path $Env:XDG_CONFIG_HOME 'owna' 'cfg'))) {
            New-Item -ItemType Directory -Force (Join-Path $Env:XDG_CONFIG_HOME 'owna') | Out-Null
            Set-Content (Join-Path $Env:XDG_CONFIG_HOME 'owna' 'cfg') 'xdg copy'
        }
        $script:Xdg = ConvertTo-DFPath (Join-Path $Env:XDG_CONFIG_HOME 'owna')
        $script:Old = ConvertTo-DFPath (Join-Path $script:FakeHome '.owna')
    }
    AfterEach {
        $script:DFToolDb = $null
        $script:DFToolRecordCache = @{}
        Restore-DFTestXdg
    }

    It '-Adopt sets the XDG copy aside and links to the existing data' {
        $result = Resolve-DFToolConflict owna -Adopt -Confirm:$false
        $result.Action | Should -Be 'Adopt'
        Get-DFToolLinkTarget -Path $script:Xdg | Should -Be $script:Old
        Get-Content "$script:Xdg.dotforge-moved\cfg" | Should -Be 'xdg copy'
        @($result.Aside) | Should -Be @("$script:Xdg.dotforge-moved")
        $entry = (Read-DFToolOwnership)['owna']
        $entry.how | Should -Be 'linked'
        @($entry.links).Count | Should -Be 1
        Test-Path (Join-Path $script:Old 'cfg') | Should -BeTrue
    }
    It '-Adopt changes nothing, and says why, when the XDG copy can''t be set aside' {
        Mock Rename-DFOldCopy { throw 'The process cannot access the file because it is being used.' }
        $result = Resolve-DFToolConflict owna -Adopt -Confirm:$false
        @($result.Problems) | Should -Match 'being used'
        Get-DFToolLinkTarget -Path $script:Xdg | Should -BeNullOrEmpty
        Get-Content (Join-Path $script:Xdg 'cfg') | Should -Be 'xdg copy'
        (Read-DFToolOwnership).ContainsKey('owna') | Should -BeFalse
    }
    It 'has no -Move or -Done any more' {
        $params = (Get-Command Resolve-DFToolConflict).Parameters.Keys
        $params | Should -Not -Contain 'Move'
        $params | Should -Not -Contain 'Done'
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
        $conflict = { param($Tool, $Target)
            [pscustomobject]@{ Tool = $Tool; Key = 'K'; OldPaths = @("C:\old\$Tool"); Existing = "C:\old\$Tool"; Target = $Target; TargetHasContent = $true; Guide = 'Do it by hand.'; Action = 'Conflict' } }
        $script:Waiting = @(
            [pscustomobject]@{ Name = 'aa'; State = 'Conflict'; Detail = 'd'; Conflicts = @(& $conflict 'aa' 'C:\new\aa') }
            [pscustomobject]@{ Name = 'bb'; State = 'Conflict'; Detail = 'd'; Conflicts = @(& $conflict 'bb' 'C:\new\bb') })
        Mock Get-DFToolStatus { $script:Waiting } -ParameterFilter { $Conflict }
        Mock Test-DFConflictPrompt { $true }
        Mock Import-DFToolDb { @{ $Name[0] = [pscustomobject]@{ name = $Name[0] } } }
        Mock Invoke-DFConflictAdopt { $Result }
    }
    AfterEach { Restore-DFTestXdg }

    It 'offers Adopt as the default for each tool, and adopts on Enter' {
        Mock Read-DFConflictChoice { '' }     # Enter: take the default
        $null = @(Resolve-DFToolConflict)
        Should -Invoke Read-DFConflictChoice -Times 2 -Exactly -ParameterFilter { $Default -eq 'Adopt' }
        Should -Invoke Invoke-DFConflictAdopt -Times 2 -Exactly
    }
    It 'skips a tool you skip' {
        Mock Read-DFConflictChoice { 'S' }
        $null = Resolve-DFToolConflict
        Should -Invoke Invoke-DFConflictAdopt -Times 0 -Exactly
    }
    It 'only lists the tools when it can''t ask' {
        Mock Test-DFConflictPrompt { $false }
        Mock Read-DFConflictChoice { 'A' }
        $null = Resolve-DFToolConflict
        Should -Invoke Read-DFConflictChoice -Times 0 -Exactly
        Should -Invoke Write-Host -ParameterFilter { "$Object" -match 'bb' }
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
