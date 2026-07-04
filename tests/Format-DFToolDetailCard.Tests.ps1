BeforeAll {
    . "$PSScriptRoot/../Private/DFCatalog.ps1"
    . "$PSScriptRoot/../Private/Format-DFToolInfo.ps1"

    function New-TestInfo {
        param($Details, $GitHub)
        $src = New-DFToolSourceInfo -Source scoop -PackageId 'extras/zed' -Name zed `
            -Description 'code editor' -LatestVersion '0.191.6' -MatchKind exact-name
        New-DFToolInfo -Name zed -Description 'code editor' -Sources @($src) `
            -Latest ([ordered]@{ scoop = '0.191.6' }) -Homepage 'https://zed.dev' `
            -License 'GPL-3.0' -MatchKind exact-name -Details $Details -GitHub $GitHub
    }
}

Describe 'Format-DFToolDetailCount' {
    It 'formats plain, k, and M counts' {
        Format-DFToolDetailCount -Count 998      | Should -Be '998'
        Format-DFToolDetailCount -Count 12345    | Should -Be '12.3k'
        Format-DFToolDetailCount -Count 1234567  | Should -Be '1.2M'
    }

    It 'handles k/M bucket boundaries correctly' {
        Format-DFToolDetailCount -Count 999      | Should -Be '999'
        Format-DFToolDetailCount -Count 1000     | Should -Be '1k'
        Format-DFToolDetailCount -Count 999949   | Should -Be '999.9k'
        Format-DFToolDetailCount -Count 999999   | Should -Be '1M'
    }
}

Describe 'Format-DFToolDetailCard' {
    It 'renders detail sections from populated Details' {
        $details = [ordered]@{
            scoop = New-DFToolSourceDetail -Source scoop -PackageId 'extras/zed' `
                -Dependencies @('extras/vcredist2022') -InstallHint 'scoop install extras/zed' `
                -Notes 'Run zed once to install CLI.'
            crates = New-DFToolSourceDetail -Source crates -PackageId zed `
                -Publisher 'Zed Industries' -Tags @('editor', 'rust') -Downloads 1234567 `
                -InstallHint 'cargo install zed'
        }
        $out = (Format-DFToolDetailCard -Info (New-TestInfo -Details $details) -Color $false) -join "`n"
        $out | Should -Match 'Publisher\s+Zed Industries'
        $out | Should -Match 'Deps\s+scoop: extras/vcredist2022'
        $out | Should -Match 'Tags\s+editor . rust'
        $out | Should -Match 'Downloads\s+crates 1\.2M'
        $out | Should -Match 'Install\s+scoop install extras/zed'
        $out | Should -Match 'cargo install zed'
        $out | Should -Match 'Notes\s+Run zed once'
    }

    It 'marks sources whose detail fetch failed (null Details value)' {
        $details = [ordered]@{ choco = $null }
        $out = (Format-DFToolDetailCard -Info (New-TestInfo -Details $details) -Color $false) -join "`n"
        $out | Should -Match 'details unavailable: choco'
    }

    It 'renders the GitHub section' {
        $gh = [pscustomobject]@{
            PSTypeName = 'DotForge.RepoInfo'; Owner = 'zed-industries'; Repo = 'zed'
            Stars = 55123; OpenIssues = 1400; PushedAt = [datetime]'2026-07-01'
            LatestRelease = 'v0.192.0'; LatestReleaseAt = [datetime]'2026-06-28'
            Archived = $false; DefaultBranch = 'main'; Description = 'Code at the speed of thought'; License = 'GPL-3.0'
        }
        $out = (Format-DFToolDetailCard -Info (New-TestInfo -GitHub $gh) -Color $false) -join "`n"
        $out | Should -Match 'GitHub\s+. 55\.1k'
        $out | Should -Match 'release v0\.192\.0 \(2026-06-28\)'
        $out | Should -Match 'Code at the speed of thought'
    }

    It 'appends the more-matches footer' {
        $out = (Format-DFToolDetailCard -Info (New-TestInfo) -Color $false -MoreMatches 7 -QueryText zed) -join "`n"
        $out | Should -Match '\+ 7 more matches .* trifle zed -All'
    }

    It 'omits every detail section when Details and GitHub are empty' {
        $out = (Format-DFToolDetailCard -Info (New-TestInfo) -Color $false) -join "`n"
        $out | Should -Not -Match 'Publisher'
        $out | Should -Not -Match '(?m)^Install\s'
        $out | Should -Not -Match 'GitHub'
    }
}

Describe 'Format-DFToolInfoTable Id column' {
    It 'shows source:packageId per row' {
        $src = New-DFToolSourceInfo -Source winget -PackageId 'Zed.Zed' -Name Zed -MatchKind exact-id
        $info = New-DFToolInfo -Name Zed -Sources @($src) -MatchKind exact-id
        $rows = Format-DFToolInfoTable -Infos @($info) -Color $false -Width 200
        $rows[0] | Should -Match 'Id'
        $rows[1] | Should -Match 'winget:Zed\.Zed'
    }
}
