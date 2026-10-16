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
