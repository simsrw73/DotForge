BeforeAll {
    . "$PSScriptRoot/../Private/ConvertTo-DFPath.ps1"
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/Get-DFCachedCommandOutput.ps1"
    $script:CompanionPath = Join-Path $PSScriptRoot '../Tools/direnv.ps1'
}

Describe 'direnv tool JSON' {
    It 'is natively XDG-compliant -- no xdg.vars needed' {
        $j = Get-Content (Join-Path $PSScriptRoot '../Tools/direnv.json') -Raw | ConvertFrom-Json
        $j.xdg.method | Should -Be 'default'
    }
}

# Scoped narrowly to the hook caching, mirroring zoxide.Tests.ps1/carapace.Tests.ps1.
Describe 'direnv tool sidecar caching' -Skip:(-not (Get-Command direnv.exe -ErrorAction Ignore)) {
    BeforeEach {
        $script:SavedCacheHome = $Env:XDG_CACHE_HOME
        $Env:XDG_CACHE_HOME    = Join-Path $TestDrive 'cache'
        Remove-Item $Env:XDG_CACHE_HOME -Recurse -Force -ErrorAction Ignore
    }
    AfterEach {
        $Env:XDG_CACHE_HOME = $script:SavedCacheHome
    }

    It 'caches the real hook script, and does not regenerate it on a second load' {
        # Genuinely calls the real direnv binary -- see carapace.Tests.ps1 for why
        # a function stand-in would defeat this test (no fingerprintable .Source).
        . $script:CompanionPath
        $cacheFile = Join-Path $Env:XDG_CACHE_HOME 'dotforge' 'direnv-hook.txt'
        Test-Path $cacheFile | Should -BeTrue
        $writtenAfterFirst = (Get-Item $cacheFile).LastWriteTimeUtc

        Start-Sleep -Milliseconds 50
        . $script:CompanionPath

        (Get-Item $cacheFile).LastWriteTimeUtc | Should -Be $writtenAfterFirst
    }
}
