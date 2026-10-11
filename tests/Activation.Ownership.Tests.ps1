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
}

# A requested tool whose old config location holds the user's config is left
# alone until they resolve it (docs/superpowers/specs/2026-10-11-config-ownership-design.md).
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
        New-OldConfig owna
        Register-DFTool -Name owna -WarningVariable warnings 3>$null
        (Get-DFToolStatus owna).State | Should -Be 'Conflict'
        $Env:OWN_A | Should -BeNullOrEmpty
        Get-Alias ownax -Scope Global -ErrorAction Ignore | Should -BeNullOrEmpty
        @($warnings | Where-Object { "$_" -match "owna isn't active" }).Count | Should -Be 1
        "$warnings" | Should -Match 'Resolve-DFToolConflict owna -Move'
        (Read-DFToolOwnership).ContainsKey('owna') | Should -BeFalse
    }
    It 'blocks a tool that requires a conflicted tool' {
        New-OldConfig owna
        Register-DFTool -Name ownb 3>$null
        (Get-DFToolStatus ownb).State | Should -Be 'Missing'
        (Get-DFToolStatus ownb).Detail | Should -Match 'owna'
        $Env:OWN_B | Should -BeNullOrEmpty
    }
    It 'activates an owned tool despite leftovers in the old location' {
        New-OldConfig owna
        Save-DFToolOwnership -Ownership @{ owna = [pscustomobject]@{ since = 'x'; how = 'adopt' } }
        Register-DFTool -Name owna 3>$null
        (Get-DFToolStatus owna).State | Should -Be 'Active'
    }
    It 'lists conflicts with Get-DFToolStatus -Conflict' {
        New-OldConfig owna
        Register-DFTool -Name owna 3>$null
        (Get-DFToolStatus -Conflict).Name | Should -Be @('owna')
    }
    It 'names the guide instead of -Move when the location must not be moved' {
        Write-OwnRecord owna OWN_A -Native @{ OWN_A = @{ paths = @('${HOME}/.owna'); move = $false; guide = 'Use owna''s own mover.' } }
        New-OldConfig owna
        Register-DFTool -Name owna -WarningVariable warnings 3>$null
        "$warnings" | Should -Match "Use owna's own mover"
        "$warnings" | Should -Not -Match '-Move'
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
        New-OldConfig owna
        Register-DFTool -Name owna, ownc 3>$null
        (Get-DFToolStatus owna).State | Should -Be 'Conflict'
        (Get-DFToolStatus ownc).Roles | Should -Contain 'navigation'
        (Get-DFToolStatus owna).Roles | Should -Not -Contain 'navigation'
    }
}
