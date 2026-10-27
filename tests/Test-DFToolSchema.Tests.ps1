BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
}

Describe 'Test-DFToolSchema' {
    Context 'valid records' {
        It 'passes a minimal valid tool record' {
            $tool = [PSCustomObject]@{
                name       = 'mytool'
                executable = 'mytool.exe'
            }
            $result = Test-DFToolSchema -Tool $tool
            $result.Valid | Should -BeTrue
            $result.Errors | Should -BeNullOrEmpty
        }

        It 'passes a tool with type = "exe"' {
            $tool = [PSCustomObject]@{ name = 't'; executable = 't.exe'; type = 'exe' }
            (Test-DFToolSchema -Tool $tool).Valid | Should -BeTrue
        }

        It 'passes a tool with type = "module"' {
            $tool = [PSCustomObject]@{ name = 't'; executable = 't'; type = 'module' }
            (Test-DFToolSchema -Tool $tool).Valid | Should -BeTrue
        }

        It 'passes a fully populated valid record' {
            $tool = [PSCustomObject]@{
                name        = 'bat'
                executable  = 'bat.exe'
                description = 'Modern cat'
                tags        = @('viewer')
                packages    = [PSCustomObject]@{ scoop = 'bat' }
                xdg         = [PSCustomObject]@{
                    compliance = 'partial'
                    method     = 'env'
                    vars       = [PSCustomObject]@{ BAT_CONFIG_PATH = '${XDG_CONFIG_HOME}/bat/bat.conf' }
                    dirs       = @()
                }
                aliases = [PSCustomObject]@{}
                picker  = $null
            }
            (Test-DFToolSchema -Tool $tool).Valid | Should -BeTrue
        }
    }

    Context 'invalid records' {
        It 'fails when name is missing' {
            $tool = [PSCustomObject]@{ executable = 'tool.exe' }
            $result = Test-DFToolSchema -Tool $tool
            $result.Valid | Should -BeFalse
            $result.Errors | Where-Object { $_ -match 'name' } | Should -Not -BeNullOrEmpty
        }

        It 'fails when executable is missing' {
            $tool = [PSCustomObject]@{ name = 'mytool' }
            $result = Test-DFToolSchema -Tool $tool
            $result.Valid | Should -BeFalse
            $result.Errors | Where-Object { $_ -match 'executable' } | Should -Not -BeNullOrEmpty
        }

        It 'fails when xdg.method is not a valid value' {
            $tool = [PSCustomObject]@{
                name       = 'mytool'
                executable = 'mytool.exe'
                xdg        = [PSCustomObject]@{ method = 'invalid' }
            }
            $result = Test-DFToolSchema -Tool $tool
            $result.Valid | Should -BeFalse
            $result.Errors | Where-Object { $_ -match 'xdg.method' } | Should -Not -BeNullOrEmpty
        }

        It 'fails when type is not a valid value' {
            $tool = [PSCustomObject]@{ name = 't'; executable = 't.exe'; type = 'binary' }
            $result = Test-DFToolSchema -Tool $tool
            $result.Valid | Should -BeFalse
            $result.Errors | Where-Object { $_ -match 'type' } | Should -Not -BeNullOrEmpty
        }

        It 'rejects the old scoopBucket, pointing at a feed in packages' {
            $t = '{ "name": "t", "executable": "t.exe", "scoopBucket": { "name": "x", "url": "u" } }' | ConvertFrom-Json
            $result = Test-DFToolSchema -Tool $t
            $result.Valid | Should -BeFalse
            "$($result.Errors)" | Should -Match 'scoopBucket was replaced'
        }

        It 'accepts a packages value that is an id or { id, feed }, and rejects a feed without a url' {
            foreach ($ok in '"g"', '{ "id": "g", "feed": { "name": "b", "url": "https://u" } }', '{ "id": "g" }') {
                (Test-DFToolSchema -Tool ("{ ""name"": ""t"", ""executable"": ""t.exe"", ""packages"": { ""scoop"": $ok } }" | ConvertFrom-Json)).Valid | Should -BeTrue -Because $ok
            }
            $result = Test-DFToolSchema -Tool ('{ "name": "t", "executable": "t.exe", "packages": { "scoop": { "id": "g", "feed": { "name": "b" } } } }' | ConvertFrom-Json)
            $result.Valid | Should -BeFalse
            "$($result.Errors)" | Should -Match 'packages.scoop'
        }

        It 'accepts a one-element executableExclude array' {
            $t = '{ "name": "t", "executable": "t.exe", "executableExclude": ["*\\Git\\usr\\bin\\*"] }' | ConvertFrom-Json
            $result = Test-DFToolSchema -Tool $t
            $result.Valid | Should -BeTrue -Because "$($result.Errors)"
        }

        It 'rejects an executableExclude that is not an array of strings' {
            $t = '{ "name": "t", "executable": "t.exe", "executableExclude": "x" }' | ConvertFrom-Json
            $result = Test-DFToolSchema -Tool $t
            $result.Valid | Should -BeFalse
            "$($result.Errors)" | Should -Match 'executableExclude'
        }

        It 'rejects roles that is not an object' {
            $t = '{ "name": "t", "executable": "t.exe", "roles": ["listing"] }' | ConvertFrom-Json
            $result = Test-DFToolSchema -Tool $t
            $result.Valid | Should -BeFalse
            "$($result.Errors)" | Should -Match 'roles'
        }

        It 'rejects a non-integer role priority' {
            $t = '{ "name": "t", "executable": "t.exe", "roles": { "pager": { "priority": "high" } } }' | ConvertFrom-Json
            $result = Test-DFToolSchema -Tool $t
            $result.Valid | Should -BeFalse
            "$($result.Errors)" | Should -Match 'priority'
        }

        It 'accepts an integer role priority and an empty role block' {
            $t = '{ "name": "t", "executable": "t.exe", "roles": { "pager": { "priority": 10 }, "grep": {} } }' | ConvertFrom-Json
            (Test-DFToolSchema -Tool $t).Valid | Should -BeTrue
        }

        It 'accepts wrapper groups with unlessArg and unlessFile, and rejects wrong types' {
            $valid = '{ "name": "t", "executable": "t.exe", "wrapper": { "args": [ { "unlessArg": ["--x"], "unlessFile": "${XDG_CONFIG_HOME}/t/c", "args": ["--x", "1"] }, { "ifFile": "${XDG_CONFIG_HOME}/t/c", "unlessArg": ["-C"], "args": ["-C", "{file}"] } ] } }' | ConvertFrom-Json
            $result = Test-DFToolSchema -Tool $valid
            $result.Valid | Should -BeTrue -Because "$($result.Errors)"
            foreach ($bad in '{ "unlessArg": "--x", "args": ["a"] }', '{ "unlessFile": 1, "args": ["a"] }', '{ "args": ["a"] }') {
                $tool = ('{ "name": "t", "executable": "t.exe", "wrapper": { "args": [ ' + $bad + ' ] } }') | ConvertFrom-Json
                (Test-DFToolSchema -Tool $tool).Valid | Should -BeFalse -Because "$bad is invalid"
            }
        }

        It 'accepts a theme apply function name and rejects an empty or non-string one' {
            $valid = '{ "name": "t", "executable": "t.exe", "theme": { "key": "TTheme", "apply": "Invoke-TApply" } }' | ConvertFrom-Json
            (Test-DFToolSchema -Tool $valid).Valid | Should -BeTrue
            foreach ($bad in '""', '1', '["x"]') {
                $tool = ('{ "name": "t", "executable": "t.exe", "theme": { "key": "TTheme", "apply": ' + $bad + ' } }') | ConvertFrom-Json
                $result = Test-DFToolSchema -Tool $tool
                $result.Valid | Should -BeFalse -Because "apply $bad is invalid"
                "$($result.Errors)" | Should -Match 'theme\.apply'
            }
            (ConvertTo-DFToolRecord ('{ "name": "t", "executable": "t.exe", "theme": { "key": "TTheme" } }' | ConvertFrom-Json)).theme.PSObject.Properties.Name | Should -Contain 'apply'
        }

        It 'accepts folder declarations in a role block and rejects wrong types' {
            $valid = '{ "name": "t", "executable": "t.exe", "roles": { "navigation": { "directories": ["t", "list"], "enter": "cd" }, "file-search": { "directoryScan": ["t", "{depth}"] } } }' | ConvertFrom-Json
            $result = Test-DFToolSchema -Tool $valid
            $result.Valid | Should -BeTrue -Because "$($result.Errors)"
            foreach ($bad in '{ "directoriesScored": "yes" }', '{ "directories": "t list" }', '{ "directories": [] }', '{ "directories": [1] }', '{ "enter": ["cd"] }', '{ "enter": "" }', '{ "directoryScan": "fd" }') {
                $field = ($bad | ConvertFrom-Json).PSObject.Properties.Name
                $tool = ('{ "name": "t", "executable": "t.exe", "roles": { "navigation": ' + $bad + ' } }') | ConvertFrom-Json
                $result = Test-DFToolSchema -Tool $tool
                $result.Valid | Should -BeFalse -Because "$bad is invalid"
                "$($result.Errors)" | Should -Match "roles\.navigation\.$field"
            }
        }

        It 'accepts a boolean role optIn and rejects another type' {
            $valid = '{ "name": "t", "executable": "t.exe", "roles": { "optional": { "optIn": true } } }' | ConvertFrom-Json
            $invalid = '{ "name": "t", "executable": "t.exe", "roles": { "optional": { "optIn": "yes" } } }' | ConvertFrom-Json
            $result = Test-DFToolSchema -Tool $valid
            $result.Valid | Should -BeTrue -Because "$($result.Errors)"
            $result = Test-DFToolSchema -Tool $invalid
            $result.Valid | Should -BeFalse
            "$($result.Errors)" | Should -Match 'optIn'
        }
    }

    Context 'field shapes' {
        BeforeAll {
            function script:Get-SchemaErrors($Extra) {
                $tool = [pscustomobject]@{ name = 't'; executable = 't.exe' }
                foreach ($k in $Extra.Keys) { $tool | Add-Member -NotePropertyName $k -NotePropertyValue $Extra[$k] }
                "$((Test-DFToolSchema -Tool $tool).Errors)"
            }
            $script:Picker = { param([hashtable]$p) [pscustomobject](@{ function = 'Select-T'; list = 't list' } + $p) }
        }

        It 'accepts picker null, "custom", and a complete object' {
            Get-SchemaErrors @{ picker = $null } | Should -BeNullOrEmpty
            Get-SchemaErrors @{ picker = 'custom' } | Should -BeNullOrEmpty
            Get-SchemaErrors @{ picker = (& $script:Picker @{ action = 'Set-Location {}'; parse = '$_.Split("\t")[0]'; ansi = $true }) } |
                Should -BeNullOrEmpty
        }
        It 'rejects any other picker string, and an object without function and list' {
            Get-SchemaErrors @{ picker = 'yes' } | Should -Match 'picker'
            Get-SchemaErrors @{ picker = [pscustomobject]@{ function = 'Select-T' } } | Should -Match 'picker.list'
            Get-SchemaErrors @{ picker = [pscustomobject]@{ list = 't list' } } | Should -Match 'picker.function'
        }
        It 'accepts a list of pickers, and names the element at fault' {
            Get-SchemaErrors @{ picker = @((& $script:Picker @{}), [pscustomobject]@{ function = 'Select-U'; list = 'u' }) } | Should -BeNullOrEmpty
            Get-SchemaErrors @{ picker = @((& $script:Picker @{}), [pscustomobject]@{ list = 'u' }) } | Should -BeExactly 'picker[1].function is required (a string)'
            Get-SchemaErrors @{ picker = @((& $script:Picker @{}), 'custom') } | Should -BeExactly 'picker[1] must be an object'
            Get-SchemaErrors @{ picker = @((& $script:Picker @{ ansi = 'no' })) } | Should -Match 'picker\[0\]\.ansi'
        }
        It 'rejects picker booleans written as strings' {
            Get-SchemaErrors @{ picker = (& $script:Picker @{ ansi = 'false' }) } | Should -Match 'picker.ansi'
            Get-SchemaErrors @{ picker = (& $script:Picker @{ list_accepts_path = 'true' }) } | Should -Match 'picker.list_accepts_path'
        }
        It 'rejects a picker action or parse that is not valid PowerShell (instead of failing at profile load)' {
            Get-SchemaErrors @{ picker = (& $script:Picker @{ action = 'Set-Location {} )' }) } | Should -Match 'picker.action'
            Get-SchemaErrors @{ picker = (& $script:Picker @{ parse = '$_.Split(' }) } | Should -Match 'picker.parse'
        }
        It 'rejects an alias without a string command, or with non-string args' {
            Get-SchemaErrors @{ aliases = [pscustomobject]@{ ok = [pscustomobject]@{ command = 'x'; args = @('-a') } } } | Should -BeNullOrEmpty
            Get-SchemaErrors @{ aliases = [pscustomobject]@{ bad = [pscustomobject]@{ args = @('-a') } } } | Should -Match 'aliases.bad'
            Get-SchemaErrors @{ aliases = [pscustomobject]@{ bad = 'x' } } | Should -Match 'aliases.bad'
            Get-SchemaErrors @{ aliases = [pscustomobject]@{ bad = [pscustomobject]@{ command = 'x'; args = @(1, [pscustomobject]@{}) } } } |
                Should -Match 'aliases.bad'
        }
        It 'rejects aliases that is not an object with its current message' {
            Get-SchemaErrors @{ aliases = 'bad' } | Should -BeExactly 'aliases must be an object keyed by alias name'
        }
        It 'checks role-block aliases and env with the same rules' {
            $roles = [pscustomobject]@{ listing = [pscustomobject]@{ aliases = [pscustomobject]@{ ls = [pscustomobject]@{ args = @() } } } }
            Get-SchemaErrors @{ roles = $roles } | Should -Match 'roles.listing.aliases.ls'
            $roles = [pscustomobject]@{ pager = [pscustomobject]@{ env = [pscustomobject]@{ PAGER = [pscustomobject]@{} } } }
            Get-SchemaErrors @{ roles = $roles } | Should -Match 'roles.pager.env.PAGER'
        }
        It 'requires env and themeMap to be objects of plain values' {
            Get-SchemaErrors @{ env = [pscustomobject]@{ LESS = '-R'; N = 3 } } | Should -BeNullOrEmpty
            Get-SchemaErrors @{ env = 'LESS=-R' } | Should -Match '\benv\b'
            Get-SchemaErrors @{ env = [pscustomobject]@{ LESS = @('-R') } } | Should -Match 'env.LESS'
            Get-SchemaErrors @{ themeMap = [pscustomobject]@{ 'catppuccin-mocha' = 'catppuccin' } } | Should -BeNullOrEmpty
            Get-SchemaErrors @{ themeMap = [pscustomobject]@{ 'catppuccin-mocha' = 1 } } | Should -Match 'themeMap'
        }
        It 'rejects the old dependsOn, naming after and requires' {
            Get-SchemaErrors @{ dependsOn = @('fnm') } | Should -Match 'dependsOn was replaced: use after .* or requires'
        }
        It 'rejects xdg.method config, pointing at setup.seed' {
            Get-SchemaErrors @{ xdg = [pscustomobject]@{ method = 'config' } } | Should -Match 'setup\.seed'
        }
        It 'requires setup.seed to map destinations to file names' {
            Get-SchemaErrors @{ setup = [pscustomobject]@{ seed = [pscustomobject]@{ '${XDG_CONFIG_HOME}/t/c' = 't/c' } } } | Should -BeNullOrEmpty
            Get-SchemaErrors @{ setup = [pscustomobject]@{ seed = [pscustomobject]@{ '${XDG_CONFIG_HOME}/t/c' = 3 } } } | Should -Match 'setup\.seed'
            Get-SchemaErrors @{ setup = 'x' } | Should -Match 'setup must be an object'
        }
        It 'requires after to be an array of strings, and prewarm a boolean' {
            Get-SchemaErrors @{ after = @('fnm') } | Should -BeNullOrEmpty
            Get-SchemaErrors @{ after = 'fnm' } | Should -Match 'after'
            Get-SchemaErrors @{ after = @('fnm', 3) } | Should -Match 'after'
            Get-SchemaErrors @{ prewarm = $false } | Should -BeNullOrEmpty
            Get-SchemaErrors @{ prewarm = 'false' } | Should -Match 'prewarm'
        }
        It 'rejects a non-object installs block with its current message' {
            Get-SchemaErrors @{ installs = 'bad' } | Should -BeExactly 'installs must be an object'
        }
        It 'rejects a non-array installs install with its current message' {
            Get-SchemaErrors @{ installs = [pscustomobject]@{ from = 'source'; install = 'install' } } |
                Should -BeExactly 'installs.install must be an array (argv)'
        }
        It 'rejects malformed requires with its current message' {
            Get-SchemaErrors @{ requires = 'source' } |
                Should -BeExactly 'requires must be an array of tool names or role:<role> entries'
        }
        It 'rejects an invalid picker type with its current message' {
            Get-SchemaErrors @{ picker = $true } | Should -BeExactly 'picker must be null, "custom", an object or a list of objects'
        }

        Context 'theme' {
            It 'accepts a full theme block' {
                Get-SchemaErrors @{ theme = [pscustomobject]@{ key = 'XTheme'; default = 'a'; map = [pscustomobject]@{ a = 'A' }; files = 'x'
                    valid = @('A'); fallback = 'A'; env = [pscustomobject]@{ X_THEME = '{theme}' }; command = 'Select-XTheme' } } | Should -BeNullOrEmpty
            }
            It 'requires key to name a *Theme config key' {
                Get-SchemaErrors @{ theme = [pscustomobject]@{ key = 'x' } } | Should -Match 'theme.key'
            }
            It 'rejects a non-object theme' {
                Get-SchemaErrors @{ theme = 'dracula' } | Should -Match 'theme must be an object'
            }
            It 'requires valid to be strings' {
                Get-SchemaErrors @{ theme = [pscustomobject]@{ key = 'XTheme'; valid = @(1) } } | Should -Match 'theme.valid'
            }
            It 'requires env values to be strings' {
                Get-SchemaErrors @{ theme = [pscustomobject]@{ key = 'XTheme'; env = [pscustomobject]@{ X = 1 } } } | Should -Match 'theme.env.X'
            }
            It 'warns about a misspelled theme field' {
                (Test-DFToolSchema -Tool ([pscustomobject]@{ name = 'x'; executable = 'x.exe'; theme = [pscustomobject]@{ key = 'XTheme'; defualt = 'a' } })).Warnings |
                    Should -Match "theme.defualt.*theme.default"
            }
        }

        Context 'wrapper' {
            It 'accepts strings and ifFile groups' {
                Get-SchemaErrors @{ wrapper = [pscustomobject]@{ args = @('-x', [pscustomobject]@{ ifFile = '${XDG_CONFIG_HOME}/x'; args = @('--config', '{file}') }) } } | Should -BeNullOrEmpty
            }
            It 'requires args to be an array' {
                Get-SchemaErrors @{ wrapper = [pscustomobject]@{ args = '-x' } } | Should -Match 'wrapper.args must be an array'
            }
            It 'rejects a malformed group' {
                Get-SchemaErrors @{ wrapper = [pscustomobject]@{ args = @([pscustomobject]@{ args = @('-x') }) } } | Should -Match 'wrapper.args\[0\]'
            }
            It 'rejects {theme} without a theme block' {
                Get-SchemaErrors @{ wrapper = [pscustomobject]@{ args = @('-s', '{theme}') } } | Should -Match 'no theme block'
            }
            It 'rejects {theme} when valid can reject and there is no fallback' {
                Get-SchemaErrors @{ theme = [pscustomobject]@{ key = 'XTheme'; valid = @('a') }; wrapper = [pscustomobject]@{ args = @('-s', '{theme}') } } | Should -Match 'needs a fallback'
            }
            It 'requires custom to be a boolean' {
                Get-SchemaErrors @{ wrapper = [pscustomobject]@{ custom = 'yes'; args = @() } } | Should -Match 'wrapper.custom'
            }
        }
    }

    Context 'typo warnings' {
        BeforeAll {
            function script:Get-SchemaWarnings([pscustomobject]$Tool) {
                (Test-DFToolSchema -Tool $Tool).Warnings
            }
        }

        It 'warns about a field that looks like a misspelled known field, naming the suggestion' {
            $w = Get-SchemaWarnings ([pscustomobject]@{ name = 't'; executable = 't.exe'; requirs = @('x'); themMap = [pscustomobject]@{} })
            "$w" | Should -Match "requirs.*requires"
            "$w" | Should -Match "themMap.*themeMap"
        }
        It 'uses the known spelling for an exact-case typo match' {
            Get-DFFieldSuggestion -Name 'NAME' -Known @('name') | Should -BeExactly 'name'
        }
        It 'checks inside picker, xdg and role blocks too' {
            $tool = [pscustomobject]@{
                name = 't'; executable = 't.exe'
                picker = [pscustomobject]@{ function = 'Select-T'; list = 'l'; preview_windows = 'up' }
                xdg = [pscustomobject]@{ method = 'env'; varz = [pscustomobject]@{} }
                roles = [pscustomobject]@{ listing = [pscustomobject]@{ priorty = 5 } }
            }
            $w = "$(Get-SchemaWarnings $tool)"
            $w | Should -Match 'preview_windows.*preview_window'
            $w | Should -Match 'varz.*vars'
            $w | Should -Match 'priorty.*priority'
        }
        It 'checks each picker in a list' {
            $tool = [pscustomobject]@{
                name = 't'; executable = 't.exe'
                picker = @([pscustomobject]@{ function = 'A'; list = 'a' }, [pscustomobject]@{ function = 'B'; list = 'b'; headr = 'x' })
            }
            "$(Get-SchemaWarnings $tool)" | Should -Match "picker\[1\]\.headr.*picker\[1\]\.header"
        }
        It 'does not warn about extra fields that resemble nothing known (tool authors may carry data)' {
            Get-SchemaWarnings ([pscustomobject]@{ name = 't'; executable = 't.exe'; homepage = 'https://x'; notes = 'n' }) |
                Should -BeNullOrEmpty
        }
        It 'keeps the tool valid when it only has warnings' {
            (Test-DFToolSchema -Tool ([pscustomobject]@{ name = 't'; executable = 't.exe'; requirs = @() })).Valid |
                Should -BeTrue
        }
    }
}

