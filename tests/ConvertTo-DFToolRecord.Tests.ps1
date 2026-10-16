BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
}

Describe 'ConvertTo-DFToolRecord' {
    It 'gives a minimal record every field, with defaults' {
        $r = ConvertTo-DFToolRecord ('{ "name": "t", "executable": "t.exe" }' | ConvertFrom-Json)
        $r.name        | Should -Be 't'
        $r.executable  | Should -Be 't.exe'
        $r.type        | Should -Be 'exe'
        $r.description | Should -Be ''
        @($r.tags).Count      | Should -Be 0
        @($r.after).Count | Should -Be 0
        $r.prewarm     | Should -BeTrue
        foreach ($p in 'packages', 'xdg', 'env', 'aliases', 'picker', 'themeMap', 'theme', 'wrapper', 'settings') {
            $r.PSObject.Properties[$p] | Should -Not -BeNullOrEmpty -Because "$p must exist"
            $r.$p | Should -BeNullOrEmpty
        }
    }

    It 'keeps every value the record sets, including fields it does not know' {
        $raw = '{ "name": "t", "executable": "t.exe", "type": "module", "prewarm": false,
                  "tags": ["a"], "after": ["x"], "customField": 42 }' | ConvertFrom-Json
        $r = ConvertTo-DFToolRecord $raw
        $r.type | Should -Be 'module'
        $r.prewarm | Should -BeFalse
        $r.tags | Should -Be @('a')
        $r.after | Should -Be @('x')
        $r.customField | Should -Be 42
    }

    It 'defaults executableExclude to an empty array' {
        $r = ConvertTo-DFToolRecord ('{ "name": "t", "executable": "t.exe" }' | ConvertFrom-Json)
        $r.PSObject.Properties['executableExclude'] | Should -Not -BeNullOrEmpty
        @($r.executableExclude).Count | Should -Be 0
    }

    It 'defaults roles to an empty object' {
        $r = ConvertTo-DFToolRecord ('{ "name": "t", "executable": "t.exe" }' | ConvertFrom-Json)
        @($r.roles.PSObject.Properties).Count | Should -Be 0
    }

    It 'normalizes each role block: priority defaults to 0, optIn defaults to false, and aliases get the alias shape' {
        $raw = '{ "name": "t", "executable": "t.exe", "roles": {
                    "listing": { "priority": 20, "aliases": { "ls": { "command": "t" } } },
                    "grep": {}, "optional": { "optIn": true } } }' | ConvertFrom-Json
        $r = ConvertTo-DFToolRecord $raw
        $r.roles.listing.priority | Should -Be 20
        $r.roles.listing.aliases.ls.command | Should -Be 't'
        @($r.roles.listing.aliases.ls.args).Count | Should -Be 0
        $r.roles.grep.priority | Should -Be 0
        $r.roles.grep.optIn | Should -BeFalse
        $r.roles.optional.optIn | Should -BeTrue
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
        foreach ($p in 'vars', 'dirs', 'instructions', 'compliance') {
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

    It 'normalizes each installs block when a tool declares a list' {
        $raw = '{ "name": "t", "executable": "t", "installs": [
                    { "from": "npm", "install": ["npm", "install", "{id}"], "batch": true },
                    { "from": "pypi", "function": "Install-Package", "args": { "Name": "{id}" }, "reactivate": true }
                ] }' | ConvertFrom-Json
        $r = ConvertTo-DFToolRecord $raw

        @($r.installs).Count | Should -Be 2
        $r.installs[0].from | Should -Be 'npm'
        @($r.installs[0].install) | Should -Be @('npm', 'install', '{id}')
        $r.installs[0].batch | Should -BeTrue
        $r.installs[1].from | Should -Be 'pypi'
        $r.installs[1].function | Should -Be 'Install-Package'
        $r.installs[1].reactivate | Should -BeTrue
        $r.installs[1].elevate | Should -BeFalse
    }

    It 'defaults the declarative picker fields, and leaves a non-object picker alone' {
        $r = ConvertTo-DFToolRecord ('{ "name": "t", "executable": "t", "picker": { "function": "F", "list": "ls" } }' | ConvertFrom-Json)
        $r.picker -is [System.Collections.IList] | Should -BeTrue -Because 'a declarative picker normalizes to a list'
        $r.picker.Count                | Should -Be 1
        $r.picker[0].preview_window    | Should -Be 'right:60%'
        $r.picker[0].preview           | Should -Be ''
        $r.picker[0].header            | Should -Be ''
        $r.picker[0].ansi              | Should -BeFalse
        $r.picker[0].list_accepts_path | Should -BeFalse
        foreach ($p in 'alias', 'action', 'parse') {
            $r.picker[0].PSObject.Properties[$p] | Should -Not -BeNullOrEmpty -Because "picker.$p must exist"
        }
        (ConvertTo-DFToolRecord ('{ "name": "t", "executable": "t", "picker": "custom" }' | ConvertFrom-Json)).picker |
            Should -Be 'custom'
    }

    It 'normalizes a list of pickers in order' {
        $r = ConvertTo-DFToolRecord ('{ "name": "t", "executable": "t", "picker": [ { "function": "A", "list": "a" }, { "function": "B", "list": "b" } ] }' | ConvertFrom-Json)
        $r.picker.function | Should -Be @('A', 'B')
        $r.picker[1].preview_window | Should -Be 'right:60%'
    }

    It 'lets every shipped record be read with plain property access under StrictMode' {
        $fields = 'name', 'executable', 'type', 'description', 'tags', 'packages', 'xdg', 'env',
                  'aliases', 'picker', 'after', 'requires', 'roles', 'themeMap', 'theme', 'wrapper', 'settings', 'prewarm', 'setup'
        foreach ($file in Get-ChildItem (Join-Path $PSScriptRoot '..' 'Tools') -Filter '*.json') {
            $r = ConvertTo-DFToolRecord (Get-Content $file.FullName -Raw | ConvertFrom-Json)
            {
                Set-StrictMode -Version Latest
                foreach ($f in $fields) { $null = $r.$f }
                if ($r.xdg) { $null = $r.xdg.method, $r.xdg.vars, $r.xdg.dirs, $r.xdg.instructions, $r.xdg.compliance }
                if ($r.setup) { $null = $r.setup.seed }
                if ($r.picker -and $r.picker -isnot [string]) { foreach ($p in @($r.picker)) { $null = $p.function, $p.list, $p.alias, $p.action, $p.parse } }
                if ($r.aliases) { foreach ($a in $r.aliases.PSObject.Properties) { $null = $a.Value.command, $a.Value.args } }
            } | Should -Not -Throw -Because $file.Name
        }
    }

    Context 'theme' {
        It 'is $null when absent' {
            (ConvertTo-DFToolRecord ([pscustomobject]@{ name = 'x'; executable = 'x.exe' })).theme | Should -BeNullOrEmpty
        }
        It 'fills every field' {
            $theme = (ConvertTo-DFToolRecord ([pscustomobject]@{ name = 'x'; executable = 'x.exe'; theme = [pscustomobject]@{ key = 'XTheme' } })).theme
            $theme.key | Should -Be 'XTheme'
            foreach ($f in 'default', 'map', 'files', 'fallback', 'env', 'command') { $theme.PSObject.Properties[$f] | Should -Not -BeNullOrEmpty }
            , $theme.valid | Should -BeOfType [string[]]
        }
        It 'takes map from the legacy top-level themeMap when theme.map is absent' {
            $legacy = [pscustomobject]@{ 'catppuccin-mocha' = 'Catppuccin Mocha' }
            $theme = (ConvertTo-DFToolRecord ([pscustomobject]@{ name = 'x'; executable = 'x.exe'; themeMap = $legacy; theme = [pscustomobject]@{ key = 'XTheme' } })).theme
            $theme.map.'catppuccin-mocha' | Should -Be 'Catppuccin Mocha'
        }
    }

    It 'normalizes wrapper args into groups' {
        $w = (ConvertTo-DFToolRecord ([pscustomobject]@{ name = 'x'; executable = 'x.exe'; wrapper = [pscustomobject]@{ args = @('-s', [pscustomobject]@{ ifFile = 'f'; args = @('-c', '{file}') }) } })).wrapper
        $w.custom | Should -BeFalse
        $w.args.Count | Should -Be 2
        $w.args[0].ifFile | Should -BeNullOrEmpty
        $w.args[0].args | Should -Be @('-s')
        $w.args[1].ifFile | Should -Be 'f'
        $w.args[1].args | Should -Be @('-c', '{file}')
    }
}

Describe 'ConvertTo-DFToolRecord role flags' {
    It 'keeps a role block''s flags as word -> string arrays' {
        $tool = '{ "name": "t", "executable": "t.exe", "roles": { "listing": { "flags": { "long": ["--long"], "color": [] } } } }' | ConvertFrom-Json
        $record = ConvertTo-DFToolRecord $tool
        $record.roles.listing.flags.long | Should -Be @('--long')
        @($record.roles.listing.flags.color).Count | Should -Be 0
    }

    It 'gives a role block without flags a null flags field' {
        $tool = '{ "name": "t", "executable": "t.exe", "roles": { "pager": {} } }' | ConvertFrom-Json
        $record = ConvertTo-DFToolRecord $tool
        $record.roles.pager.PSObject.Properties['flags'] | Should -Not -BeNullOrEmpty
        $record.roles.pager.flags | Should -BeNullOrEmpty
    }
}
