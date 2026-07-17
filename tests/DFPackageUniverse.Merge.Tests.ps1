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

    Context 'Resolve-DFPackageUniverseToolRecord' {
        BeforeAll {
            # Pester 5.8.0 does not carry a function defined directly in a
            # Context body (outside a hook) into Run-phase It scope; wrapping
            # in BeforeAll is the idiomatic fix. Body/behavior unchanged.
            function M {
                param($Source, $PackageId, $Name = $null, $Description = $null, $Homepage = $null, $License = $null, $Publisher = $null, $Extra = $null)
                [pscustomobject]@{
                    source = $Source; package_id = $PackageId; name = $Name; version = '1'
                    description = $Description; homepage = $Homepage; license = $License
                    publisher = $Publisher; tags = $null; extra = $Extra
                }
            }
        }

        It 'prefers the winget friendly name over choco and scoop' {
            $members = @(
                (M -Source 'scoop'  -PackageId 'main/bat' -Name 'bat')
                (M -Source 'winget' -PackageId 'sharkdp.bat' -Name 'bat')
                (M -Source 'choco'  -PackageId 'bat' -Name 'Bat')
            )
            $rec = Resolve-DFPackageUniverseToolRecord -Members $members
            $rec.Name | Should -Be 'bat'
            $rec.NameSource | Should -Be 'winget'
            $rec.SourceCount | Should -Be 3
        }

        It 'picks the richer winget description over a terse scoop one' {
            $members = @(
                (M -Source 'scoop'  -PackageId 'main/x' -Name 'x' -Description 'short')
                (M -Source 'winget' -PackageId 'A.X' -Name 'x' -Description 'A full description of what X does.')
            )
            $rec = Resolve-DFPackageUniverseToolRecord -Members $members
            $rec.Description | Should -Be 'A full description of what X does.'
            $rec.DescriptionSource | Should -Be 'winget'
        }

        It 'derives repo_url from choco ProjectSourceUrl' {
            $extra = ConvertTo-Json -Compress @{ ProjectSourceUrl = 'https://github.com/sharkdp/bat' }
            $members = @( (M -Source 'choco' -PackageId 'bat' -Name 'bat' -Extra $extra) )
            $rec = Resolve-DFPackageUniverseToolRecord -Members $members
            $rec.RepoUrl | Should -Be 'https://github.com/sharkdp/bat'
        }

        It 'flags a genuine license conflict but not MIT vs MIT License' {
            $conflict = Resolve-DFPackageUniverseToolRecord -Members @(
                (M -Source 'winget' -PackageId 'A.X' -Name 'x' -License 'MIT')
                (M -Source 'choco'  -PackageId 'x'   -Name 'x' -License 'Apache-2.0')
            )
            $conflict.NeedsReview | Should -BeTrue
            $conflict.ReviewReasons[0] | Should -Match 'license-conflict'

            $ok = Resolve-DFPackageUniverseToolRecord -Members @(
                (M -Source 'winget' -PackageId 'A.X' -Name 'x' -License 'MIT')
                (M -Source 'choco'  -PackageId 'x'   -Name 'x' -License 'MIT License')
            )
            $ok.NeedsReview | Should -BeFalse
        }

        It 'does not flag winget MIT against a choco license URL' {
            $rec = Resolve-DFPackageUniverseToolRecord -Members @(
                (M -Source 'winget' -PackageId 'A.X' -Name 'x' -License 'MIT')
                (M -Source 'choco'  -PackageId 'x'   -Name 'x' -License 'https://opensource.org/licenses/MIT')
            )
            $rec.NeedsReview | Should -BeFalse
        }

        It 'falls back to package_id when no member has a name (NOT NULL guard)' {
            $rec = Resolve-DFPackageUniverseToolRecord -Members @( (M -Source 'scoop' -PackageId 'main/thing') )
            $rec.Name | Should -Be 'main/thing'
        }
    }
}
