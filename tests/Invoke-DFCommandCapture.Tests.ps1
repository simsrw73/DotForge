BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
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
        $r.PSObject.Properties.Name | Should -Contain 'TimedOut'
        $r.TimedOut | Should -BeFalse
    }

    It 'returns a timeout result for an executable that exceeds its time limit' {
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-DFCommandCapture -Name 'pwsh' -Arguments @('-NoProfile', '-Command', 'Start-Sleep 60') -TimeoutSeconds 1

        $r.TimedOut | Should -BeTrue
        $r.ExitCode | Should -Be -1
        $r.Text | Should -Be ''
        $clock.Elapsed.TotalSeconds | Should -BeLessThan 20
    }

    It 'continues to capture non-executable commands without a timeout' {
        function Test-DFCaptureFunction { param($Value) "function $Value" }

        $r = Invoke-DFCommandCapture -Name 'Test-DFCaptureFunction' -Arguments @('works')

        $r.Text | Should -Be 'function works'
        $r.TimedOut | Should -BeFalse
    }

    It 'reports an executable that fails to run as an error, not a timeout' {
        Mock Invoke-DFBoundedProcess { throw 'the program could not start' }

        { Invoke-DFCommandCapture -Name 'pwsh' -Arguments @('-NoProfile') } | Should -Throw '*could not start*'
    }
}
