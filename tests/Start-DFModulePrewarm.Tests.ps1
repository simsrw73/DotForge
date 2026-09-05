BeforeAll {
    . "$PSScriptRoot/../Private/Start-DFModulePrewarm.ps1"
}

Describe 'Start-DFModulePrewarm' {
    It 'returns $null and starts no job when -ModuleNames is empty' {
        Start-DFModulePrewarm -ModuleNames @() | Should -BeNullOrEmpty
    }

    It 'returns a job that completes without throwing for a real, importable module' {
        $job = Start-DFModulePrewarm -ModuleNames @('Microsoft.PowerShell.Management')
        $job | Should -Not -BeNullOrEmpty
        $job | Wait-Job -Timeout 10 | Out-Null
        $job.State | Should -Be 'Completed'
        $job | Remove-Job -Force
    }

    It 'tolerates a module name that does not exist, without the job failing' {
        $job = Start-DFModulePrewarm -ModuleNames @('ThisModuleDoesNotExist12345')
        $job | Wait-Job -Timeout 10 | Out-Null
        $job.State | Should -Be 'Completed'
        $job | Remove-Job -Force
    }

    It 'imports every named module in its own runspace, never the caller''s' {
        # Regression for the exact invariant this function exists to exploit --
        # confirmed empirically in docs/superpowers/specs/2026-09-05-startup-perf-audit.md
        # that a background-job import never crosses into the caller's session.
        $job = Start-DFModulePrewarm -ModuleNames @('Microsoft.PowerShell.Archive')
        $job | Wait-Job -Timeout 10 | Out-Null
        Get-Module -Name 'Microsoft.PowerShell.Archive' | Should -BeNullOrEmpty
        $job | Remove-Job -Force
    }

    It 'imports multiple named modules from the same job' {
        $job = Start-DFModulePrewarm -ModuleNames @('Microsoft.PowerShell.Management', 'Microsoft.PowerShell.Archive')
        $job | Wait-Job -Timeout 10 | Out-Null
        $job.State | Should -Be 'Completed'
        $job | Remove-Job -Force
    }
}