Describe 'Import-DFToolDb schema warnings' {
    It 'loads a tool with a typo warning, and reports the warning with the file name' {
        $dir = Join-Path $TestDrive 'tools-typo'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        '{ "name": "typotool", "executable": "typo.exe", "requirs": [] }' | Set-Content (Join-Path $dir 'typotool.json')
        $db = Import-DFToolDb -ToolsPath $dir -WarningVariable w 3>$null
        $db.ContainsKey('typotool') | Should -BeTrue
        "$w" | Should -Match 'typotool\.json.*requirs.*requires'
    }
}

Describe 'Seed tool JSON files' {
    BeforeAll {

    }

    $seedFiles = @(
        'bat', 'eza', 'fzf', 'ripgrep', 'zoxide',
        'fd', 'broot', 'jq', 'glow', 'procs', 'fastfetch',
        'curl', 'wget', 'docker', 'less', 'gh', 'delta',
        'lazygit', 'rustup', 'uv', 'chezmoi', 'micro',
        'bitwarden', 'npm', 'fnm', 'scoop', 'winget',
        'posh-git', 'psreadline', 'PSFzf', 'Terminal-Icons', 'oh-my-posh',
        'gsudo', 'mdcat', 'lsd'
    ) | ForEach-Object {
        @{ Name = $_; Path = Join-Path $PSScriptRoot "../Tools/$_.json" }
    }

    It 'seed file <Name>.json exists' -ForEach $seedFiles {
        Test-Path $Path | Should -BeTrue -Because "$Name.json must exist in Tools/"
    }
}

