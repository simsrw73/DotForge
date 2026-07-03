BeforeAll {
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/Test-DFToolSchema.ps1"
    . "$PSScriptRoot/../Private/Import-DFToolDb.ps1"
    . "$PSScriptRoot/../Private/DFCatalog.ps1"
    . "$PSScriptRoot/../Private/Get-DFCatalogInstalled.ps1"
    . "$PSScriptRoot/../Public/Update-DFPackageCache.ps1"
}

Describe 'Update-DFPackageCache' {
    BeforeEach {
        $script:SavedXdgCache = $Env:XDG_CACHE_HOME
        $Env:XDG_CACHE_HOME = Join-Path $TestDrive 'cache'
        $script:SavedProviders = $script:DFCatalogProviders
        $script:DFCatalogAvailability = @{}
        $global:DFTestRefreshLog = [System.Collections.Generic.List[string]]::new()

        $script:DFCatalogProviders = @{
            scoop = @{
                Name = 'scoop'; Kind = 'snapshot'; Test = { $true }
                Search = { }
                GetInstalled = { [pscustomobject]@{ Source = 'scoop'; Name = 'ripgrep'; PackageId = 'ripgrep'; InstalledVersion = '14.1.0' } }
                Refresh = { param($Query) $global:DFTestRefreshLog.Add("scoop:$Query") }
            }
            crates = @{
                Name = 'crates'; Kind = 'query-cache'; Test = { $true }
                Search = { }
                GetInstalled = { }
                Refresh = { param($Query) $global:DFTestRefreshLog.Add("crates:$Query") }
            }
            npm = @{
                Name = 'npm'; Kind = 'query-cache'; Test = { $true }
                Search = { }
                GetInstalled = { }
                Refresh = { param($Query) $global:DFTestRefreshLog.Add("npm:$Query") }
            }
        }
    }
    AfterEach {
        $Env:XDG_CACHE_HOME = $script:SavedXdgCache
        $script:DFCatalogProviders = $script:SavedProviders
        $script:DFCatalogAvailability = @{}
        Remove-Variable -Name DFTestRefreshLog -Scope Global -ErrorAction Ignore
        Remove-Item (Join-Path $TestDrive 'cache') -Recurse -Force -ErrorAction Ignore
    }

    It 'refreshes snapshot provider indexes' {
        Update-DFPackageCache -Quiet
        $global:DFTestRefreshLog | Where-Object { $_ -like 'scoop:*' } | Should -Not -BeNullOrEmpty
    }

    It 're-warms every seen query against each query-cache provider' {
        Add-DFCatalogSeenQuery -Query 'static site generator'
        Update-DFPackageCache -Quiet
        $global:DFTestRefreshLog | Should -Contain 'crates:static site generator'
        $global:DFTestRefreshLog | Should -Contain 'npm:static site generator'
    }

    It 're-warms installed tool names' {
        Update-DFPackageCache -Quiet
        $global:DFTestRefreshLog | Should -Contain 'crates:ripgrep'
        $global:DFTestRefreshLog | Should -Contain 'npm:ripgrep'
    }

    It 'does not re-warm the same query twice' {
        Add-DFCatalogSeenQuery -Query 'ripgrep'     # duplicates the installed tool name
        Update-DFPackageCache -Quiet
        @($global:DFTestRefreshLog | Where-Object { $_ -eq 'crates:ripgrep' }).Count | Should -Be 1
    }

    It 'honors -Source' {
        Update-DFPackageCache -Quiet -Source crates
        $global:DFTestRefreshLog | Where-Object { $_ -like 'scoop:*' } | Should -BeNullOrEmpty
        $global:DFTestRefreshLog | Where-Object { $_ -like 'npm:*' } | Should -BeNullOrEmpty
    }

    It 'keeps going when one provider refresh fails' {
        $script:DFCatalogProviders['crates'].Refresh = { param($Query) throw 'boom' }
        { Update-DFPackageCache -Quiet -WarningAction SilentlyContinue } | Should -Not -Throw
        $global:DFTestRefreshLog | Should -Contain 'npm:ripgrep'
    }
}
