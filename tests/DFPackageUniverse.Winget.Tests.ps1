BeforeAll {
    Import-Module powershell-yaml
    . "$PSScriptRoot/../build/Private/DFPackageUniverse.Winget.ps1"

    # Real content pulled from microsoft/winget-pkgs via `gh api` against
    # manifests/m/Microsoft/VisualStudioCode/1.105.0/ (2026-07-14), used
    # instead of a hand-guessed fixture per the design-spec correction: every
    # locale file (including the default) carries a BCP-47 tag.
    $script:VersionManifestYaml = @'
PackageIdentifier: Microsoft.VisualStudioCode
PackageVersion: 1.105.0
DefaultLocale: en-US
ManifestType: version
ManifestVersion: 1.10.0
'@

    $script:DefaultLocaleManifestYaml = @'
PackageIdentifier: Microsoft.VisualStudioCode
PackageVersion: 1.105.0
PackageLocale: en-US
Publisher: Microsoft Corporation
PublisherUrl: https://www.microsoft.com/
PrivacyUrl: https://privacy.microsoft.com/
PackageName: Microsoft Visual Studio Code
PackageUrl: https://code.visualstudio.com
License: Microsoft Software License
LicenseUrl: https://code.visualstudio.com/license
ShortDescription: Microsoft Visual Studio Code is a code editor redefined and optimized for building and debugging modern web and cloud applications. Microsoft Visual Studio Code is free and available on your favorite platform - Linux, macOS, and Windows.
Moniker: vscode
Tags:
- developer-tools
- editor
ManifestType: defaultLocale
ManifestVersion: 1.10.0
'@

    $script:InstallerManifestYaml = @'
PackageIdentifier: Microsoft.VisualStudioCode
PackageVersion: 1.105.0
ManifestType: installer
ManifestVersion: 1.10.0
'@

    # Built from the (deprecated) singleton schema doc
    # (doc/manifest/schema/1.5.0/singleton.md) — no live example was found
    # via GitHub code search, so this fixture is schema-derived rather than
    # pulled from a real manifest. Note singleton's field list has no
    # PackageUrl equivalent, so homepage is expected to come back empty.
    $script:SingletonManifestYaml = @'
PackageIdentifier: Foo.Bar
PackageVersion: 1.0.0
PackageLocale: en-US
Publisher: Foo Inc
PackageName: Bar Tool
License: MIT
ShortDescription: A small tool that does bar things.
Tags:
- cli
- utility
ManifestType: singleton
ManifestVersion: 1.5.0
'@

    # A MINIMAL real-world defaultLocale manifest: Tags, PackageUrl and
    # Description are all optional in the winget schema, and a large minority of
    # the live catalog omits them. Mirrors the real
    # manifests/0/0state/scafld/2.5.0 -- the first package that broke when the
    # build script went strict on 2026-07-15, taking 4,734 of 13,763 packages
    # (~34%) with it. The two fixtures above BOTH declare Tags, which is exactly
    # why the unit tests stayed green through that regression.
    $script:MinimalLocaleManifestYaml = @'
PackageIdentifier: 0state.scafld
PackageVersion: 2.5.0
PackageLocale: en-US
Publisher: 0state
PublisherUrl: https://github.com/0state
PackageName: scafld
License: MIT
ShortDescription: Project scaffolding tool.
ManifestType: defaultLocale
ManifestVersion: 1.10.0
'@

    function New-WingetVersionFolder {
        param([string]$Dir, [string]$PackageId, [hashtable]$Files)
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        foreach ($name in $Files.Keys) {
            Set-Content -Path (Join-Path $Dir $name) -Value $Files[$name] -Encoding UTF8
        }
    }
}

