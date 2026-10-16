BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
}

# The global cd alias resolves to Set-LocationWithFnm; a Pester test's own scope keeps
# its copy of cd, so the tests call the function directly.
Describe 'Tools/fnm.ps1' {
    BeforeEach {
        $script:Calls = [System.Collections.Generic.List[string]]::new()
        $global:DFFnmTestCalls = $script:Calls
        # A stand-in for zoxide's cd, registered before fnm.
        function global:DFFnmTestPreviousCd { $global:DFFnmTestCalls.Add("previous:$($args -join ' ')") }
        Set-Alias -Name cd -Value DFFnmTestPreviousCd -Scope Global -Option AllScope -Force
        # A stand-in for fnm: its env script defines Set-FnmOnLoad and Set-LocationWithFnm and rebinds cd.
        function global:fnm {
            @'
function global:Set-FnmOnLoad { $global:DFFnmTestCalls.Add('fnm-on-load') }
function global:Set-LocationWithFnm { param($path) Set-Location $path; Set-FnmOnLoad }
Set-Alias -Scope global -Option AllScope -Force cd Set-LocationWithFnm
'@
        }
    }

    AfterEach {
        Set-Alias -Name cd -Value Set-Location -Scope Global -Option AllScope -Force
        Remove-DFTestGlobal -Function 'fnm', 'DFFnmTestPreviousCd', 'Set-FnmOnLoad', 'Set-LocationWithFnm'
        Remove-Variable DFFnmTestCalls -Scope Global -ErrorAction Ignore
    }

    It 'chains cd through the command that owned it before fnm, then switches Node' {
        . "$PSScriptRoot/../Tools/fnm.ps1"
        Set-LocationWithFnm foo bar
        $script:Calls | Should -Be @('previous:foo bar', 'fnm-on-load')
    }

    It 'passes no arguments when cd has none' {
        . "$PSScriptRoot/../Tools/fnm.ps1"
        Set-LocationWithFnm
        $script:Calls | Should -Be @('previous:', 'fnm-on-load')
    }

    It 'leaves no global variable behind' {
        . "$PSScriptRoot/../Tools/fnm.ps1"
        Get-Variable cdBeforeFnm -Scope Global -ErrorAction Ignore | Should -BeNullOrEmpty
    }
}
