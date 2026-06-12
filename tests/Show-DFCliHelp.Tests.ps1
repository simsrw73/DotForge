BeforeAll {
    . "$PSScriptRoot/../Private/Invoke-DFCommandCapture.ps1"
    . "$PSScriptRoot/../Private/Format-DFCliHelpText.ps1"
    . "$PSScriptRoot/../Private/Resolve-DFCliHelpFlag.ps1"
    . "$PSScriptRoot/../Public/DFHelpers.Pager.ps1"
    . "$PSScriptRoot/../Public/DFHelpers.Help.ps1"
}

Describe 'Show-DFCliHelp' {
    BeforeEach {
        Mock Get-Command { [pscustomobject]@{ Name = 'demo' } } -ParameterFilter { $Name -eq 'demo' }
        Mock Invoke-DFCommandCapture { [pscustomobject]@{ Text = "USAGE`n body"; ExitCode = 0 } }
        Mock Resolve-DFCliHelpFlag { '--help' }
        Mock Format-DFCliHelpText { 'COLORIZED' }
        Mock Invoke-DFWithPager {}
    }

    It 'warns and returns when the command is not found' {
        Mock Get-Command { $null }
        Show-DFCliHelp -Name 'nope' -WarningVariable w -WarningAction SilentlyContinue | Out-Null
        $w | Should -Not -BeNullOrEmpty
        Should -Invoke Resolve-DFCliHelpFlag -Times 0
    }

    It 'uses an explicit -Flag and does not call the resolver' {
        Show-DFCliHelp -Name 'demo' -Flag '--tree' | Out-Null
        Should -Invoke Resolve-DFCliHelpFlag -Times 0
        Should -Invoke Invoke-DFCommandCapture -ParameterFilter { $Arguments[0] -eq '--tree' }
    }

    It 'calls the resolver when no flag is given' {
        Show-DFCliHelp -Name 'demo' | Out-Null
        Should -Invoke Resolve-DFCliHelpFlag -Times 1
    }

    It 'writes colorized output to the pipeline by default' {
        Show-DFCliHelp -Name 'demo' | Should -Be 'COLORIZED'
        Should -Invoke Invoke-DFWithPager -Times 0
    }

    It 'routes through the pager when -Paged is set' {
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
        Show-DFCliHelpPaged -Name 'demo' | Out-Null
        Should -Invoke Invoke-DFWithPager -Times 1
    }
}
