BeforeAll {
    . "$PSScriptRoot/../Private/Resolve-DFPackageManager.ps1"
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
