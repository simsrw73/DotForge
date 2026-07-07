BeforeAll {
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/Test-DFToolSchema.ps1"
    . "$PSScriptRoot/../Private/Import-DFToolDb.ps1"
    . "$PSScriptRoot/../Private/Get-DFCatalogInstalled.ps1"
}

Describe 'Get-DFCatalogInstalled' {
    BeforeEach {
        # Minimal tool db with a cross-catalog packages map -- IdentityMap
        # construction is unchanged by this feature and unrelated to the
        # fetch mechanism below.
        $script:ToolsPath = Join-Path $TestDrive 'tools'
        New-Item -ItemType Directory $script:ToolsPath -Force | Out-Null
        @{
            name       = 'ripgrep'
            executable = 'rg.exe'
            packages   = @{ scoop = 'ripgrep'; winget = 'BurntSushi.ripgrep.MSVC'; choco = 'ripgrep' }
            xdg        = @{ method = 'default' }
        } | ConvertTo-Json | Set-Content (Join-Path $script:ToolsPath 'ripgrep.json')
    }

    It 'aggregates whatever -FetchItems returns into Items' {
        $r = Get-DFCatalogInstalled -ToolsPath $script:ToolsPath -FetchItems {
            @(
                [pscustomobject]@{ Source = 'scoop'; Name = 'ripgrep'; PackageId = 'ripgrep'; InstalledVersion = '14.1.0' }
                [pscustomobject]@{ Source = 'crates'; Name = 'fd-find'; PackageId = 'fd-find'; InstalledVersion = '10.2.0' }
            )
        }
        @($r.Items).Count | Should -Be 2
        @($r.Items | Where-Object Source -eq 'scoop')[0].Name | Should -Be 'ripgrep'
        @($r.Items | Where-Object Source -eq 'crates')[0].InstalledVersion | Should -Be '10.2.0'
    }

    It 'builds the cross-catalog identity map from Tools/*.json packages' {
        $r = Get-DFCatalogInstalled -ToolsPath $script:ToolsPath -FetchItems { @() }
        $r.IdentityMap['scoop:ripgrep'] | Should -Be 'ripgrep'
        $r.IdentityMap['winget:burntsushi.ripgrep.msvc'] | Should -Be 'ripgrep'
        $r.IdentityMap['choco:ripgrep'] | Should -Be 'ripgrep'
    }

    It 'calls the real Invoke-DFCatalogInstalledFetch when -FetchItems is not supplied' {
        Mock Invoke-DFCatalogInstalledFetch {
            @([pscustomobject]@{ Source = 'npm'; Name = 'x'; PackageId = 'x'; InstalledVersion = '1' })
        }
        $r = Get-DFCatalogInstalled -ToolsPath $script:ToolsPath
        Should -Invoke Invoke-DFCatalogInstalledFetch -Times 1
        @($r.Items)[0].Source | Should -Be 'npm'
    }
}

Describe 'Invoke-DFCatalogInstalledFetch' {
    BeforeAll {
        $script:FakeRoot = Join-Path $TestDrive 'fakeprivate'
        New-Item -ItemType Directory $script:FakeRoot -Force | Out-Null

        Set-Content (Join-Path $script:FakeRoot 'FakeGood.ps1') @'
function Get-FakeGoodInstalled {
    [pscustomobject]@{ Source = 'good'; Name = 'thing'; PackageId = 'thing'; InstalledVersion = '1.0' }
}
'@
        Set-Content (Join-Path $script:FakeRoot 'FakeBad.ps1') @'
function Get-FakeBadInstalled {
    throw 'boom'
}
'@
        Set-Content (Join-Path $script:FakeRoot 'FakeEmpty.ps1') @'
function Get-FakeEmptyInstalled {
}
'@
    }

    It 'aggregates items across multiple providers' {
        $deps = @{ good = @('FakeGood.ps1'); empty = @('FakeEmpty.ps1') }
        $fnNames = @{ good = 'Get-FakeGoodInstalled'; empty = 'Get-FakeEmptyInstalled' }
        $r = @(Invoke-DFCatalogInstalledFetch -Deps $deps -FnNames $fnNames -PrivateRoot $script:FakeRoot)
        $r.Count | Should -Be 1
        $r[0].Name | Should -Be 'thing'
    }

    It 'isolates one provider''s failure from the others' {
        $deps = @{ good = @('FakeGood.ps1'); bad = @('FakeBad.ps1') }
        $fnNames = @{ good = 'Get-FakeGoodInstalled'; bad = 'Get-FakeBadInstalled' }
        $r = @(Invoke-DFCatalogInstalledFetch -Deps $deps -FnNames $fnNames -PrivateRoot $script:FakeRoot)
        $r.Count | Should -Be 1
        $r[0].Source | Should -Be 'good'
    }

    It 'returns nothing but does not throw when every provider fails' {
        $deps = @{ bad = @('FakeBad.ps1') }
        $fnNames = @{ bad = 'Get-FakeBadInstalled' }
        { $script:r = @(Invoke-DFCatalogInstalledFetch -Deps $deps -FnNames $fnNames -PrivateRoot $script:FakeRoot) } |
            Should -Not -Throw
        $script:r.Count | Should -Be 0
    }

    It 'every real provider resolves and runs without error (drift detection against the shipped dependency map)' {
        $privateRoot = "$PSScriptRoot/../Private"
        $verboseRecords = Invoke-DFCatalogInstalledFetch -Deps $script:DFCatalogInstalledDeps `
            -FnNames $script:DFCatalogInstalledFn -PrivateRoot $privateRoot -Verbose 4>&1 |
            Where-Object { $_ -is [System.Management.Automation.VerboseRecord] }
        $failures = @($verboseRecords | Where-Object Message -match "installed enumeration for '.*' failed")
        $failures | Should -BeNullOrEmpty -Because (($failures.Message) -join '; ')
    }
}
