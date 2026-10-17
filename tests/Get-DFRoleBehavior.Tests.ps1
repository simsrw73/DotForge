BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }

    $script:Role = ConvertTo-DFRoleRecord -Name 'listing' -Role ('{ "kind": "single", "hook": "Initialize-DFRoleListing",
        "behaviors": {
          "words": { "long": "d", "all": "h", "color": "c", "one-per-line": "1", "literal": "q" },
          "aliases": { "ll": ["long", "color", "literal"], "la": ["long", "all", "color", "literal"] },
          "pickers": [ { "alias": "ff", "function": "Select-File", "list": ["one-per-line", "color", "literal"],
                         "list_accepts_path": true, "preview": "bat {}", "action": "output" } ] } }' | ConvertFrom-Json)
    function script:New-Member([string]$FlagsJson) {
        ConvertTo-DFToolRecord ("{ ""name"": ""lsx"", ""executable"": ""lsx.exe"", ""roles"": { ""listing"": { ""flags"": $FlagsJson } } }" | ConvertFrom-Json)
    }
}

Describe 'Get-DFRoleBehaviorAlias' {
    BeforeEach { Clear-DFToolNote -Tool 'lsx' }

    It 'turns each alias''s words into the winner''s flags, in the role''s order' {
        $tool = New-Member '{ "long": ["--long"], "all": ["--all"], "color": ["--color=auto"], "one-per-line": ["-1"], "literal": ["--literal"] }'
        $aliases = Get-DFRoleBehaviorAlias -RoleDefinition $script:Role -Block $tool.roles.listing -Tool $tool
        $aliases.ll.command | Should -Be 'lsx'
        $aliases.ll.args | Should -Be @('--long', '--color=auto', '--literal')
        $aliases.la.args | Should -Be @('--long', '--all', '--color=auto', '--literal')
    }

    It 'adds nothing for a word mapped to []' {
        $tool = New-Member '{ "long": ["--long"], "all": ["--all"], "color": [], "one-per-line": ["-1"], "literal": [] }'
        (Get-DFRoleBehaviorAlias -RoleDefinition $script:Role -Block $tool.roles.listing -Tool $tool).ll.args | Should -Be @('--long')
    }

    It 'skips a missing word and reports it' {
        $tool = New-Member '{ "long": ["--long"], "color": [], "one-per-line": ["-1"], "literal": [] }'
        (Get-DFRoleBehaviorAlias -RoleDefinition $script:Role -Block $tool.roles.listing -Tool $tool).la.args | Should -Be @('--long')
        Get-DFToolNote -Tool 'lsx' | Should -Be @("listing: no flag for 'all' (la)")
    }
}

Describe 'Get-DFRolePicker' {
    BeforeEach { Clear-DFToolNote -Tool 'lsx' }

    It 'builds the list command from the winner''s flags and keeps the other fields' {
        $tool = New-Member '{ "long": ["--long"], "all": ["--all"], "color": ["--color=always"], "one-per-line": ["-1"], "literal": ["--literal"] }'
        $picker = @(Get-DFRolePicker -RoleDefinition $script:Role -Block $tool.roles.listing -Tool $tool)
        $picker.Count | Should -Be 1
        $picker[0].list | Should -Be 'lsx -1 --color=always --literal'
        $picker[0].alias | Should -Be 'ff'
        $picker[0].list_accepts_path | Should -BeTrue
        $picker[0].preview | Should -Be 'bat {}'
    }

    It 'does not change the role definition''s picker' {
        $tool = New-Member '{ "long": [], "all": [], "color": [], "one-per-line": ["-1"], "literal": [] }'
        Get-DFRolePicker -RoleDefinition $script:Role -Block $tool.roles.listing -Tool $tool | Out-Null
        $script:Role.behaviors.pickers[0].list | Should -Be @('one-per-line', 'color', 'literal')
    }
}

Describe 'flag groups' {
    BeforeEach { Clear-DFToolNote -Tool 'lsx'; Set-DFTestXdg }
    AfterEach { Restore-DFTestXdg }

    It 'passes a group only while ifFile exists and unlessFile does not' {
        $cfg = Join-Path $TestDrive 'c.yaml'; $own = Join-Path $Env:XDG_CONFIG_HOME 'own.yaml'
        Remove-Item $cfg, $own -ErrorAction Ignore
        $flags = [pscustomobject]@{ theme = @([pscustomobject]@{ ifFile = $cfg; unlessFile = '${XDG_CONFIG_HOME}/own.yaml'; args = @('--config', '{file}') }) }
        $tool = [pscustomobject]@{ name = 'lsx'; executable = 'lsx.exe'; settings = $null; theme = $null }
        (Resolve-DFRoleWords -Words @('theme') -Flags $flags -Tool $tool).Args | Should -BeNullOrEmpty
        Set-Content $cfg 'x'
        (Resolve-DFRoleWords -Words @('theme') -Flags $flags -Tool $tool).Args | Should -Be @('--config', $cfg)
        New-Item -ItemType File -Force $own | Out-Null
        (Resolve-DFRoleWords -Words @('theme') -Flags $flags -Tool $tool).Args | Should -BeNullOrEmpty
    }
    It 'expands {theme} in a group path from the tool''s theme' {
        $folder = Join-Path $TestDrive 'flavor'; New-Item -ItemType Directory -Force $folder | Out-Null; Set-Content (Join-Path $folder 'c.yaml') 'x'
        Mock Get-DFToolTheme { [pscustomobject]@{ Value = $folder } }
        $flags = [pscustomobject]@{ theme = @([pscustomobject]@{ ifFile = '{theme}/c.yaml'; args = @('--config', '{file}') }) }
        $tool = [pscustomobject]@{ name = 'lsx'; executable = 'lsx.exe'; settings = $null; theme = [pscustomobject]@{ key = 'X' } }
        (Resolve-DFRoleWords -Words @('theme') -Flags $flags -Tool $tool).Args | Should -Be @('--config', (Join-Path $folder 'c.yaml'))
    }
    It 'treats {theme} with no theme value as a missing file' {
        Mock Get-DFToolTheme { [pscustomobject]@{ Value = $null } }
        $flags = [pscustomobject]@{ theme = @([pscustomobject]@{ ifFile = '{theme}/c.yaml'; args = @('--config', '{file}') }) }
        $tool = [pscustomobject]@{ name = 'lsx'; executable = 'lsx.exe'; settings = $null; theme = [pscustomobject]@{ key = 'X' } }
        (Resolve-DFRoleWords -Words @('theme') -Flags $flags -Tool $tool).Args | Should -BeNullOrEmpty
    }
}

