BeforeAll {
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/ConvertTo-DFPath.ps1"
    . "$PSScriptRoot/../Private/DFCatalog.ps1"
}

Describe 'Get-DFCatalogCacheRoot' {
    BeforeEach { $script:SavedXdgCache = $Env:XDG_CACHE_HOME }
    AfterEach  { $Env:XDG_CACHE_HOME = $script:SavedXdgCache }

    It 'returns catalogs dir under XDG_CACHE_HOME/dotforge' {
        $Env:XDG_CACHE_HOME = $TestDrive
        Get-DFCatalogCacheRoot | Should -Be (Join-Path $TestDrive 'dotforge/catalogs')
    }

    It 'warns and returns $null when XDG_CACHE_HOME is unset' {
        $Env:XDG_CACHE_HOME = $null
        $result = Get-DFCatalogCacheRoot -WarningVariable warnings -WarningAction SilentlyContinue
        $result | Should -BeNullOrEmpty
        $warnings | Should -Not -BeNullOrEmpty
    }
}

Describe 'ConvertTo-DFCatalogQueryKey' {
    It 'normalizes case, trim, and internal whitespace' {
        $r = ConvertTo-DFCatalogQueryKey -Query "  Static   Site`tGenerator "
        $r.Normalized | Should -Be 'static site generator'
    }

    It 'produces a filename-safe key with an 8-hex hash suffix' {
        $r = ConvertTo-DFCatalogQueryKey -Query 'static site generator'
        $r.Key | Should -Match '^static_site_generator-[0-9a-f]{8}$'
    }

    It 'sanitizes characters outside [a-z0-9._-]' {
        $r = ConvertTo-DFCatalogQueryKey -Query 'C++ IDE!'
        $r.Key | Should -Match '^[a-z0-9._-]+-[0-9a-f]{8}$'
    }

    It 'truncates the readable part to 40 chars but stays unique via the hash' {
        $long = 'x' * 100
        $r = ConvertTo-DFCatalogQueryKey -Query $long
        ($r.Key -replace '-[0-9a-f]{8}$').Length | Should -BeLessOrEqual 40
        $r2 = ConvertTo-DFCatalogQueryKey -Query ('x' * 101)
        $r2.Key | Should -Not -Be $r.Key
    }

    It 'is deterministic' {
        (ConvertTo-DFCatalogQueryKey -Query 'ripgrep').Key |
            Should -Be (ConvertTo-DFCatalogQueryKey -Query 'ripgrep').Key
    }
}

Describe 'Write-DFCatalogCacheFile / Read-DFCatalogCacheFile' {
    BeforeEach {
        $script:SavedXdgCache = $Env:XDG_CACHE_HOME
        $Env:XDG_CACHE_HOME = $TestDrive
    }
    AfterEach { $Env:XDG_CACHE_HOME = $script:SavedXdgCache }

    It 'round-trips an envelope of results' {
        $path = Join-Path $TestDrive 'dotforge/catalogs/npm/queries/ripgrep-abcd1234.json'
        $results = @([pscustomobject]@{ Name = 'ripgrep'; LatestVersion = '14.1.1' })
        Write-DFCatalogCacheFile -Path $path -Query 'ripgrep' -Results $results

        $r = Read-DFCatalogCacheFile -Path $path -Ttl ([timespan]::FromHours(24))
        $r.Data.Count | Should -Be 1
        $r.Data[0].Name | Should -Be 'ripgrep'
        $r.Data[0].LatestVersion | Should -Be '14.1.1'
        $r.Stale | Should -BeFalse
        $r.AgeMinutes | Should -BeLessOrEqual 1
    }

    It 'leaves no temp files behind' {
        $path = Join-Path $TestDrive 'dotforge/catalogs/npm/queries/tmp-test.json'
        Write-DFCatalogCacheFile -Path $path -Query 'q' -Results @()
        Get-ChildItem (Split-Path $path) -Filter '*.tmp.*' | Should -BeNullOrEmpty
    }

    It 'reports Stale when the envelope is older than the TTL' {
        $path = Join-Path $TestDrive 'stale.json'
        $old = [datetime]::UtcNow.AddHours(-48).ToString('o')
        Set-Content -Path $path -Value (@{ timestamp = $old; query = 'q'; results = @() } | ConvertTo-Json) -Encoding UTF8

        $r = Read-DFCatalogCacheFile -Path $path -Ttl ([timespan]::FromHours(24))
        $r.Stale | Should -BeTrue
        $r.AgeMinutes | Should -BeGreaterThan (47 * 60)
    }

    It 'returns $null for a missing file' {
        Read-DFCatalogCacheFile -Path (Join-Path $TestDrive 'nope.json') -Ttl ([timespan]::FromHours(1)) |
            Should -BeNullOrEmpty
    }

    It 'returns $null for a corrupt file' {
        $path = Join-Path $TestDrive 'corrupt.json'
        Set-Content -Path $path -Value 'not json {' -Encoding UTF8
        Read-DFCatalogCacheFile -Path $path -Ttl ([timespan]::FromHours(1)) |
            Should -BeNullOrEmpty
    }
}

