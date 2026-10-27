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

# ifFree: an alias that must not hide a program of the same name (cc over a C compiler).
Describe 'Register-DFToolAliases ifFree' {
    BeforeEach {
        Reset-DFTestSession; Set-DFTestXdg
        # TestDrive lasts for the whole Describe: start each test with no cached lookups.
        Remove-Item (Join-Path $Env:XDG_CACHE_HOME 'dotforge') -Recurse -Force -ErrorAction Ignore
    }
    AfterEach {
        Restore-DFTestXdg
        Remove-Alias dfxfree -Force -Scope Global -ErrorAction Ignore
        Remove-DFTestGlobal -Function 'dfxfree'
    }

    It 'skips an ifFree alias when a program of that name exists, with a status note' {
        Mock Test-DFCommandExists { $true }
        $tool = '{ "name": "t", "aliases": { "dfxfree": { "command": "Get-Date", "ifFree": true } } }' | ConvertFrom-Json
        Register-DFToolAliases -Tool $tool
        Get-Alias dfxfree -Scope Global -ErrorAction Ignore | Should -BeNullOrEmpty
        Test-Path 'function:global:dfxfree' | Should -BeFalse
        Get-DFToolNote -Tool t | Should -Match 'dfxfree'
    }
    It 'creates an ifFree alias when the name is free' {
        Mock Test-DFCommandExists { $false }
        $tool = '{ "name": "t", "aliases": { "dfxfree": { "command": "Get-Date", "args": ["-Format", "yyyy"], "ifFree": true } } }' | ConvertFrom-Json
        Register-DFToolAliases -Tool $tool
        Test-Path 'function:global:dfxfree' | Should -BeTrue
    }
    It 'creates an alias without ifFree even when a program has that name' {
        Mock Test-DFCommandExists { $true }
        $tool = '{ "name": "t", "aliases": { "dfxfree": { "command": "Get-Date" } } }' | ConvertFrom-Json
        Register-DFToolAliases -Tool $tool
        (Get-Alias dfxfree -Scope Global).Definition | Should -Be 'Get-Date'
    }
    It 'looks the names up once until PATH changes (a shell start doesn''t pay for it)' {
        Mock Test-DFCommandExists { $false }
        $tool = '{ "name": "t", "aliases": { "dfxfree": { "command": "Get-Date", "ifFree": true } } }' | ConvertFrom-Json
        Register-DFToolAliases -Tool $tool
        Register-DFToolAliases -Tool $tool
        Should -Invoke Test-DFCommandExists -Times 1 -Exactly
        $saved = $Env:Path
        try {
            $Env:Path = "$Env:Path;C:\dfx-new-folder"
            Register-DFToolAliases -Tool $tool
            Should -Invoke Test-DFCommandExists -Times 2 -Exactly
        } finally { $Env:Path = $saved }
    }
    It 'normalizes ifFree, false when absent' {
        $record = ConvertTo-DFToolRecord ('{ "name": "t", "executable": "t.exe", "aliases": { "a": { "command": "x", "ifFree": true }, "b": { "command": "y" } } }' | ConvertFrom-Json)
        $record.aliases.a.ifFree | Should -BeTrue
        $record.aliases.b.ifFree | Should -BeFalse
    }
    It 'ifFree must be a boolean' {
        $errors = (Test-DFToolSchema -Tool ('{ "name": "t", "executable": "t.exe", "aliases": { "a": { "command": "x", "ifFree": "yes" } } }' | ConvertFrom-Json)).Errors
        $errors | Should -Match 'ifFree'
    }
}
