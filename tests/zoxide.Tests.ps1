BeforeAll {
    . "$PSScriptRoot/../Private/ConvertTo-DFPath.ps1"
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/Get-DFCachedCommandOutput.ps1"
    $script:CompanionPath = Join-Path $PSScriptRoot '../Tools/zoxide.ps1'
}

# Scoped narrowly to the init-script caching this session's startup-perf audit
# added (docs/superpowers/specs/2026-09-05-startup-perf-audit.md) -- zoxide.ps1
# has no pre-existing coverage beyond this and is otherwise out of scope here.
Describe 'zoxide tool sidecar caching' -Skip:(-not (Get-Command zoxide.exe -ErrorAction Ignore)) {
    BeforeEach {
        $script:SavedCacheHome = $Env:XDG_CACHE_HOME
        $Env:XDG_CACHE_HOME    = Join-Path $TestDrive 'cache'
        Remove-Item $Env:XDG_CACHE_HOME -Recurse -Force -ErrorAction Ignore
    }
    AfterEach {
        $Env:XDG_CACHE_HOME = $script:SavedCacheHome
        Remove-Alias -Name cd -Scope Global -Force -ErrorAction Ignore
    }

    It 'caches the real init script, and does not regenerate it on a second load' {
        # Genuinely calls the real zoxide binary -- see carapace.Tests.ps1 for why
        # a function stand-in would defeat this test (no fingerprintable .Source).
        . $script:CompanionPath
        $cacheFile = Join-Path $Env:XDG_CACHE_HOME 'dotforge' 'zoxide-init.txt'
        Test-Path $cacheFile | Should -BeTrue
        $writtenAfterFirst = (Get-Item $cacheFile).LastWriteTimeUtc

        Start-Sleep -Milliseconds 50
        . $script:CompanionPath

        (Get-Item $cacheFile).LastWriteTimeUtc | Should -Be $writtenAfterFirst
    }
}
