BeforeAll {
    . "$PSScriptRoot/../Private/Invoke-DFCommandCapture.ps1"
}

Describe 'Invoke-DFCommandCapture' {
    It 'captures stdout text and a zero exit code' {
        $r = Invoke-DFCommandCapture -Name 'pwsh' -Arguments @('-NoProfile', '-Command', 'Write-Output dotforge-capture-test')
        $r.Text     | Should -Match 'dotforge-capture-test'
        $r.ExitCode | Should -Be 0
    }

    It 'reports a non-zero exit code' {
        $r = Invoke-DFCommandCapture -Name 'pwsh' -Arguments @('-NoProfile', '-Command', 'exit 3')
        $r.ExitCode | Should -Be 3
    }

    It 'preserves original line breaks (no console-width rewrapping)' {
        $r = Invoke-DFCommandCapture -Name 'pwsh' -Arguments @('-NoProfile', '-Command', 'Write-Output one; Write-Output two')
        ($r.Text -split "`r?`n").Count | Should -BeGreaterOrEqual 2
    }

    It 'returns an object with Text and ExitCode properties' {
        $r = Invoke-DFCommandCapture -Name 'pwsh' -Arguments @('-NoProfile', '-Command', 'Write-Output x')
        $r.PSObject.Properties.Name | Should -Contain 'Text'
        $r.PSObject.Properties.Name | Should -Contain 'ExitCode'
    }
}
