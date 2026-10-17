BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    $script:Tools = Join-Path $PSScriptRoot '..' 'Tools'
}

Describe 'broot tool' {
    BeforeEach {
        Set-DFTestXdg; Reset-DFTestSession; Set-DFTestConfig $null
        # $TestDrive (and so the XDG folders) lasts the whole Describe: start each test clean.
        Remove-Item (Get-DFToolSetupStatePath), (Join-Path $Env:XDG_CONFIG_HOME 'broot') -Recurse -Force -ErrorAction Ignore
        Mock Test-DFToolAvailable { $true }
        Mock Write-DFConflictNotice { }
        Mock Write-Host { }
        Mock Invoke-DFBoundedProcess { [pscustomobject]@{ Lines = @(); ExitCode = 0 } }
        $script:SavedConfigDir = $Env:BROOT_CONFIG_DIR
        $script:ConfigDir = Join-Path $Env:XDG_CONFIG_HOME 'broot'
    }
    AfterEach { $Env:BROOT_CONFIG_DIR = $script:SavedConfigDir; Restore-DFTestXdg; Set-DFTestConfig $null }

    It 'points BROOT_CONFIG_DIR at its XDG folder and seeds conf.hjson and verbs.hjson' {
        Start-DFSession -Config @{ Tools = @('broot') } -ToolsPath $script:Tools 3>$null
        $Env:BROOT_CONFIG_DIR | Should -Be $script:ConfigDir
        Get-Content (Join-Path $script:ConfigDir 'conf.hjson') -Raw | Should -Be (Get-Content (Join-Path $script:Tools 'broot' 'conf.hjson') -Raw)
        Test-Path (Join-Path $script:ConfigDir 'verbs.hjson') | Should -BeTrue
    }
    It 'seeds a conf.hjson that imports no skin, so the theme passed by br decides' {
        $conf = Get-Content (Join-Path $script:Tools 'broot' 'conf.hjson') -Raw
        $conf | Should -Match 'verbs\.hjson'
        $conf | Should -Not -Match '(?m)^\s*file:\s*skins/'
    }
    It 'resolves its theme to the bundled catppuccin skin, following Theme' {
        Start-DFSession -Config @{ Tools = @('broot') } -ToolsPath $script:Tools 3>$null
        (Get-DFToolTheme -Tool $script:DFSessionToolDb['broot']).Value | Should -Be (ConvertTo-DFPath (Join-Path $script:Tools 'broot' 'catppuccin-mocha'))
        Reset-DFTestSession
        Start-DFSession -Config @{ Tools = @('broot'); Theme = 'catppuccin-latte' } -ToolsPath $script:Tools 3>$null
        (Get-DFToolTheme -Tool $script:DFSessionToolDb['broot']).Value | Should -Be (ConvertTo-DFPath (Join-Path $script:Tools 'broot' 'catppuccin-latte'))
    }
    It 'knows the BrootTheme setting' {
        $script:DFConfigKeys.Keys | Should -Contain 'BrootTheme'
    }
}
