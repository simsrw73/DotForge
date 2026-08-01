BeforeAll {
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/ConvertTo-DFPath.ps1"
    . "$PSScriptRoot/../Private/Test-DFOutputPiped.ps1"
    . "$PSScriptRoot/../Private/DFCatalog.ps1"
    . "$PSScriptRoot/../Private/Get-DFCatalogInstalled.ps1"
    . "$PSScriptRoot/../Private/Test-DFToolIdentityGuideSchema.ps1"
    . "$PSScriptRoot/../Private/Get-DFToolIdentityGuide.ps1"
    . "$PSScriptRoot/../Private/Resolve-DFCatalogQueryMerge.ps1"
}

Describe 'Resolve-DFCatalogQueryMerge identity resolution' {
    BeforeEach {
        $script:SavedXdgCache = $Env:XDG_CACHE_HOME
        $Env:XDG_CACHE_HOME = Join-Path $TestDrive 'cache'
        $script:SavedProviders = $script:DFCatalogProviders
        $script:DFCatalogAvailability = @{}

        $script:DFCatalogProviders = @{
            scoop = @{
                Name = 'scoop'; Kind = 'snapshot'; Test = { $true }
                Search = { param($Query, $Fresh)
                    if ($Query -eq 'zed') {
                        New-DFToolSourceInfo -Source scoop -PackageId 'extras/zed' -Name 'zed' `
                            -Description 'code editor' -LatestVersion '0.191.0' -MatchKind exact-name
                    }
                }
                GetInstalled = { }
                Refresh = { }
            }
            choco = @{
                Name = 'choco'; Kind = 'query-cache'; Test = { $true }
                Search = { param($Query, $Fresh)
                    if ($Query -eq 'zed') {
                        New-DFToolSourceInfo -Source choco -PackageId 'zed' -Name 'zed' `
                            -Description 'schema tool' -LatestVersion '1.4.2' -MatchKind exact-name
                    }
                }
                GetInstalled = { }
                Refresh = { }
            }
        }
        Mock Get-DFToolIdentityGuide { [pscustomobject]@{ Raw = $null; IdIndex = @{} } }
    }
    AfterEach {
        $Env:XDG_CACHE_HOME = $script:SavedXdgCache
        $script:DFCatalogProviders = $script:SavedProviders
        $script:DFCatalogAvailability = @{}
    }

    It 'splits two different-source same-named hits with no identity link at all' {
        Mock Get-DFCatalogInstalled { @{ Items = @(); IdentityMap = @{} } }
        $r = @(Resolve-DFCatalogQueryMerge -QueryText zed)
        $r.Count | Should -Be 2
        @($r.Name) | Should -Be @('zed', 'zed')
        @($r.Sources.Source) | Sort-Object | Should -Be @('choco', 'scoop')
    }

    It 'merges two different-source same-named hits when the tool-identity guide links them' {
        Mock Get-DFCatalogInstalled { @{ Items = @(); IdentityMap = @{} } }
        Mock Get-DFToolIdentityGuide {
            [pscustomobject]@{
                Raw = $null
                IdIndex = @{ 'scoop:extras/zed' = 'zed'; 'choco:zed' = 'zed' }
            }
        }
        $r = @(Resolve-DFCatalogQueryMerge -QueryText zed)
        $r.Count | Should -Be 1
        $r[0].Sources.Count | Should -Be 2
    }

    It 'still merges via the live Tools/*.json IdentityMap (existing behavior preserved)' {
        Mock Get-DFCatalogInstalled {
            @{ Items = @(); IdentityMap = @{ 'scoop:extras/zed' = 'zed'; 'choco:zed' = 'zed' } }
        }
        $r = @(Resolve-DFCatalogQueryMerge -QueryText zed)
        $r.Count | Should -Be 1
        $r[0].Sources.Count | Should -Be 2
    }

    It 'resolves a scoop bucket-qualified id against the guide''s bare-name entry' {
        Mock Get-DFCatalogInstalled { @{ Items = @(); IdentityMap = @{} } }
        Mock Get-DFToolIdentityGuide {
            [pscustomobject]@{
                Raw = $null
                IdIndex = @{ 'scoop:zed' = 'zed'; 'choco:zed' = 'zed' }   # bare, not bucket-qualified
            }
        }
        $r = @(Resolve-DFCatalogQueryMerge -QueryText zed)
        $r.Count | Should -Be 1
    }

    It 'prefers Tools/*.json over a conflicting guide entry for the same (source, packageId)' {
        Mock Get-DFCatalogInstalled {
            @{ Items = @(); IdentityMap = @{ 'scoop:extras/zed' = 'zed-editor' } }
        }
        Mock Get-DFToolIdentityGuide {
            [pscustomobject]@{ Raw = $null; IdIndex = @{ 'scoop:extras/zed' = 'some-other-name' } }
        }
        $r = @(Resolve-DFCatalogQueryMerge -QueryText zed)
        ($r | Where-Object { $_.Sources.Source -contains 'scoop' }).Name | Should -Be 'zed-editor'
    }

    It 'still groups same-source same-name hits together (unaffected by the identity change)' {
        $script:DFCatalogProviders['scoop'].Search = { param($Query, $Fresh)
            if ($Query -eq 'zed') {
                New-DFToolSourceInfo -Source scoop -PackageId 'main/zed' -Name 'zed' -MatchKind exact-name
                New-DFToolSourceInfo -Source scoop -PackageId 'extras/zed' -Name 'zed' -MatchKind keyword
            }
        }
        $script:DFCatalogProviders.Remove('choco')
        Mock Get-DFCatalogInstalled { @{ Items = @(); IdentityMap = @{} } }
        $r = @(Resolve-DFCatalogQueryMerge -QueryText zed)
        $r.Count | Should -Be 1
        $r[0].Sources.Count | Should -Be 2
    }
}
