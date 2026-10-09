BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    $script:CompanionPath = Join-Path $PSScriptRoot '../Tools/carapace.ps1'
}

# Scoped narrowly to the init-script caching this session's startup-perf audit
# added (docs/superpowers/specs/2026-09-05-startup-perf-audit.md) -- carapace.ps1's
# broader behavior (inshellisense bridging, the PSFzf trailing-space rewrite) has
# no pre-existing coverage and is out of scope here.
Describe 'carapace tool sidecar caching' -Skip:(-not (Get-Command carapace.exe -ErrorAction Ignore)) {
    BeforeEach {
        $script:SavedCacheHome  = $Env:XDG_CACHE_HOME
        $script:SavedConfigHome = $Env:XDG_CONFIG_HOME
        $script:SavedBridges    = $Env:CARAPACE_BRIDGES
        $Env:XDG_CACHE_HOME     = Join-Path $TestDrive 'cache'
        # The companion deploys specs under XDG_CONFIG_HOME; never the user's real one.
        $Env:XDG_CONFIG_HOME    = Join-Path $TestDrive 'config'
        Remove-Item $Env:XDG_CACHE_HOME, $Env:XDG_CONFIG_HOME -Recurse -Force -ErrorAction Ignore
        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
    }
    AfterEach {
        $Env:XDG_CACHE_HOME    = $script:SavedCacheHome
        $Env:XDG_CONFIG_HOME   = $script:SavedConfigHome
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

    It 'deploys byte-identical specs and leaves them untouched on a second load' {
        . $script:CompanionPath
        $specDir = Join-Path $Env:XDG_CONFIG_HOME 'carapace' 'specs'
        $bundled = Join-Path $PSScriptRoot '..' 'Tools' 'carapace' 'specs'
        $times = @{}
        foreach ($f in Get-ChildItem $bundled -Filter '*.yaml') {
            $dest = Join-Path $specDir $f.Name
            (Get-Content $dest -Raw) | Should -BeExactly (Get-Content $f.FullName -Raw)
            $times[$f.Name] = (Get-Item $dest).LastWriteTimeUtc
        }
        Start-Sleep -Milliseconds 50
        . $script:CompanionPath
        foreach ($name in $times.Keys) {
            (Get-Item (Join-Path $specDir $name)).LastWriteTimeUtc | Should -Be $times[$name]
        }
    }

    It 'regenerates the cached init when a user adds a spec' {
        . $script:CompanionPath
        $cacheFile = Join-Path $Env:XDG_CACHE_HOME 'dotforge' 'carapace-init.txt'
        $before = (Get-Item $cacheFile).LastWriteTimeUtc
        Start-Sleep -Milliseconds 50
        Set-Content (Join-Path $Env:XDG_CONFIG_HOME 'carapace' 'specs' 'dfdemo.yaml') -Value 'name: dfdemo'
        . $script:CompanionPath
        (Get-Item $cacheFile).LastWriteTimeUtc | Should -BeGreaterThan $before
    }
}

# carapace's completer returns "" to suppress file fallback when it has no
# answer; pwsh 7.6 throws on that, and PSFzf swallows the throw so Tab does
# nothing. The sidecar rewrites the sentinel to a bare return.
Describe 'carapace init rewrites' {
    BeforeAll {
        # Minimal stand-in for the two codegen lines the sidecar rewrites.
        $script:FakeInit = @'
carapace x powershell | ConvertFrom-Json | ForEach-Object { [CompletionResult]::new($_.CompletionText, $_.ListItemText) }
if ($completions.count -eq 0) {
  return "" # prevent default file completion
}
'@
    }
    BeforeEach {
        $script:SavedBridges = $Env:CARAPACE_BRIDGES
        # The companion deploys specs under XDG config; keep it off the real one.
        $script:SavedConfigHome = $Env:XDG_CONFIG_HOME
        $Env:XDG_CONFIG_HOME = Join-Path $TestDrive 'config'
        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
        $script:Captured = $null
        Mock Enable-DFCarapaceInshellisenseBridge { $false }
        Mock Get-DFCachedCommandOutput { $script:FakeInit }
        Mock Invoke-Expression { $script:Captured = $Command }
    }
    AfterEach {
        $Env:CARAPACE_BRIDGES = $script:SavedBridges
        $Env:XDG_CONFIG_HOME  = $script:SavedConfigHome
    }

    It 'replaces the empty-string sentinel with a bare return when PSFzf is available' {
        Mock Get-Module { [pscustomobject]@{ Name = 'PSFzf' } } -ParameterFilter { $Name -eq 'PSFzf' }
        . $script:CompanionPath
        $script:Captured | Should -Not -Match 'return ""'
        $script:Captured | Should -Match '(?m)^\s*return\s*$'
    }

    It 'replaces the empty-string sentinel with a bare return when PSFzf is absent' {
        Mock Get-Module { $null } -ParameterFilter { $Name -eq 'PSFzf' }
        . $script:CompanionPath
        $script:Captured | Should -Not -Match 'return ""'
        $script:Captured | Should -Match '(?m)^\s*return\s*$'
    }

    It 'drops whitespace-only items before the trimmed constructor under PSFzf' {
        Mock Get-Module { [pscustomobject]@{ Name = 'PSFzf' } } -ParameterFilter { $Name -eq 'PSFzf' }
        . $script:CompanionPath
        $script:Captured | Should -Match ([regex]::Escape('Where-Object { ([string]$_.CompletionText).Trim() } | ForEach-Object {'))
        $script:Captured | Should -Match ([regex]::Escape('([string]$_.CompletionText).TrimEnd()'))
    }
}

Describe 'carapace completer with a path carapace cannot complete' -Skip:(-not (Get-Command carapace.exe -ErrorAction Ignore)) {
    BeforeEach {
        $script:SavedCacheHome  = $Env:XDG_CACHE_HOME
        $script:SavedConfigHome = $Env:XDG_CONFIG_HOME
        $script:SavedBridges    = $Env:CARAPACE_BRIDGES
        $Env:XDG_CACHE_HOME     = Join-Path $TestDrive 'cache'
        $Env:XDG_CONFIG_HOME    = Join-Path $TestDrive 'config'
        $Env:CARAPACE_BRIDGES   = ''
        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
        Mock Enable-DFCarapaceInshellisenseBridge { $false }
        New-Item -ItemType Directory -Path (Join-Path $TestDrive 'work' 'sub') -Force | Out-Null
        Set-Content -Path (Join-Path $TestDrive 'work' 'sibling.txt') -Value 'x'
        Push-Location (Join-Path $TestDrive 'work' 'sub')
    }
    AfterEach {
        Pop-Location
        $Env:XDG_CACHE_HOME   = $script:SavedCacheHome
        $Env:XDG_CONFIG_HOME  = $script:SavedConfigHome
        $Env:CARAPACE_BRIDGES = $script:SavedBridges
    }

    It 'does not throw on a backslash-relative path and falls back to filesystem completion' {
        # Real regression: `bat ..\<Tab>` threw inside CompleteInput on pwsh 7.6.
        . $script:CompanionPath
        { $script:r = [System.Management.Automation.CommandCompletion]::CompleteInput('bat ..\', 7, @{}) } |
            Should -Not -Throw
        @($script:r.CompletionMatches.CompletionText) | Should -Contain '..\sibling.txt'
    }
}
