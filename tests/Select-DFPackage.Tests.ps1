BeforeAll {
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/ConvertTo-DFPath.ps1"
    . "$PSScriptRoot/../Private/Invoke-DFFzf.ps1"
    . "$PSScriptRoot/../Public/Invoke-DFPicker.ps1"
    . "$PSScriptRoot/../Private/DFCatalog.ps1"
    . "$PSScriptRoot/../Private/Invoke-DFSqliteQuery.ps1"
    . "$PSScriptRoot/../Private/Test-DFToolSchema.ps1"
    . "$PSScriptRoot/../Private/Import-DFToolDb.ps1"
    . "$PSScriptRoot/../Private/Get-DFCatalogInstalled.ps1"
    . "$PSScriptRoot/../Private/Get-DFCatalogLocalPackages.ps1"
    . "$PSScriptRoot/../Private/Format-DFToolInfo.ps1"
    . "$PSScriptRoot/../Public/Find-DFPackage.ps1"
    . "$PSScriptRoot/../Public/Select-DFPackage.ps1"
    . "$PSScriptRoot/../Private/Get-DFCategoryDb.ps1"

    function Initialize-LocalCaches {
        # Scoop index + one cached npm query + installed snapshot — local data only.
        Write-DFCatalogCacheFile -Path (Join-Path $Env:XDG_CACHE_HOME 'dotforge/catalogs/scoop/index.json') -Query '' -Results @(
            [pscustomobject]@{ name = 'ripgrep'; bucket = 'main'; version = '15.1.0'; description = 'regex search'; homepage = ''; license = 'MIT' }
        )
        Write-DFCatalogCacheFile -Path (Join-Path $Env:XDG_CACHE_HOME 'dotforge/catalogs/npm/queries/prettier-abc.json') -Query 'prettier' -Results @(
            [pscustomobject]@{ Source = 'npm'; PackageId = 'prettier'; Name = 'prettier'; Description = 'formatter'; LatestVersion = '3.3.0'; MatchKind = 'exact-name' }
        )
    }
}

