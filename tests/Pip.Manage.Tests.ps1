BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    . "$PSScriptRoot/../Tools/pip.manage.ps1"
    $script:Mgr = [pscustomobject]@{ name = 'pip' }
    $script:Fx = "$PSScriptRoot/fixtures/managers/pip"
}

Describe 'pip manager operations' {
    It 'parses installed packages' {
        Mock Invoke-DFManagerCommand { [pscustomobject]@{ ExitCode = 0; Output = (Get-Content "$script:Fx/list.txt" -Raw) } }
        $rows = @(Get-DFPipInstalled -Manager $script:Mgr)
        $rows[0].Id | Should -Be 'pip'; $rows[0].Installed | Should -Be '25.1.1'; $rows[0].Available | Should -BeNullOrEmpty
        Should -Invoke Invoke-DFManagerCommand -Times 1 -Exactly -ParameterFilter { $Operation -eq 'list' -and ($Argv -join ' ') -eq 'pip list --user --format=json' }
    }
    It 'parses outdated packages with available versions' {
        Mock Invoke-DFManagerCommand { [pscustomobject]@{ ExitCode = 0; Output = (Get-Content "$script:Fx/outdated.txt" -Raw) } }
        $rows = @(Get-DFPipOutdated -Manager $script:Mgr)
        $rows[0].Id | Should -Be 'pip'; $rows[0].Installed | Should -Be '25.1.1'; $rows[0].Available | Should -Be '25.2'
        foreach ($row in $rows) { ($row.PSObject.Properties.Name | Sort-Object) -join ',' | Should -Be 'Available,Id,Installed' }
        Should -Invoke Invoke-DFManagerCommand -ParameterFilter { $Operation -eq 'outdated' -and ($Argv -join ' ') -eq 'pip list --user --outdated --format=json' }
    }
    It 'returns no rows for empty garbage or failed output' {
        foreach ($result in @([pscustomobject]@{ ExitCode = 0; Output = '' }, [pscustomobject]@{ ExitCode = 0; Output = 'error: something' }, [pscustomobject]@{ ExitCode = 1; Output = 'failed' })) {
            Mock Invoke-DFManagerCommand { $result }
            @(Get-DFPipInstalled -Manager $script:Mgr) | Should -BeNullOrEmpty
        }
    }
}
