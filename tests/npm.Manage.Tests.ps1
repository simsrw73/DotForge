#Requires -Version 7.2

BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    . "$PSScriptRoot/../Tools/npm.manage.ps1"
    $script:Mgr = [pscustomobject]@{ name = 'npm' }
    $script:Fx = "$PSScriptRoot/fixtures/managers/npm"
}

Describe 'Get-DFNpmInstalled' {
    It 'parses the recorded sample to expected rows' {
        Mock Invoke-DFManagerCommand {
            [pscustomobject]@{ ExitCode = 0; Output = (Get-Content "$script:Fx/list.txt" -Raw) }
        }
        $rows = @(Get-DFNpmInstalled -Manager $script:Mgr)
        $rows.Count | Should -Be 5

        $p1 = $rows | Where-Object Id -eq '@fission-ai/openspec'
        $p1.Installed | Should -Be '1.14.1'
        $p1.Available | Should -BeNullOrEmpty

        $p2 = $rows | Where-Object Id -eq 'commitizen'
        $p2.Installed | Should -Be '4.3.2'
        $p2.Available | Should -BeNullOrEmpty

        $p3 = $rows | Where-Object Id -eq 'prettier'
        $p3.Installed | Should -Be '3.9.9'
        $p3.Available | Should -BeNullOrEmpty
    }

    It 'passes the expected argv to Invoke-DFManagerCommand' {
        Mock Invoke-DFManagerCommand {
            [pscustomobject]@{ ExitCode = 0; Output = (Get-Content "$script:Fx/list.txt" -Raw) }
        }
        $null = Get-DFNpmInstalled -Manager $script:Mgr
        Should -Invoke Invoke-DFManagerCommand -Times 1 -Exactly -ParameterFilter {
            $Operation -eq 'list' -and ($Argv -join ' ') -eq 'npm ls -g --depth=0 --json' -and $Manager.name -eq 'npm'
        }
    }

    It 'returns only { Id; Installed; Available } objects' {
        Mock Invoke-DFManagerCommand {
            [pscustomobject]@{ ExitCode = 0; Output = (Get-Content "$script:Fx/list.txt" -Raw) }
        }
        $rows = @(Get-DFNpmInstalled -Manager $script:Mgr)
        $rows.Count | Should -BeGreaterThan 0
        foreach ($r in $rows) {
            ($r.PSObject.Properties.Name | Sort-Object) -join ',' | Should -Be 'Available,Id,Installed'
        }
    }

    It 'returns no rows on empty output' {
        Mock Invoke-DFManagerCommand {
            [pscustomobject]@{ ExitCode = 0; Output = '' }
        }
        @(Get-DFNpmInstalled -Manager $script:Mgr).Count | Should -Be 0
    }

    It 'returns no rows and does not throw on garbage output' {
        Mock Invoke-DFManagerCommand {
            [pscustomobject]@{ ExitCode = 0; Output = 'error: something' }
        }
        { $rows = @(Get-DFNpmInstalled -Manager $script:Mgr) } | Should -Not -Throw
        $rows.Count | Should -Be 0
    }

    It 'reads the JSON even when npm exits 1 (it does when packages are outdated, or the tree has problems)' {
        Mock Invoke-DFManagerCommand {
            [pscustomobject]@{ ExitCode = 1; Output = (Get-Content "$script:Fx/list.txt" -Raw) }
        }
        @(Get-DFNpmInstalled -Manager $script:Mgr).Count | Should -BeGreaterThan 0
    }
    It 'returns no rows when npm fails without JSON' {
        Mock Invoke-DFManagerCommand { [pscustomobject]@{ ExitCode = 1; Output = 'npm ERR! code E404' } }
        @(Get-DFNpmInstalled -Manager $script:Mgr).Count | Should -Be 0
    }
}

Describe 'Get-DFNpmOutdated' {
    It 'parses the recorded sample to expected rows' {
        Mock Invoke-DFManagerCommand {
            [pscustomobject]@{ ExitCode = 0; Output = (Get-Content "$script:Fx/outdated.txt" -Raw) }
        }
        $rows = @(Get-DFNpmOutdated -Manager $script:Mgr)
        $rows.Count | Should -Be 3

        $p1 = $rows | Where-Object Id -eq '@fission-ai/openspec'
        $p1.Installed | Should -Be '1.14.1'
        $p1.Available | Should -Be '1.15.0'

        $p2 = $rows | Where-Object Id -eq 'commitizen'
        $p2.Installed | Should -Be '4.3.2'
        $p2.Available | Should -Be '4.3.3'

        $p3 = $rows | Where-Object Id -eq 'prettier'
        $p3.Installed | Should -Be '3.9.9'
        $p3.Available | Should -Be '3.10.0'
    }

    It 'passes the expected argv to Invoke-DFManagerCommand' {
        Mock Invoke-DFManagerCommand {
            [pscustomobject]@{ ExitCode = 0; Output = (Get-Content "$script:Fx/outdated.txt" -Raw) }
        }
        $null = Get-DFNpmOutdated -Manager $script:Mgr
        Should -Invoke Invoke-DFManagerCommand -Times 1 -Exactly -ParameterFilter {
            $Operation -eq 'outdated' -and ($Argv -join ' ') -eq 'npm outdated -g --json' -and $Manager.name -eq 'npm'
        }
    }

    It 'returns only { Id; Installed; Available } objects' {
        Mock Invoke-DFManagerCommand {
            [pscustomobject]@{ ExitCode = 0; Output = (Get-Content "$script:Fx/outdated.txt" -Raw) }
        }
        $rows = @(Get-DFNpmOutdated -Manager $script:Mgr)
        $rows.Count | Should -BeGreaterThan 0
        foreach ($r in $rows) {
            ($r.PSObject.Properties.Name | Sort-Object) -join ',' | Should -Be 'Available,Id,Installed'
        }
    }

    It 'returns no rows on empty output' {
        Mock Invoke-DFManagerCommand {
            [pscustomobject]@{ ExitCode = 0; Output = '' }
        }
        @(Get-DFNpmOutdated -Manager $script:Mgr).Count | Should -Be 0
    }

    It 'returns no rows and does not throw on garbage output' {
        Mock Invoke-DFManagerCommand {
            [pscustomobject]@{ ExitCode = 0; Output = 'error: something' }
        }
        { $rows = @(Get-DFNpmOutdated -Manager $script:Mgr) } | Should -Not -Throw
        $rows.Count | Should -Be 0
    }

    It 'reads the JSON even when npm exits 1 (it does when packages are outdated, or the tree has problems)' {
        Mock Invoke-DFManagerCommand {
            [pscustomobject]@{ ExitCode = 1; Output = (Get-Content "$script:Fx/outdated.txt" -Raw) }
        }
        @(Get-DFNpmOutdated -Manager $script:Mgr).Count | Should -BeGreaterThan 0
    }
    It 'returns no rows when npm fails without JSON' {
        Mock Invoke-DFManagerCommand { [pscustomobject]@{ ExitCode = 1; Output = 'npm ERR! code E404' } }
        @(Get-DFNpmOutdated -Manager $script:Mgr).Count | Should -Be 0
    }
}