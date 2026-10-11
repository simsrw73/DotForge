BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    . "$PSScriptRoot/../Tools/uv.manage.ps1"
    . "$PSScriptRoot/../Tools/uv.ps1"
    $script:Mgr = [pscustomobject]@{ name = 'uv' }; $script:Fx = "$PSScriptRoot/fixtures/managers/uv"
}
AfterAll {
    Remove-DFTestGlobal -Function 'Select-UvVenv'
    Remove-DFTestGlobal -Alias fvenv
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

Describe 'Select-UvVenv' {
    AfterEach {
        Remove-Variable __DFUvActivated, __DFUvAction -Scope Global -ErrorAction Ignore
    }

    It 'finds a lowercase activate.ps1, as Linux venvs name it' {
        $venv = Join-Path $TestDrive 'venv'
        $bin = Join-Path $venv $(if ($IsWindows) { 'Scripts' } else { 'bin' })
        New-Item -ItemType Directory -Path $bin -Force | Out-Null
        $cfg = Join-Path $venv 'pyvenv.cfg'
        $activate = Join-Path $bin 'activate.ps1'
        Set-Content $cfg 'home = test'
        Set-Content $activate '$global:__DFUvActivated = $true'
        $global:__DFUvAction = $null
        Mock Invoke-DFPicker { $global:__DFUvAction = $Action }

        Select-UvVenv -Path $TestDrive
        & $global:__DFUvAction $cfg

        $global:__DFUvActivated | Should -BeTrue
    }
}