Describe 'New-DFToolSourceInfo / New-DFToolInfo' {
    It 'stamps DotForge.ToolSourceInfo with source fields' {
        $s = New-DFToolSourceInfo -Source 'scoop' -PackageId 'main/ripgrep' -Name 'ripgrep' `
            -Description 'search tool' -LatestVersion '14.1.1' -MatchKind 'exact-name'
        $s.PSObject.TypeNames[0] | Should -Be 'DotForge.ToolSourceInfo'
        $s.Source | Should -Be 'scoop'
        $s.PackageId | Should -Be 'main/ripgrep'
        $s.Installed | Should -BeFalse
        $s.MatchKind | Should -Be 'exact-name'
    }

    It 'stamps DotForge.ToolInfo carrying its sources' {
        $s = New-DFToolSourceInfo -Source 'scoop' -PackageId 'main/ripgrep' -Name 'ripgrep' -MatchKind 'exact-name'
        $i = New-DFToolInfo -Name 'ripgrep' -Description 'search tool' -Sources @($s)
        $i.PSObject.TypeNames[0] | Should -Be 'DotForge.ToolInfo'
        $i.Name | Should -Be 'ripgrep'
        $i.Sources.Count | Should -Be 1
        $i.Installed | Should -BeFalse
    }
}

Describe 'Get-DFCatalogProvider' {
    BeforeEach {
        $script:SavedProviders = $script:DFCatalogProviders
        $script:DFCatalogProviders = @{}
        $script:DFCatalogAvailability = @{}
        # Global (not $script: + GetNewClosure) — GetNewClosure would rebind
        # $script: to a cloned dynamic module and the increments would vanish.
        $global:DFTestProbeCount = 0

        $script:DFCatalogProviders['crates'] = @{
            Name = 'crates'; Kind = 'query-cache'; Test = { $true }
        }
        $script:DFCatalogProviders['scoop'] = @{
            Name = 'scoop'; Kind = 'snapshot'
            Test = { $global:DFTestProbeCount++; $true }
        }
        $script:DFCatalogProviders['npm'] = @{
            Name = 'npm'; Kind = 'query-cache'; Test = { $false }
        }
    }
    AfterEach {
        $script:DFCatalogProviders = $script:SavedProviders
        $script:DFCatalogAvailability = @{}
        Remove-Variable -Name DFTestProbeCount -Scope Global -ErrorAction Ignore
    }

    It 'returns available providers in canonical order' {
        $p = Get-DFCatalogProvider
        $p.Name | Should -Be @('scoop', 'crates')   # canonical order, npm filtered (Test=$false)
    }

    It 'filters by -Source' {
        $p = Get-DFCatalogProvider -Source 'crates'
        $p.Name | Should -Be @('crates')
    }

    It 'memoizes availability probes for the session' {
        $null = Get-DFCatalogProvider
        $null = Get-DFCatalogProvider
        $global:DFTestProbeCount | Should -Be 1
    }
}

Describe 'Add-DFCatalogSeenQuery' {
    BeforeEach {
        $script:SavedXdgCache = $Env:XDG_CACHE_HOME
        $Env:XDG_CACHE_HOME = $TestDrive
    }
    AfterEach { $Env:XDG_CACHE_HOME = $script:SavedXdgCache }

    It 'persists queries most-recent-first without duplicates' {
        Add-DFCatalogSeenQuery -Query 'aaa'
        Add-DFCatalogSeenQuery -Query 'bbb'
        Add-DFCatalogSeenQuery -Query 'aaa'
        $file = Join-Path $TestDrive 'dotforge/catalogs/seen-queries.json'
        $seen = Get-Content $file -Raw | ConvertFrom-Json
        @($seen).Count | Should -Be 2
        @($seen)[0].query | Should -Be 'aaa'
        @($seen)[1].query | Should -Be 'bbb'
    }

    It 'caps the list at 50 entries, dropping the oldest' {
        1..55 | ForEach-Object { Add-DFCatalogSeenQuery -Query "q$_" }
        $file = Join-Path $TestDrive 'dotforge/catalogs/seen-queries.json'
        $seen = Get-Content $file -Raw | ConvertFrom-Json
        @($seen).Count | Should -Be 50
        @($seen)[0].query | Should -Be 'q55'
        @($seen).query | Should -Not -Contain 'q1'
    }

    It 'is a no-op without XDG_CACHE_HOME' {
        $Env:XDG_CACHE_HOME = $null
        { Add-DFCatalogSeenQuery -Query 'x' -WarningAction SilentlyContinue } | Should -Not -Throw
    }
}
