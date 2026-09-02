BeforeAll {
    . "$PSScriptRoot/../Private/Format-DFPreviewSummary.ps1"
}

Describe 'Format-DFPreviewSummary' {
    It 'renders only populated labels, in the given order, above a separator and the body' {
        $fields = [ordered]@{ Name = 'git'; Description = $null; Version = '2.55.0' }
        $result = Format-DFPreviewSummary -Fields $fields -Body @('raw line 1', 'raw line 2')
        $result[0] | Should -Be 'Name: git'
        $result[1] | Should -Be 'Version: 2.55.0'
        $result[2] | Should -Be ''
        $result[3] | Should -Match '^-+$'
        $result[4] | Should -Be ''
        $result[5] | Should -Be 'raw line 1'
        $result[6] | Should -Be 'raw line 2'
    }

    It 'skips empty-string values the same as $null' {
        $fields = [ordered]@{ Name = 'git'; Description = '' }
        $result = Format-DFPreviewSummary -Fields $fields -Body @('body')
        ($result -join "`n") | Should -Not -Match 'Description'
    }

    It 'falls back to the plain body when no field has a value' {
        $fields = [ordered]@{ Name = $null; Version = '' }
        $result = Format-DFPreviewSummary -Fields $fields -Body @('raw', 'output')
        $result | Should -Be @('raw', 'output')
    }

    It 'falls back to the (empty) body when the body itself is empty and nothing matched' {
        $fields = [ordered]@{ Name = $null }
        $result = Format-DFPreviewSummary -Fields $fields -Body @()
        $result | Should -BeNullOrEmpty
    }

    It 'does not throw when -Body contains a $null element, and preserves surrounding lines' {
        $fields = [ordered]@{ Name = $null }
        { $script:result = Format-DFPreviewSummary -Fields $fields -Body @('a', $null, 'b') } | Should -Not -Throw
        $script:result | Should -Be @('a', ' ', 'b')
    }

    It 'does not throw when -Body contains an empty-string element, and preserves surrounding lines' {
        $fields = [ordered]@{ Name = $null }
        { $script:result = Format-DFPreviewSummary -Fields $fields -Body @('a', '', 'b') } | Should -Not -Throw
        $script:result | Should -Be @('a', ' ', 'b')
    }

    It 'does not throw when -Body itself is $null, and treats it as an empty body' {
        $fields = [ordered]@{ Name = $null }
        { $script:result = Format-DFPreviewSummary -Fields $fields -Body $null } | Should -Not -Throw
        $script:result | Should -BeNullOrEmpty
    }
}
