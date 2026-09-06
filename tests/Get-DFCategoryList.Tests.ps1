BeforeAll {
    . "$PSScriptRoot/../Private/Test-DFCategoryDbSchema.ps1"
    . "$PSScriptRoot/../Private/Get-DFCategoryDb.ps1"
    . "$PSScriptRoot/../Private/Format-DFCategoryList.ps1"
    . "$PSScriptRoot/../Public/Get-DFCategoryList.ps1"
    $script:RealGetDFCategoryDb = Get-Command Get-DFCategoryDb -CommandType Function -ErrorAction SilentlyContinue
}

Describe 'Get-DFCategoryList' {
    BeforeEach {
        $script:FixturePath = Join-Path $TestDrive 'tool-categories.json'
        @{
            schemaVersion = 1; updated = '2026-07-01'
            taxonomy = @{ function = @('editor', 'search'); worksWith = @('text') }
            tools = @{ micro = @{ function = @('editor'); worksWith = @('text'); interface = 'cli' } }
        } | ConvertTo-Json -Depth 6 | Set-Content $script:FixturePath

        # Get-DFCategoryDb's refreshed-vs-shipped comparison runs unconditionally
        # even when -Path overrides the "shipped" side, so a real ambient
        # $Env:XDG_DATA_HOME/dotforge/tool-categories.json (from actual DotForge
        # usage on the dev machine) can silently outrank this fixture -- isolate
        # it so the mock below always exercises the fixture, not real-world state.
        $script:SavedDataHome = $Env:XDG_DATA_HOME
        $Env:XDG_DATA_HOME = Join-Path $TestDrive 'xdg-data-home'

        Mock Get-DFCategoryDb -MockWith {
            & $script:RealGetDFCategoryDb -Path $script:FixturePath
        }
    }
    AfterEach {
        $Env:XDG_DATA_HOME = $script:SavedDataHome
    }

    It 'defaults to both facets with counts' {
        $out = (Get-DFCategoryList) -join "`n"
        $out | Should -Match 'editor \(1\)'
    }

    It 'honors -Facet' {
        $out = (Get-DFCategoryList -Facet worksWith) -join "`n"
        $out | Should -Match 'text'
        $out | Should -Not -Match 'Function'
    }

    It 'honors -Counts:$false' {
        $out = (Get-DFCategoryList -Counts:$false) -join "`n"
        $out | Should -Not -Match '\('
    }

    It 'is aliased to tcats' {
        Get-Alias tcats -ErrorAction Ignore | Should -Not -BeNullOrEmpty
    }

    It 'always emits strings, never objects' {
        (Get-DFCategoryList) | ForEach-Object { $_ | Should -BeOfType [string] }
    }
}
