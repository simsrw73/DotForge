BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
}

Describe 'tool notes' {
    BeforeEach { Reset-DFTestSession; Clear-DFToolNote -Tool 'eza' }

    It 'returns notes in the order they were added, once each' {
        Add-DFToolNote -Tool 'eza' -Note 'first'
        Add-DFToolNote -Tool 'eza' -Note 'second'
        Add-DFToolNote -Tool 'eza' -Note 'first'
        Get-DFToolNote -Tool 'eza' | Should -Be @('first', 'second')
    }

    It 'starts each registration clean' {
        Add-DFToolNote -Tool 'eza' -Note 'old'
        Clear-DFToolNote -Tool 'eza'
        Get-DFToolNote -Tool 'eza' | Should -BeNullOrEmpty
    }

    It 'keeps tools apart' {
        Add-DFToolNote -Tool 'eza' -Note 'a'
        Get-DFToolNote -Tool 'lsd' | Should -BeNullOrEmpty
    }
}
