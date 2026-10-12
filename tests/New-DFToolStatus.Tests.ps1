BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
}

Describe 'New-DFToolStatus' {
    It 'joins detail lines with "; "' {
        (New-DFToolStatus -Name a -State Missing -Detail 'one', 'two').Detail | Should -Be 'one; two'
    }
    It 'has an empty Detail when given none' {
        (New-DFToolStatus -Name a -State Active).Detail | Should -Be ''
    }
    It 'skips empty lines' {
        (New-DFToolStatus -Name a -State Missing -Detail '', 'two').Detail | Should -Be 'two'
    }
    It 'appends a line with Add-DFToolStatusDetail' {
        $status = New-DFToolStatus -Name a -State Missing -Detail 'one'
        Add-DFToolStatusDetail -Status $status -Text 'more'
        $status.Detail | Should -Be 'one; more'
    }
    It 'shows Detail, not DetailItems, by default' {
        $status = New-DFToolStatus -Name a -State Active
        $status.PSStandardMembers.DefaultDisplayPropertySet.ReferencedPropertyNames |
            Should -Be @('Name', 'State', 'RequestedBy', 'Roles', 'Detail')
    }
}
