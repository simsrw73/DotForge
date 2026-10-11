BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    function script:Rec([string]$Json) { ConvertTo-DFToolRecord ($Json | ConvertFrom-Json) }
}

Describe 'Get-DFElevationMethod' {
    BeforeEach {
        Mock Test-DFElevated { $false }
        Mock Test-DFInteractiveHost { $true }
        Mock Test-DFWindowsSudoInline { $false }
        $script:Db = @{ gsudo = Rec '{ "name": "gsudo", "executable": "gsudo.exe", "roles": { "elevator": {} } }' }
        $script:None = { param($t) $false }
        $script:All = { param($t) $true }
    }
    It 'runs directly in an elevated shell' {
        Mock Test-DFElevated { $true }
        (Get-DFElevationMethod -ToolDb $script:Db -IsAvailable $script:All).Method | Should -Be 'Direct'
    }
    It 'uses an installed elevator' {
        $m = Get-DFElevationMethod -ToolDb $script:Db -IsAvailable $script:All
        $m.Method | Should -Be 'Elevator'
        $m.Executable | Should -Be 'gsudo.exe'
        $m.Detail | Should -Be 'through gsudo'
    }
    It 'counts an elevator installed earlier in the same plan' {
        (Get-DFElevationMethod -ToolDb $script:Db -IsAvailable $script:None -Planned gsudo).Method | Should -Be 'Elevator'
    }
    It 'uses Windows sudo when it is on in inline mode and there is no elevator' {
        Mock Test-DFWindowsSudoInline { $true }
        $m = Get-DFElevationMethod -ToolDb $script:Db -IsAvailable $script:None
        $m.Method | Should -Be 'WindowsSudo'
        $m.Executable | Should -Be 'sudo'
    }
    It 'falls back to a separate administrator window' {
        (Get-DFElevationMethod -ToolDb $script:Db -IsAvailable $script:None).Method | Should -Be 'RunAs'
    }
    It 'is Unavailable with no one to answer a prompt' {
        Mock Test-DFInteractiveHost { $false }
        Mock Test-DFWindowsSudoInline { $true }
        $m = Get-DFElevationMethod -ToolDb $script:Db -IsAvailable $script:None
        $m.Method | Should -Be 'Unavailable'
        $m.Detail | Should -Be 'no one to answer the admin prompt'
    }
}
