BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
}
Describe 'Invoke-DFToolSetup' {
    BeforeEach {
        Set-DFTestXdg; Reset-DFTestSession; Set-DFTestConfig $null
        $script:Tools = Join-Path $TestDrive "su-$([guid]::NewGuid().ToString('N').Substring(0,6))"
        New-Item -ItemType Directory (Join-Path $script:Tools 'st') -Force | Out-Null
        Set-Content (Join-Path $script:Tools 'st' 'c.conf') 'default' -NoNewline
        '{ "name": "st", "executable": "st.exe", "setup": { "seed": { "${XDG_CONFIG_HOME}/st/c.conf": "st/c.conf" } } }' |
            Set-Content (Join-Path $script:Tools 'st.json')
        Mock Test-DFToolAvailable { $true }
        Mock Write-DFConflictNotice { }
        Start-DFSession -Config @{ Tools = @('st') } -ToolsPath $script:Tools 3>$null
        $script:Dest = Join-Path $Env:XDG_CONFIG_HOME 'st' 'c.conf'
    }
    AfterEach { Restore-DFTestXdg; Set-DFTestConfig $null }

    It 'brings back a deleted seed' {
        Remove-Item $script:Dest
        Invoke-DFToolSetup -Name st -ToolsPath $script:Tools
        Get-Content $script:Dest -Raw | Should -Be 'default'
    }
    It 'keeps an edited seed without -Force, and overwrites it with -Force' {
        Set-Content $script:Dest 'mine' -NoNewline
        Invoke-DFToolSetup -Name st -ToolsPath $script:Tools
        Get-Content $script:Dest -Raw | Should -Be 'mine'
        Invoke-DFToolSetup -Name st -Force -Confirm:$false -ToolsPath $script:Tools
        Get-Content $script:Dest -Raw | Should -Be 'default'
    }
    It '-WhatIf runs nothing' {
        Remove-Item $script:Dest
        Invoke-DFToolSetup -Name st -WhatIf -ToolsPath $script:Tools 6>$null
        Test-Path $script:Dest | Should -BeFalse
        (Get-DFToolSetupState).PSObject.Properties['st'] | Should -Not -BeNullOrEmpty
    }
    It 'honors -Confirm: with no one to answer, nothing is re-seeded' {
        # -Confirm lowers $ConfirmPreference for every write setup makes, so each one
        # asks. A child pwsh -NonInteractive turns the prompt into an error instead of
        # waiting for a person. It shares this test's XDG folders, so the setup record
        # from BeforeEach stops Start-DFSession from re-seeding.
        $tools = Join-Path $TestDrive "confirm-$([guid]::NewGuid().ToString('N').Substring(0,6))"
        Copy-Item $script:Tools $tools -Recurse
        (Get-Content (Join-Path $tools 'st.json') -Raw) -replace '"st\.exe"', '"pwsh"' | Set-Content (Join-Path $tools 'st.json')
        Remove-Item $script:Dest -ErrorAction Ignore   # $TestDrive persists across this Describe's tests
        $manifest = Join-Path $PSScriptRoot '..' 'DotForge.psd1'
        $child = @"
Import-Module '$manifest'
Start-DFSession -Config @{ Tools = @('st') } -ToolsPath '$tools' 3>`$null
Invoke-DFToolSetup -Name st -Confirm -ToolsPath '$tools'
"@
        $null = & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -Command $child 2>&1
        Test-Path $script:Dest | Should -BeFalse
    }
    It 'refuses a tool that isn''t active in the session' {
        { Invoke-DFToolSetup -Name nope -ToolsPath $script:Tools -ErrorAction Stop } | Should -Throw '*not active*'
    }
}
