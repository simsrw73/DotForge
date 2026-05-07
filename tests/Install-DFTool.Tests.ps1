BeforeAll {
    . "$PSScriptRoot/../Private/Test-DFToolSchema.ps1"
    . "$PSScriptRoot/../Private/Import-DFToolDb.ps1"
    . "$PSScriptRoot/../Private/Resolve-DFPackageManager.ps1"
    . "$PSScriptRoot/../Public/Install-DFTool.ps1"
}

Describe 'Install-DFTool' {
    BeforeEach {
        $script:DFToolDb          = $null
        $script:DFPackageManagers = $null
        $script:TmpTools = Join-Path $TestDrive 'tools'
        New-Item -ItemType Directory -Force -Path $script:TmpTools | Out-Null

        @'
{
  "name": "pkgtool",
  "executable": "pkgtool.exe",
  "packages": { "scoop": "pkgtool-scoop", "winget": "Vendor.pkgtool" }
}
'@ | Set-Content (Join-Path $script:TmpTools 'pkgtool.json')

        @'
{ "name": "nopkg", "executable": "nopkg.exe", "packages": {} }
'@ | Set-Content (Join-Path $script:TmpTools 'nopkg.json')

        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
    }

    It 'warns for an unknown tool name' {
        Install-DFTool -Name 'nosuch' -ToolsPath $script:TmpTools -WarningVariable warns 3>$null
        $warns | Where-Object { $_ -match 'nosuch' } | Should -Not -BeNullOrEmpty
    }

    It 'warns when no package manager is available for the tool' {
        Mock Get-Command { $null }
        Install-DFTool -Name 'pkgtool' -ToolsPath $script:TmpTools -WarningVariable warns 3>$null
        $warns | Where-Object { $_ -match 'pkgtool' } | Should -Not -BeNullOrEmpty
    }

    It 'warns when the available PM has no package for the tool' {
        Mock Get-Command { if ($Name -eq 'choco') { [PSCustomObject]@{ Name = 'choco' } } else { $null } }
        Install-DFTool -Name 'pkgtool' -PackageManager 'choco' -ToolsPath $script:TmpTools -WarningVariable warns 3>$null
        $warns | Where-Object { $_ -match 'pkgtool' } | Should -Not -BeNullOrEmpty
    }

    It 'uses -PackageManager override when specified' {
        $script:ScoopCalled = $false
        function script:scoop { $script:ScoopCalled = $true; $global:LASTEXITCODE = 0 }
        Mock Get-Command { [PSCustomObject]@{ Name = $Name } }
        Install-DFTool -Name 'pkgtool' -PackageManager 'scoop' -ToolsPath $script:TmpTools
        $script:ScoopCalled | Should -BeTrue
    }

    It 'uses $DFConfig.PackageManagerOrder when set' {
        $Global:DFConfig = @{ PackageManagerOrder = @('winget') }
        $script:WingetCalled = $false
        function script:winget { $script:WingetCalled = $true; $global:LASTEXITCODE = 0 }
        Mock Get-Command { [PSCustomObject]@{ Name = $Name } }
        Install-DFTool -Name 'pkgtool' -ToolsPath $script:TmpTools
        $script:WingetCalled | Should -BeTrue
        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
    }

    It 'does not throw when -WhatIf is specified' {
        Mock Get-Command { [PSCustomObject]@{ Name = $Name } }
        { Install-DFTool -Name 'pkgtool' -PackageManager 'scoop' -ToolsPath $script:TmpTools -WhatIf } |
            Should -Not -Throw
    }

    It 'processes multiple tool names in a single call' {
        Mock Get-Command { $null }
        Install-DFTool -Name @('pkgtool', 'nopkg', 'nosuch') -ToolsPath $script:TmpTools `
            -WarningVariable warns 3>$null
        @($warns).Count | Should -Be 3
    }
}
