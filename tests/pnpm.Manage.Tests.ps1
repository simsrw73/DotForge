#Requires -Version 7.2

BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    . "$PSScriptRoot/../Tools/pnpm.manage.ps1"
    $script:Mgr = [pscustomobject]@{ name = 'pnpm' }
    $script:Fx = "$PSScriptRoot/fixtures/managers/pnpm"
}

Describe 'Get-DFPnpmInstalled' {
    It 'parses the recorded sample to expected rows' {
        Mock Invoke-DFManagerCommand {
            [pscustomobject]@{ ExitCode = 0; Output = (Get-Content "$script:Fx/list.txt" -Raw) }
        }
        $rows = @(Get-DFPnpmInstalled -Manager $script:Mgr)
        $rows.Count | Should -Be 4

        $p1 = $rows | Where-Object Id -eq '@types/node'
        $p1.Installed | Should -Be '20.11.0'
        $p1.Available | Should -BeNullOrEmpty

        $p2 = $rows | Where-Object Id -eq 'eslint'
        $p2.Installed | Should -Be '8.56.0'
        $p2.Available | Should -BeNullOrEmpty

        $p3 = $rows | Where-Object Id -eq 'typescript'
        $p3.Installed | Should -Be '5.3.3'
        $p3.Available | Should -BeNullOrEmpty
    }

    It 'passes the expected argv to Invoke-DFManagerCommand' {
        Mock Invoke-DFManagerCommand {
            [pscustomobject]@{ ExitCode = 0; Output = (Get-Content "$script:Fx/list.txt" -Raw) }
        }
        $null = Get-DFPnpmInstalled -Manager $script:Mgr
        Should -Invoke Invoke-DFManagerCommand -Times 1 -Exactly -ParameterFilter {
            $Operation -eq 'list' -and ($Argv -join ' ') -eq 'pnpm ls -g --json' -and $Manager.name -eq 'pnpm'
        }
    }

    It 'returns only { Id; Installed; Available } objects' {
        Mock Invoke-DFManagerCommand {
            [pscustomobject]@{ ExitCode = 0; Output = (Get-Content "$script:Fx/list.txt" -Raw) }
        }
        $rows = @(Get-DFPnpmInstalled -Manager $script:Mgr)
        $rows.Count | Should -BeGreaterThan 0
        foreach ($r in $rows) {
            ($r.PSObject.Properties.Name | Sort-Object) -join ',' | Should -Be 'Available,Id,Installed'
        }
    }

    It 'returns no rows on empty output' {
        Mock Invoke-DFManagerCommand {
            [pscustomobject]@{ ExitCode = 0; Output = '' }
        }
        @(Get-DFPnpmInstalled -Manager $script:Mgr).Count | Should -Be 0
    }

    It 'returns no rows and does not throw on garbage output' {
        Mock Invoke-DFManagerCommand {
            [pscustomobject]@{ ExitCode = 0; Output = 'error: something' }
        }
        { $rows = @(Get-DFPnpmInstalled -Manager $script:Mgr) } | Should -Not -Throw
        $rows.Count | Should -Be 0
    }

    It 'reads the JSON even when pnpm exits 1 (it does when packages are outdated, or the tree has problems)' {
        Mock Invoke-DFManagerCommand {
            [pscustomobject]@{ ExitCode = 1; Output = (Get-Content "$script:Fx/list.txt" -Raw) }
        }
        @(Get-DFPnpmInstalled -Manager $script:Mgr).Count | Should -BeGreaterThan 0
    }
    It 'returns no rows when pnpm fails without JSON' {
        Mock Invoke-DFManagerCommand { [pscustomobject]@{ ExitCode = 1; Output = 'npm ERR! code E404' } }
        @(Get-DFPnpmInstalled -Manager $script:Mgr).Count | Should -Be 0
    }
}

Describe 'Get-DFPnpmOutdated' {
    It 'parses the recorded sample to expected rows' {
        Mock Invoke-DFManagerCommand {
            [pscustomobject]@{ ExitCode = 0; Output = (Get-Content "$script:Fx/outdated.txt" -Raw) }
        }
        $rows = @(Get-DFPnpmOutdated -Manager $script:Mgr)
        $rows.Count | Should -Be 3

        $p1 = $rows | Where-Object Id -eq '@types/node'
        $p1.Installed | Should -Be '20.11.0'
        $p1.Available | Should -Be '20.11.24'

        $p2 = $rows | Where-Object Id -eq 'eslint'
        $p2.Installed | Should -Be '8.56.0'
        $p2.Available | Should -Be '9.0.0'

        $p3 = $rows | Where-Object Id -eq 'typescript'
        $p3.Installed | Should -Be '5.3.3'
        $p3.Available | Should -Be '5.4.0'
    }

    It 'passes the expected argv to Invoke-DFManagerCommand' {
        Mock Invoke-DFManagerCommand {
            [pscustomobject]@{ ExitCode = 0; Output = (Get-Content "$script:Fx/outdated.txt" -Raw) }
        }
        $null = Get-DFPnpmOutdated -Manager $script:Mgr
        Should -Invoke Invoke-DFManagerCommand -Times 1 -Exactly -ParameterFilter {
            $Operation -eq 'outdated' -and ($Argv -join ' ') -eq 'pnpm outdated -g --format json' -and $Manager.name -eq 'pnpm'
        }
    }

    It 'returns only { Id; Installed; Available } objects' {
        Mock Invoke-DFManagerCommand {
            [pscustomobject]@{ ExitCode = 0; Output = (Get-Content "$script:Fx/outdated.txt" -Raw) }
        }
        $rows = @(Get-DFPnpmOutdated -Manager $script:Mgr)
        $rows.Count | Should -BeGreaterThan 0
        foreach ($r in $rows) {
            ($r.PSObject.Properties.Name | Sort-Object) -join ',' | Should -Be 'Available,Id,Installed'
        }
    }

    It 'returns no rows on empty output' {
        Mock Invoke-DFManagerCommand {
            [pscustomobject]@{ ExitCode = 0; Output = '' }
        }
        @(Get-DFPnpmOutdated -Manager $script:Mgr).Count | Should -Be 0
    }

    It 'returns no rows and does not throw on garbage output' {
        Mock Invoke-DFManagerCommand {
            [pscustomobject]@{ ExitCode = 0; Output = 'error: something' }
        }
        { $rows = @(Get-DFPnpmOutdated -Manager $script:Mgr) } | Should -Not -Throw
        $rows.Count | Should -Be 0
    }

    It 'reads the JSON even when pnpm exits 1 (it does when packages are outdated, or the tree has problems)' {
        Mock Invoke-DFManagerCommand {
            [pscustomobject]@{ ExitCode = 1; Output = (Get-Content "$script:Fx/outdated.txt" -Raw) }
        }
        @(Get-DFPnpmOutdated -Manager $script:Mgr).Count | Should -BeGreaterThan 0
    }
    It 'returns no rows when pnpm fails without JSON' {
        Mock Invoke-DFManagerCommand { [pscustomobject]@{ ExitCode = 1; Output = 'npm ERR! code E404' } }
        @(Get-DFPnpmOutdated -Manager $script:Mgr).Count | Should -Be 0
    }
}