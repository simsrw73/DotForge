BeforeAll {
    . "$PSScriptRoot/../Private/ConvertTo-DFPath.ps1"
}

Describe 'ConvertTo-DFPath' {
    It 'collapses . and .. and normalizes separators' {
        ConvertTo-DFPath 'C:\a\.\b\..\c' | Should -Be 'C:\a\c'
        ConvertTo-DFPath 'C:\Users\me/.config/bat/bat.conf' | Should -Be 'C:\Users\me\.config\bat\bat.conf'
    }
    It 'strips a trailing separator but preserves the root' {
        ConvertTo-DFPath 'C:\a\b\'  | Should -Be 'C:\a\b'
        ConvertTo-DFPath 'C:\a\b\\' | Should -Be 'C:\a\b'
        ConvertTo-DFPath 'C:\'      | Should -Be 'C:\'
    }
    It 'expands a leading ~ to $HOME' {
        ConvertTo-DFPath '~'       | Should -Be ([System.IO.Path]::GetFullPath($HOME))
        ConvertTo-DFPath '~/glow'  | Should -Be (Join-Path $HOME 'glow')
        ConvertTo-DFPath '~\glow'  | Should -Be (Join-Path $HOME 'glow')
    }
    It 'does not touch a ~ that is not leading' {
        # Non-existent short-name path: GetFullPath leaves PROGRA~1 as-is (string only).
        ConvertTo-DFPath 'C:\zzznope\PROGRA~1\x' | Should -Be 'C:\zzznope\PROGRA~1\x'
    }
    It 'warns and returns relative input unchanged' {
        $w = ConvertTo-DFPath 'foo\bar' -WarningVariable warn -WarningAction SilentlyContinue
        $w | Should -Be 'foo\bar'
        $warn | Should -Match 'not an absolute path'
    }
    It 'treats a leading ~foo (no separator) as relative' {
        ConvertTo-DFPath '~foo' -WarningAction SilentlyContinue | Should -Be '~foo'
    }
    It 'passes null and empty through unchanged' {
        ConvertTo-DFPath ''   | Should -Be ''
        ConvertTo-DFPath $null | Should -BeNullOrEmpty
    }
    It 'is idempotent' {
        $once = ConvertTo-DFPath 'C:\a\.\b\..\c\'
        ConvertTo-DFPath $once | Should -Be $once
    }
    It 'canonicalizes a non-existent path without error' {
        ConvertTo-DFPath 'C:\no\such\x\..\y' | Should -Be 'C:\no\such\y'
    }
}
