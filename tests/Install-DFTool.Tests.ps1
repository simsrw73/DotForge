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

    It 'tolerates $DFConfig being set to $null' {
        # Regression: guarding on the variable's existence rather than its value
        # threw "Cannot index into a null array" for a profile with $DFConfig = $null.
        $Global:DFConfig = $null
        Mock Get-Command { [PSCustomObject]@{ Name = $Name } }
        function script:scoop { $global:LASTEXITCODE = 0 }
        { Install-DFTool -Name 'pkgtool' -PackageManager 'scoop' -ToolsPath $script:TmpTools } |
            Should -Not -Throw
        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
    }

    It 'installs a cargo-only tool via cargo when scoop/winget/choco lack it' {
        @'
{ "name": "cargotool", "executable": "cargotool.exe", "packages": { "cargo": "cargotool" } }
'@ | Set-Content (Join-Path $script:TmpTools 'cargotool.json')
        $script:DFToolDb = $null

        $script:CargoArgs = $null
        function script:cargo { $script:CargoArgs = $args; $global:LASTEXITCODE = 0 }
        # cargo present; the default managers are not
        Mock Get-Command { if ($Name -eq 'cargo') { [PSCustomObject]@{ Name = 'cargo' } } else { $null } }

        Install-DFTool -Name 'cargotool' -ToolsPath $script:TmpTools
        ($script:CargoArgs -join ' ') | Should -Match 'install\s+cargotool'
    }

    It 'prefers scoop over cargo when both are declared and available' {
        @'
{ "name": "dualtool", "executable": "dualtool.exe", "packages": { "scoop": "dualtool", "cargo": "dualtool" } }
'@ | Set-Content (Join-Path $script:TmpTools 'dualtool.json')
        $script:DFToolDb = $null

        $script:ScoopHit = $false; $script:CargoHit = $false
        function script:scoop { $script:ScoopHit = $true; $global:LASTEXITCODE = 0 }
        function script:cargo { $script:CargoHit = $true; $global:LASTEXITCODE = 0 }
        Mock Get-Command { [PSCustomObject]@{ Name = $Name } }   # everything available

        Install-DFTool -Name 'dualtool' -ToolsPath $script:TmpTools
        $script:ScoopHit | Should -BeTrue
        $script:CargoHit | Should -BeFalse
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

    It 'installs via Install-PSResource when psresource package is specified' {
        @'
{ "name": "psmod", "type": "module", "executable": "PsMod",
  "packages": { "psresource": "PsMod" } }
'@ | Set-Content (Join-Path $script:TmpTools 'psmod.json')
        $script:DFToolDb = $null

        $script:PSResourceCalled = $false
        function script:Install-PSResource {
            param($Name, $Scope, $ErrorAction)
            $script:PSResourceCalled = $true
        }
        Mock Get-Command { [PSCustomObject]@{ Name = 'Install-PSResource' } } `
            -ParameterFilter { $Name -eq 'Install-PSResource' }

        Install-DFTool -Name 'psmod' -PackageManager 'psresource' -ToolsPath $script:TmpTools
        $script:PSResourceCalled | Should -BeTrue

        Remove-Item (Join-Path $script:TmpTools 'psmod.json') -ErrorAction Ignore
        $script:DFToolDb = $null
    }
}
