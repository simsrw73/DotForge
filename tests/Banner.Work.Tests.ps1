BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
}

# The banner's background jobs run while tools load; collecting them never
# waits on one that isn't done.
Describe 'Banner background work' {
    It 'runs jobs in parallel and returns each finished result by name' {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $handle = Start-DFBannerWork -Work @(
            @{ Name = 'a'; ScriptBlock = { param($x) Start-Sleep -Milliseconds 300; "a$x" }; ArgumentList = @(1) }
            @{ Name = 'b'; ScriptBlock = { Start-Sleep -Milliseconds 300; 'b' }; ArgumentList = @() })
        $results = Receive-DFBannerWork -Handle $handle -WaitMs 3000
        $sw.ElapsedMilliseconds | Should -BeLessThan 550
        $results['a'] | Should -Be 'a1'
        $results['b'] | Should -Be 'b'
    }
    It 'leaves out a job that is not done within the wait, without waiting for it' {
        $handle = Start-DFBannerWork -Work @(@{ Name = 'slow'; ScriptBlock = { Start-Sleep -Seconds 5; 'x' }; ArgumentList = @() })
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $results = Receive-DFBannerWork -Handle $handle -WaitMs 100
        $sw.ElapsedMilliseconds | Should -BeLessThan 1000
        $results.ContainsKey('slow') | Should -BeFalse
    }
    It 'leaves out a job that throws' {
        $handle = Start-DFBannerWork -Work @(@{ Name = 'bad'; ScriptBlock = { throw 'boom' }; ArgumentList = @() })
        (Receive-DFBannerWork -Handle $handle -WaitMs 3000).ContainsKey('bad') | Should -BeFalse
    }
    It 'handles no work at all' {
        (Receive-DFBannerWork -Handle (Start-DFBannerWork -Work @()) -WaitMs 100).Count | Should -Be 0
    }
}
