BeforeAll {
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/ConvertTo-DFPath.ps1"
    . "$PSScriptRoot/../Private/Resolve-DFPackageManager.ps1"
    . "$PSScriptRoot/../Public/Initialize-DFEnvironment.ps1"
}

Describe 'Initialize-DFEnvironment' {
    BeforeEach {
        $script:DFPackageManagers = $null
        $script:Saved = @{
            Config = $Env:XDG_CONFIG_HOME
            Data   = $Env:XDG_DATA_HOME
            State  = $Env:XDG_STATE_HOME
            Cache  = $Env:XDG_CACHE_HOME
        }
        Remove-Item Env:\XDG_CONFIG_HOME -ErrorAction Ignore
        Remove-Item Env:\XDG_DATA_HOME   -ErrorAction Ignore
        Remove-Item Env:\XDG_STATE_HOME  -ErrorAction Ignore
        Remove-Item Env:\XDG_CACHE_HOME  -ErrorAction Ignore
    }
    AfterEach {
        $Env:XDG_CONFIG_HOME = $script:Saved.Config
        $Env:XDG_DATA_HOME   = $script:Saved.Data
        $Env:XDG_STATE_HOME  = $script:Saved.State
        $Env:XDG_CACHE_HOME  = $script:Saved.Cache
    }

    It 'sets XDG env vars when they are absent' {
        Mock Get-Command { $null }
        Initialize-DFEnvironment
        $Env:XDG_CONFIG_HOME | Should -Not -BeNullOrEmpty
        $Env:XDG_DATA_HOME   | Should -Not -BeNullOrEmpty
        $Env:XDG_STATE_HOME  | Should -Not -BeNullOrEmpty
        $Env:XDG_CACHE_HOME  | Should -Not -BeNullOrEmpty
    }

    It 'does not override XDG vars that are already set' {
        $Env:XDG_CONFIG_HOME = 'C:\custom\config'
        Mock Get-Command { $null }
        Initialize-DFEnvironment
        $Env:XDG_CONFIG_HOME | Should -Be 'C:\custom\config'
    }

    It 'creates the four XDG base directories' {
        $Env:XDG_CONFIG_HOME = Join-Path $TestDrive 'config'
        $Env:XDG_DATA_HOME   = Join-Path $TestDrive 'data'
        $Env:XDG_STATE_HOME  = Join-Path $TestDrive 'state'
        $Env:XDG_CACHE_HOME  = Join-Path $TestDrive 'cache'
        Mock Get-Command { $null }
        Initialize-DFEnvironment
        Test-Path $Env:XDG_CONFIG_HOME | Should -BeTrue
        Test-Path $Env:XDG_DATA_HOME   | Should -BeTrue
        Test-Path $Env:XDG_STATE_HOME  | Should -BeTrue
        Test-Path $Env:XDG_CACHE_HOME  | Should -BeTrue
    }

    It 'emits a warning when no package managers are found' {
        Mock Get-Command { $null }
        Initialize-DFEnvironment -WarningVariable warns 3>$null
        $warns | Should -Not -BeNullOrEmpty
    }

    It 'does not warn when at least one package manager is found' {
        Mock Get-Command { [PSCustomObject]@{ Name = 'scoop' } }
        Initialize-DFEnvironment -WarningVariable warns 3>$null
        $warns | Should -BeNullOrEmpty
    }

    It 'is idempotent — calling twice does not throw' {
        Mock Get-Command { $null }
        $Env:XDG_CONFIG_HOME = Join-Path $TestDrive 'config'
        $Env:XDG_DATA_HOME   = Join-Path $TestDrive 'data'
        $Env:XDG_STATE_HOME  = Join-Path $TestDrive 'state'
        $Env:XDG_CACHE_HOME  = Join-Path $TestDrive 'cache'
        { Initialize-DFEnvironment; Initialize-DFEnvironment } | Should -Not -Throw
    }

    It 'canonicalizes a ~-rooted XDG value the user set' {
        $saved = $Env:XDG_CONFIG_HOME
        try {
            $Env:XDG_CONFIG_HOME = '~/dftest-config'
            Initialize-DFEnvironment 6>$null
            $Env:XDG_CONFIG_HOME | Should -Be (Join-Path $HOME 'dftest-config')
        } finally {
            $Env:XDG_CONFIG_HOME = $saved
            Remove-Item (Join-Path $HOME 'dftest-config') -Recurse -Force -ErrorAction Ignore
        }
    }
}