Describe 'Get-DFRoleBehaviorEnv' {
    BeforeAll {
        $script:EnvRole = ConvertTo-DFRoleRecord -Name 'pager' -Role ('{ "kind": "single", "hook": "Initialize-DFRolePager",
            "behaviors": { "words": { "quit": "q", "color": "c" }, "env": { "PAGER": ["quit", "color"] } } }' | ConvertFrom-Json)
    }
    It 'builds each variable as the winner''s executable and its flags' {
        $tool = ConvertTo-DFToolRecord ('{ "name": "lsx", "executable": "lsx.exe", "roles": { "pager": { "flags": { "quit": ["-F"], "color": ["-R"] } } } }' | ConvertFrom-Json)
        Mock ConvertTo-DFToolExePathToken { 'lsx' }
        (Get-DFRoleBehaviorEnv -RoleDefinition $script:EnvRole -Block $tool.roles.pager -Tool $tool)['PAGER'] | Should -Be 'lsx -F -R'
    }
    It 'quotes an argument that holds a space' {
        $tool = ConvertTo-DFToolRecord ('{ "name": "lsx", "executable": "lsx.exe", "roles": { "pager": { "flags": { "quit": ["--config", "C:/Program Files/x.yaml"], "color": [] } } } }' | ConvertFrom-Json)
        Mock ConvertTo-DFToolExePathToken { 'lsx' }
        (Get-DFRoleBehaviorEnv -RoleDefinition $script:EnvRole -Block $tool.roles.pager -Tool $tool)['PAGER'] | Should -Be 'lsx --config "C:/Program Files/x.yaml"'
    }
}

Describe 'role behaviors keep data from becoming code' {
    BeforeEach { Clear-DFToolNote -Tool 'lsx'; Set-DFTestXdg }
    AfterEach { Restore-DFTestXdg }

    It 'quotes a picker argument that is not plainly safe as a PowerShell literal' {
        $tool = New-Member '{ "long": [], "all": [], "color": ["--x=$(Get-Date);rm -rf"], "one-per-line": ["-1"], "literal": ["it''s"] }'
        $list = (Get-DFRolePicker -RoleDefinition $script:Role -Block $tool.roles.listing -Tool $tool)[0].list
        $list | Should -Be "lsx -1 '--x=`$(Get-Date);rm -rf' 'it''s'"
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($list, [ref]$tokens, [ref]$errors)
        $errors | Should -BeNullOrEmpty
        @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.SubExpressionAst] }, $true)).Count | Should -Be 0
    }

    It 'drops a group whose path holds a shell-active character, with a note' {
        $odd = Join-Path $TestDrive 'a$b'; New-Item -ItemType Directory -Force $odd | Out-Null; Set-Content (Join-Path $odd 'c.yaml') 'x'
        $role = ConvertTo-DFRoleRecord -Name 'pager' -Role ('{ "kind": "single", "hook": "Initialize-DFRolePager",
            "behaviors": { "words": { "theme": "t" }, "env": { "PAGER": ["theme"] } } }' | ConvertFrom-Json)
        $tool = ConvertTo-DFToolRecord ("{ ""name"": ""lsx"", ""executable"": ""lsx.exe"", ""roles"": { ""pager"": { ""flags"": { ""theme"": [{ ""ifFile"": ""$($odd.Replace('\','/'))/c.yaml"", ""args"": [""--config"", ""{file}""] }] } } } }" | ConvertFrom-Json)
        Mock ConvertTo-DFToolExePathToken { 'lsx' }
        (Get-DFRoleBehaviorEnv -RoleDefinition $role -Block $tool.roles.pager -Tool $tool)['PAGER'] | Should -Be 'lsx'
        Get-DFToolNote -Tool 'lsx' | Should -Match 'unsafe'
    }

    It 'skips a group whose unlessFile cannot be resolved' {
        $cfg = Join-Path $TestDrive 'c.yaml'; Set-Content $cfg 'x'
        $flags = [pscustomobject]@{ theme = @([pscustomobject]@{ ifFile = $cfg; unlessFile = '{settings.missing}/own.yaml'; args = @('--config', '{file}') }) }
        $tool = [pscustomobject]@{ name = 'lsx'; executable = 'lsx.exe'; settings = $null; theme = $null }
        (Resolve-DFRoleWords -Words @('theme') -Flags $flags -Tool $tool).Args | Should -BeNullOrEmpty
    }
}
