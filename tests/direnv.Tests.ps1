BeforeAll {
    . "$PSScriptRoot/../Private/Test-DFOutputPiped.ps1"
    . "$PSScriptRoot/../Private/Write-DFFileAtomic.ps1"
    . "$PSScriptRoot/../Private/DFCatalog.Base.ps1"
    . "$PSScriptRoot/../Private/DFReleaseData.ps1"
    . "$PSScriptRoot/../Private/Get-DFConfiguredTheme.ps1"
    . "$PSScriptRoot/../Private/ConvertTo-DFPath.ps1"
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/Get-DFCachedCommandOutput.ps1"
    $script:CompanionPath = Join-Path $PSScriptRoot '../Tools/direnv.ps1'
    $script:OriginalLocationChangedAction = $ExecutionContext.SessionState.InvokeCommand.LocationChangedAction
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
        # Uninstall the real hook the test installed; see the last Describe.
        $ExecutionContext.SessionState.InvokeCommand.LocationChangedAction = $script:OriginalLocationChangedAction
    }

    It 'caches the real hook script, and does not regenerate it on a second load' {
        # Genuinely calls the real direnv binary -- see carapace.Tests.ps1 for why
        # a function stand-in would defeat this test (no fingerprintable .Source).
        . $script:CompanionPath; . Initialize-DFRoleProjectEnv -Role project-env
        $cacheFile = Join-Path $Env:XDG_CACHE_HOME 'dotforge' 'direnv-hook.txt'
        Test-Path $cacheFile | Should -BeTrue
        $writtenAfterFirst = (Get-Item $cacheFile).LastWriteTimeUtc

        Start-Sleep -Milliseconds 50
        . $script:CompanionPath; . Initialize-DFRoleProjectEnv -Role project-env

        (Get-Item $cacheFile).LastWriteTimeUtc | Should -Be $writtenAfterFirst
    }
}

# Runs after the caching test. direnv's real hook attaches to the process-wide
# LocationChangedAction; left installed, every later Set-Location in the run calls
# direnv, which on Windows can unload variables such as PATH.
Describe 'direnv tests clean up after themselves' {
    It 'leaves LocationChangedAction as it found it' {
        $ExecutionContext.SessionState.InvokeCommand.LocationChangedAction | Should -Be $script:OriginalLocationChangedAction
    }
}
