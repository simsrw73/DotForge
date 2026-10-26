BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    # Catalogs exist because their provider files register; load the real ones.
    Get-ChildItem "$PSScriptRoot/../Modules/DotForge.Catalog/Private" -Filter 'DFCatalog.*.ps1' | Where-Object Name -ne 'DFCatalog.Base.ps1' |
        ForEach-Object { . $_.FullName }
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

    It 'keys registry sources (crates, psgallery) by their catalog names' {
        @{
            name = 'mdcat'; executable = 'mdcat.exe'; xdg = @{ method = 'default' }
            packages = @{ scoop = 'mdcat'; crates = 'mdcat' }
        } | ConvertTo-Json | Set-Content (Join-Path $script:ToolsPath 'mdcat.json')
        @{
            name = 'posh-git'; executable = 'posh-git'; type = 'module'; xdg = @{ method = 'default' }
            packages = @{ psgallery = 'posh-git' }
        } | ConvertTo-Json | Set-Content (Join-Path $script:ToolsPath 'posh-git.json')
        $r = Get-DFCatalogInstalled -ToolsPath $script:ToolsPath -FetchItems { @() }
        $r.IdentityMap['crates:mdcat'] | Should -Be 'mdcat'
        $r.IdentityMap['psgallery:posh-git'] | Should -Be 'posh-git'
        $r.IdentityMap['scoop:mdcat'] | Should -Be 'mdcat'
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
        $providers = @(
            @{ Name = 'good';  Files = @('FakeGood.ps1');  InstalledFunction = 'Get-FakeGoodInstalled' }
            @{ Name = 'empty'; Files = @('FakeEmpty.ps1'); InstalledFunction = 'Get-FakeEmptyInstalled' })
        $r = @(Invoke-DFCatalogInstalledFetch -Providers $providers -PrivateRoot $script:FakeRoot)
        $r.Count | Should -Be 1
        $r[0].Name | Should -Be 'thing'
    }

    It 'isolates one provider''s failure from the others' {
        $providers = @(
            @{ Name = 'good'; Files = @('FakeGood.ps1'); InstalledFunction = 'Get-FakeGoodInstalled' }
            @{ Name = 'bad';  Files = @('FakeBad.ps1');  InstalledFunction = 'Get-FakeBadInstalled' })
        $r = @(Invoke-DFCatalogInstalledFetch -Providers $providers -PrivateRoot $script:FakeRoot)
        $r.Count | Should -Be 1
        $r[0].Source | Should -Be 'good'
    }

    It 'returns nothing but does not throw when every provider fails' {
        $providers = @(@{ Name = 'bad'; Files = @('FakeBad.ps1'); InstalledFunction = 'Get-FakeBadInstalled' })
        { $script:r = @(Invoke-DFCatalogInstalledFetch -Providers $providers -PrivateRoot $script:FakeRoot) } |
            Should -Not -Throw
        $script:r.Count | Should -Be 0
    }

    It 'keeps what finished when the time limit cuts off a slow provider, even under ErrorActionPreference Stop' {
        Set-Content (Join-Path $script:FakeRoot 'FakeSlow.ps1') @'
function Get-FakeSlowInstalled {
    Start-Sleep -Seconds 20
    [pscustomobject]@{ Source = 'slow'; Name = 'late'; PackageId = 'late'; InstalledVersion = '1.0' }
}
'@
        $providers = @(
            @{ Name = 'good'; Files = @('FakeGood.ps1'); InstalledFunction = 'Get-FakeGoodInstalled' }
            @{ Name = 'slow'; Files = @('FakeSlow.ps1'); InstalledFunction = 'Get-FakeSlowInstalled' })
        $ErrorActionPreference = 'Stop'   # a profile setting; the fetch must still fail soft
        $script:r = $null
        { $script:r = @(Invoke-DFCatalogInstalledFetch -Providers $providers -PrivateRoot $script:FakeRoot -TimeoutSeconds 2) } |
            Should -Not -Throw
        @($script:r.Source) | Should -Be @('good')
    }

    It 'every registered provider loads in a fresh runspace (its Files list is complete), without running a package manager' {
        # Running the real installed-list functions would run scoop, winget, pipx, ... (no test may).
        # A probe stands in for each: in the provider's own fresh runspace, it checks that the real
        # function loaded and that every DotForge command it calls resolves from the provider's Files.
        $privateRoot = Join-Path $TestDrive 'catalog-private'
        Copy-Item "$PSScriptRoot/../Modules/DotForge.Catalog/Private" $privateRoot -Recurse -Force
        $providers = @($script:DFCatalogProviders.Values)
        $providers.Count | Should -Be 7
        $probeFile = Join-Path $privateRoot 'DFCatalog.Probe.ps1'
        Set-Content $probeFile (@(foreach ($provider in $providers) {
            $probeName = "Test-DFProbe$($provider.Name -replace '\W', '')"
            "function $probeName {"
            "    `$command = Get-Command '$($provider.InstalledFunction)' -ErrorAction Stop"
            "    `$calls = `$command.ScriptBlock.Ast.FindAll({ param(`$a) `$a -is [System.Management.Automation.Language.CommandAst] }, `$true) | ForEach-Object { `$_.GetCommandName() } | Where-Object { `$_ -like '*-DF*' } | Sort-Object -Unique"
            "    foreach (`$call in `$calls) { `$null = Get-Command `$call -ErrorAction Stop }"
            "    [pscustomobject]@{ Source = '$($provider.Name)' }"
            '}'
        }) -join "`n")
        $probeProviders = @(foreach ($provider in $providers) {
            [pscustomobject]@{ Name = $provider.Name; Files = @($provider.Files) + 'DFCatalog.Probe.ps1'; InstalledFunction = "Test-DFProbe$($provider.Name -replace '\W', '')" }
        })
        # A provider whose probe failed returns nothing (the fetch's per-provider catch; its
        # Write-Verbose runs in a parallel runspace, so it can't be seen here): compare names.
        $loaded = @(Invoke-DFCatalogInstalledFetch -Providers $probeProviders -PrivateRoot $privateRoot -TimeoutSeconds 60)  # room for a cold CI runner
        @($loaded.Source | Sort-Object) | Should -Be @($providers.Name | Sort-Object)
    }
}
