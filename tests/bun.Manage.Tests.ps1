#Requires -Version 7.2

BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    . "$PSScriptRoot/../Tools/bun.manage.ps1"
    $script:Mgr = [pscustomobject]@{ name = 'bun' }
    $script:Fx = "$PSScriptRoot/fixtures/managers/bun"
}

Describe 'Get-DFBunInstalled' {
    It 'parses the recorded sample to expected rows' {
        Mock Invoke-DFManagerCommand {
            [pscustomobject]@{ ExitCode = 0; Output = (Get-Content "$script:Fx/list.txt" -Raw) }
        }
        $rows = @(Get-DFBunInstalled -Manager $script:Mgr)
        $rows.Count | Should -Be 4

        $p1 = $rows | Where-Object Id -eq '@oh-my-pi/pi-coding-agent'
        $p1.Installed | Should -Be '18.8.5'
        $p1.Available | Should -BeNullOrEmpty

        $p2 = $rows | Where-Object Id -eq '@opencode/cli'
        $p2.Installed | Should -Be '2.0.24'
        $p2.Available | Should -BeNullOrEmpty

        $p3 = $rows | Where-Object Id -eq 'ccusage'
        $p3.Installed | Should -Be '20.0.26'
        $p3.Available | Should -BeNullOrEmpty

        $p4 = $rows | Where-Object Id -eq 'tokscale'
        $p4.Installed | Should -Be '4.18.0'
        $p4.Available | Should -BeNullOrEmpty
    }

    It 'passes the expected argv to Invoke-DFManagerCommand' {
        Mock Invoke-DFManagerCommand {
            [pscustomobject]@{ ExitCode = 0; Output = (Get-Content "$script:Fx/list.txt" -Raw) }
        }
        $null = Get-DFBunInstalled -Manager $script:Mgr
        Should -Invoke Invoke-DFManagerCommand -Times 1 -Exactly -ParameterFilter {
            $Operation -eq 'list' -and ($Argv -join ' ') -eq 'bun pm ls -g' -and $Manager.name -eq 'bun'
        }
    }

    It 'returns only { Id; Installed; Available } objects' {
        Mock Invoke-DFManagerCommand {
            [pscustomobject]@{ ExitCode = 0; Output = (Get-Content "$script:Fx/list.txt" -Raw) }
        }
        $rows = @(Get-DFBunInstalled -Manager $script:Mgr)
        $rows.Count | Should -BeGreaterThan 0
        foreach ($r in $rows) {
            ($r.PSObject.Properties.Name | Sort-Object) -join ',' | Should -Be 'Available,Id,Installed'
        }
    }

    It 'returns no rows on empty output' {
        Mock Invoke-DFManagerCommand {
            [pscustomobject]@{ ExitCode = 0; Output = '' }
        }
        @(Get-DFBunInstalled -Manager $script:Mgr).Count | Should -Be 0
    }

    It 'returns no rows and does not throw on garbage output' {
        Mock Invoke-DFManagerCommand {
            [pscustomobject]@{ ExitCode = 0; Output = 'error: something' }
        }
        { $rows = @(Get-DFBunInstalled -Manager $script:Mgr) } | Should -Not -Throw
        $rows.Count | Should -Be 0
    }

    It 'returns no rows on non-zero exit code' {
        Mock Invoke-DFManagerCommand {
            [pscustomobject]@{ ExitCode = 1; Output = (Get-Content "$script:Fx/list.txt" -Raw) }
        }
        @(Get-DFBunInstalled -Manager $script:Mgr).Count | Should -Be 0
    }
}