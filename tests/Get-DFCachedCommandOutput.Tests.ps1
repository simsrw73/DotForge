BeforeAll {
    . "$PSScriptRoot/../Private/ConvertTo-DFPath.ps1"
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/Get-DFCachedCommandOutput.ps1"
}

Describe 'Get-DFCachedCommandOutput' {
    BeforeEach {
        $script:SavedCacheHome = $Env:XDG_CACHE_HOME
        $Env:XDG_CACHE_HOME = Join-Path $TestDrive 'cache'
        Remove-Item $Env:XDG_CACHE_HOME -Recurse -Force -ErrorAction Ignore

        # A real file stands in for the resolved executable so LastWriteTimeUtc
        # is real data, not a mocked property on a fake path.
        $script:FakeExe = Join-Path $TestDrive 'fake-tool.exe'
        Set-Content -Path $script:FakeExe -Value 'binary-stand-in' -Encoding UTF8
        Mock Get-Command { [PSCustomObject]@{ Source = $script:FakeExe } }
    }
    AfterEach {
        $Env:XDG_CACHE_HOME = $script:SavedCacheHome
    }

    It 'calls -Generate and caches the result on a cold cache' {
        $script:calls = 0
        $result = Get-DFCachedCommandOutput -Name 'test-tool' -Executable 'test-tool' -Generate {
            $script:calls++
            'generated-output'
        }
        $result | Should -Be 'generated-output'
        $script:calls | Should -Be 1
        Test-Path (Join-Path $Env:XDG_CACHE_HOME 'dotforge' 'test-tool.txt') | Should -BeTrue
    }

    It 'reuses the cache on a second call -- does not re-invoke -Generate' {
        Get-DFCachedCommandOutput -Name 'test-tool' -Executable 'test-tool' -Generate { 'first' } | Out-Null

        $result = Get-DFCachedCommandOutput -Name 'test-tool' -Executable 'test-tool' -Generate {
            throw '-Generate should not run on a cache hit'
        }
        $result | Should -Be 'first'
    }

    It 'regenerates when the executable file changes (LastWriteTimeUtc differs)' {
        Get-DFCachedCommandOutput -Name 'test-tool' -Executable 'test-tool' -Generate { 'stale' } | Out-Null

        Start-Sleep -Milliseconds 50
        Set-Content -Path $script:FakeExe -Value 'a rebuilt binary' -Encoding UTF8

        $result = Get-DFCachedCommandOutput -Name 'test-tool' -Executable 'test-tool' -Generate { 'fresh' }
        $result | Should -Be 'fresh'
    }

    It 'regenerates when the resolved path changes even if the old file is untouched' {
        Get-DFCachedCommandOutput -Name 'test-tool' -Executable 'test-tool' -Generate { 'from-old-path' } | Out-Null

        $newExe = Join-Path $TestDrive 'different-tool.exe'
        Set-Content -Path $newExe -Value 'binary-stand-in' -Encoding UTF8
        Mock Get-Command { [PSCustomObject]@{ Source = $newExe } }

        $result = Get-DFCachedCommandOutput -Name 'test-tool' -Executable 'test-tool' -Generate { 'from-new-path' }
        $result | Should -Be 'from-new-path'
    }

    It 'bypasses a valid cache when -Force is passed' {
        Get-DFCachedCommandOutput -Name 'test-tool' -Executable 'test-tool' -Generate { 'first' } | Out-Null

        $result = Get-DFCachedCommandOutput -Name 'test-tool' -Executable 'test-tool' -Force -Generate { 'forced' }
        $result | Should -Be 'forced'
    }

    It 'never caches an empty result, and retries -Generate next call' {
        Get-DFCachedCommandOutput -Name 'test-tool' -Executable 'test-tool' -Generate { '' } | Out-Null
        Test-Path (Join-Path $Env:XDG_CACHE_HOME 'dotforge' 'test-tool.txt') | Should -BeFalse

        $script:calls = 0
        Get-DFCachedCommandOutput -Name 'test-tool' -Executable 'test-tool' -Generate { $script:calls++; 'now-real' } | Out-Null
        $script:calls | Should -Be 1
    }

    It 'falls back to always calling -Generate, uncached, when the resolved command has no backing file (e.g. a function stand-in)' {
        # Regression: tests/scoop.Tests.ps1 stubs scoop-search as a PowerShell
        # function, not a real binary. Get-Command on a function does not
        # populate .Source with a usable file path -- Get-Item on it must not
        # throw, it must fall back to uncached generation.
        Mock Get-Command { [PSCustomObject]@{ Source = '' } }
        $script:calls = 0
        Get-DFCachedCommandOutput -Name 'test-tool' -Executable 'stub-function' -Generate { $script:calls++; 'x' } | Out-Null
        Get-DFCachedCommandOutput -Name 'test-tool' -Executable 'stub-function' -Generate { $script:calls++; 'x' } | Out-Null
        $script:calls | Should -Be 2
    }

    It 'falls back to always calling -Generate, uncached, when the executable does not resolve' {
        Mock Get-Command { $null }
        $script:calls = 0
        Get-DFCachedCommandOutput -Name 'test-tool' -Executable 'missing-tool' -Generate { $script:calls++; 'x' } | Out-Null
        Get-DFCachedCommandOutput -Name 'test-tool' -Executable 'missing-tool' -Generate { $script:calls++; 'x' } | Out-Null
        $script:calls | Should -Be 2
    }

    It 'falls back to always calling -Generate, uncached, when XDG_CACHE_HOME is unset' {
        $Env:XDG_CACHE_HOME = $null
        $script:calls = 0
        Get-DFCachedCommandOutput -Name 'test-tool' -Executable 'test-tool' -Generate { $script:calls++; 'x' } | Out-Null
        Get-DFCachedCommandOutput -Name 'test-tool' -Executable 'test-tool' -Generate { $script:calls++; 'x' } | Out-Null
        $script:calls | Should -Be 2
    }

    It 'keeps separate cache entries for different -Name values' {
        Get-DFCachedCommandOutput -Name 'tool-a' -Executable 'test-tool' -Generate { 'output-a' } | Out-Null
        Get-DFCachedCommandOutput -Name 'tool-b' -Executable 'test-tool' -Generate { 'output-b' } | Out-Null

        Get-DFCachedCommandOutput -Name 'tool-a' -Executable 'test-tool' -Generate { throw 'should not run' } | Should -Be 'output-a'
        Get-DFCachedCommandOutput -Name 'tool-b' -Executable 'test-tool' -Generate { throw 'should not run' } | Should -Be 'output-b'
    }
}
