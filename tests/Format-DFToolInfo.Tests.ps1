BeforeAll {
    . "$PSScriptRoot/../Private/DFCatalog.ps1"
    . "$PSScriptRoot/../Private/Format-DFToolInfo.ps1"

    function New-TestToolInfo {
        $scoop = New-DFToolSourceInfo -Source 'scoop' -PackageId 'main/ripgrep' -Name 'ripgrep' `
            -Description 'Recursively search directories' -LatestVersion '14.1.1' `
            -Homepage 'https://github.com/BurntSushi/ripgrep' -License 'MIT' `
            -Installed -InstalledVersion '14.1.0' -MatchKind 'exact-name' -CacheAgeMinutes 180
        $choco = New-DFToolSourceInfo -Source 'choco' -PackageId 'ripgrep' -Name 'ripgrep' `
            -LatestVersion '14.1.0' -MatchKind 'exact-name' -CacheAgeMinutes 720

        $latest = [ordered]@{ scoop = '14.1.1'; choco = '14.1.0' }
        New-DFToolInfo -Name 'ripgrep' -Description 'Recursively search directories' `
            -Installed -InstalledVia @('scoop') -InstalledVersion '14.1.0' `
            -Sources @($scoop, $choco) -Latest $latest `
            -Homepage 'https://github.com/BurntSushi/ripgrep' -License 'MIT' `
            -MatchKind 'exact-name' -CacheAge 720
    }
}

Describe 'Format-DFToolInfoCard' {
    It 'renders name, description, install state, sources, and metadata without color' {
        $card = (Format-DFToolInfoCard -Info (New-TestToolInfo) -Color $false) -join "`n"
        $card | Should -Match 'ripgrep'
        $card | Should -Match 'Recursively search directories'
        $card | Should -Match 'Installed'
        $card | Should -Match 'scoop \(14\.1\.0\)'
        $card | Should -Match 'main/ripgrep'
        $card | Should -Match 'choco'
        $card | Should -Match 'https://github\.com/BurntSushi/ripgrep'
        $card | Should -Match 'MIT'
        $card | Should -Not -Match "`e\["
    }

    It 'shows per-source cache ages' {
        $card = (Format-DFToolInfoCard -Info (New-TestToolInfo) -Color $false) -join "`n"
        $card | Should -Match 'Cache'
        $card | Should -Match 'scoop 3h'
        $card | Should -Match 'choco 12h'
    }

    It 'adds ANSI sequences when Color is true' {
        $card = (Format-DFToolInfoCard -Info (New-TestToolInfo) -Color $true) -join "`n"
        $card | Should -Match "`e\["
    }

    It 'renders a not-installed marker' {
        $info = New-DFToolInfo -Name 'fd' -Sources @() -Description 'find alternative'
        $card = (Format-DFToolInfoCard -Info $info -Color $false) -join "`n"
        $card | Should -Match 'not installed'
    }
}

Describe 'Format-DFToolInfoTable' {
    It 'renders one row per tool with name, sources, and description' {
        $rows = Format-DFToolInfoTable -Infos @(New-TestToolInfo) -Color $false -Width 120
        $text = $rows -join "`n"
        $text | Should -Match 'ripgrep'
        $text | Should -Match 'scoop'
        $text | Should -Not -Match "`e\["
    }

    It 'truncates descriptions to the given width' {
        $info = New-DFToolInfo -Name 'x' -Sources @() -Description ('d' * 300)
        $rows = Format-DFToolInfoTable -Infos @($info) -Color $false -Width 80
        foreach ($row in $rows) { $row.Length | Should -BeLessOrEqual 80 }
    }
}
