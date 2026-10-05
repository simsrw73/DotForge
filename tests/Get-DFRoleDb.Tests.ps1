BeforeAll {
    . "$PSScriptRoot/../Private/Get-DFRoleDb.ps1"
    $script:ShippedRoles = Join-Path $PSScriptRoot '../data/roles.json'
}

Describe 'Get-DFRoleDb' {
    BeforeEach { $script:DFRoleDb = $null }

    It 'loads the shipped roles keyed by name' {
        $db = Get-DFRoleDb -Path $script:ShippedRoles
        $db['prompt'].kind | Should -Be 'single'
        $db['prompt'].exclusive | Should -BeTrue
        $db['prompt'].hook | Should -Be 'Initialize-DFRolePrompt'
        $db['grep'].kind | Should -Be 'category'
    }

    It 'loads reserved names, including roles with several reserved kinds' {
        $db = Get-DFRoleDb -Path $script:ShippedRoles
        $db['listing'].reserved.aliases | Should -Be @('ls', 'll', 'la', 'tree')
        $db['pager'].reserved.env | Should -Be @('PAGER')
        $db['prompt'].reserved.code | Should -Contain 'Invoke-Expression'
        $db['editor'].reserved.env | Should -Be @('EDITOR', 'VISUAL')
    }

    It 'loads reserved names when reserved has a single kind' {
        $file = Join-Path $TestDrive 'roles-one.json'
        '{ "r": { "kind": "single", "hook": "Initialize-DFRoleR", "reserved": { "aliases": ["x"] } } }' | Set-Content $file
        (Get-DFRoleDb -Path $file)['r'].reserved.aliases | Should -Be @('x')
    }

    It 'normalizes every field so reads are StrictMode-safe' {
        $file = Join-Path $TestDrive 'roles.json'
        '{ "x": { "kind": "category" } }' | Set-Content $file
        $r = (Get-DFRoleDb -Path $file)['x']
        Set-StrictMode -Version Latest
        $r.exclusive | Should -BeFalse
        $r.hook | Should -BeNullOrEmpty
        $r.emptyMembership | Should -BeFalse
        @($r.reserved.env).Count | Should -Be 0
        @($r.reserved.aliases).Count | Should -Be 0
        @($r.reserved.code).Count | Should -Be 0
        $r.description | Should -Be ''
    }

    It 'skips an entry with an unknown kind, with a warning' {
        $file = Join-Path $TestDrive 'roles.json'
        '{ "bad": { "kind": "multi" }, "ok": { "kind": "category" } }' | Set-Content $file
        $db = Get-DFRoleDb -Path $file -WarningVariable w -WarningAction SilentlyContinue
        $db.ContainsKey('bad') | Should -BeFalse
        $db.ContainsKey('ok') | Should -BeTrue
        "$w" | Should -Match 'bad'
    }

    It 'skips a single role whose hook does not follow Initialize-DFRole<Name>' {
        $file = Join-Path $TestDrive 'roles.json'
        '{ "p": { "kind": "single", "hook": "Start-Prompt" } }' | Set-Content $file
        $db = Get-DFRoleDb -Path $file -WarningAction SilentlyContinue
        $db.ContainsKey('p') | Should -BeFalse
    }

    It 'rejects a category role that declares a hook or reserved names' {
        $file = Join-Path $TestDrive 'roles.json'
        '{ "c": { "kind": "category", "reserved": { "env": ["X"] } } }' | Set-Content $file
        (Get-DFRoleDb -Path $file -WarningAction SilentlyContinue).ContainsKey('c') | Should -BeFalse
    }

    It 'returns an empty table and warns when the file is missing' {
        $db = Get-DFRoleDb -Path (Join-Path $TestDrive 'nope.json') -WarningVariable w -WarningAction SilentlyContinue
        $db.Count | Should -Be 0
        "$w" | Should -Match 'role definitions unavailable'
    }

    It 'caches the default location and does not cache an explicit path' {
        $null = Get-DFRoleDb -Path $script:ShippedRoles
        $script:DFRoleDb | Should -BeNullOrEmpty
        $first = Get-DFRoleDb
        [object]::ReferenceEquals((Get-DFRoleDb), $first) | Should -BeTrue
    }

    It 'every shipped role is valid (nothing skipped)' {
        $raw = Get-Content $script:ShippedRoles -Raw | ConvertFrom-Json
        $db = Get-DFRoleDb -Path $script:ShippedRoles -WarningVariable w
        $w | Should -BeNullOrEmpty
        $db.Count | Should -Be @($raw.PSObject.Properties).Count
    }
}
