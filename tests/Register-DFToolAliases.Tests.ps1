BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
}

Describe 'Register-DFToolAliases with no args key' {
    BeforeEach { Reset-DFTestSession }
    AfterEach { Remove-Alias testalias -Force -Scope Global -ErrorAction Ignore; Remove-DFTestGlobal -Function 'testalias' }

    It 'creates a plain alias when the record omits "args"' {
        # @($null).Count is 1, so a missing args key used to look like one argument
        # and produced a wrapper function instead of an alias.
        $tool = '{ "name": "t", "aliases": { "testalias": { "command": "notepad" } } }' | ConvertFrom-Json
        Register-DFToolAliases -Tool $tool
        (Get-Alias testalias -ErrorAction Ignore).Definition | Should -Be 'notepad'
        Test-Path 'function:global:testalias' | Should -BeFalse
    }
}

Describe 'Register-DFToolAliases' {
    BeforeEach { Reset-DFTestSession }
    AfterEach {
        Remove-Alias testalias -Force -Scope Global -ErrorAction Ignore
        Remove-DFTestGlobal -Function 'testalias-v'
        Remove-Alias ls -Force -Scope Global -ErrorAction Ignore
        Remove-DFTestGlobal -Function 'ls'
    }

    It 'creates a zero-arg alias with Set-Alias' {
        $tool = '{ "name": "t", "aliases": { "testalias": { "command": "notepad", "args": [] } } }' | ConvertFrom-Json
        Register-DFToolAliases -Tool $tool
        (Get-Alias testalias).Definition | Should -Be 'notepad'
    }

    It 'creates a wrapper function for an alias with args, removing a colliding builtin alias first' {
        $tool = '{ "name": "t", "aliases": { "ls": { "command": "eza", "args": ["--icons"] } } }' | ConvertFrom-Json
        Register-DFToolAliases -Tool $tool
        Test-Path 'Alias:\ls' | Should -BeFalse
        Test-Path 'function:global:ls' | Should -BeTrue
    }

    It 'registers the aliases passed in -Aliases instead of the tool''s own' {
        $tool = '{ "name": "rt", "aliases": { "own": { "command": "rt", "args": [] } } }' | ConvertFrom-Json
        $roleAliases = '{ "fromrole": { "command": "rt", "args": [] } }' | ConvertFrom-Json
        Register-DFToolAliases -Tool $tool -Aliases $roleAliases
        (Get-Alias fromrole -ErrorAction Ignore).Definition | Should -Be 'rt'
        Get-Alias own -ErrorAction Ignore | Should -BeNullOrEmpty
        Remove-DFTestGlobal -Alias fromrole
    }

    It 'does nothing when Tool has no aliases property' {
        $tool = '{ "name": "noaliastool" }' | ConvertFrom-Json
        { Register-DFToolAliases -Tool $tool } | Should -Not -Throw
    }

    It 'skips an alias entry with no command' {
        $tool = '{ "name": "t", "aliases": { "testalias": { "args": [] } } }' | ConvertFrom-Json
        { Register-DFToolAliases -Tool $tool } | Should -Not -Throw
        (Get-Alias testalias -ErrorAction Ignore) | Should -BeNullOrEmpty
    }
}
