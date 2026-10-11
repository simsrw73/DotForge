BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    . "$PSScriptRoot/../Tools/pipx.manage.ps1"
    $script:Mgr = [pscustomobject]@{ name = 'pipx' }; $script:Fx = "$PSScriptRoot/fixtures/managers/pipx"
}
Describe 'pipx manager operations' {
    It 'parses installed packages and invokes pipx list JSON' {
        Mock Invoke-DFManagerCommand { [pscustomobject]@{ ExitCode = 0; Output = (Get-Content "$script:Fx/list.txt" -Raw) } }
        $rows = @(Get-DFPipxInstalled -Manager $script:Mgr)
        $rows[0].Id | Should -Be 'beets'; $rows[0].Installed | Should -Be '2.13.1'; $rows[0].Available | Should -BeNullOrEmpty
        foreach ($row in $rows) { ($row.PSObject.Properties.Name | Sort-Object) -join ',' | Should -Be 'Available,Id,Installed' }
        Should -Invoke Invoke-DFManagerCommand -ParameterFilter { $Operation -eq 'list' -and ($Argv -join ' ') -eq 'pipx list --json' }
    }
    It 'returns no rows for empty garbage or failed output' {
        foreach ($result in @([pscustomobject]@{ ExitCode = 0; Output = '' }, [pscustomobject]@{ ExitCode = 0; Output = 'error: something' }, [pscustomobject]@{ ExitCode = 1; Output = 'failed' })) { Mock Invoke-DFManagerCommand { $result }; @(Get-DFPipxInstalled -Manager $script:Mgr) | Should -BeNullOrEmpty }
    }
}
