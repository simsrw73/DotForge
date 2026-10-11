BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    . "$PSScriptRoot/../Tools/psresource.manage.ps1"
    $script:Mgr = [pscustomobject]@{ name = 'psresource' }
    $script:Fx = "$PSScriptRoot/fixtures/managers/psresource"
}
Describe 'psresource manager operations' {
    It 'maps current-user PSResources to the manager contract' {
        Mock Get-DFPSResourceInstalledRaw { (Get-Content "$script:Fx/list.txt" -Raw | ConvertFrom-Json) }
        $rows = @(Get-DFPSResourceInstalled -Manager $script:Mgr)
        $rows[0].Id | Should -Be 'Admin'; $rows[0].Installed | Should -Be '1.1.13'; $rows[0].Available | Should -BeNullOrEmpty
        @($rows | Where-Object Id -eq 'Admin').Count | Should -Be 1
        foreach ($row in $rows) { ($row.PSObject.Properties.Name | Sort-Object) -join ',' | Should -Be 'Available,Id,Installed' }
        Should -Invoke Get-DFPSResourceInstalledRaw -Times 1 -Exactly
    }
    It 'returns no rows for empty garbage or failed output' {
        Mock Get-DFPSResourceInstalledRaw { @() }; @(Get-DFPSResourceInstalled -Manager $script:Mgr) | Should -BeNullOrEmpty
        Mock Get-DFPSResourceInstalledRaw { throw 'error: something' }; { @(Get-DFPSResourceInstalled -Manager $script:Mgr) } | Should -Not -Throw
        @(Get-DFPSResourceInstalled -Manager $script:Mgr) | Should -BeNullOrEmpty
    }
}
