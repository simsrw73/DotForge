BeforeAll {
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/DFCatalog.ps1"
    . "$PSScriptRoot/../Private/Start-DFCatalogRefreshJob.ps1"   # must exist for Mock
}

Describe 'New-DFToolSourceDetail' {
    It 'builds a typed object with all fields' {
        $d = New-DFToolSourceDetail -Source npm -PackageId left-pad `
            -Publisher 'npm, Inc.' -Maintainers @('alice') -Dependencies @('lodash@^4') `
            -Tags @('cli') -Downloads 12345 -RepositoryUrl 'https://github.com/x/y' `
            -InstallHint 'npm install -g left-pad' -Readme '# hi'
        $d.PSObject.TypeNames[0] | Should -Be 'DotForge.ToolSourceDetail'
        $d.Source | Should -Be 'npm'
        $d.Downloads | Should -Be 12345
        $d.Maintainers | Should -Be @('alice')
        $d.Readme | Should -Be '# hi'
    }
    It 'defaults optional fields to empty/null' {
        $d = New-DFToolSourceDetail -Source scoop -PackageId 'main/rg'
        $d.Downloads | Should -BeNullOrEmpty
        @($d.Tags).Count | Should -Be 0
    }
}

Describe 'Get-DFCatalogDetailCache' {
    BeforeEach {
        $script:SavedXdgCache = $Env:XDG_CACHE_HOME
        $Env:XDG_CACHE_HOME = Join-Path $TestDrive 'cache'
        # Pester 5 does not clear TestDrive between Its; wipe the cache dir so
        # each test starts from a genuine miss.
        if (Test-Path $Env:XDG_CACHE_HOME) { Remove-Item $Env:XDG_CACHE_HOME -Recurse -Force }
    }
    AfterEach { $Env:XDG_CACHE_HOME = $script:SavedXdgCache }

    It 'fetches live on miss and writes the cache file' {
        $d = Get-DFCatalogDetailCache -Provider npm -PackageId left-pad -Fetch { param($id)
            New-DFToolSourceDetail -Source npm -PackageId $id -Publisher 'p' }
        $d.Publisher | Should -Be 'p'
        $key = (ConvertTo-DFCatalogQueryKey -Query 'left-pad').Key
        Test-Path (Join-Path $Env:XDG_CACHE_HOME "dotforge/catalogs/npm/details/$key.json") | Should -BeTrue
    }

    It 'serves a fresh cache hit without invoking Fetch' {
        $null = Get-DFCatalogDetailCache -Provider npm -PackageId left-pad -Fetch { param($id)
            New-DFToolSourceDetail -Source npm -PackageId $id -Publisher 'cached' }
        $d = Get-DFCatalogDetailCache -Provider npm -PackageId left-pad -Fetch { throw 'must not fetch' }
        $d.Publisher | Should -Be 'cached'
    }

    It 'stores the RAW PackageId in the envelope query field (for re-warm)' {
        $null = Get-DFCatalogDetailCache -Provider scoop -PackageId 'Extras/Zed' -Fetch { param($id)
            New-DFToolSourceDetail -Source scoop -PackageId $id }
        $key = (ConvertTo-DFCatalogQueryKey -Query 'Extras/Zed').Key
        $file = Join-Path $Env:XDG_CACHE_HOME "dotforge/catalogs/scoop/details/$key.json"
        (Get-Content $file -Raw | ConvertFrom-Json).query | Should -BeExactly 'Extras/Zed'
    }

    It 'kicks a background detail re-warm on a stale hit (registered provider)' {
        Mock Start-DFCatalogRefreshJob { }
        # Background re-warm only fires for a REGISTERED provider — register a
        # stand-in npm entry so this test reflects that precondition.
        $script:DFCatalogProviders['npm'] = @{ Name = 'npm' }
        try {
            $null = Get-DFCatalogDetailCache -Provider npm -PackageId left-pad -Fetch { param($id)
                New-DFToolSourceDetail -Source npm -PackageId $id }
            $script:DFCatalogTtl['npm'] = [timespan]::FromMinutes(-1)   # force stale
            try {
                $d = Get-DFCatalogDetailCache -Provider npm -PackageId left-pad -Fetch { throw 'no inline fetch' }
                $d | Should -Not -BeNullOrEmpty
                Should -Invoke Start-DFCatalogRefreshJob -ParameterFilter { $Kind -eq 'detail' -and $Query -eq 'left-pad' }
            } finally { $script:DFCatalogTtl.Remove('npm') }
        } finally { $script:DFCatalogProviders.Remove('npm') }
    }

    It 'treats a stale hit as a miss for an unregistered provider (no background job, inline refresh)' {
        Mock Start-DFCatalogRefreshJob { }
        $null = Get-DFCatalogDetailCache -Provider github -PackageId 'owner/repo' -Fetch { param($id)
            New-DFToolSourceDetail -Source github -PackageId $id -Publisher 'old' }
        $script:DFCatalogTtl['github'] = [timespan]::FromMinutes(-1)   # force stale
        try {
            $d = Get-DFCatalogDetailCache -Provider github -PackageId 'owner/repo' -Fetch { param($id)
                New-DFToolSourceDetail -Source github -PackageId $id -Publisher 'fresh' }
            $d.Publisher | Should -Be 'fresh'
            Should -Invoke Start-DFCatalogRefreshJob -Times 0
        } finally { $script:DFCatalogTtl.Remove('github') }
    }

    It 'falls back to the stale cache for an unregistered provider when the inline refresh throws' {
        Mock Start-DFCatalogRefreshJob { }
        $null = Get-DFCatalogDetailCache -Provider github -PackageId 'owner/repo' -Fetch { param($id)
            New-DFToolSourceDetail -Source github -PackageId $id -Publisher 'old' }
        $script:DFCatalogTtl['github'] = [timespan]::FromMinutes(-1)   # force stale
        try {
            $d = Get-DFCatalogDetailCache -Provider github -PackageId 'owner/repo' -Fetch { throw 'api down' }
            $d.Publisher | Should -Be 'old'
            Should -Invoke Start-DFCatalogRefreshJob -Times 0
        } finally { $script:DFCatalogTtl.Remove('github') }
    }

    It 'falls back to stale cache when the live fetch throws' {
        $null = Get-DFCatalogDetailCache -Provider npm -PackageId left-pad -Fetch { param($id)
            New-DFToolSourceDetail -Source npm -PackageId $id -Publisher 'old' }
        $d = Get-DFCatalogDetailCache -Provider npm -PackageId left-pad -Fresh -Fetch { throw 'api down' }
        $d.Publisher | Should -Be 'old'
    }

    It 'returns null (no throw, no cache write) when fetch returns nothing' {
        $d = Get-DFCatalogDetailCache -Provider npm -PackageId nope -Fetch { $null }
        $d | Should -BeNullOrEmpty
    }
}

Describe 'Get-DFCatalogDetail dispatcher' {
    BeforeEach {
        $script:SavedProviders = $script:DFCatalogProviders
        $script:DFCatalogProviders = @{
            npm = @{ Name = 'npm'; Detail = { param($Id, $Fresh)
                New-DFToolSourceDetail -Source npm -PackageId $Id -Publisher "fresh=$Fresh" } }
            bare = @{ Name = 'bare' }   # no Detail hook
        }
    }
    AfterEach { $script:DFCatalogProviders = $script:SavedProviders }

    It 'invokes the provider Detail hook with id and fresh flag' {
        (Get-DFCatalogDetail -Source npm -PackageId x -Fresh).Publisher | Should -Be 'fresh=True'
    }
    It 'returns null for providers without a Detail hook' {
        Get-DFCatalogDetail -Source bare -PackageId x | Should -BeNullOrEmpty
    }
    It 'swallows a throwing hook and returns null' {
        $script:DFCatalogProviders.npm.Detail = { throw 'boom' }
        Get-DFCatalogDetail -Source npm -PackageId x | Should -BeNullOrEmpty
    }
}

Describe 'New-DFToolInfo Details/GitHub properties' {
    It 'always carries Details and GitHub (null by default)' {
        $i = New-DFToolInfo -Name x -Sources @()
        $i.PSObject.Properties.Name | Should -Contain 'Details'
        $i.PSObject.Properties.Name | Should -Contain 'GitHub'
        $i.Details | Should -BeNullOrEmpty
    }
}
