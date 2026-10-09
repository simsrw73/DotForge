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

    It 'seed file <Name>.json exists and passes schema validation' -ForEach $seedFiles {
        Test-Path $Path | Should -BeTrue -Because "$Name.json must exist in Tools/"
        $tool = Get-Content $Path -Raw | ConvertFrom-Json
        $errors = @()
        Test-DFToolSchema -Tool $tool -Errors ([ref]$errors) |
            Should -BeTrue -Because ($errors -join '; ')
    }
}
