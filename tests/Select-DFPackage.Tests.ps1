BeforeAll {
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/Invoke-DFFzf.ps1"
    . "$PSScriptRoot/../Public/Invoke-DFPicker.ps1"
    . "$PSScriptRoot/../Private/DFCatalog.ps1"
    . "$PSScriptRoot/../Private/Invoke-DFSqliteQuery.ps1"
    . "$PSScriptRoot/../Private/Get-DFCatalogLocalPackages.ps1"
    . "$PSScriptRoot/../Public/Select-DFPackage.ps1"

    function Initialize-LocalCaches {
        # Scoop index + one cached npm query + installed snapshot — local data only.
        Write-DFCatalogCacheFile -Path (Join-Path $Env:XDG_CACHE_HOME 'dotforge/catalogs/scoop/index.json') -Query '' -Results @(
            [pscustomobject]@{ name = 'ripgrep'; bucket = 'main'; version = '15.1.0'; description = 'regex search'; homepage = ''; license = 'MIT' }
        )
        Write-DFCatalogCacheFile -Path (Join-Path $Env:XDG_CACHE_HOME 'dotforge/catalogs/npm/queries/prettier-abc.json') -Query 'prettier' -Results @(
            [pscustomobject]@{ Source = 'npm'; PackageId = 'prettier'; Name = 'prettier'; Description = 'formatter'; LatestVersion = '3.3.0'; MatchKind = 'exact-name' }
        )
        Write-DFCatalogCacheFile -Path (Join-Path $Env:XDG_CACHE_HOME 'dotforge/catalogs/installed.json') -Query '' -Results @(
            [pscustomobject]@{ Source = 'crates'; Name = 'ripgrep'; PackageId = 'ripgrep'; InstalledVersion = '14.1.1' }
        )
    }
}

Describe 'Get-DFCatalogLocalPackages' {
    BeforeEach {
        $script:SavedXdgCache = $Env:XDG_CACHE_HOME
        $Env:XDG_CACHE_HOME = Join-Path $TestDrive 'cache'
        Initialize-LocalCaches
    }
    AfterEach {
        $Env:XDG_CACHE_HOME = $script:SavedXdgCache
        Remove-Item (Join-Path $TestDrive 'cache') -Recurse -Force -ErrorAction Ignore
    }

    It 'aggregates local caches into one entry per package with merged sources' {
        $packages = @(Get-DFCatalogLocalPackages)
        $rg = $packages | Where-Object Name -eq 'ripgrep'
        $rg | Should -Not -BeNullOrEmpty
        $rg.Sources | Should -Match 'scoop'
        $rg.Sources | Should -Match 'crates'
        $rg.Description | Should -Be 'regex search'
        ($packages | Where-Object Name -eq 'prettier').Sources | Should -Match 'npm'
    }

    It 'returns nothing when no cache root is configured' {
        $Env:XDG_CACHE_HOME = $null
        @(Get-DFCatalogLocalPackages -WarningAction SilentlyContinue) | Should -BeNullOrEmpty
    }
}

Describe 'Select-DFPackage' {
    BeforeEach {
        $script:SavedXdgCache = $Env:XDG_CACHE_HOME
        $Env:XDG_CACHE_HOME = Join-Path $TestDrive 'cache'
        Initialize-LocalCaches
        function Find-DFPackage { param([string[]]$Query) }   # stub for mocking
    }
    AfterEach {
        $Env:XDG_CACHE_HOME = $script:SavedXdgCache
        Remove-Item (Join-Path $TestDrive 'cache') -Recurse -Force -ErrorAction Ignore
    }

    It 'shows the info card for the picked package' {
        Mock Invoke-DFFzf { "ripgrep`tscoop,crates`tregex search" }
        Mock Find-DFPackage { }
        Select-DFPackage
        Should -Invoke Find-DFPackage -Times 1 -Exactly -ParameterFilter { $Query -contains 'ripgrep' }
    }

    It 'does nothing when the picker is cancelled' {
        Mock Invoke-DFFzf { $null }
        Mock Find-DFPackage { }
        Select-DFPackage
        Should -Invoke Find-DFPackage -Times 0 -Exactly
    }

    It 'warns when no local catalog data exists yet' {
        Remove-Item (Join-Path $TestDrive 'cache') -Recurse -Force
        Mock Invoke-DFFzf { $null }
        $warnings = @()
        Select-DFPackage -WarningVariable warnings -WarningAction SilentlyContinue 3>$null
        $warnings | Should -Not -BeNullOrEmpty
    }

    It 'is aliased to ftrifle' {
        Get-Alias ftrifle -ErrorAction Ignore | Should -Not -BeNullOrEmpty
    }
}