Describe 'Get-DFCatalogLocalPackages' {
    BeforeEach {
        $script:SavedXdgCache = $Env:XDG_CACHE_HOME
        $Env:XDG_CACHE_HOME = Join-Path $TestDrive 'cache'
        Initialize-LocalCaches
        Mock Get-DFCatalogInstalled {
            @{
                Items       = @([pscustomobject]@{ Source = 'crates'; Name = 'ripgrep'; PackageId = 'ripgrep'; InstalledVersion = '14.1.1' })
                IdentityMap = @{}
            }
        }
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
        Mock Get-DFCatalogInstalled { @{ Items = @(); IdentityMap = @{} } }
        function Find-DFPackage {
            [CmdletBinding()]
            param(
                [string[]]$Query,
                [string]$Category,
                [string]$WorksWith,
                [string[]]$Source,
                [switch]$AsObject,
                [switch]$Readme,
                [switch]$GitInfo
            )
        }   # stub for mocking
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

    Context 'query mode' {
        BeforeEach {
            Mock Find-DFPackage {
                $src = New-DFToolSourceInfo -Source scoop -PackageId 'extras/zed' -Name zed `
                    -Description 'editor' -LatestVersion '1.0' -MatchKind exact-name
                New-DFToolInfo -Name zed -Description 'editor' -Sources @($src) -MatchKind exact-name
            } -ParameterFilter { $AsObject }
        }

        It 'searches, pre-renders preview files, and passes a preview command' {
            Mock Invoke-DFFzf {
                $script:CapturedArgs = $FzfArgs
                $script:CapturedItems = $InputItems
                $script:PreviewFileExistedAtPickTime = Test-Path (($InputItems[0] -split "`t")[0])
                $null
            }
            Select-DFPackage zed
            $script:CapturedArgs -join ' ' | Should -Match '--preview'
            $fields = $script:CapturedItems[0] -split "`t"
            $fields[0] | Should -Match 'dotforge-preview.*\.txt$'  # pre-rendered card file path
            $fields[1] | Should -Be 'scoop:extras/zed' # qualified id
            $fields[2] | Should -Be 'zed'
            $script:PreviewFileExistedAtPickTime | Should -BeTrue
        }

        It 'cleans the preview temp dir after the picker exits' {
            $script:Dir = $null
            Mock Invoke-DFFzf {
                $script:Dir = Split-Path (($InputItems[0] -split "`t")[0]) -Parent
                $null
            }
            Select-DFPackage zed
            Test-Path $script:Dir | Should -BeFalse
        }

        It 'invokes Find-DFPackage with the qualified id and passthrough switches on selection' {
            Mock Invoke-DFFzf { $InputItems[0] }   # simulate picking the first row
            Mock Find-DFPackage {
                if ($AsObject) {
                    $src = New-DFToolSourceInfo -Source scoop -PackageId 'extras/zed' -Name zed `
                        -Description 'editor' -LatestVersion '1.0' -MatchKind exact-name
                    New-DFToolInfo -Name zed -Description 'editor' -Sources @($src) -MatchKind exact-name
                } else {
                    'card'
                }
            }
            Select-DFPackage zed -Readme -GitInfo
            Should -Invoke Find-DFPackage -ParameterFilter {
                (-not $AsObject) -and ($Query -contains 'scoop:extras/zed') -and $Readme -and $GitInfo
            }
        }

        It 'warns when the query has no matches' {
            Mock Find-DFPackage { @() } -ParameterFilter { $AsObject }
            $w = $null
            Select-DFPackage zzz -WarningVariable w -WarningAction SilentlyContinue
            "$w" | Should -Match 'no matches'
        }
    }

    Context '-Categories browse mode' {
        BeforeEach {
            $script:FakeDb = [pscustomobject]@{
                Raw = [pscustomobject]@{
                    taxonomy = [pscustomobject]@{ function = @('search', 'editor'); worksWith = @('text') }
                }
                FacetIndex = @{
                    'function:search' = @('ripgrep')
                    'function:editor' = @('micro')
                    'worksWith:text'  = @('ripgrep', 'micro')
                }
            }
            Mock Get-DFCategoryDb { $script:FakeDb }
        }

        It '-Categories lists function and worksWith values with counts, divided' {
            Mock Invoke-DFFzf {
                $script:CapturedItems = $InputItems
                $null   # simulate cancel — just inspect what was offered
            }
            Select-DFPackage -Categories
            $joined = $script:CapturedItems -join "`n"
            $joined | Should -Match 'search'
            $joined | Should -Match 'editor'
            $joined | Should -Match 'text'
            $joined | Should -Match '— browse by works-with —'
        }

        It 'recurses into -Category when a function value is picked' {
            Mock Invoke-DFFzf {
                ($InputItems | Where-Object { $_ -like 'search*' }) | Select-Object -First 1
            }
            Mock Find-DFPackage { @() } -ParameterFilter { $Category -eq 'search' -and $AsObject }
            Select-DFPackage -Categories
            Should -Invoke Find-DFPackage -ParameterFilter { $Category -eq 'search' }
        }

        It 'recurses into -WorksWith when a worksWith value is picked' {
            Mock Invoke-DFFzf {
                ($InputItems | Where-Object { $_ -like 'text*' }) | Select-Object -First 1
            }
            Mock Find-DFPackage { @() } -ParameterFilter { $WorksWith -eq 'text' -and $AsObject }
            Select-DFPackage -Categories
            Should -Invoke Find-DFPackage -ParameterFilter { $WorksWith -eq 'text' }
        }

        It 'does nothing when the divider row is selected' {
            Mock Invoke-DFFzf { '— browse by works-with —' }
            Mock Find-DFPackage { }
            Select-DFPackage -Categories
            Should -Invoke Find-DFPackage -Times 0 -Exactly
        }

        It '-Category <value> searches, previews, and selects exactly like query mode' {
            Mock Find-DFPackage {
                $src = New-DFToolSourceInfo -Source scoop -PackageId 'main/ripgrep' -Name ripgrep `
                    -Description 'search tool' -LatestVersion '14.1.0' -MatchKind exact-name
                New-DFToolInfo -Name ripgrep -Description 'search tool' -Sources @($src) -MatchKind exact-name
            } -ParameterFilter { $Category -eq 'search' -and $AsObject }
            Mock Invoke-DFFzf { $InputItems[0] }
            Mock Find-DFPackage { 'card' } -ParameterFilter { -not $AsObject }
            Select-DFPackage -Category search
            Should -Invoke Find-DFPackage -ParameterFilter { (-not $AsObject) -and ($Query -contains 'scoop:main/ripgrep') }
        }

        It 'warns when -Category <value> has no matches' {
            Mock Find-DFPackage { @() } -ParameterFilter { $Category -eq 'search' -and $AsObject }
            $w = $null
            Select-DFPackage -Category search -WarningVariable w -WarningAction SilentlyContinue
            "$w" | Should -Match "category 'search'"
        }

        It 'warns when the category database is unavailable' {
            Mock Get-DFCategoryDb { [pscustomobject]@{ Raw = $null; FacetIndex = @{} } }
            $w = $null
            Select-DFPackage -Categories -WarningVariable w -WarningAction SilentlyContinue
            "$w" | Should -Match 'unavailable'
        }
    }
}
