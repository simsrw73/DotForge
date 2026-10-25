BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    $script:Mgr = [pscustomobject]@{ name = 'm' }
}

Describe 'Invoke-DFManagerBatch' {
    BeforeEach { Mock Invoke-DFManagerCommand { [pscustomobject]@{ ExitCode = 0; Output = 'ok' } } }
    It 'makes one call for a batching manager, with a result per id' {
        $block = [pscustomobject]@{ batch = $true; update = [string[]]@('m', 'update', '{id}') }
        $r = @(Invoke-DFManagerBatch -Operation update -Manager $script:Mgr -Block $block -Ids a, b)
        $r.Id | Should -Be @('a', 'b')
        $r.ExitCode | Should -Be @(0, 0)
        Should -Invoke Invoke-DFManagerCommand -Times 1 -Exactly -ParameterFilter { $Operation -eq 'update' -and ($Argv -join ' ') -eq 'm update a b' }
    }
    It 'makes one call per id otherwise' {
        $block = [pscustomobject]@{ batch = $false; remove = [string[]]@('m', 'rm', '{id}') }
        $null = Invoke-DFManagerBatch -Operation remove -Manager $script:Mgr -Block $block -Ids a, b
        Should -Invoke Invoke-DFManagerCommand -Times 2 -Exactly
        Should -Invoke Invoke-DFManagerCommand -Times 1 -Exactly -ParameterFilter { ($Argv -join ' ') -eq 'm rm b' }
    }
    It 'installs with the block''s install argv' {
        $block = [pscustomobject]@{ batch = $true; install = [string[]]@('m', 'i', '{id}') }
        $null = Invoke-DFManagerBatch -Operation install -Manager $script:Mgr -Block $block -Ids a
        Should -Invoke Invoke-DFManagerCommand -Times 1 -ParameterFilter { $Operation -eq 'install' -and ($Argv -join ' ') -eq 'm i a' }
    }
    It 'installs with the block''s function and args, {id} replaced by the ids' {
        $block = [pscustomobject]@{ batch = $true; install = $null; function = 'Install-X'; args = [pscustomobject]@{ Name = '{id}'; TrustRepository = $true } }
        $null = Invoke-DFManagerBatch -Operation install -Manager $script:Mgr -Block $block -Ids a, b
        Should -Invoke Invoke-DFManagerCommand -Times 1 -ParameterFilter { $Function -eq 'Install-X' -and ($Arguments.Name -join ',') -eq 'a,b' -and $Arguments.TrustRepository -is [bool] -and $Arguments.TrustRepository }
    }
    It 'calls a function operation with {id} replaced' {
        $block = [pscustomobject]@{ batch = $true; update = [pscustomobject]@{ function = 'Update-X'; args = [pscustomobject]@{ Name = '{id}'; Scope = 'CurrentUser' } } }
        $null = Invoke-DFManagerBatch -Operation update -Manager $script:Mgr -Block $block -Ids a
        Should -Invoke Invoke-DFManagerCommand -Times 1 -ParameterFilter { $Function -eq 'Update-X' -and $Arguments.Name -contains 'a' -and $Arguments.Scope -eq 'CurrentUser' }
    }
    It 'passes the elevation through' {
        $block = [pscustomobject]@{ batch = $true; update = [string[]]@('m', 'up', '{id}') }
        $null = Invoke-DFManagerBatch -Operation update -Manager $script:Mgr -Block $block -Ids a -Elevation ([pscustomobject]@{ Method = 'RunAs' })
        Should -Invoke Invoke-DFManagerCommand -Times 1 -ParameterFilter { $Elevation.Method -eq 'RunAs' }
    }
    It 'passes -Environment to every manager command' {
        $block = [pscustomobject]@{ batch = $false; install = [string[]]@('m', 'i', '{id}') }
        $null = Invoke-DFManagerBatch -Operation install -Manager $script:Mgr -Block $block -Ids a, b -Environment ([ordered]@{ X = 'y' })
        Should -Invoke Invoke-DFManagerCommand -Times 2 -Exactly -ParameterFilter { $Environment['X'] -eq 'y' }
    }
    It 'passes -Environment to a function operation' {
        $block = [pscustomobject]@{ batch = $true; update = [pscustomobject]@{ function = 'Update-X'; args = [pscustomobject]@{ Name = '{id}' } } }
        $null = Invoke-DFManagerBatch -Operation update -Manager $script:Mgr -Block $block -Ids a -Environment ([ordered]@{ X = 'y' })
        Should -Invoke Invoke-DFManagerCommand -Times 1 -Exactly -ParameterFilter { $Function -eq 'Update-X' -and $Environment['X'] -eq 'y' }
    }
    It 'reports an operation the manager does not declare, without calling it' {
        $r = @(Invoke-DFManagerBatch -Operation update -Manager $script:Mgr -Block ([pscustomobject]@{ batch = $true; update = $null }) -Ids a)
        $r[0].Id | Should -Be 'a'
        $r[0].ExitCode | Should -Be -1
        $r[0].Output | Should -Be "can't update through m"
        Should -Invoke Invoke-DFManagerCommand -Times 0
    }
}
