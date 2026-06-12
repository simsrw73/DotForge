BeforeAll {
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/Invoke-DFCommandCapture.ps1"
    . "$PSScriptRoot/../Private/Resolve-DFCliHelpFlag.ps1"
}

Describe 'Resolve-DFCliHelpFlag' {
    BeforeEach {
        $script:SavedCache = $Env:XDG_CACHE_HOME
        $Env:XDG_CACHE_HOME = Join-Path $TestDrive 'cache'
        # TestDrive persists for the whole Describe; clear any cache a prior test wrote
        $df = Join-Path $Env:XDG_CACHE_HOME 'dotforge'
        if (Test-Path $df) { Remove-Item $df -Recurse -Force }
    }
    AfterEach {
        $Env:XDG_CACHE_HOME = $script:SavedCache
    }

    It 'returns the first candidate that produces help-looking output' {
        Mock Invoke-DFCommandCapture {
            [pscustomobject]@{ Text = "USAGE`n  thing`n  more`n  lines"; ExitCode = 0 }
        }
        Resolve-DFCliHelpFlag -Name 'demo' | Should -Be '--help'
    }

    It 'rejects an unknown-option error and moves to the next candidate' {
        Mock Invoke-DFCommandCapture {
            param($Name, $Arguments)
            if ($Arguments[0] -eq '--help') {
                [pscustomobject]@{ Text = "error: unknown option '--help'"; ExitCode = 1 }
            } else {
                [pscustomobject]@{ Text = "Usage:`n  demo`n  -x do"; ExitCode = 0 }
            }
        }
        Resolve-DFCliHelpFlag -Name 'demo' | Should -Be '-help'
    }

    It 'tries -h last' {
        $script:tried = @()
        Mock Invoke-DFCommandCapture {
            param($Name, $Arguments)
            $script:tried += $Arguments[0]
            if ($Arguments[0] -eq '-h') {
                [pscustomobject]@{ Text = "USAGE`n a`n b`n c"; ExitCode = 0 }
            } else {
                [pscustomobject]@{ Text = "error: unrecognized flag"; ExitCode = 1 }
            }
        }
        Resolve-DFCliHelpFlag -Name 'demo' | Should -Be '-h'
        $script:tried[-1] | Should -Be '-h'
        $script:tried[0]  | Should -Be '--help'
    }

    It 'writes the discovered flag to the cache' {
        Mock Invoke-DFCommandCapture {
            [pscustomobject]@{ Text = "USAGE`n a`n b`n c"; ExitCode = 0 }
        }
        Resolve-DFCliHelpFlag -Name 'demo' | Out-Null
        $cacheFile = Join-Path $Env:XDG_CACHE_HOME 'dotforge/cli-help-flags.json'
        Test-Path $cacheFile | Should -BeTrue
        (Get-Content $cacheFile -Raw | ConvertFrom-Json).demo | Should -Be '--help'
    }

    It 'returns the cached flag without running the command' {
        $cacheDir = Join-Path $Env:XDG_CACHE_HOME 'dotforge'
        New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
        '{ "demo": "-?" }' | Set-Content (Join-Path $cacheDir 'cli-help-flags.json')
        Mock Invoke-DFCommandCapture { throw 'should not run' }
        Resolve-DFCliHelpFlag -Name 'demo' | Should -Be '-?'
        Should -Invoke Invoke-DFCommandCapture -Times 0
    }

    It 're-guesses when -Force is passed even with a cache entry' {
        $cacheDir = Join-Path $Env:XDG_CACHE_HOME 'dotforge'
        New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
        '{ "demo": "-?" }' | Set-Content (Join-Path $cacheDir 'cli-help-flags.json')
        Mock Invoke-DFCommandCapture {
            [pscustomobject]@{ Text = "USAGE`n a`n b`n c"; ExitCode = 0 }
        }
        Resolve-DFCliHelpFlag -Name 'demo' -Force | Should -Be '--help'
        Should -Invoke Invoke-DFCommandCapture -Times 1
    }

    It 'returns $null when every candidate produces empty output' {
        Mock Invoke-DFCommandCapture { [pscustomobject]@{ Text = ''; ExitCode = 1 } }
        Resolve-DFCliHelpFlag -Name 'demo' | Should -BeNullOrEmpty
    }
}
