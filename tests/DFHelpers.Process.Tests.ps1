BeforeAll {
    . "$PSScriptRoot/../Private/Invoke-DFFzf.ps1"
    . "$PSScriptRoot/../Public/Invoke-DFPicker.ps1"
    . "$PSScriptRoot/../Public/DFHelpers.Process.ps1"
}

Describe 'Select-DFProcess' {
    It 'returns a Process object for the selected process' {
        $proc = Get-Process -Id $PID
        $line = '{0,-35} {1,7} {2,8:F1} {3,10}' -f $proc.Name, $proc.Id, $proc.CPU, [math]::Round($proc.WorkingSet / 1MB)
        Mock Invoke-DFFzf { $line }
        $result = fps
        $result | Should -BeOfType [System.Diagnostics.Process]
        $result.Id | Should -Be $PID
    }

    It 'returns nothing when user cancels' {
        Mock Invoke-DFFzf { $null }
        fps | Should -BeNullOrEmpty
    }
}

Describe 'Get-DFTopProcess' {
    It 'does not throw with default parameters' {
        { top } | Should -Not -Throw
    }

    It 'does not throw with -By Memory' {
        { top -By Memory } | Should -Not -Throw
    }

    It 'does not throw with -Count 5' {
        { top -Count 5 } | Should -Not -Throw
    }
}
