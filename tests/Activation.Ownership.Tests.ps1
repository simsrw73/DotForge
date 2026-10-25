BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }

    # A user tool record (installed: a module tool named Pester) whose variable
    # $Var moves its config from ~/.<name> to $XDG_CONFIG_HOME/<name>.
    function Write-OwnRecord([string]$Name, [string]$Var, [string[]]$Requires = @(), [hashtable]$Roles = $null, $Native = $null) {
        $native = if ($Native) { $Native } else { @{ $Var = @("`${HOME}/.$Name") } }
        $rec = [ordered]@{ name = $Name; executable = 'Pester'; type = 'module'
            xdg = @{ method = 'env'; vars = @{ $Var = "`${XDG_CONFIG_HOME}/$Name" }; native = $native }
            aliases = @{ "${Name}x" = @{ command = 'Get-Date' } } }
        if ($Requires) { $rec.requires = $Requires }
        if ($Roles) { $rec.roles = $Roles }
        $rec | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $script:UserTools "$Name.json")
    }
    function New-OldConfig([string]$Name) {
        New-Item -ItemType File -Force (Join-Path $script:FakeHome ".$Name" 'cfg') | Out-Null
    }
    # Content in both the old and the XDG location: the one case that is still a Conflict.
    function New-BothConfig([string]$Name) {
        New-OldConfig $Name
        New-Item -ItemType File -Force (Join-Path $Env:XDG_CONFIG_HOME $Name 'cfg') | Out-Null
    }
}

