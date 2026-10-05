BeforeAll {
    . "$PSScriptRoot/../Private/Test-DFOutputPiped.ps1"
    . "$PSScriptRoot/../Private/Write-DFFileAtomic.ps1"
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/DFCatalog.Base.ps1"
    . "$PSScriptRoot/../Private/DFReleaseData.ps1"
    . "$PSScriptRoot/../Private/Get-DFConfiguredTheme.ps1"
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

Describe 'Get-DFXdgPath' {
    BeforeEach { $script:saved = $Env:XDG_CACHE_HOME }
    AfterEach  { $Env:XDG_CACHE_HOME = $script:saved }

    It 'returns the environment value, canonicalized, when set' {
        $Env:XDG_CACHE_HOME = 'C:\x\.\cache\'
        Get-DFXdgPath -Kind Cache | Should -Be 'C:\x\cache'
    }

    It 'returns the XDG default under $HOME when unset, without setting the variable' {
        $Env:XDG_CACHE_HOME = $null
        Get-DFXdgPath -Kind Cache | Should -Be (ConvertTo-DFPath (Join-Path $HOME '.cache'))
        $Env:XDG_CACHE_HOME | Should -BeNullOrEmpty
    }

    It 'knows every kind' -ForEach @(
        @{ Kind = 'Config'; Tail = '.config' }
        @{ Kind = 'Data';   Tail = '.local\share' }
        @{ Kind = 'State';  Tail = '.local\state' }
        @{ Kind = 'Cache';  Tail = '.cache' }
        @{ Kind = 'Bin';    Tail = '.local\bin' }
    ) {
        $var = "XDG_$($Kind.ToUpperInvariant())_HOME"
        $saved = [Environment]::GetEnvironmentVariable($var)
        try {
            [Environment]::SetEnvironmentVariable($var, $null)
            Get-DFXdgPath -Kind $Kind | Should -Be (ConvertTo-DFPath (Join-Path $HOME $Tail))
        } finally { [Environment]::SetEnvironmentVariable($var, $saved) }
    }
}
