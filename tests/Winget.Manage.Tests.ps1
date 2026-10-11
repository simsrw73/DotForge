BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    . "$PSScriptRoot/../Tools/winget.manage.ps1"
    $script:Mgr = [pscustomobject]@{ name = 'winget' }
    $script:Fx = "$PSScriptRoot/fixtures/managers/winget"
}

Describe 'Winget manager inventory' {
    BeforeEach { Mock Invoke-DFManagerCommand { [pscustomobject]@{ ExitCode = 0; Output = (Get-Content "$script:Fx/list.txt" -Raw) } } }
    It 'parses installed packages through the CLI fallback' {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'Get-WinGetPackage' }
        $rows = @(Get-DFWingetInstalled -Manager $script:Mgr)
        $rows[0].Id | Should -Be 'BurntSushi.ripgrep.MSVC'; $rows[0].Installed | Should -Be '15.2.0'; $rows[0].Available | Should -BeNullOrEmpty
        Should -Invoke Invoke-DFManagerCommand -ParameterFilter { $Operation -eq 'list' -and ($Argv -join ' ') -eq 'winget list --source winget' }
    }
    It 'returns no rows for empty, garbage, or failed output' -ForEach @('', 'error: something') {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'Get-WinGetPackage' }
        Mock Invoke-DFManagerCommand { [pscustomobject]@{ ExitCode = 0; Output = $_ } }
        @(Get-DFWingetInstalled -Manager $script:Mgr) | Should -BeNullOrEmpty
    }
    It 'returns no rows when the manager fails' {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'Get-WinGetPackage' }
        Mock Invoke-DFManagerCommand { [pscustomobject]@{ ExitCode = 1; Output = 'failed' } }
        @(Get-DFWingetInstalled -Manager $script:Mgr) | Should -BeNullOrEmpty
    }
}

Describe 'Winget manager updates' {
    BeforeEach { Mock Get-Command { $null } -ParameterFilter { $Name -eq 'Get-WinGetPackage' }; Mock Invoke-DFManagerCommand { [pscustomobject]@{ ExitCode = 0; Output = (Get-Content "$script:Fx/outdated.txt" -Raw) } } }
    It 'parses outdated packages and uses upgrade' {
        $rows = @(Get-DFWingetOutdated -Manager $script:Mgr)
        $rows[0].Id | Should -Be 'BurntSushi.ripgrep.MSVC'; $rows[0].Installed | Should -Be '15.2.0'; $rows[0].Available | Should -Be '15.3.0'
        Should -Invoke Invoke-DFManagerCommand -ParameterFilter { $Operation -eq 'outdated' -and ($Argv -join ' ') -eq 'winget upgrade --source winget' }
    }
    It 'returns only the inventory contract properties' {
        foreach ($row in @(Get-DFWingetOutdated -Manager $script:Mgr)) { ($row.PSObject.Properties.Name | Sort-Object) -join ',' | Should -Be 'Available,Id,Installed' }
    }
    It 'returns no rows for malformed or failed output' -ForEach @('', 'error: something') {
        Mock Invoke-DFManagerCommand { [pscustomobject]@{ ExitCode = 0; Output = $_ } }
        @(Get-DFWingetOutdated -Manager $script:Mgr) | Should -BeNullOrEmpty
    }
    It 'returns no rows for a non-zero exit code' {
        Mock Invoke-DFManagerCommand { [pscustomobject]@{ ExitCode = 1; Output = 'failed' } }
        @(Get-DFWingetOutdated -Manager $script:Mgr) | Should -BeNullOrEmpty
    }
}
