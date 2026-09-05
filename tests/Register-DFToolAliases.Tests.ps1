BeforeAll {
    . "$PSScriptRoot/../Private/Register-DFToolAliases.ps1"
}

Describe 'Register-DFToolAliases' {
    AfterEach {
        Remove-Alias testalias -Force -Scope Global -ErrorAction Ignore
        Remove-Item 'function:global:testalias-v' -ErrorAction Ignore
        Remove-Alias ls -Force -Scope Global -ErrorAction Ignore
        Remove-Item 'function:global:ls' -ErrorAction Ignore
    }

    It 'creates a zero-arg alias with Set-Alias' {
        $tool = '{ "name": "t", "aliases": { "testalias": { "command": "notepad", "args": [] } } }' | ConvertFrom-Json
        Register-DFToolAliases -Tool $tool -RoleWinner $null
        (Get-Alias testalias).Definition | Should -Be 'notepad'
    }

    It 'creates a wrapper function for an alias with args, removing a colliding builtin alias first' {
        $tool = '{ "name": "t", "aliases": { "ls": { "command": "eza", "args": ["--icons"] } } }' | ConvertFrom-Json
        Register-DFToolAliases -Tool $tool -RoleWinner $null
        Test-Path 'Alias:\ls' | Should -BeFalse
        Test-Path 'function:global:ls' | Should -BeTrue
    }

    It 'skips an alias whose key is suppressed by a different role winner' {
        $tool = '{ "name": "lsd", "role": "listing", "aliases": { "ls": { "command": "lsd", "args": [] } } }' | ConvertFrom-Json
        $roleWinner = @{ WinnerName = 'eza'; AliasKeys = @('ls') }
        Register-DFToolAliases -Tool $tool -RoleWinner $roleWinner
        (Get-Alias ls -ErrorAction Ignore) | Should -BeNullOrEmpty
    }

    It 'still applies the role winner''s own aliases (WinnerName matches Tool.name)' {
        $tool = '{ "name": "eza", "role": "listing", "aliases": { "ls": { "command": "eza", "args": [] } } }' | ConvertFrom-Json
        $roleWinner = @{ WinnerName = 'eza'; AliasKeys = @('ls') }
        Register-DFToolAliases -Tool $tool -RoleWinner $roleWinner
        (Get-Alias ls).Definition | Should -Be 'eza'
    }

    It 'does nothing when Tool has no aliases property' {
        $tool = '{ "name": "noaliastool" }' | ConvertFrom-Json
        { Register-DFToolAliases -Tool $tool -RoleWinner $null } | Should -Not -Throw
    }

    It 'skips an alias entry with no command' {
        $tool = '{ "name": "t", "aliases": { "testalias": { "args": [] } } }' | ConvertFrom-Json
        { Register-DFToolAliases -Tool $tool -RoleWinner $null } | Should -Not -Throw
        (Get-Alias testalias -ErrorAction Ignore) | Should -BeNullOrEmpty
    }
}
