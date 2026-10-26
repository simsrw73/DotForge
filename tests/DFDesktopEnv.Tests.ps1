BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    function script:New-DesktopRecord([hashtable]$Extra = @{}) {
        ConvertTo-DFToolRecord ([pscustomobject](@{
            name    = 'deska'; executable = 'deska.exe'
            xdg     = [pscustomobject]@{ method = 'env'; vars = [pscustomobject]@{ FOO = '${XDG_CONFIG_HOME}/foo' } }
            env     = [pscustomobject]@{ BAR = 'plain' }
            desktop = @('FOO', 'BAR')
        } + $Extra))
    }
}

# The Windows user environment, the state of what DotForge wrote there, and what each record
# expects (docs/superpowers/specs/2026-10-26-desktop-variables-design.md).
Describe 'DFDesktopEnv' {
    BeforeEach { Set-DFTestXdg }
    AfterEach {
        Remove-Item -LiteralPath (Get-DFDesktopEnvKey) -Recurse -Force -ErrorAction Ignore
        Restore-DFTestXdg
    }

    It 'tests never use the real user environment' {
        Get-DFDesktopEnvKey | Should -Not -Be 'HKCU:\Environment'
        Get-DFDesktopEnvKey | Should -BeLike 'HKCU:\Software\DotForge-Tests\*'
    }
    It 'writes, reads and removes a value' -Skip:(-not $IsWindows) {
        Get-DFDesktopEnvValue -Name DFTEST_A | Should -BeNullOrEmpty
        Set-DFDesktopEnvValue -Name DFTEST_A -Value 'x'
        Get-DFDesktopEnvValue -Name DFTEST_A | Should -Be 'x'
        Remove-DFDesktopEnvValue -Name DFTEST_A
        Get-DFDesktopEnvValue -Name DFTEST_A | Should -BeNullOrEmpty
    }
    It 'keeps an ExpandString value''s kind when replacing it, and reads it unexpanded' -Skip:(-not $IsWindows) {
        $key = Get-DFDesktopEnvKey
        New-Item -Path $key -Force | Out-Null
        New-ItemProperty -Path $key -Name DFTEST_B -Value '%USERPROFILE%\a' -PropertyType ExpandString | Out-Null
        Get-DFDesktopEnvValue -Name DFTEST_B | Should -Be '%USERPROFILE%\a'
        Set-DFDesktopEnvValue -Name DFTEST_B -Value 'C:\b'
        (Get-Item $key).GetValueKind('DFTEST_B') | Should -Be 'ExpandString'
        Set-DFDesktopEnvValue -Name DFTEST_C -Value 'C:\c'
        (Get-Item $key).GetValueKind('DFTEST_C') | Should -Be 'String'
    }
    It 'expected values come from xdg.vars and env' {
        $expected = @(Get-DFDesktopEnvExpected -Tool (New-DesktopRecord))
        $expected.Name | Should -Be @('FOO', 'BAR')
        ($expected | Where-Object Name -eq FOO).Value | Should -Be (ConvertTo-DFPath (Join-Path $Env:XDG_CONFIG_HOME 'foo'))
        ($expected | Where-Object Name -eq BAR).Value | Should -Be 'plain'
    }
    It 'a record without desktop expects nothing and has no note' {
        $plain = ConvertTo-DFToolRecord ([pscustomobject]@{ name = 'p'; executable = 'p.exe' })
        @(Get-DFDesktopEnvExpected -Tool $plain).Count | Should -Be 0
        Mock Get-DFDesktopEnvValue { }
        @(Get-DFDesktopEnvNote -Tool $plain).Count | Should -Be 0
        Should -Invoke Get-DFDesktopEnvValue -Times 0 -Exactly
    }
    It 'the note says a missing variable isn''t set' -Skip:(-not $IsWindows) {
        Set-DFDesktopEnvValue -Name BAR -Value 'plain'
        @(Get-DFDesktopEnvNote -Tool (New-DesktopRecord)) | Should -Be @("FOO isn't set for desktop apps; Set-DFDesktopEnv deska sets it")
    }
    It 'the note says what desktop apps see when it differs' -Skip:(-not $IsWindows) {
        Set-DFDesktopEnvValue -Name FOO -Value 'C:\theirs'
        Set-DFDesktopEnvValue -Name BAR -Value 'plain'
        @(Get-DFDesktopEnvNote -Tool (New-DesktopRecord)) | Should -Be @('desktop apps see FOO = C:\theirs')
    }
    It 'no note when every value matches' -Skip:(-not $IsWindows) {
        Set-DFDesktopEnvValue -Name FOO -Value (Join-Path $Env:XDG_CONFIG_HOME 'foo')
        Set-DFDesktopEnvValue -Name BAR -Value 'plain'
        @(Get-DFDesktopEnvNote -Tool (New-DesktopRecord)).Count | Should -Be 0
    }
    It 'no note off Windows' {
        Mock Test-DFIsWindows { $false }
        @(Get-DFDesktopEnvNote -Tool (New-DesktopRecord)).Count | Should -Be 0
    }
    It 'state round-trips, and an unreadable file reads as $null' {
        (Read-DFDesktopEnvState).Count | Should -Be 0
        Save-DFDesktopEnvState -State @{ FOO = [pscustomobject]@{ tool = 'deska'; value = 'v'; since = 's' } }
        (Read-DFDesktopEnvState)['FOO'].tool | Should -Be 'deska'
        Set-Content -LiteralPath (Get-DFDesktopEnvStatePath) '{ bad'
        Read-DFDesktopEnvState 3>$null | Should -BeNullOrEmpty
    }
    It 'broadcasts nothing while tests redirect the key' {
        Mock Invoke-DFSettingChangeBroadcast { }
        Send-DFEnvironmentChange
        Should -Invoke Invoke-DFSettingChangeBroadcast -Times 0 -Exactly
    }
}
