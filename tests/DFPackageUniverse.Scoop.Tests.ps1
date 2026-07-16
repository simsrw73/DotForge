BeforeAll {
    . "$PSScriptRoot/../build/Private/DFPackageUniverse.Scoop.ps1"
}

Describe 'DFPackageUniverse.Scoop' {
    Context 'ConvertTo-DFPackageUniverseScoopRow' {
        It 'maps a manifest entry to a raw_packages row' {
            $entry = [pscustomobject]@{
                name        = 'ripgrep'
                bucket      = 'main'
                version     = '14.1.1'
                description = 'Recursively search directories for a regex pattern'
                homepage    = 'https://github.com/BurntSushi/ripgrep'
                license     = 'MIT'
            }

            $row = ConvertTo-DFPackageUniverseScoopRow -Entry $entry

            $row.source | Should -Be 'scoop'
            $row.package_id | Should -Be 'main/ripgrep'
            $row.name | Should -Be 'ripgrep'
            $row.version | Should -Be '14.1.1'
            $row.description | Should -Be 'Recursively search directories for a regex pattern'
            $row.homepage | Should -Be 'https://github.com/BurntSushi/ripgrep'
            $row.license | Should -Be 'MIT'
            $row.publisher | Should -BeNullOrEmpty
            $row.tags | Should -BeNullOrEmpty
            $row.extra | Should -BeNullOrEmpty
            $row.fetched_at | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Get-DFPackageUniverseScoopRows' {
        BeforeEach {
            $script:logged = @()
        }

        It 'converts every fetched item to a row' {
            $items = @(
                [pscustomobject]@{ name = 'ripgrep'; bucket = 'main'; version = '14.1.1'; description = 'd1'; homepage = 'h1'; license = 'MIT' }
                [pscustomobject]@{ name = 'fd'; bucket = 'main'; version = '10.2.0'; description = 'd2'; homepage = 'h2'; license = 'MIT' }
            )
            $fetchItems = { param($ScoopRoot) $items }.GetNewClosure()
            $log = { param($Level, $PackageId, $Message) $script:logged += , @($Level, $PackageId, $Message) }

            $rows = @(Get-DFPackageUniverseScoopRows -ScoopRoot 'C:\fake\scoop' -FetchItems $fetchItems -Log $log)

            $rows.Count | Should -Be 2
            $rows.package_id | Should -Contain 'main/ripgrep'
            $rows.package_id | Should -Contain 'main/fd'
            $script:logged.Count | Should -Be 0
        }

        It 'logs an error and returns no rows when FetchItems returns nothing' {
            $fetchItems = { param($ScoopRoot) @() }
            $log = { param($Level, $PackageId, $Message) $script:logged += , @($Level, $PackageId, $Message) }

            $rows = @(Get-DFPackageUniverseScoopRows -ScoopRoot 'C:\fake\scoop' -FetchItems $fetchItems -Log $log)

            $rows.Count | Should -Be 0
            $script:logged.Count | Should -Be 1
            $script:logged[0][0] | Should -Be 'error'
        }

        It 'logs a warning and skips an entry that fails conversion, without aborting the rest' {
            Mock ConvertTo-DFPackageUniverseScoopRow {
                param($Entry)
                if ($Entry.name -eq 'broken') { throw 'boom' }
                [pscustomobject]@{
                    source = 'scoop'; package_id = "$($Entry.bucket)/$($Entry.name)"
                    name = $Entry.name; version = $Entry.version; description = $Entry.description
                    homepage = $Entry.homepage; license = $Entry.license
                    publisher = $null; tags = $null; extra = $null; fetched_at = [datetime]::UtcNow.ToString('o')
                }
            }
            $badEntry = [pscustomobject]@{ bucket = 'main'; name = 'broken' }
            $goodEntry = [pscustomobject]@{ name = 'fd'; bucket = 'main'; version = '10.2.0'; description = 'd'; homepage = 'h'; license = 'MIT' }
            $fetchItems = { param($ScoopRoot) @($badEntry, $goodEntry) }.GetNewClosure()
            $log = { param($Level, $PackageId, $Message) $script:logged += , @($Level, $PackageId, $Message) }

            $rows = @(Get-DFPackageUniverseScoopRows -ScoopRoot 'C:\fake\scoop' -FetchItems $fetchItems -Log $log)

            $rows.Count | Should -Be 1
            $rows[0].package_id | Should -Be 'main/fd'
            $script:logged.Count | Should -Be 1
            $script:logged[0][0] | Should -Be 'warning'
            $script:logged[0][1] | Should -Be 'main/broken'
        }
    }
}
