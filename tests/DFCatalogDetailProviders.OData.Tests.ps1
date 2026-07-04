BeforeAll {
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/DFCatalog.Choco.ps1"
    . "$PSScriptRoot/../Private/DFCatalog.PSGallery.ps1"
    . "$PSScriptRoot/../Private/DFCatalog.ps1"
    . "$PSScriptRoot/../Private/Start-DFCatalogRefreshJob.ps1"

    function New-FakeODataEntry {
        param($Id, $Downloads)
        # Mimics Invoke-RestMethod's XML projection: plain strings for
        # untyped elements, '#text'-wrapped objects for m:typed ones.
        [pscustomobject]@{
            properties = [pscustomobject]@{
                Id            = $Id
                Version       = '14.1.1'
                Authors       = 'BurntSushi'
                ProjectUrl    = 'https://github.com/BurntSushi/ripgrep'
                Tags          = 'search grep cli'
                ReleaseNotes  = 'Fixed things.'
                DownloadCount = [pscustomobject]@{ '#text' = "$Downloads" }
                Dependencies  = 'chocolatey-core.extension:1.3.3:|other:2.0:'
                DocsUrl       = 'https://example.org/docs'
            }
        }
    }
}

Describe 'ConvertFrom-DFCatalogODataDetailEntry' {
    It 'maps a full OData entry' {
        $d = ConvertFrom-DFCatalogODataDetailEntry -Source choco -Entry (New-FakeODataEntry -Id ripgrep -Downloads 998877) `
            -InstallHint 'choco install ripgrep'
        $d.Publisher | Should -Be 'BurntSushi'
        $d.Downloads | Should -Be 998877
        $d.Tags | Should -Be @('search', 'grep', 'cli')
        $d.Dependencies | Should -Be @('chocolatey-core.extension (1.3.3)', 'other (2.0)')
        $d.RepositoryUrl | Should -Be 'https://github.com/BurntSushi/ripgrep'
        $d.ReleaseNotes | Should -Be 'Fixed things.'
        $d.InstallHint | Should -Be 'choco install ripgrep'
    }
    It 'returns null for a null entry' {
        ConvertFrom-DFCatalogODataDetailEntry -Source choco -Entry $null -InstallHint 'x' | Should -BeNullOrEmpty
    }
}

Describe 'choco + psgallery detail hooks' {
    BeforeEach {
        $script:SavedXdgCache = $Env:XDG_CACHE_HOME
        $Env:XDG_CACHE_HOME = Join-Path $TestDrive 'cache'
    }
    AfterEach { $Env:XDG_CACHE_HOME = $script:SavedXdgCache }

    It 'choco: fetches FindPackagesById filtered to the latest version' {
        Mock Invoke-RestMethod { @(New-FakeODataEntry -Id ripgrep -Downloads 5) } -ParameterFilter {
            $Uri -like '*community.chocolatey.org*FindPackagesById*IsLatestVersion*'
        }
        $d = Get-DFCatalogChocoDetail -PackageId ripgrep -Fresh
        $d.Publisher | Should -Be 'BurntSushi'
        $d.InstallHint | Should -Be 'choco install ripgrep'
    }

    It 'psgallery: same shape, PSResource install hint' {
        Mock Invoke-RestMethod { @(New-FakeODataEntry -Id PSFzf -Downloads 7) } -ParameterFilter {
            $Uri -like '*powershellgallery.com*FindPackagesById*IsLatestVersion*'
        }
        $d = Get-DFCatalogPSGalleryDetail -PackageId PSFzf -Fresh
        $d.InstallHint | Should -Be 'Install-PSResource PSFzf'
    }

    It 'registers Detail hooks on both providers' {
        $script:DFCatalogProviders['choco'].Detail | Should -Not -BeNullOrEmpty
        $script:DFCatalogProviders['psgallery'].Detail | Should -Not -BeNullOrEmpty
    }
}
