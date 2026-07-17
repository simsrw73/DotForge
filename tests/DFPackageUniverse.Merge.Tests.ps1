BeforeAll {
    Set-StrictMode -Version Latest
    Import-Module PSSQLite
    . "$PSScriptRoot/../build/Private/DFPackageUniverse.Links.ps1"  # Get-DFPackageUniverseRepoKey
    . "$PSScriptRoot/../build/Private/DFPackageUniverse.Merge.ps1"
}

Describe 'DFPackageUniverse.Merge' {
    Context 'ConvertFrom-DFDbNull' {
        It 'maps DBNull to null and passes other values through' {
            ConvertFrom-DFDbNull ([DBNull]::Value) | Should -BeNullOrEmpty
            ConvertFrom-DFDbNull 'hello' | Should -Be 'hello'
        }
    }

    Context 'ConvertTo-DFNormalizedLicense' {
        It 'folds MIT and MIT License to the same identifier' {
            (ConvertTo-DFNormalizedLicense 'MIT') | Should -Be (ConvertTo-DFNormalizedLicense 'MIT License')
        }
        It 'treats a license URL as null (choco stores LicenseUrl, not an SPDX id)' {
            ConvertTo-DFNormalizedLicense 'https://github.com/x/y/blob/main/LICENSE' | Should -BeNullOrEmpty
        }
        It 'returns null for empty input' {
            ConvertTo-DFNormalizedLicense '' | Should -BeNullOrEmpty
        }
        It 'distinguishes genuinely different licenses' {
            (ConvertTo-DFNormalizedLicense 'Apache-2.0') | Should -Not -Be (ConvertTo-DFNormalizedLicense 'MIT')
        }
    }
}
