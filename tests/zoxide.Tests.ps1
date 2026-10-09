BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    $script:CompanionPath = Join-Path $PSScriptRoot '../Tools/zoxide.ps1'
}

# Scoped narrowly to the init-script caching this session's startup-perf audit
# added (docs/superpowers/specs/2026-09-05-startup-perf-audit.md) -- zoxide.ps1
# has no pre-existing coverage beyond this and is otherwise out of scope here.
Describe 'zoxide tool sidecar caching' -Skip:(-not (Get-Command zoxide.exe -ErrorAction Ignore)) {
    BeforeEach {
        Set-DFTestXdg

        Remove-Item $Env:XDG_CACHE_HOME -Recurse -Force -ErrorAction Ignore
    }
    AfterEach {
        Remove-Alias -Name cd -Scope Global -Force -ErrorAction Ignore
        Restore-DFTestXdg
    }

    It 'caches the real init script, and does not regenerate it on a second load' {
        # Genuinely calls the real zoxide binary -- see carapace.Tests.ps1 for why
        # a function stand-in would defeat this test (no fingerprintable .Source).
        . $script:CompanionPath; . Initialize-DFRoleNavigation -Role navigation
        $cacheFile = Join-Path $Env:XDG_CACHE_HOME 'dotforge' 'zoxide-init.txt'
        Test-Path $cacheFile | Should -BeTrue
        $writtenAfterFirst = (Get-Item $cacheFile).LastWriteTimeUtc

        Start-Sleep -Milliseconds 50
        . $script:CompanionPath; . Initialize-DFRoleNavigation -Role navigation

        (Get-Item $cacheFile).LastWriteTimeUtc | Should -Be $writtenAfterFirst
    }
}