# A requested tool whose old location holds the user's data, with the XDG location empty, is
# linked and activated; with both holding content it is left alone until they resolve it
# (docs/superpowers/specs/2026-10-25-link-existing-design.md).
Describe 'Activation and config ownership' {
    BeforeEach {
        Set-DFTestXdg
        Reset-DFTestSession
        $script:DFToolDb = $null
        $script:DFToolRecordCache = @{}
        $script:FakeHome = Join-Path $TestDrive 'home'
        # TestDrive lasts for the whole Describe: start each test with no files.
        Remove-Item $script:FakeHome, (Join-Path $TestDrive 'xdg') -Recurse -Force -ErrorAction Ignore
        Mock Get-DFNativeRoot { if ($Name -eq 'HOME') { $script:FakeHome } }
        $script:UserTools = Join-Path $Env:XDG_CONFIG_HOME 'dotforge' 'tools'
        New-Item -ItemType Directory -Force $script:UserTools | Out-Null
        foreach ($v in 'OWN_A', 'OWN_B', 'OWN_C') { [Environment]::SetEnvironmentVariable($v, $null, 'Process') }
        Write-OwnRecord owna OWN_A
        Write-OwnRecord ownb OWN_B -Requires owna
    }
    AfterEach {
        foreach ($v in 'OWN_A', 'OWN_B', 'OWN_C') { [Environment]::SetEnvironmentVariable($v, $null, 'Process') }
        foreach ($a in 'ownax', 'ownbx', 'owncx') { Remove-DFTestGlobal -Alias $a }
        $script:DFToolDb = $null
        $script:DFToolRecordCache = @{}
        Restore-DFTestXdg
    }

    It 'activates and records ownership when nothing is in the old location' {
        Register-DFTool -Name owna 3>$null
        (Get-DFToolStatus owna).State | Should -Be 'Active'
        $Env:OWN_A | Should -Not -BeNullOrEmpty
        (Read-DFToolOwnership)['owna'].how | Should -Be 'clean'
    }
    It 'skips a conflicted tool entirely and warns once' {
        New-BothConfig owna
        Register-DFTool -Name owna -WarningVariable warnings 3>$null
        (Get-DFToolStatus owna).State | Should -Be 'Conflict'
        $Env:OWN_A | Should -BeNullOrEmpty
        Get-Alias ownax -Scope Global -ErrorAction Ignore | Should -BeNullOrEmpty
        @($warnings | Where-Object { "$_" -match 'waiting on your existing config: owna' }).Count | Should -Be 1
        (Get-DFToolStatus owna).Detail | Should -Match 'Resolve-DFToolConflict owna -Adopt'
        (Get-DFToolStatus owna).Detail | Should -Not -Match '-Move'
        (Read-DFToolOwnership).ContainsKey('owna') | Should -BeFalse
    }
    It 'blocks a tool that requires a conflicted tool' {
        New-BothConfig owna
        Register-DFTool -Name ownb 3>$null
        (Get-DFToolStatus ownb).State | Should -Be 'Blocked'
        (Get-DFToolStatus ownb).Detail | Should -Match 'owna'
        $Env:OWN_B | Should -BeNullOrEmpty
    }
    It 'says a blocked tool is waiting on another, not that it is missing' {
        New-BothConfig owna
        Register-DFTool -Name ownb -WarningVariable warnings 3>$null
        "$warnings" | Should -Match 'ownb \(requires owna'
        "$warnings" | Should -Not -Match "isn't installed"
        (Get-DFToolStatus -Missing).Name | Should -Not -Contain 'ownb'
    }
    It 'still calls a tool missing when it is not installed, whatever it requires' {
        New-OldConfig owna
        Mock Test-DFToolAvailable { $false }
        Register-DFTool -Name ownb 3>$null
        (Get-DFToolStatus ownb).State | Should -Be 'Missing'
    }

    It 'activates an owned tool despite leftovers in the old location' {
        New-OldConfig owna
        Save-DFToolOwnership -Ownership @{ owna = [pscustomobject]@{ since = 'x'; how = 'adopt' } }
        Register-DFTool -Name owna 3>$null
        (Get-DFToolStatus owna).State | Should -Be 'Active'
    }
    It 'lists conflicts with Get-DFToolStatus -Conflict' {
        New-BothConfig owna
        Register-DFTool -Name owna 3>$null
        (Get-DFToolStatus -Conflict).Name | Should -Be @('owna')
    }
    It 'adds the record''s guide to the advice' {
        Write-OwnRecord owna OWN_A -Native @{ OWN_A = @{ paths = @('${HOME}/.owna'); guide = 'Use owna''s own mover.' } }
        New-BothConfig owna
        Register-DFTool -Name owna 3>$null
        (Get-DFToolStatus owna).Detail | Should -Match "Use owna's own mover"
        (Get-DFToolStatus owna).Detail | Should -Match '-Adopt'
    }
    It 'gives each tool''s instructions once, even when several of its paths share them' {
        Write-OwnRecord owna OWN_A -Native @{
            OWN_A = @{ paths = @('${HOME}/.owna'); guide = 'Use owna''s own mover.' }
            '${XDG_DATA_HOME}/owna' = @{ paths = @('${HOME}/.owna-data'); guide = 'Use owna''s own mover.' } }
        New-BothConfig owna
        New-Item -ItemType File -Force (Join-Path $script:FakeHome '.owna-data' 'db') | Out-Null
        New-Item -ItemType File -Force (Join-Path $Env:XDG_DATA_HOME 'owna' 'db') | Out-Null
        Register-DFTool -Name owna 3>$null
        ([regex]::Matches((Get-DFToolStatus owna).Detail, "own mover")).Count | Should -Be 1
    }
    It 'names every waiting tool in one warning' {
        Write-OwnRecord ownc OWN_C
        New-BothConfig owna
        New-BothConfig ownc
        Register-DFTool -Name owna, ownc -WarningVariable warnings 3>$null
        @($warnings | Where-Object { "$_" -match 'waiting on your existing config' }).Count | Should -Be 1
        "$warnings" | Should -Match '2 tools are waiting on your existing config: owna, ownc'
        "$warnings" | Should -Match 'Get-DFToolStatus -Conflict'
    }
    It 'does not record ownership when the ownership file is corrupt' {
        $path = Get-DFToolOwnershipPath
        New-DFDirectory (Split-Path $path) | Out-Null
        Set-Content $path '{ bad'
        Register-DFTool -Name owna 3>$null
        Get-Content $path -Raw | Should -Match 'bad'
    }
    It 'gives a role to another member when its preferred member is in conflict' {
        Write-OwnRecord owna OWN_A -Roles @{ navigation = @{ priority = 90 } }
        Write-OwnRecord ownc OWN_C -Roles @{ navigation = @{ priority = 10 } }
        New-BothConfig owna
        Register-DFTool -Name owna, ownc 3>$null
        (Get-DFToolStatus owna).State | Should -Be 'Conflict'
        (Get-DFToolStatus ownc).Roles | Should -Contain 'navigation'
        (Get-DFToolStatus owna).Roles | Should -Not -Contain 'navigation'
    }

    It 'checks a tool that only reaches PATH during the load' {
        # fnm puts node and npm on PATH only when its companion runs: the tool
        # isn't installed when the load starts, but is when its turn comes.
        New-BothConfig owna
        $script:AvailableCalls = 0
        Mock Test-DFToolAvailable { $script:AvailableCalls++; $script:AvailableCalls -gt 1 }
        Register-DFTool -Name owna 3>$null
        (Get-DFToolStatus owna).State | Should -Be 'Conflict'
        $Env:OWN_A | Should -BeNullOrEmpty
    }
    It 'records ownership only for tools that end up active' {
        # ownb has no old config, but requires owna, which is in conflict.
        New-BothConfig owna
        Register-DFTool -Name ownb 3>$null
        (Get-DFToolStatus ownb).State | Should -Be 'Blocked'
        (Read-DFToolOwnership).ContainsKey('ownb') | Should -BeFalse
    }
    It 'warns about a conflict once, not again on a later Register-DFTool' {
        Write-OwnRecord ownc OWN_C
        New-BothConfig owna
        Register-DFTool -Name owna 3>$null
        Register-DFTool -Name ownc -WarningVariable warnings 3>$null
        "$warnings" | Should -Not -Match 'waiting on your existing config'
    }
    It 'warns again when you name the conflicted tool again' {
        New-BothConfig owna
        Register-DFTool -Name owna 3>$null
        Register-DFTool -Name owna -WarningVariable warnings 3>$null
        "$warnings" | Should -Match 'waiting on your existing config: owna'
    }

    Context 'links to existing data' {
        It 'links an empty XDG location to existing data, leaves the variable unset, and activates the tool' {
            New-OldConfig owna
            Register-DFTool -Name owna 3>$null
            $xdg = ConvertTo-DFPath (Join-Path $Env:XDG_CONFIG_HOME 'owna')
            (Get-DFToolStatus owna).State | Should -Be 'Active'
            Get-DFToolLinkTarget -Path $xdg | Should -Be (ConvertTo-DFPath (Join-Path $script:FakeHome '.owna'))
            $Env:OWN_A | Should -BeNullOrEmpty
            Get-Alias ownax -Scope Global -ErrorAction Ignore | Should -Not -BeNullOrEmpty
            $entry = (Read-DFToolOwnership)['owna']
            $entry.how | Should -Be 'linked'
            @($entry.links).Count | Should -Be 1
            (Get-DFToolStatus owna).Detail | Should -Match 'linked'
        }
        It 'changes nothing on a second registration' {
            New-OldConfig owna
            Register-DFTool -Name owna 3>$null
            $before = Get-Content (Get-DFToolOwnershipPath) -Raw
            Register-DFTool -Name owna 3>$null
            Get-Content (Get-DFToolOwnershipPath) -Raw | Should -Be $before
            (Get-DFToolStatus owna).State | Should -Be 'Active'
        }
        It 'still sets a variable whose location is fresh' {
            $rec = [ordered]@{ name = 'owna'; executable = 'Pester'; type = 'module'
                xdg = @{ method = 'env'; vars = @{ OWN_A = '${XDG_CONFIG_HOME}/owna'; OWN_A_DATA = '${XDG_DATA_HOME}/owna' }
                    native = @{ OWN_A = @('${HOME}/.owna'); OWN_A_DATA = @('${HOME}/.owna-data') } } }
            $rec | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $script:UserTools 'owna.json')
            New-OldConfig owna
            try {
                Register-DFTool -Name owna 3>$null
                $Env:OWN_A | Should -BeNullOrEmpty
                $Env:OWN_A_DATA | Should -Be (ConvertTo-DFPath (Join-Path $Env:XDG_DATA_HOME 'owna'))
            } finally { [Environment]::SetEnvironmentVariable('OWN_A_DATA', $null, 'Process') }
        }
        It 'links to where a variable set outside DotForge points' {
            $mine = Join-Path $TestDrive 'mine-owna'
            New-Item -ItemType File -Force (Join-Path $mine 'cfg') | Out-Null
            [Environment]::SetEnvironmentVariable('OWN_A', $mine, 'Process')
            Register-DFTool -Name owna 3>$null
            Get-DFToolLinkTarget -Path (Join-Path $Env:XDG_CONFIG_HOME 'owna') | Should -Be (ConvertTo-DFPath $mine)
            $Env:OWN_A | Should -Be $mine
        }
        It 'never checks a tool already owned as clean' {
            Save-DFToolOwnership -Ownership @{ owna = [pscustomobject]@{ since = 'x'; how = 'clean' } }
            New-OldConfig owna
            Mock Test-DFPathHasContent { $true }
            Register-DFTool -Name owna 3>$null
            Should -Invoke Test-DFPathHasContent -Times 0 -Exactly
            Get-DFToolLinkTarget -Path (Join-Path $Env:XDG_CONFIG_HOME 'owna') | Should -BeNullOrEmpty
        }
        It 'removes a link whose target is gone, says so, and sets the variable again' {
            New-OldConfig owna
            Register-DFTool -Name owna 3>$null
            [IO.Directory]::Delete((Join-Path $script:FakeHome '.owna'), $true)
            Register-DFTool -Name owna 3>$null
            Get-DFToolLinkTarget -Path (Join-Path $Env:XDG_CONFIG_HOME 'owna') | Should -BeNullOrEmpty
            (Get-DFToolStatus owna).Detail | Should -Match 'gone'
            $Env:OWN_A | Should -Be (ConvertTo-DFPath (Join-Path $Env:XDG_CONFIG_HOME 'owna'))
            (Read-DFToolOwnership)['owna'].how | Should -Not -Be 'linked'
        }
        It 'notes a single file it can''t link without Developer Mode, and leaves its variable unset' {
            Write-OwnRecord owna OWN_A -Native @{ OWN_A = @('${HOME}/.ownarc') }
            New-Item -ItemType File -Force (Join-Path $script:FakeHome '.ownarc') | Out-Null
            Mock Test-DFDeveloperMode { $false }
            Register-DFTool -Name owna 3>$null
            (Get-DFToolStatus owna).State | Should -Be 'Active'
            $Env:OWN_A | Should -BeNullOrEmpty
            (Get-DFToolStatus owna).Detail | Should -Match 'Developer Mode'
        }
        It 'never writes a seed into a linked folder' {
            $rec = [ordered]@{ name = 'owna'; executable = 'Pester'; type = 'module'
                xdg = @{ method = 'env'; vars = @{ OWN_A = '${XDG_CONFIG_HOME}/owna' }; native = @{ OWN_A = @('${HOME}/.owna') } }
                setup = @{ seed = @{ '${XDG_CONFIG_HOME}/owna/seeded.conf' = 'owna/seeded.conf' } } }
            $rec | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $script:UserTools 'owna.json')
            New-Item -ItemType File -Force (Join-Path $script:UserTools 'owna' 'seeded.conf') | Out-Null
            New-OldConfig owna
            Register-DFTool -Name owna 3>$null
            Test-Path (Join-Path $script:FakeHome '.owna' 'seeded.conf') | Should -BeFalse
        }
    }

}
