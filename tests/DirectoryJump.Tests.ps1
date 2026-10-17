BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }

    # A session where the given records are active and win their single roles.
    function script:Set-DeclarationSession([object[]]$Records, [hashtable]$Winners = @{}) {
        Reset-DFTestSession
        $script:DFSessionStatus = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($record in $Records) {
            $script:DFSessionToolDb[$record.name] = $record
            $script:DFSessionStatus[$record.name] = New-DFToolStatus -Name $record.name -State Active -RequestedBy 'Tools'
        }
        $script:DFSessionRoleWinners = @{}
        foreach ($role in $Winners.Keys) { $script:DFSessionRoleWinners[$role] = @{ Role = $role; Winner = $Winners[$role]; Reason = 'priority' } }
    }
    $script:Zoxide = '{ "name": "zx", "executable": "zx.exe", "roles": { "navigation": { "directories": ["zx", "query", "--list"], "enter": "cd" } } }' | ConvertFrom-Json
    $script:Fd = '{ "name": "fdx", "executable": "fdx.exe", "roles": { "file-search": { "directoryScan": ["fdx", "--type", "d", "--exact-depth", "{depth}"] } } }' | ConvertFrom-Json
    $script:Plain = '{ "name": "aplain", "executable": "a.exe", "roles": { "file-search": {} } }' | ConvertFrom-Json
}

Describe 'Get-DFRoleDeclaration' {
    AfterEach { Reset-DFTestSession }

    It 'reads a field from the session winner of a single role' {
        Set-DeclarationSession @($script:Zoxide) @{ navigation = 'zx' }
        Get-DFRoleDeclaration -Role navigation -Field enter | Should -Be 'cd'
        Get-DFRoleDeclaration -Role navigation -Field directories | Should -Be @('zx', 'query', '--list')
    }
    It 'reads a field from the first active member of a category role that declares it' {
        Set-DeclarationSession @($script:Plain, $script:Fd)
        Get-DFRoleDeclaration -Role file-search -Field directoryScan | Should -Be @('fdx', '--type', 'd', '--exact-depth', '{depth}')
    }
    It 'reads the fields from loaded (normalized) records' {
        $db = Import-DFToolDb -Name zoxide, fd -ToolsPath (Join-Path $PSScriptRoot '..' 'Tools')
        Set-DeclarationSession @($db.zoxide, $db.fd) @{ navigation = 'zoxide' }
        Get-DFRoleDeclaration -Role navigation -Field enter | Should -Be 'cd'
        Get-DFRoleDeclaration -Role navigation -Field directories | Should -Be @('zoxide', 'query', '--list')
        Get-DFRoleDeclaration -Role file-search -Field directoryScan | Should -Be @('fd', '--type', 'd', '--exact-depth', '{depth}')
    }
    It 'returns nothing when the declaring tool is not in the session' {
        Set-DeclarationSession @()
        Get-DFRoleDeclaration -Role navigation -Field enter | Should -BeNullOrEmpty
        Get-DFRoleDeclaration -Role file-search -Field directoryScan | Should -BeNullOrEmpty
    }
    It 'returns nothing for an unknown role or field, without throwing' {
        Set-DeclarationSession @($script:Zoxide) @{ navigation = 'zx' }
        { Get-DFRoleDeclaration -Role no-such-role -Field enter } | Should -Not -Throw
        Get-DFRoleDeclaration -Role navigation -Field nothing | Should -BeNullOrEmpty
    }
}