Describe 'DFPackageUniverse.Winget' {
    Context 'ConvertFrom-DFPackageUniverseWingetLocaleYaml' {
        It 'maps a real defaultLocale manifest' {
            $fields = ConvertFrom-DFPackageUniverseWingetLocaleYaml -YamlText $script:DefaultLocaleManifestYaml
            $fields.name | Should -Be 'Microsoft Visual Studio Code'
            $fields.publisher | Should -Be 'Microsoft Corporation'
            $fields.description | Should -Match 'code editor redefined'
            $fields.homepage | Should -Be 'https://code.visualstudio.com'
            $fields.license | Should -Be 'Microsoft Software License'
            (ConvertFrom-Json $fields.tags) | Should -Be @('developer-tools', 'editor')
        }

        It 'maps a singleton manifest, leaving homepage empty (no PackageUrl field in that schema)' {
            $fields = ConvertFrom-DFPackageUniverseWingetLocaleYaml -YamlText $script:SingletonManifestYaml
            $fields.name | Should -Be 'Bar Tool'
            $fields.publisher | Should -Be 'Foo Inc'
            $fields.description | Should -Be 'A small tool that does bar things.'
            $fields.homepage | Should -BeNullOrEmpty
            $fields.license | Should -Be 'MIT'
            (ConvertFrom-Json $fields.tags) | Should -Be @('cli', 'utility')
        }

        It 'maps a manifest omitting the optional Tags/PackageUrl fields UNDER STRICT MODE' {
            # Set-StrictMode here on purpose: Build-DFPackageUniverseRaw.ps1 runs
            # Set-StrictMode -Version Latest, and StrictMode is dynamically
            # scoped, so this mapper executes strict in production but non-strict
            # under a default Pester run. That gap let a 4,734-package data loss
            # pass a fully green suite on 2026-07-15: $content.Tags throws on a
            # manifest with no Tags, and the caller logged a warning and skipped
            # the package. Absent optional fields must map to empty, not throw.
            Set-StrictMode -Version Latest

            $fields = ConvertFrom-DFPackageUniverseWingetLocaleYaml -YamlText $script:MinimalLocaleManifestYaml

            $fields.name | Should -Be 'scafld'
            $fields.publisher | Should -Be '0state'
            $fields.description | Should -Be 'Project scaffolding tool.'
            $fields.license | Should -Be 'MIT'
            $fields.tags | Should -BeNullOrEmpty
            $fields.homepage | Should -BeNullOrEmpty
        }

        It 'captures the full manifest into extra, including fields Phase A dropped (PublisherUrl, Moniker, PrivacyUrl, LicenseUrl)' {
            $fields = ConvertFrom-DFPackageUniverseWingetLocaleYaml -YamlText $script:DefaultLocaleManifestYaml
            $extra = $fields.extra | ConvertFrom-Json

            $extra.PublisherUrl | Should -Be 'https://www.microsoft.com/'
            $extra.PrivacyUrl   | Should -Be 'https://privacy.microsoft.com/'
            $extra.Moniker      | Should -Be 'vscode'
            $extra.LicenseUrl   | Should -Be 'https://code.visualstudio.com/license'
            $extra.PackageUrl   | Should -Be 'https://code.visualstudio.com'
        }

        It 'captures only present fields into extra for a minimal manifest, under strict mode' {
            Set-StrictMode -Version Latest
            $fields = ConvertFrom-DFPackageUniverseWingetLocaleYaml -YamlText $script:MinimalLocaleManifestYaml
            $extra = $fields.extra | ConvertFrom-Json

            $extra.PublisherUrl | Should -Be 'https://github.com/0state'
            $extra.PSObject.Properties.Name | Should -Not -Contain 'Moniker'
            $extra.PSObject.Properties.Name | Should -Not -Contain 'PackageUrl'
        }

        It 'resolves a full version folder whose locale manifest omits Tags, under strict mode' {
            Set-StrictMode -Version Latest
            $dir = Join-Path $TestDrive 'strict/0state.scafld/2.5.0'
            New-WingetVersionFolder -Dir $dir -Files @{
                '0state.scafld.yaml'               = @'
PackageIdentifier: 0state.scafld
PackageVersion: 2.5.0
DefaultLocale: en-US
ManifestType: version
ManifestVersion: 1.10.0
'@
                '0state.scafld.locale.en-US.yaml' = $script:MinimalLocaleManifestYaml
            }

            $row = Resolve-DFPackageUniverseWingetVersionRow -VersionDir $dir -Log { param($l, $p, $m) }
            $row | Should -Not -BeNullOrEmpty
            $row.package_id | Should -Be '0state.scafld'
            $row.version | Should -Be '2.5.0'
            $row.tags | Should -BeNullOrEmpty
            ($row.extra | ConvertFrom-Json).PublisherUrl | Should -Be 'https://github.com/0state'
        }
    }

    Context 'Select-DFPackageUniverseWingetLatestVersion' {
        It 'picks the highest semver-parseable version' {
            $folders = 'C:\pkgs\1.2.0', 'C:\pkgs\1.10.0', 'C:\pkgs\1.9.0'
            Select-DFPackageUniverseWingetLatestVersion -VersionFolders $folders | Should -Be 'C:\pkgs\1.10.0'
        }

        It 'falls back to ordinal string comparison for non-parseable names' {
            $folders = 'C:\pkgs\2023a', 'C:\pkgs\2023b'
            Select-DFPackageUniverseWingetLatestVersion -VersionFolders $folders | Should -Be 'C:\pkgs\2023b'
        }

        It 'returns the only folder when there is exactly one' {
            Select-DFPackageUniverseWingetLatestVersion -VersionFolders @('C:\pkgs\1.0.0') | Should -Be 'C:\pkgs\1.0.0'
        }
    }

    Context 'Get-DFPackageUniverseWingetPackageDirectories' {
        BeforeEach {
            $script:SnapshotRoot = Join-Path $TestDrive 'winget-pkgs'
        }
        AfterEach {
            Remove-Item $script:SnapshotRoot -Recurse -Force -ErrorAction Ignore
        }

        It 'finds a 2-segment package (Publisher/Package)' {
            $dir = Join-Path $script:SnapshotRoot 'manifests/m/Microsoft/VisualStudioCode/1.105.0'
            New-WingetVersionFolder -Dir $dir -PackageId 'Microsoft.VisualStudioCode' -Files @{
                'Microsoft.VisualStudioCode.yaml' = $script:VersionManifestYaml
            }

            $dirs = @(Get-DFPackageUniverseWingetPackageDirectories -SnapshotRoot $script:SnapshotRoot)
            $dirs.Count | Should -Be 1
            $dirs[0].VersionFolders.Count | Should -Be 1
            $dirs[0].VersionFolders[0] | Should -Be $dir
        }

        It 'finds a deeper dotted-identifier package (Publisher/Package/Sub/Sub)' {
            $dir = Join-Path $script:SnapshotRoot 'manifests/m/Microsoft/VisualStudio/2022/Community/17.8.0'
            New-WingetVersionFolder -Dir $dir -PackageId 'Microsoft.VisualStudio.2022.Community' -Files @{
                'Microsoft.VisualStudio.2022.Community.yaml' = $script:VersionManifestYaml
            }

            $dirs = @(Get-DFPackageUniverseWingetPackageDirectories -SnapshotRoot $script:SnapshotRoot)
            $dirs.Count | Should -Be 1
            $dirs[0].Path | Should -Be (Split-Path $dir -Parent)
        }

        It 'finds multiple version folders under the same package' {
            $pkgRoot = Join-Path $script:SnapshotRoot 'manifests/m/Microsoft/VisualStudioCode'
            New-WingetVersionFolder -Dir (Join-Path $pkgRoot '1.104.0') -PackageId 'x' -Files @{ 'x.yaml' = $script:VersionManifestYaml }
            New-WingetVersionFolder -Dir (Join-Path $pkgRoot '1.105.0') -PackageId 'x' -Files @{ 'x.yaml' = $script:VersionManifestYaml }

            $dirs = @(Get-DFPackageUniverseWingetPackageDirectories -SnapshotRoot $script:SnapshotRoot)
            $dirs.Count | Should -Be 1
            $dirs[0].VersionFolders.Count | Should -Be 2
        }
    }

    Context 'Resolve-DFPackageUniverseWingetVersionRow' {
        BeforeEach {
            $script:VersionDir = Join-Path $TestDrive 'version-dir'
            $script:logged = @()
            $script:log = { param($Level, $PackageId, $Message) $script:logged += , @($Level, $PackageId, $Message) }
        }
        AfterEach {
            Remove-Item $script:VersionDir -Recurse -Force -ErrorAction Ignore
        }

        It 'resolves a multi-file manifest via its tagged default-locale file' {
            New-WingetVersionFolder -Dir $script:VersionDir -PackageId 'Microsoft.VisualStudioCode' -Files @{
                'Microsoft.VisualStudioCode.yaml'           = $script:VersionManifestYaml
                'Microsoft.VisualStudioCode.installer.yaml' = $script:InstallerManifestYaml
                'Microsoft.VisualStudioCode.locale.en-US.yaml' = $script:DefaultLocaleManifestYaml
            }

            $row = Resolve-DFPackageUniverseWingetVersionRow -VersionDir $script:VersionDir -Log $script:log

            $row.source | Should -Be 'winget'
            $row.package_id | Should -Be 'Microsoft.VisualStudioCode'
            $row.version | Should -Be '1.105.0'
            $row.name | Should -Be 'Microsoft Visual Studio Code'
            $row.homepage | Should -Be 'https://code.visualstudio.com'
            $script:logged.Count | Should -Be 0
        }

        It 'resolves a singleton manifest directly' {
            New-WingetVersionFolder -Dir $script:VersionDir -PackageId 'Foo.Bar' -Files @{
                'Foo.Bar.yaml' = $script:SingletonManifestYaml
            }

            $row = Resolve-DFPackageUniverseWingetVersionRow -VersionDir $script:VersionDir -Log $script:log

            $row.source | Should -Be 'winget'
            $row.package_id | Should -Be 'Foo.Bar'
            $row.version | Should -Be '1.0.0'
            $row.name | Should -Be 'Bar Tool'
            $script:logged.Count | Should -Be 0
        }

        It 'logs a review row and returns $null when the default-locale file is missing' {
            New-WingetVersionFolder -Dir $script:VersionDir -PackageId 'Microsoft.VisualStudioCode' -Files @{
                'Microsoft.VisualStudioCode.yaml'           = $script:VersionManifestYaml
                'Microsoft.VisualStudioCode.installer.yaml' = $script:InstallerManifestYaml
            }

            $row = Resolve-DFPackageUniverseWingetVersionRow -VersionDir $script:VersionDir -Log $script:log

            $row | Should -BeNullOrEmpty
            $script:logged.Count | Should -Be 1
            $script:logged[0][0] | Should -Be 'review'
        }

        It 'logs a review row and returns $null when there is no root manifest at all' {
            New-WingetVersionFolder -Dir $script:VersionDir -PackageId 'x' -Files @{
                'x.installer.yaml' = $script:InstallerManifestYaml
            }

            $row = Resolve-DFPackageUniverseWingetVersionRow -VersionDir $script:VersionDir -Log $script:log

            $row | Should -BeNullOrEmpty
            $script:logged.Count | Should -Be 1
            $script:logged[0][0] | Should -Be 'review'
        }
    }

    Context 'Get-DFPackageUniverseWingetRows' {
        BeforeEach {
            $script:SnapshotRoot = Join-Path $TestDrive 'winget-pkgs-rows'
            $script:logged = @()
            $script:log = { param($Level, $PackageId, $Message) $script:logged += , @($Level, $PackageId, $Message) }
            $script:neverFetch = { throw 'FetchSnapshot should not be invoked when -WingetPkgsSnapshot is supplied' }
        }
        AfterEach {
            Remove-Item $script:SnapshotRoot -Recurse -Force -ErrorAction Ignore
        }

        It 'never invokes FetchSnapshot when a snapshot path is supplied' {
            $dir = Join-Path $script:SnapshotRoot 'manifests/m/Microsoft/VisualStudioCode/1.105.0'
            New-WingetVersionFolder -Dir $dir -PackageId 'Microsoft.VisualStudioCode' -Files @{
                'Microsoft.VisualStudioCode.yaml' = $script:VersionManifestYaml
                'Microsoft.VisualStudioCode.locale.en-US.yaml' = $script:DefaultLocaleManifestYaml
            }

            $rows = @(Get-DFPackageUniverseWingetRows -WingetPkgsSnapshot $script:SnapshotRoot -FetchSnapshot $script:neverFetch -Log $script:log)

            $rows.Count | Should -Be 1
            $rows[0].package_id | Should -Be 'Microsoft.VisualStudioCode'
        }

        It 'logs an error and returns no rows when the snapshot path does not exist' {
            $rows = @(Get-DFPackageUniverseWingetRows -WingetPkgsSnapshot (Join-Path $TestDrive 'does-not-exist') -FetchSnapshot $script:neverFetch -Log $script:log)

            $rows.Count | Should -Be 0
            $script:logged.Count | Should -Be 1
            $script:logged[0][0] | Should -Be 'error'
        }
    }
}