Describe 'Shipped tool JSON files' {
    # Every shipped tool, discovered rather than listed, so a new tool is covered automatically.
    $shipped = Get-ChildItem (Join-Path $PSScriptRoot '../Tools') -Filter '*.json' |
        ForEach-Object { @{ Name = $_.BaseName; Path = $_.FullName } }

    It '<Name>.json passes schema validation with no errors and no warnings' -ForEach $shipped {
        $tool = Get-Content $Path -Raw | ConvertFrom-Json
        $result = Test-DFToolSchema -Tool $tool
        $result.Valid | Should -BeTrue -Because ($result.Errors -join '; ')
        $result.Warnings | Should -BeNullOrEmpty
    }
}

Describe 'Test-DFToolSchema role flags' {
    It 'rejects role flags that are not word -> string arrays: <Json>' -ForEach @(
        @{ Json = '"flags": ["--long"]' }, @{ Json = '"flags": { "long": "--long" }' }, @{ Json = '"flags": { "long": [1] }' }
    ) {
        $tool = "{ ""name"": ""t"", ""executable"": ""t.exe"", ""roles"": { ""listing"": { $Json } } }" | ConvertFrom-Json
        (Test-DFToolSchema -Tool $tool).Errors -join ';' | Should -Match 'roles.listing.flags'
    }

    It 'accepts role flags of word -> string arrays' {
        $tool = '{ "name": "t", "executable": "t.exe", "roles": { "listing": { "flags": { "long": ["--long"], "color": [] } } } }' | ConvertFrom-Json
        (Test-DFToolSchema -Tool $tool).Errors | Should -BeNullOrEmpty
    }
}

