BeforeAll {
    . "$PSScriptRoot/../Private/Invoke-DFCommandCapture.ps1"
}

Describe 'Invoke-DFCommandCapture' {
    It 'captures stdout text and a zero exit code' {
        $r = Invoke-DFCommandCapture -Name 'cmd.exe' -Arguments @('/c', 'echo', 'dotforge-capture-test')
        $r.Text     | Should -Match 'dotforge-capture-test'
        $r.ExitCode | Should -Be 0
    }

    It 'reports a non-zero exit code' {
        $r = Invoke-DFCommandCapture -Name 'cmd.exe' -Arguments @('/c', 'exit', '3')
        $r.ExitCode | Should -Be 3
    }

    It 'returns an object with Text and ExitCode properties' {
        $r = Invoke-DFCommandCapture -Name 'cmd.exe' -Arguments @('/c', 'echo', 'x')
        $r.PSObject.Properties.Name | Should -Contain 'Text'
        $r.PSObject.Properties.Name | Should -Contain 'ExitCode'
    }
}
