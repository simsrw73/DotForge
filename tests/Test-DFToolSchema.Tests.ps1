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
            $errors = @()
            Test-DFToolSchema -Tool $tool -Errors ([ref]$errors) | Should -BeTrue
            $errors | Should -BeNullOrEmpty
        }

        It 'passes a tool with type = "exe"' {
            $tool = [PSCustomObject]@{ name = 't'; executable = 't.exe'; type = 'exe' }
            Test-DFToolSchema -Tool $tool -Errors ([ref]$null) | Should -BeTrue
        }

        It 'passes a tool with type = "module"' {
            $tool = [PSCustomObject]@{ name = 't'; executable = 't'; type = 'module' }
            Test-DFToolSchema -Tool $tool -Errors ([ref]$null) | Should -BeTrue
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
            Test-DFToolSchema -Tool $tool -Errors ([ref]$null) | Should -BeTrue
        }
    }

    Context 'invalid records' {
        It 'fails when name is missing' {
            $tool = [PSCustomObject]@{ executable = 'tool.exe' }
            $errors = @()
            Test-DFToolSchema -Tool $tool -Errors ([ref]$errors) | Should -BeFalse
            $errors | Where-Object { $_ -match 'name' } | Should -Not -BeNullOrEmpty
        }

        It 'fails when executable is missing' {
            $tool = [PSCustomObject]@{ name = 'mytool' }
            $errors = @()
            Test-DFToolSchema -Tool $tool -Errors ([ref]$errors) | Should -BeFalse
            $errors | Where-Object { $_ -match 'executable' } | Should -Not -BeNullOrEmpty
        }

        It 'fails when xdg.method is not a valid value' {
            $tool = [PSCustomObject]@{
                name       = 'mytool'
                executable = 'mytool.exe'
                xdg        = [PSCustomObject]@{ method = 'invalid' }
            }
            $errors = @()
            Test-DFToolSchema -Tool $tool -Errors ([ref]$errors) | Should -BeFalse
            $errors | Where-Object { $_ -match 'xdg.method' } | Should -Not -BeNullOrEmpty
        }

        It 'fails when type is not a valid value' {
            $tool = [PSCustomObject]@{ name = 't'; executable = 't.exe'; type = 'binary' }
            $errors = @()
            Test-DFToolSchema -Tool $tool -Errors ([ref]$errors) | Should -BeFalse
            $errors | Where-Object { $_ -match 'type' } | Should -Not -BeNullOrEmpty
        }

        It 'rejects a scoopBucket without both name and url' {
            $t = '{ "name": "t", "executable": "t.exe", "scoopBucket": { "name": "x" } }' | ConvertFrom-Json
            $errs = @()
            Test-DFToolSchema -Tool $t -Errors ([ref]$errs) | Should -BeFalse
            "$errs" | Should -Match 'scoopBucket'
        }

        It 'accepts a one-element executableExclude array' {
            $t = '{ "name": "t", "executable": "t.exe", "executableExclude": ["*\\Git\\usr\\bin\\*"] }' | ConvertFrom-Json
            $errs = @()
            Test-DFToolSchema -Tool $t -Errors ([ref]$errs) | Should -BeTrue -Because "$errs"
        }

        It 'rejects an executableExclude that is not an array of strings' {
            $t = '{ "name": "t", "executable": "t.exe", "executableExclude": "x" }' | ConvertFrom-Json
            $errs = @()
            Test-DFToolSchema -Tool $t -Errors ([ref]$errs) | Should -BeFalse
            "$errs" | Should -Match 'executableExclude'
        }

        It 'rejects roles that is not an object' {
            $t = '{ "name": "t", "executable": "t.exe", "roles": ["listing"] }' | ConvertFrom-Json
            $errs = @()
            Test-DFToolSchema -Tool $t -Errors ([ref]$errs) | Should -BeFalse
            "$errs" | Should -Match 'roles'
        }

        It 'rejects a non-integer role priority' {
            $t = '{ "name": "t", "executable": "t.exe", "roles": { "pager": { "priority": "high" } } }' | ConvertFrom-Json
            $errs = @()
            Test-DFToolSchema -Tool $t -Errors ([ref]$errs) | Should -BeFalse
            "$errs" | Should -Match 'priority'
        }

        It 'accepts an integer role priority and an empty role block' {
            $t = '{ "name": "t", "executable": "t.exe", "roles": { "pager": { "priority": 10 }, "grep": {} } }' | ConvertFrom-Json
            $errs = @()
            Test-DFToolSchema -Tool $t -Errors ([ref]$errs) | Should -BeTrue
        }

        It 'accepts a boolean role optIn and rejects another type' {
            $valid = '{ "name": "t", "executable": "t.exe", "roles": { "optional": { "optIn": true } } }' | ConvertFrom-Json
            $invalid = '{ "name": "t", "executable": "t.exe", "roles": { "optional": { "optIn": "yes" } } }' | ConvertFrom-Json
            $errors = @()
            Test-DFToolSchema -Tool $valid -Errors ([ref]$errors) | Should -BeTrue -Because "$errors"
            $errors = @()
            Test-DFToolSchema -Tool $invalid -Errors ([ref]$errors) | Should -BeFalse
            "$errors" | Should -Match 'optIn'
        }
    }

    Context 'field shapes' {
        BeforeAll {
            function script:Get-SchemaErrors($Extra) {
                $tool = [pscustomobject]@{ name = 't'; executable = 't.exe' }
                foreach ($k in $Extra.Keys) { $tool | Add-Member -NotePropertyName $k -NotePropertyValue $Extra[$k] }
                $errs = @()
                $null = Test-DFToolSchema -Tool $tool -Errors ([ref]$errs)
                "$errs"
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
        It 'requires dependsOn to be an array of strings, and prewarm a boolean' {
            Get-SchemaErrors @{ dependsOn = @('fnm') } | Should -BeNullOrEmpty
            Get-SchemaErrors @{ dependsOn = 'fnm' } | Should -Match 'dependsOn'
            Get-SchemaErrors @{ dependsOn = @('fnm', 3) } | Should -Match 'dependsOn'
            Get-SchemaErrors @{ prewarm = $false } | Should -BeNullOrEmpty
            Get-SchemaErrors @{ prewarm = 'false' } | Should -Match 'prewarm'
        }
    }

    Context 'typo warnings' {
        BeforeAll {
            function script:Get-SchemaWarnings([pscustomobject]$Tool) {
                $errs = @(); $warns = @()
                $null = Test-DFToolSchema -Tool $Tool -Errors ([ref]$errs) -Warnings ([ref]$warns)
                $warns
            }
        }

        It 'warns about a field that looks like a misspelled known field, naming the suggestion' {
            $w = Get-SchemaWarnings ([pscustomobject]@{ name = 't'; executable = 't.exe'; dependson = @('x'); themMap = [pscustomobject]@{} })
            "$w" | Should -Match "dependson.*dependsOn"
            "$w" | Should -Match "themMap.*themeMap"
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
        It 'does not warn about extra fields that resemble nothing known (tool authors may carry data)' {
            Get-SchemaWarnings ([pscustomobject]@{ name = 't'; executable = 't.exe'; homepage = 'https://x'; notes = 'n' }) |
                Should -BeNullOrEmpty
        }
        It 'keeps the tool valid when it only has warnings' {
            $errs = @(); $warns = @()
            Test-DFToolSchema -Tool ([pscustomobject]@{ name = 't'; executable = 't.exe'; dependson = @() }) -Errors ([ref]$errs) -Warnings ([ref]$warns) |
                Should -BeTrue
        }
    }
}

Describe 'Import-DFToolDb schema warnings' {
    It 'loads a tool with a typo warning, and reports the warning with the file name' {
        $dir = Join-Path $TestDrive 'tools-typo'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        '{ "name": "typotool", "executable": "typo.exe", "dependson": [] }' | Set-Content (Join-Path $dir 'typotool.json')
        $db = Import-DFToolDb -ToolsPath $dir -WarningVariable w 3>$null
        $db.ContainsKey('typotool') | Should -BeTrue
        "$w" | Should -Match 'typotool\.json.*dependson.*dependsOn'
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
        $errors = @(); $warnings = @()
        Test-DFToolSchema -Tool $tool -Errors ([ref]$errors) -Warnings ([ref]$warnings) |
            Should -BeTrue -Because ($errors -join '; ')
        $warnings | Should -BeNullOrEmpty
    }
}