Describe 'Test-DFToolSchema role flag groups' {
    It 'accepts a flag group' {
        $tool = '{ "name": "t", "executable": "t.exe", "roles": { "pager": { "flags": { "theme": [{ "ifFile": "a", "unlessFile": "b", "args": ["-c", "{file}"] }] } } } }' | ConvertFrom-Json
        (Test-DFToolSchema -Tool $tool).Errors | Should -BeNullOrEmpty
    }
    It 'rejects a flag group whose args is not an array of strings' {
        $tool = '{ "name": "t", "executable": "t.exe", "roles": { "pager": { "flags": { "theme": [{ "ifFile": "a", "args": "x" }] } } } }' | ConvertFrom-Json
        (Test-DFToolSchema -Tool $tool).Errors -join ';' | Should -Match 'roles.pager.flags'
    }
}

# M6: a package object's install fields (the script source's) are checked for every record, user records too.
Describe 'packages object install fields (schema)' {
    BeforeAll {
        function script:Get-PackageErrs($Entry) {
            (Test-DFToolSchema -Tool ([pscustomobject]@{ name = 't'; executable = 't.exe'; packages = [pscustomobject]@{ script = $Entry } })).Errors
        }
    }
    It 'accepts installed and remove paths rooted at ${HOME} or an XDG folder, and update argv or self' {
        Get-PackageErrs ([pscustomobject]@{ id = 'https://x.invalid/i.ps1'; installed = '${HOME}/.local/bin/t.exe'; remove = @('${XDG_DATA_HOME}/t'); update = @('t', 'update') }) | Should -BeNullOrEmpty
        Get-PackageErrs ([pscustomobject]@{ id = 'https://x.invalid/i.ps1'; installed = '${HOME}/t.exe'; update = 'self' }) | Should -BeNullOrEmpty
    }
    It 'rejects a path that isn''t rooted there, or climbs out with ..' {
        Get-PackageErrs ([pscustomobject]@{ id = 'https://x.invalid/i.ps1'; installed = 'C:/t.exe' }) | Should -Match 'installed'
        Get-PackageErrs ([pscustomobject]@{ id = 'https://x.invalid/i.ps1'; installed = '${HOME}/t.exe'; remove = @('${HOME}/../x') }) | Should -Match 'remove'
    }
    It 'rejects an update that is neither an argv nor self' {
        Get-PackageErrs ([pscustomobject]@{ id = 'https://x.invalid/i.ps1'; installed = '${HOME}/t.exe'; update = 'later' }) | Should -Match 'update'
    }
}