Describe 'the directory-jump role' {
    It 'is a single role with its hook and the key-handler reserved code' {
        $role = (Get-DFRoleDb)['directory-jump']
        $role.kind | Should -Be 'single'
        $role.hook | Should -Be 'Initialize-DFRoleDirectoryJump'
        $role.reserved.code | Should -Be @('Set-DFRoleKeyHandler', 'Register-DFFuzzyKeyHandler')
    }
    It 'knows the DirectoryJumpDepth setting' {
        $script:DFConfigKeys.Keys | Should -Contain 'DirectoryJumpDepth'
    }
    It 'gets its folder sources from zoxide and fd' {
        $tools = Join-Path $PSScriptRoot '..' 'Tools'
        $zoxide = Get-Content (Join-Path $tools 'zoxide.json') -Raw | ConvertFrom-Json
        $fd = Get-Content (Join-Path $tools 'fd.json') -Raw | ConvertFrom-Json
        $zoxide.roles.navigation.directories | Should -Be @('zoxide', 'query', '--list')
        $zoxide.roles.navigation.enter | Should -Be 'cd'
        $fd.roles.'file-search'.directoryScan | Should -Be @('fd', '--type', 'd', '--exact-depth', '{depth}')
    }
}

Describe 'Get-DFDirectoryJumpCandidate' {
    BeforeAll {
        $script:Tree = Join-Path $TestDrive 'tree'
        foreach ($dir in 'a\b\c\d\e\f\g', 'x y', "q'uote", 'w[1]', '.hidden\inner') {
            New-Item -ItemType Directory -Path (Join-Path $script:Tree $dir) -Force | Out-Null
        }
        (Get-Item -LiteralPath (Join-Path $script:Tree '.hidden') -Force).Attributes += 'Hidden'
        # Ranked folders: one outside the tree, one also found by the scan (in other case).
        $script:Ranked = @((Join-Path $TestDrive 'elsewhere'), (Join-Path $script:Tree 'X Y'))
        New-Item -ItemType Directory -Path $script:Ranked[0] -Force | Out-Null
        function global:Get-DFTestRanked { $script:Ranked }
        $script:Navigation = [pscustomobject]@{ name = 'zx'; executable = 'zx.exe'; roles = [pscustomobject]@{ navigation = [pscustomobject]@{ directories = @('Get-DFTestRanked'); enter = $null; directoryScan = $null } } }
    }
    AfterAll { Remove-DFTestGlobal -Function Get-DFTestRanked }
    BeforeEach { Push-Location -LiteralPath $script:Tree }
    AfterEach { Pop-Location; Reset-DFTestSession }

    It 'lists the ranked folders first, then the scan level by level, without repeats' {
        Set-DeclarationSession @($script:Navigation) @{ navigation = 'zx' }
        $list = @(Get-DFDirectoryJumpCandidate -Depth 3)
        $list[0].Path | Should -Be $script:Ranked[0]
        $list[1].Path | Should -Be $script:Ranked[1]
        @($list.Path | Where-Object { $_ -ieq (Join-Path $script:Tree 'x y') }).Count | Should -Be 1
        $levels = @($list | Select-Object -Skip 2 | ForEach-Object { @($_.Shown -split '[\\/]').Count })
        $levels | Should -Be @($levels | Sort-Object) -Because 'the scan goes one depth at a time'
        $list.Shown | Should -Contain 'a\b\c'
        $list.Shown | Should -Not -Contain 'a\b\c\d'
    }
    It 'shows a ranked folder under $HOME with ~' {
        $underHome = Join-Path $HOME 'dfj-test-shown'
        Set-Item function:global:Get-DFTestRanked ([scriptblock]::Create("'$underHome'"))
        Set-DeclarationSession @($script:Navigation) @{ navigation = 'zx' }
        (@(Get-DFDirectoryJumpCandidate -Depth 1))[0].Shown | Should -Be (Join-Path '~' 'dfj-test-shown')
        Set-Item function:global:Get-DFTestRanked { $script:Ranked }
    }
    It 'skips hidden folders, and keeps names with spaces, quotes and brackets' {
        Set-DeclarationSession @()
        $shown = @(Get-DFDirectoryJumpCandidate -Depth 6).Shown
        $shown | Should -Contain "q'uote"
        $shown | Should -Contain 'w[1]'
        $shown | Should -Contain 'x y'
        $shown | Should -Contain 'a\b\c\d\e\f'
        $shown | Should -Not -Contain 'a\b\c\d\e\f\g'
        @($shown | Where-Object { $_ -like '.hidden*' }).Count | Should -Be 0
    }
    It 'uses the declared folder scan, one call per depth' {
        $script:ScanCalls = @()
        function global:Invoke-DFTestScan { $script:ScanCalls += [string]$args[-1]; if ($args[-1] -eq '1') { 'x y\'; 'a\' } }
        $scan = [pscustomobject]@{ name = 'fdx'; executable = 'fdx.exe'; roles = [pscustomobject]@{ 'file-search' = [pscustomobject]@{ directories = $null; enter = $null; directoryScan = @('Invoke-DFTestScan', '--exact-depth', '{depth}') } } }
        Set-DeclarationSession @($scan)
        $list = @(Get-DFDirectoryJumpCandidate -Depth 3)
        $list.Shown | Should -Be @('x y', 'a')
        $list[0].Path | Should -Be (Join-Path $script:Tree 'x y')
        $script:ScanCalls | Should -Be @('1', '2', '3')
        Remove-DFTestGlobal -Function Invoke-DFTestScan
    }
    It 'lists only the ranked folders outside the file system, without throwing' {
        Set-DeclarationSession @($script:Navigation) @{ navigation = 'zx' }
        Push-Location Env:
        try { $list = @(Get-DFDirectoryJumpCandidate -Depth 2) } finally { Pop-Location }
        $list.Path | Should -Be $script:Ranked
    }
    It 'gives nothing extra when the ranked list fails' {
        function global:Get-DFTestRanked { throw 'boom' }
        Set-DeclarationSession @($script:Navigation) @{ navigation = 'zx' }
        { @(Get-DFDirectoryJumpCandidate -Depth 1) } | Should -Not -Throw
        @(Get-DFDirectoryJumpCandidate -Depth 1).Shown | Should -Contain 'a'
        Set-Item function:global:Get-DFTestRanked { $script:Ranked }
    }
}

Describe 'Enter-DFDirectory' {
    BeforeAll {
        $script:Target = Join-Path $TestDrive 'enter'
        foreach ($dir in 'w[1]', "q'uote") { New-Item -ItemType Directory -Path (Join-Path $script:Target $dir) -Force | Out-Null }
        function global:Invoke-DFTestEnter { $script:Entered += , @($args) }
    }
    AfterAll { Remove-DFTestGlobal -Function Invoke-DFTestEnter }
    BeforeEach { $script:Entered = @(); Push-Location $TestDrive }
    AfterEach { Pop-Location; Reset-DFTestSession }

    It 'passes the folder to the declared enter command as one literal argument' {
        $nav = [pscustomobject]@{ name = 'zx'; executable = 'zx.exe'; roles = [pscustomobject]@{ navigation = [pscustomobject]@{ directories = $null; enter = 'Invoke-DFTestEnter'; directoryScan = $null } } }
        Set-DeclarationSession @($nav) @{ navigation = 'zx' }
        foreach ($name in 'w[1]', "q'uote") {
            $script:Entered = @()
            Enter-DFDirectory -Path (Join-Path $script:Target $name) | Should -BeTrue
            $script:Entered.Count | Should -Be 1
            $script:Entered[0] | Should -Be @((Join-Path $script:Target $name))
        }
    }
    It 'uses Set-Location -LiteralPath without an enter command' {
        Set-DeclarationSession @()
        Enter-DFDirectory -Path (Join-Path $script:Target 'w[1]') | Should -BeTrue
        (Get-Location).ProviderPath | Should -Be (Join-Path $script:Target 'w[1]')
    }
    It 'says so in one line when the folder is gone' {
        Set-DeclarationSession @()
        Mock Write-Host { }
        Enter-DFDirectory -Path (Join-Path $script:Target 'gone') | Should -BeFalse
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { "$Object" -like 'DotForge: *gone no longer exists' }
    }
}
