BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    . "$PSScriptRoot/../Tools/cargo.manage.ps1"
    $script:Mgr = [pscustomobject]@{ name = 'cargo' }; $script:Fx = "$PSScriptRoot/fixtures/managers/cargo"
}
Describe 'cargo manager operations' {
    It 'parses installed crates and invokes cargo install list' {
        Mock Invoke-DFManagerCommand { [pscustomobject]@{ ExitCode = 0; Output = (Get-Content "$script:Fx/list.txt" -Raw) } }
        $rows = @(Get-DFCargoInstalled -Manager $script:Mgr)
        $rows[0].Id | Should -Be 'choose'; $rows[0].Installed | Should -Be '1.3.7'; $rows[0].Available | Should -BeNullOrEmpty
        $rows[1].Id | Should -Be 'wpmctl'; $rows[1].Installed | Should -Be '0.1.0'
        foreach ($row in $rows) { ($row.PSObject.Properties.Name | Sort-Object) -join ',' | Should -Be 'Available,Id,Installed' }
        Should -Invoke Invoke-DFManagerCommand -ParameterFilter { $Operation -eq 'list' -and ($Argv -join ' ') -eq 'cargo install --list' }
    }
    It 'returns no rows for empty garbage or failed output' {
        foreach ($result in @([pscustomobject]@{ ExitCode = 0; Output = '' }, [pscustomobject]@{ ExitCode = 0; Output = 'error: something' }, [pscustomobject]@{ ExitCode = 1; Output = 'failed' })) { Mock Invoke-DFManagerCommand { $result }; @(Get-DFCargoInstalled -Manager $script:Mgr) | Should -BeNullOrEmpty }
    }
}
