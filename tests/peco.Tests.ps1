BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    $script:Tools = Join-Path $PSScriptRoot '..' 'Tools'
}

Describe 'peco tool' {
    BeforeEach {
        Set-DFTestXdg; Reset-DFTestSession; Set-DFTestConfig $null
        # $TestDrive (and so the XDG folders) lasts the whole Describe: start each test clean.
        Remove-Item (Get-DFToolSetupStatePath), (Join-Path $Env:XDG_CONFIG_HOME 'peco') -Recurse -Force -ErrorAction Ignore
        Mock Test-DFToolAvailable { $true }
        Mock Write-DFConflictNotice { }
        $script:Config = Join-Path $Env:XDG_CONFIG_HOME 'peco' 'config.json'
    }
    AfterEach { Restore-DFTestXdg; Set-DFTestConfig $null }

    It 'seeds its config with the catppuccin-mocha style' {
        Start-DFSession -Config @{ Tools = @('peco') } -ToolsPath $script:Tools 3>$null
        Get-Content $script:Config -Raw | Should -Be (Get-Content (Join-Path $script:Tools 'peco' 'catppuccin-mocha.json') -Raw)
    }
    It 'follows Theme' {
        Start-DFSession -Config @{ Tools = @('peco'); Theme = 'catppuccin-frappe' } -ToolsPath $script:Tools 3>$null
        (Get-Content $script:Config -Raw | ConvertFrom-Json).Style.Matched | Should -Be @('#e78284')
    }
    It 'keeps an existing config' {
        New-Item -ItemType Directory (Split-Path $script:Config) -Force | Out-Null
        Set-Content $script:Config '{}' -NoNewline
        Start-DFSession -Config @{ Tools = @('peco') } -ToolsPath $script:Tools 3>$null
        Get-Content $script:Config -Raw | Should -Be '{}'
    }
}
