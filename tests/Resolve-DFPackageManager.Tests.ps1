BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
}

Describe 'Resolve-DFPackageManager' {
    BeforeEach { $script:DFPackageManagers = $null }

    It 'returns only managers found on PATH' {
        Mock Get-Command { if ($Name -eq 'scoop') { [PSCustomObject]@{ Name = 'scoop' } } else { $null } }
        $result = Resolve-DFPackageManager
        $result | Should -Contain 'scoop'
        $result | Should -Not -Contain 'winget'
        $result | Should -Not -Contain 'choco'
    }

    It 'returns empty array when no managers are found' {
        Mock Get-Command { $null }
        $result = Resolve-DFPackageManager
        @($result).Count | Should -Be 0
    }

    It 'caches result on second call (Get-Command not called again)' {
        Mock Get-Command { [PSCustomObject]@{ Name = $Name } } -Verifiable
        Resolve-DFPackageManager | Out-Null
        Resolve-DFPackageManager | Out-Null
        # Get-Command should only be called for the first invocation (3 PMs)
        Should -Invoke Get-Command -Times 3 -Exactly
    }

    It 'reloads when -Force is specified' {
        Mock Get-Command { $null }
        Resolve-DFPackageManager | Out-Null  # caches empty
        Mock Get-Command { [PSCustomObject]@{ Name = 'scoop' } } -ParameterFilter { $Name -eq 'scoop' }
        $result = Resolve-DFPackageManager -Force
        $result | Should -Contain 'scoop'
    }

    It 'respects custom -Priority order' {
        Mock Get-Command { [PSCustomObject]@{ Name = $Name } }
        $result = Resolve-DFPackageManager -Priority @('winget', 'scoop')
        @($result)[0] | Should -Be 'winget'
        @($result)[1] | Should -Be 'scoop'
        @($result).Count | Should -Be 2
    }

    It 'does not let a call with a custom -Priority read or overwrite the cached default-priority result' {
        Mock Get-Command { [PSCustomObject]@{ Name = $Name } }
        $default = Resolve-DFPackageManager   # caches the default order: scoop, winget, choco
        $custom  = Resolve-DFPackageManager -Priority @('winget', 'scoop')
        @($custom)[0] | Should -Be 'winget'
        @($custom)[1] | Should -Be 'scoop'
        # cache must still reflect the default-priority result, not the custom one
        $cachedAgain = Resolve-DFPackageManager
        @($cachedAgain).Count | Should -Be @($default).Count
        @($cachedAgain)[0] | Should -Be $default[0]
    }
}

Describe 'Get-DFPackageManagerOrder' {
    BeforeEach {
        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
        $mk = { param($n, $p) ConvertTo-DFToolRecord ([pscustomobject]@{ name = $n; executable = "$n.exe"; roles = [pscustomobject]@{ 'package-manager' = [pscustomobject]@{ priority = $p } } }) }
        $script:Db = @{ scoop = (& $mk 'scoop' 30); winget = (& $mk 'winget' 20); choco = (& $mk 'choco' 10) }
    }
    AfterEach { Remove-Variable DFConfig -Scope Global -ErrorAction Ignore }

    It 'orders members by priority' {
        Get-DFPackageManagerOrder -ToolDb $script:Db | Should -Be @('scoop', 'winget', 'choco')
    }

    It 'puts the Defaults choice first' {
        $Global:DFConfig = @{ Defaults = @{ 'package-manager' = 'choco' } }
        Get-DFPackageManagerOrder -ToolDb $script:Db | Should -Be @('choco', 'scoop', 'winget')
    }

    It 'ignores a Defaults value that is not a member' {
        $Global:DFConfig = @{ Defaults = @{ 'package-manager' = 'apt' } }
        Get-DFPackageManagerOrder -ToolDb $script:Db | Should -Be @('scoop', 'winget', 'choco')
    }

    It 'falls back to the built-in order when the role has no members' {
        Get-DFPackageManagerOrder -ToolDb @{} | Should -Be @('scoop', 'winget', 'choco')
    }

    It 'drives Resolve-DFPackageManager''s default order' {
        $Global:DFConfig = @{ Defaults = @{ 'package-manager' = 'choco' } }
        Mock Get-DFPackageManagerOrder { 'choco', 'scoop' }
        Mock Get-Command { [PSCustomObject]@{ Name = $Name } }
        Resolve-DFPackageManager -Force | Should -Be @('choco', 'scoop')
    }
}
