BeforeAll {
    . "$PSScriptRoot/../Private/Format-DFCategoryList.ps1"

    $script:Db = [pscustomobject]@{
        Raw = [pscustomobject]@{
            taxonomy = [pscustomobject]@{ function = @('editor', 'search'); worksWith = @('text') }
        }
        FacetIndex = @{
            'function:editor'  = @('micro')
            'function:search'  = @('ripgrep', 'fd')
            'worksWith:text'   = @('micro')
        }
    }
}

Describe 'Format-DFCategoryList' {
    It 'lists both facets with counts by default' {
        $out = (Format-DFCategoryList -Database $script:Db -Facet $null -Counts $true -Color $false) -join "`n"
        $out | Should -Match 'Function'
        $out | Should -Match 'editor \(1\)'
        $out | Should -Match 'search \(2\)'
        $out | Should -Match 'WorksWith'
        $out | Should -Match 'text \(1\)'
    }

    It 'narrows to one facet' {
        $out = (Format-DFCategoryList -Database $script:Db -Facet 'function' -Counts $true -Color $false) -join "`n"
        $out | Should -Match 'Function'
        $out | Should -Not -Match 'WorksWith'
    }

    It 'omits counts when -Counts is false' {
        $out = (Format-DFCategoryList -Database $script:Db -Facet 'function' -Counts $false -Color $false) -join "`n"
        $out | Should -Match 'editor'
        $out | Should -Not -Match '\('
    }

    It 'sorts values alphabetically' {
        $lines = Format-DFCategoryList -Database $script:Db -Facet 'function' -Counts $false -Color $false
        ($lines | Where-Object { $_ -match 'editor|search' }) | Should -Be @('  editor', '  search')
    }

    It 'renders a friendly message when the db is unavailable' {
        $emptyDb = [pscustomobject]@{ Raw = $null; FacetIndex = @{} }
        $out = (Format-DFCategoryList -Database $emptyDb -Facet $null -Counts $true -Color $false) -join "`n"
        $out | Should -Match 'unavailable'
    }
}
