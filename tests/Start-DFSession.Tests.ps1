BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }

    # A private Tools folder: each companion records that it ran.
    function script:New-SessionTool([string]$Name, [string]$Extra = '') {
        $json = "{ ""name"": ""$Name"", ""executable"": ""$Name.exe""$Extra }"
        Set-Content (Join-Path $script:Tools "$Name.json") $json
        "`$global:DFTestActivated += '$Name'" | Set-Content (Join-Path $script:Tools "$Name.ps1")
    }
}

Describe 'Start-DFSession' {
    BeforeEach {
        Set-DFTestXdg
        Set-DFTestConfig $null
        $script:DFSessionStatus = $null
        $script:DFToolRecordCache = @{}
        $script:DFToolDb = $null
        $script:DFToolAvailability = @{}
        $script:Tools = Join-Path $TestDrive "tools-$([guid]::NewGuid().ToString('N').Substring(0, 6))"
        New-Item -ItemType Directory $script:Tools | Out-Null
        $global:DFTestActivated = @()
        New-SessionTool 'alpha'
        New-SessionTool 'beta'
        New-SessionTool 'gamma'
        New-SessionTool 'unrequested'
        $script:DFGroupDb = Get-DFGroupDb -Path (New-Item (Join-Path $script:Tools 'groups.txt') -Force -Value '{ "pair": { "description": "d", "tools": ["alpha", "beta"] } }').FullName
        $script:Installed = @('alpha.exe', 'beta.exe', 'unrequested.exe')
        Mock Test-DFToolAvailable { $Executable -in $script:Installed }
        Mock Write-DFConflictNotice { }
    }
    AfterEach {
        Restore-DFTestXdg
        Set-DFTestConfig $null
        $script:DFGroupDb = $null
        Remove-Variable DFTestActivated -Scope Global -ErrorAction Ignore
    }

    It 'activates only requested, installed tools, and never looks at an unrequested one' {
        Start-DFSession -Config @{ Tools = @('+pair', 'gamma') } -ToolsPath $script:Tools 3>$null
        $global:DFTestActivated | Should -Be @('alpha', 'beta')
        Should -Invoke Test-DFToolAvailable -Times 0 -ParameterFilter { $Executable -eq 'unrequested.exe' }
    }

    It 'records each requested tool''s state in Get-DFToolStatus' {
        Start-DFSession -Config @{ Tools = @('+pair', 'gamma'); ExcludeTools = @('beta') } -ToolsPath $script:Tools 3>$null
        $s = Get-DFToolStatus
        ($s | Where-Object Name -eq 'alpha').State | Should -Be 'Active'
        ($s | Where-Object Name -eq 'alpha').RequestedBy | Should -Be '+pair'
        ($s | Where-Object Name -eq 'beta').State | Should -Be 'Excluded'
        ($s | Where-Object Name -eq 'gamma').State | Should -Be 'Missing'
        (Get-DFToolStatus -Missing).Name | Should -Be @('gamma')
    }

    It 'marks a tool whose companion throws as Failed and keeps going' {
        'throw "boom"' | Set-Content (Join-Path $script:Tools 'alpha.ps1')
        Start-DFSession -Config @{ Tools = @('alpha', 'beta') } -ToolsPath $script:Tools 3>$null
        $failed = Get-DFToolStatus -Failed
        $failed.Name | Should -Be 'alpha'
        $failed.Detail | Should -Match 'boom'
        $global:DFTestActivated | Should -Be @('beta')
    }

    It 'prints nothing about missing tools when none are missing' {
        Start-DFSession -Config @{ Tools = @('alpha') } -ToolsPath $script:Tools -WarningVariable w 3>$null
        @($w | Where-Object { $_ -match 'not installed' }) | Should -BeNullOrEmpty
    }

    It 'lists up to five missing tools by name, with the install command' {
        Start-DFSession -Config @{ Tools = @('alpha', 'gamma') } -ToolsPath $script:Tools -WarningVariable w 3>$null
        "$w" | Should -Match "1 requested tool isn't installed: gamma\. Run Install-DFTool -Missing"
    }

    It 'gives only the count and the commands when more than five are missing' {
        foreach ($n in 'm1', 'm2', 'm3', 'm4', 'm5', 'm6') { New-SessionTool $n }
        Start-DFSession -Config @{ Tools = @('m1', 'm2', 'm3', 'm4', 'm5', 'm6') } -ToolsPath $script:Tools -WarningVariable w 3>$null
        "$w" | Should -Match "6 requested tools aren't installed\. See Get-DFToolStatus -Missing"
        "$w" | Should -Not -Match 'm1'
    }

    It 'names the stand-in when a role''s preferred tool is missing' {
        New-SessionTool 'promptA' ', "roles": { "prompt": { "priority": 10 } }'
        New-SessionTool 'promptB' ', "roles": { "prompt": { "priority": 5 } }'
        $script:Installed += 'promptB.exe'
        Start-DFSession -Config @{ Tools = @('promptA', 'promptB'); Defaults = @{ prompt = 'promptA' } } -ToolsPath $script:Tools -WarningVariable w 3>$null
        "$w" | Should -Match 'promptA \(prompt — using promptB\)'
        (Get-DFToolStatus -Name promptA).Detail | Should -Match 'using promptB'
        (Get-DFToolStatus -Name promptB).Roles | Should -Contain 'prompt'
    }

    It 'only adds when called again, and warns about a tool no longer requested' {
        Start-DFSession -Config @{ Tools = @('alpha') } -ToolsPath $script:Tools 3>$null
        Start-DFSession -Config @{ Tools = @('beta') } -ToolsPath $script:Tools -WarningVariable w 3>$null
        $global:DFTestActivated | Should -Be @('alpha', 'beta')
        "$w" | Should -Match "alpha.*no longer requested.*new shell"
        (Get-DFToolStatus -Name alpha).State | Should -Be 'Active'
    }

    It 'stores the config, so Get-DFConfig reads it afterwards' {
        Start-DFSession -Config @{ Tools = @('alpha'); Theme = 'nord' } -ToolsPath $script:Tools 3>$null
        Get-DFConfig Theme | Should -Be 'nord'
    }

    It 'exports the XDG folders' {
        Start-DFSession -Config @{ Tools = @() } -ToolsPath $script:Tools 3>$null
        $Env:XDG_STATE_HOME | Should -BeLike "$TestDrive*"
        Test-Path $Env:XDG_STATE_HOME | Should -BeTrue
    }

    It 'runs the conflict check over the active tools only' {
        Start-DFSession -Config @{ Tools = @('alpha', 'gamma') } -ToolsPath $script:Tools 3>$null
        Should -Invoke Write-DFConflictNotice -Times 1 -ParameterFilter { (@($Tools).name -join ',') -eq 'alpha' }
    }
}

Describe 'Get-DFToolStatus before any session' {
    BeforeEach { $script:DFSessionStatus = $null }
    It 'says Start-DFSession has not run, and returns nothing' {
        Get-DFToolStatus -WarningVariable w 3>$null | Should -BeNullOrEmpty
        "$w" | Should -Match 'Start-DFSession'
    }
}
