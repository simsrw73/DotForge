BeforeAll {
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/Test-DFToolSchema.ps1"
    . "$PSScriptRoot/../Private/Import-DFToolDb.ps1"
    . "$PSScriptRoot/../Private/DFCatalog.ps1"
    . "$PSScriptRoot/../Private/Get-DFCatalogInstalled.ps1"
}

Describe 'Get-DFCatalogInstalled' {
    BeforeEach {
        $script:SavedXdgCache = $Env:XDG_CACHE_HOME
        $Env:XDG_CACHE_HOME = Join-Path $TestDrive 'cache'
        $script:SavedProviders = $script:DFCatalogProviders
        $script:DFCatalogAvailability = @{}
        $global:DFTestInstalledProbes = 0

        $script:DFCatalogProviders = @{
            scoop = @{
                Name = 'scoop'; Kind = 'snapshot'; Test = { $true }
                Search = { }
                GetInstalled = {
                    $global:DFTestInstalledProbes++
                    [pscustomobject]@{ Source = 'scoop'; Name = 'ripgrep'; PackageId = 'ripgrep'; InstalledVersion = '14.1.0' }
                }
                Refresh = { }
            }
            crates = @{
                Name = 'crates'; Kind = 'query-cache'; Test = { $true }
                Search = { }
                GetInstalled = {
                    [pscustomobject]@{ Source = 'crates'; Name = 'fd-find'; PackageId = 'fd-find'; InstalledVersion = '10.2.0' }
                }
                Refresh = { }
            }
        }

        # Minimal tool db with a cross-catalog packages map.
        $script:ToolsPath = Join-Path $TestDrive 'tools'
        New-Item -ItemType Directory $script:ToolsPath -Force | Out-Null
        @{
            name       = 'ripgrep'
            executable = 'rg.exe'
            packages   = @{ scoop = 'ripgrep'; winget = 'BurntSushi.ripgrep.MSVC'; choco = 'ripgrep' }
            xdg        = @{ method = 'default' }
        } | ConvertTo-Json | Set-Content (Join-Path $script:ToolsPath 'ripgrep.json')
    }
    AfterEach {
        $Env:XDG_CACHE_HOME = $script:SavedXdgCache
        $script:DFCatalogProviders = $script:SavedProviders
        $script:DFCatalogAvailability = @{}
        Remove-Variable -Name DFTestInstalledProbes -Scope Global -ErrorAction Ignore
        Remove-Item (Join-Path $TestDrive 'cache') -Recurse -Force -ErrorAction Ignore
    }

    It 'aggregates installed items across providers' {
        $r = Get-DFCatalogInstalled -ToolsPath $script:ToolsPath
        @($r.Items).Count | Should -Be 2
        @($r.Items | Where-Object Source -eq 'scoop')[0].Name | Should -Be 'ripgrep'
        @($r.Items | Where-Object Source -eq 'crates')[0].InstalledVersion | Should -Be '10.2.0'
    }

    It 'builds the cross-catalog identity map from Tools/*.json packages' {
        $r = Get-DFCatalogInstalled -ToolsPath $script:ToolsPath
        $r.IdentityMap['scoop:ripgrep'] | Should -Be 'ripgrep'
        $r.IdentityMap['winget:burntsushi.ripgrep.msvc'] | Should -Be 'ripgrep'
        $r.IdentityMap['choco:ripgrep'] | Should -Be 'ripgrep'
    }

    It 'serves the snapshot from cache within the TTL' {
        $null = Get-DFCatalogInstalled -ToolsPath $script:ToolsPath
        $null = Get-DFCatalogInstalled -ToolsPath $script:ToolsPath
        $global:DFTestInstalledProbes | Should -Be 1
    }

    It 'rebuilds with -Force' {
        $null = Get-DFCatalogInstalled -ToolsPath $script:ToolsPath
        $null = Get-DFCatalogInstalled -ToolsPath $script:ToolsPath -Force
        $global:DFTestInstalledProbes | Should -Be 2
    }
}
