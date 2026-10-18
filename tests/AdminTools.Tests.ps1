BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    $script:Tools = Join-Path $PSScriptRoot '..' 'Tools'
}

Describe 'admin categories' {
    It 'defines process-viewer and disk-usage as categories, with no hook or aliases' {
        $db = Get-DFRoleDb
        foreach ($name in 'process-viewer', 'disk-usage') {
            $db[$name].kind | Should -Be 'category'
            $db[$name].PSObject.Properties['hook'] | Should -BeNullOrEmpty
            $db[$name].description | Should -Not -BeNullOrEmpty
        }
    }
}
