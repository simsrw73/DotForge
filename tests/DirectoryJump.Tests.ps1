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
