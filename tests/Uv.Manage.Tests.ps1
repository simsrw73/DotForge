BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    . "$PSScriptRoot/../Tools/uv.manage.ps1"
    $script:Mgr = [pscustomobject]@{ name = 'uv' }; $script:Fx = "$PSScriptRoot/fixtures/managers/uv"
}
Describe 'uv manager operations' {
    It 'parses installed tools and invokes uv tool list' {
        Mock Invoke-DFManagerCommand { [pscustomobject]@{ ExitCode = 0; Output = (Get-Content "$script:Fx/list.txt" -Raw) } }
        $rows = @(Get-DFUvInstalled -Manager $script:Mgr)
        $rows[0].Id | Should -Be 'basedpyright'; $rows[0].Installed | Should -Be '1.40.2'; $rows[0].Available | Should -BeNullOrEmpty
        $rows[1].Id | Should -Be 'glances'; $rows[1].Installed | Should -Be '4.5.7'
        foreach ($row in $rows) { ($row.PSObject.Properties.Name | Sort-Object) -join ',' | Should -Be 'Available,Id,Installed' }
        Should -Invoke Invoke-DFManagerCommand -ParameterFilter { $Operation -eq 'list' -and ($Argv -join ' ') -eq 'uv tool list' }
    }
    It 'returns no rows for empty garbage or failed output' {
        foreach ($result in @([pscustomobject]@{ ExitCode = 0; Output = '' }, [pscustomobject]@{ ExitCode = 0; Output = 'error: something' }, [pscustomobject]@{ ExitCode = 1; Output = 'failed' })) { Mock Invoke-DFManagerCommand { $result }; @(Get-DFUvInstalled -Manager $script:Mgr) | Should -BeNullOrEmpty }
    }
}
