BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    . "$PSScriptRoot/../Tools/choco.manage.ps1"
    $script:Mgr = [pscustomobject]@{ name = 'choco' }
    $script:Fx = "$PSScriptRoot/fixtures/managers/choco"
}

Describe 'Chocolatey manager inventory' {
    BeforeEach { Mock Invoke-DFManagerCommand { [pscustomobject]@{ ExitCode = 0; Output = (Get-Content "$script:Fx/list.txt" -Raw) } } }
    It 'parses installed packages' {
        $rows = @(Get-DFChocoInstalled -Manager $script:Mgr)
        $rows[0].Id | Should -Be 'chocolatey'; $rows[0].Installed | Should -Be '2.7.4'; $rows[0].Available | Should -BeNullOrEmpty
        Should -Invoke Invoke-DFManagerCommand -ParameterFilter { $Operation -eq 'list' -and ($Argv -join ' ') -eq 'choco list --limit-output' }
    }
    It 'returns no rows for empty, garbage, or failed output' -ForEach @('', 'error: something') {
        Mock Invoke-DFManagerCommand { [pscustomobject]@{ ExitCode = 0; Output = $_ } }
        @(Get-DFChocoInstalled -Manager $script:Mgr) | Should -BeNullOrEmpty
    }
    It 'returns no rows when the manager fails' {
        Mock Invoke-DFManagerCommand { [pscustomobject]@{ ExitCode = 1; Output = 'failed' } }
        @(Get-DFChocoInstalled -Manager $script:Mgr) | Should -BeNullOrEmpty
    }
}

Describe 'Chocolatey manager updates' {
    BeforeEach { Mock Invoke-DFManagerCommand { [pscustomobject]@{ ExitCode = 0; Output = (Get-Content "$script:Fx/outdated.txt" -Raw) } } }
    It 'parses outdated packages and uses limit output' {
        $rows = @(Get-DFChocoOutdated -Manager $script:Mgr)
        $rows[0].Id | Should -Be 'git'; $rows[0].Installed | Should -Be '2.56.0'; $rows[0].Available | Should -Be '2.57.0'
        Should -Invoke Invoke-DFManagerCommand -ParameterFilter { $Operation -eq 'outdated' -and ($Argv -join ' ') -eq 'choco outdated --limit-output' }
    }
    It 'returns only the inventory contract properties' {
        foreach ($row in @(Get-DFChocoOutdated -Manager $script:Mgr)) { ($row.PSObject.Properties.Name | Sort-Object) -join ',' | Should -Be 'Available,Id,Installed' }
    }
    It 'returns no rows for malformed or failed output' -ForEach @('', 'error: something') {
        Mock Invoke-DFManagerCommand { [pscustomobject]@{ ExitCode = 0; Output = $_ } }
        @(Get-DFChocoOutdated -Manager $script:Mgr) | Should -BeNullOrEmpty
    }
    It 'returns no rows for a non-zero exit code' {
        Mock Invoke-DFManagerCommand { [pscustomobject]@{ ExitCode = 1; Output = 'failed' } }
        @(Get-DFChocoOutdated -Manager $script:Mgr) | Should -BeNullOrEmpty
    }
    It 'reads the rows when choco exits 2 (its enhanced exit code for "outdated packages found")' {
        Mock Invoke-DFManagerCommand { [pscustomobject]@{ ExitCode = 2; Output = (Get-Content "$script:Fx/outdated.txt" -Raw) } }
        @(Get-DFChocoOutdated -Manager $script:Mgr).Count | Should -BeGreaterThan 0
    }
}
