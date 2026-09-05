BeforeAll {
    . "$PSScriptRoot/../Private/ConvertTo-DFPath.ps1"
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/Get-DFCachedCommandOutput.ps1"
    . "$PSScriptRoot/../Private/Initialize-DFCompletionStack.ps1"
    $script:CompanionPath = Join-Path $PSScriptRoot '../Tools/carapace.ps1'
}

# Scoped narrowly to the init-script caching this session's startup-perf audit
# added (docs/superpowers/specs/2026-09-05-startup-perf-audit.md) -- carapace.ps1's
# broader behavior (inshellisense bridging, the PSFzf trailing-space rewrite) has
# no pre-existing coverage and is out of scope here.
Describe 'carapace tool sidecar caching' -Skip:(-not (Get-Command carapace.exe -ErrorAction Ignore)) {
    BeforeEach {
        $script:SavedCacheHome = $Env:XDG_CACHE_HOME
        $script:SavedBridges   = $Env:CARAPACE_BRIDGES
        $Env:XDG_CACHE_HOME    = Join-Path $TestDrive 'cache'
        Remove-Item $Env:XDG_CACHE_HOME -Recurse -Force -ErrorAction Ignore
        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
    }
    AfterEach {
        $Env:XDG_CACHE_HOME    = $script:SavedCacheHome
        $Env:CARAPACE_BRIDGES  = $script:SavedBridges
        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
    }

    It 'caches the real init script, and does not regenerate it on a second load' {
        # Genuinely calls the real carapace binary (no stub) -- a function
        # stand-in (tests/scoop.Tests.ps1's pattern for git/scoop-search) would
        # defeat this test, since Get-DFCachedCommandOutput's fingerprint needs
        # Get-Command to resolve a real file (a function has no .Source path),
        # so stubbing the command would just force the always-uncached fallback
        # path instead of exercising caching at all.
        . $script:CompanionPath
        $cacheFile = Join-Path $Env:XDG_CACHE_HOME 'dotforge' 'carapace-init.txt'
        Test-Path $cacheFile | Should -BeTrue
        $writtenAfterFirst = (Get-Item $cacheFile).LastWriteTimeUtc

        Start-Sleep -Milliseconds 50
        . $script:CompanionPath

        # If the second load had regenerated (cache miss), Set-Content would have
        # touched the file again -- unchanged mtime proves it did not.
        (Get-Item $cacheFile).LastWriteTimeUtc | Should -Be $writtenAfterFirst
    }
}
