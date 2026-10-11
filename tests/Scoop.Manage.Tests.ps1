BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    . "$PSScriptRoot/../Tools/scoop.manage.ps1"
    $script:Mgr = [pscustomobject]@{ name = 'scoop' }
    $script:Fx = "$PSScriptRoot/fixtures/managers/scoop"
}

Describe 'Scoop manager inventory' {
    BeforeEach { Mock Invoke-DFManagerCommand { [pscustomobject]@{ ExitCode = 0; Output = (Get-Content "$script:Fx/list.txt" -Raw) } } }
    It 'parses installed packages' {
        $rows = @(Get-DFScoopInstalled -Manager $script:Mgr)
        $rows[0].Id | Should -Be '7zip'; $rows[0].Installed | Should -Be '26.04'; $rows[0].Available | Should -BeNullOrEmpty
        Should -Invoke Invoke-DFManagerCommand -ParameterFilter { $Operation -eq 'list' -and ($Argv -join ' ') -eq 'scoop list' }
    }
    It 'returns no rows for empty, garbage, or failed output' -ForEach @('', 'error: something') {
        Mock Invoke-DFManagerCommand { [pscustomobject]@{ ExitCode = 0; Output = $_ } }
        @(Get-DFScoopInstalled -Manager $script:Mgr) | Should -BeNullOrEmpty
    }
    It 'returns no rows when the manager fails' {
        Mock Invoke-DFManagerCommand { [pscustomobject]@{ ExitCode = 1; Output = 'failed' } }
        @(Get-DFScoopInstalled -Manager $script:Mgr) | Should -BeNullOrEmpty
    }
}

Describe 'Scoop manager updates' {
    BeforeEach { Mock Invoke-DFManagerCommand { [pscustomobject]@{ ExitCode = 0; Output = (Get-Content "$script:Fx/outdated.txt" -Raw) } } }
    It 'parses outdated packages and uses status' {
        $rows = @(Get-DFScoopOutdated -Manager $script:Mgr)
        $rows[0].Id | Should -Be 'git'; $rows[0].Installed | Should -Be '2.56.0'; $rows[0].Available | Should -Be '2.57.0'
        Should -Invoke Invoke-DFManagerCommand -ParameterFilter { $Operation -eq 'outdated' -and ($Argv -join ' ') -eq 'scoop status' }
    }
    It 'reads scoop status columns, and skips a package that only has an Info note' {
        $rows = @(Get-DFScoopOutdated -Manager $script:Mgr)
        $rows.Id | Should -Be @('git', 'fzf')
        $rows[1].Available | Should -Be '0.75.0'
    }
    It 'returns only the inventory contract properties' {
        foreach ($row in @(Get-DFScoopOutdated -Manager $script:Mgr)) { ($row.PSObject.Properties.Name | Sort-Object) -join ',' | Should -Be 'Available,Id,Installed' }
    }
    It 'returns no rows for malformed or failed output' -ForEach @('', 'error: something') {
        Mock Invoke-DFManagerCommand { [pscustomobject]@{ ExitCode = 0; Output = $_ } }
        @(Get-DFScoopOutdated -Manager $script:Mgr) | Should -BeNullOrEmpty
    }
    It 'returns no rows for a non-zero exit code' {
        Mock Invoke-DFManagerCommand { [pscustomobject]@{ ExitCode = 1; Output = 'failed' } }
        @(Get-DFScoopOutdated -Manager $script:Mgr) | Should -BeNullOrEmpty
    }
}
