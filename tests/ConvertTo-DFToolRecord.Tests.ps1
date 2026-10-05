BeforeAll {
    . "$PSScriptRoot/../Private/Test-DFOutputPiped.ps1"
    . "$PSScriptRoot/../Private/Write-DFFileAtomic.ps1"
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/DFCatalog.Base.ps1"
    . "$PSScriptRoot/../Private/DFReleaseData.ps1"
    . "$PSScriptRoot/../Private/ConvertTo-DFPath.ps1"
    . "$PSScriptRoot/../Private/Get-DFConfiguredTheme.ps1"
    . "$PSScriptRoot/../Private/Import-DFToolDb.ps1"
}

Describe 'ConvertTo-DFToolRecord' {
    It 'gives a minimal record every field, with defaults' {
        $r = ConvertTo-DFToolRecord ('{ "name": "t", "executable": "t.exe" }' | ConvertFrom-Json)
        $r.name        | Should -Be 't'
        $r.executable  | Should -Be 't.exe'
        $r.type        | Should -Be 'exe'
        $r.description | Should -Be ''
        @($r.tags).Count      | Should -Be 0
        @($r.dependsOn).Count | Should -Be 0
        $r.prewarm     | Should -BeTrue
        foreach ($p in 'packages', 'xdg', 'env', 'aliases', 'picker', 'themeMap', 'settings') {
            $r.PSObject.Properties[$p] | Should -Not -BeNullOrEmpty -Because "$p must exist"
            $r.$p | Should -BeNullOrEmpty
        }
    }

    It 'keeps every value the record sets, including fields it does not know' {
        $raw = '{ "name": "t", "executable": "t.exe", "type": "module", "prewarm": false,
                  "tags": ["a"], "dependsOn": ["x"], "customField": 42 }' | ConvertFrom-Json
        $r = ConvertTo-DFToolRecord $raw
        $r.type | Should -Be 'module'
        $r.prewarm | Should -BeFalse
        $r.tags | Should -Be @('a')
        $r.dependsOn | Should -Be @('x')
        $r.customField | Should -Be 42
    }

    It 'defaults roles to an empty object' {
        $r = ConvertTo-DFToolRecord ('{ "name": "t", "executable": "t.exe" }' | ConvertFrom-Json)
        @($r.roles.PSObject.Properties).Count | Should -Be 0
    }

    It 'normalizes each role block: priority defaults to 0, aliases get the alias shape' {
        $raw = '{ "name": "t", "executable": "t.exe", "roles": {
                    "listing": { "priority": 20, "aliases": { "ls": { "command": "t" } } },
                    "grep": {} } }' | ConvertFrom-Json
        $r = ConvertTo-DFToolRecord $raw
        $r.roles.listing.priority | Should -Be 20
        $r.roles.listing.aliases.ls.command | Should -Be 't'
        @($r.roles.listing.aliases.ls.args).Count | Should -Be 0
        $r.roles.grep.priority | Should -Be 0
        $r.roles.grep.aliases | Should -BeNullOrEmpty
        $r.roles.grep.env | Should -BeNullOrEmpty
    }

    It 'converts the legacy role string to a roles entry and drops role' {
        $r = ConvertTo-DFToolRecord ('{ "name": "t", "executable": "t.exe", "role": "listing" }' | ConvertFrom-Json)
        $r.roles.listing.priority | Should -Be 0
        $r.PSObject.Properties['role'] | Should -BeNullOrEmpty
    }

    It 'prefers an explicit roles entry over the legacy string for the same role' {
        $raw = '{ "name": "t", "executable": "t.exe", "role": "listing", "roles": { "listing": { "priority": 5 } } }' | ConvertFrom-Json
        (ConvertTo-DFToolRecord $raw).roles.listing.priority | Should -Be 5
    }

    It 'normalizes xdg so every xdg field exists' {
        $r = ConvertTo-DFToolRecord ('{ "name": "t", "executable": "t", "xdg": { "method": "env" } }' | ConvertFrom-Json)
        $r.xdg.method | Should -Be 'env'
        foreach ($p in 'vars', 'dirs', 'config_path', 'config_content', 'instructions') {
            $r.xdg.PSObject.Properties[$p] | Should -Not -BeNullOrEmpty -Because "xdg.$p must exist"
        }
    }

    It 'normalizes each alias to { command; args[] }, treating a missing args as none' {
        $raw = '{ "name": "t", "executable": "t", "aliases": {
                    "a": { "command": "x" },
                    "b": { "command": "y", "args": "--one" },
                    "c": { "command": "z", "args": ["-p", "q"] } } }' | ConvertFrom-Json
        $r = ConvertTo-DFToolRecord $raw
        $r.aliases.a.command | Should -Be 'x'
        ,$r.aliases.a.args | Should -BeOfType [object[]]
        @($r.aliases.a.args).Count | Should -Be 0
        @($r.aliases.b.args) | Should -Be @('--one')
        @($r.aliases.c.args) | Should -Be @('-p', 'q')
    }

    It 'defaults the declarative picker fields, and leaves a non-object picker alone' {
        $r = ConvertTo-DFToolRecord ('{ "name": "t", "executable": "t", "picker": { "function": "F", "list": "ls" } }' | ConvertFrom-Json)
        $r.picker.preview_window    | Should -Be 'right:60%'
        $r.picker.preview           | Should -Be ''
        $r.picker.header            | Should -Be ''
        $r.picker.ansi              | Should -BeFalse
        $r.picker.list_accepts_path | Should -BeFalse
        foreach ($p in 'alias', 'action', 'parse') {
            $r.picker.PSObject.Properties[$p] | Should -Not -BeNullOrEmpty -Because "picker.$p must exist"
        }
        (ConvertTo-DFToolRecord ('{ "name": "t", "executable": "t", "picker": "custom" }' | ConvertFrom-Json)).picker |
            Should -Be 'custom'
    }

    It 'lets every shipped record be read with plain property access under StrictMode' {
        $fields = 'name', 'executable', 'type', 'description', 'tags', 'packages', 'xdg', 'env',
                  'aliases', 'picker', 'dependsOn', 'roles', 'themeMap', 'settings', 'prewarm'
        foreach ($file in Get-ChildItem (Join-Path $PSScriptRoot '..' 'Tools') -Filter '*.json') {
            $r = ConvertTo-DFToolRecord (Get-Content $file.FullName -Raw | ConvertFrom-Json)
            {
                Set-StrictMode -Version Latest
                foreach ($f in $fields) { $null = $r.$f }
                if ($r.xdg) { $null = $r.xdg.method, $r.xdg.vars, $r.xdg.dirs, $r.xdg.config_path, $r.xdg.config_content, $r.xdg.instructions }
                if ($r.picker -is [pscustomobject]) { $null = $r.picker.function, $r.picker.list, $r.picker.alias, $r.picker.action, $r.picker.parse }
                if ($r.aliases) { foreach ($a in $r.aliases.PSObject.Properties) { $null = $a.Value.command, $a.Value.args } }
            } | Should -Not -Throw -Because $file.Name
        }
    }
}
