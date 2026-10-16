BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
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
        # listing's are derived from its behaviors: the aliases, then the pickers' aliases.
        $db['listing'].reserved.aliases | Should -Be @('ls', 'll', 'la', 'tree', 'ff')
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

    It 'rejects a single role whose hook name does not match its own name' {
        $file = Join-Path $TestDrive 'roles-mismatch.json'
        '{ "pager": { "kind": "single", "hook": "Initialize-DFRoleEditor" }, "project-env": { "kind": "single", "hook": "Initialize-DFRoleProjectEnv" } }' | Set-Content $file
        $db = Get-DFRoleDb -Path $file -WarningVariable w -WarningAction SilentlyContinue
        $db.ContainsKey('pager') | Should -BeFalse
        "$w" | Should -Match 'Initialize-DFRolePager'
        $db.ContainsKey('project-env') | Should -BeTrue
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

Describe 'ConvertTo-DFRoleRecord behaviors' {
    BeforeAll {
        function script:ConvertFrom-RoleJson([string]$Json) { $Json | ConvertFrom-Json }
    }

    It 'reads words, aliases and pickers, and derives reserved aliases' {
        $role = ConvertFrom-RoleJson '{ "kind": "single", "hook": "Initialize-DFRoleListing",
            "behaviors": { "words": { "long": "details", "all": "hidden too" },
                           "aliases": { "ll": ["long"], "la": ["long", "all"] },
                           "pickers": [ { "alias": "ff", "function": "Select-File", "list": ["long"] } ] } }'
        $record = ConvertTo-DFRoleRecord -Name 'listing' -Role $role
        $record.behaviors.words | Should -Be @('long', 'all')
        $record.behaviors.aliases['la'] | Should -Be @('long', 'all')
        $record.behaviors.pickers[0].function | Should -Be 'Select-File'
        $record.reserved.aliases | Should -Be @('ll', 'la', 'ff')
    }

    It 'leaves behaviors null for a role without them' {
        $record = ConvertTo-DFRoleRecord -Name 'pager' -Role (ConvertFrom-RoleJson '{ "kind": "single", "hook": "Initialize-DFRolePager" }')
        $record.behaviors | Should -BeNullOrEmpty
    }

    It 'rejects behaviors that use an undefined word' {
        $role = ConvertFrom-RoleJson '{ "kind": "single", "hook": "Initialize-DFRoleListing",
            "behaviors": { "words": { "long": "details" }, "aliases": { "ll": ["long", "lnog"] } } }'
        ConvertTo-DFRoleRecord -Name 'listing' -Role $role 3>$null | Should -BeNullOrEmpty
        ConvertTo-DFRoleRecord -Name 'listing' -Role $role -WarningVariable w 3>$null | Out-Null
        "$w" | Should -Match "lnog"
    }

    It 'rejects behaviors on a category role' {
        $role = ConvertFrom-RoleJson '{ "kind": "category", "behaviors": { "words": { "a": "x" }, "aliases": { "q": ["a"] } } }'
        ConvertTo-DFRoleRecord -Name 'grep' -Role $role 3>$null | Should -BeNullOrEmpty
    }
}

Describe 'ConvertTo-DFRoleRecord fallback and env behaviors' {
    BeforeAll { function script:Read-Role([string]$Json) { $Json | ConvertFrom-Json } }

    It 'reads a fallback of reserved env' {
        $r = ConvertTo-DFRoleRecord -Name 'pager' -Role (Read-Role '{ "kind": "single", "hook": "Initialize-DFRolePager",
            "reserved": { "env": ["PAGER"] }, "fallback": { "env": { "PAGER": "more" } } }')
        $r.fallback.env.PAGER | Should -Be 'more'
    }
    It 'rejects a fallback that sets a variable the role does not reserve' {
        $role = Read-Role '{ "kind": "single", "hook": "Initialize-DFRolePager", "reserved": { "env": ["PAGER"] },
            "fallback": { "env": { "EDITOR": "notepad" } } }'
        ConvertTo-DFRoleRecord -Name 'pager' -Role $role -WarningVariable w 3>$null | Should -BeNullOrEmpty
        "$w" | Should -Match 'EDITOR'
    }
    It 'rejects a fallback on a category role' {
        ConvertTo-DFRoleRecord -Name 'grep' -Role (Read-Role '{ "kind": "category", "fallback": { "env": { "X": "y" } } }') 3>$null |
            Should -BeNullOrEmpty
    }
    It 'reads behaviors.env and reserves its variables' {
        $r = ConvertTo-DFRoleRecord -Name 'pager' -Role (Read-Role '{ "kind": "single", "hook": "Initialize-DFRolePager",
            "reserved": { "env": ["PAGER"] },
            "behaviors": { "words": { "quit": "q", "color": "c" }, "env": { "PAGER": ["quit", "color"], "BAT_PAGER": ["quit"] } } }')
        $r.behaviors.env['PAGER'] | Should -Be @('quit', 'color')
        $r.reserved.env | Should -Be @('PAGER', 'BAT_PAGER')
    }
    It 'rejects behaviors.env that uses an undefined word' {
        $role = Read-Role '{ "kind": "single", "hook": "Initialize-DFRolePager",
            "behaviors": { "words": { "quit": "q" }, "env": { "PAGER": ["quit", "nope"] } } }'
        ConvertTo-DFRoleRecord -Name 'pager' -Role $role 3>$null | Should -BeNullOrEmpty
    }
}
