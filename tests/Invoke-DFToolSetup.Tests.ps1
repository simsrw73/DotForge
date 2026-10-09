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
    It 'refuses a tool that isn''t active in the session' {
        { Invoke-DFToolSetup -Name nope -ToolsPath $script:Tools -ErrorAction Stop } | Should -Throw '*not active*'
    }
}
