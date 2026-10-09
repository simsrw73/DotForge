BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
}

Describe 'Show-DFCliHelp' {
    BeforeEach {
        $script:SavedCache = $Env:XDG_CACHE_HOME
        $Env:XDG_CACHE_HOME = Join-Path $TestDrive 'cache'
        $cacheDir = Join-Path $Env:XDG_CACHE_HOME 'dotforge'
        if (Test-Path $cacheDir) { Remove-Item $cacheDir -Recurse -Force }
        Mock Get-Command { [pscustomobject]@{ Name = 'demo' } } -ParameterFilter { $Name -eq 'demo' }
        Mock Invoke-DFCommandCapture { [pscustomobject]@{ Text = "USAGE`n body"; ExitCode = 0 } }
        Mock Format-DFCliHelpText { 'COLORIZED' }
        Mock Invoke-DFWithPager {}
    }

    AfterEach {
        $Env:XDG_CACHE_HOME = $script:SavedCache
    }

    It 'warns and returns when the command is not found' {
        Mock Resolve-DFCliHelpFlag { [pscustomobject]@{ Flag = '--help'; Capture = $null } }
        Mock Get-Command { $null }
        Show-DFCliHelp -Name 'nope' -WarningVariable w -WarningAction SilentlyContinue | Out-Null
        $w | Should -Not -BeNullOrEmpty
        Should -Invoke Resolve-DFCliHelpFlag -Times 0
    }

    It 'uses an explicit -Flag and does not call the resolver' {
        Mock Resolve-DFCliHelpFlag { [pscustomobject]@{ Flag = '--help'; Capture = $null } }
        Show-DFCliHelp -Name 'demo' -Flag '--tree' | Out-Null
        Should -Invoke Resolve-DFCliHelpFlag -Times 0
        Should -Invoke Invoke-DFCommandCapture -ParameterFilter { $Arguments[0] -eq '--tree' }
    }

    It 'calls the resolver when no flag is given' {
        Mock Resolve-DFCliHelpFlag { [pscustomobject]@{ Flag = '--help'; Capture = $null } }
        Show-DFCliHelp -Name 'demo' | Out-Null
        Should -Invoke Resolve-DFCliHelpFlag -Times 1
    }

    It 'writes colorized output to the pipeline by default' {
        Mock Resolve-DFCliHelpFlag { [pscustomobject]@{ Flag = '--help'; Capture = $null } }
        Show-DFCliHelp -Name 'demo' | Should -Be 'COLORIZED'
        Should -Invoke Invoke-DFWithPager -Times 0
    }

    It 'routes through the pager when -Paged is set' {
        Mock Resolve-DFCliHelpFlag { [pscustomobject]@{ Flag = '--help'; Capture = $null } }
        Show-DFCliHelp -Name 'demo' -Paged | Out-Null
        Should -Invoke Invoke-DFWithPager -Times 1
    }

    It 'warns when the resolver returns no flag' {
        Mock Resolve-DFCliHelpFlag { $null }
        Show-DFCliHelp -Name 'demo' -WarningVariable w -WarningAction SilentlyContinue | Out-Null
        $w | Should -Not -BeNullOrEmpty
        Should -Invoke Invoke-DFCommandCapture -Times 0
    }

    It 'Show-DFCliHelpPaged delegates with -Paged' {
        Mock Resolve-DFCliHelpFlag { [pscustomobject]@{ Flag = '--help'; Capture = $null } }
        Show-DFCliHelpPaged -Name 'demo' | Out-Null
        Should -Invoke Invoke-DFWithPager -Times 1
    }

    It 'uses the cold resolver probe result without capturing help twice' {
        Mock Invoke-DFCommandCapture {
            [pscustomobject]@{ Text = "USAGE`n  demo`n  option"; ExitCode = 0 }
        }

        Show-DFCliHelp -Name 'demo' | Should -Be 'COLORIZED'
        Should -Invoke Invoke-DFCommandCapture -Times 1
    }
}
