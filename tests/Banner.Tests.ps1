BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }

    # A user tool record with a banner part (installed: a module tool named Pester).
    function Write-BannerPart([string]$Name, [string]$Banner, [string]$Script) {
        @{ name = $Name; executable = 'Pester'; type = 'module'; banner = ($Banner | ConvertFrom-Json) } |
            ConvertTo-Json -Depth 5 | Set-Content (Join-Path $script:UserTools "$Name.json")
        Set-Content (Join-Path $script:UserTools "$Name.banner.ps1") $Script
        $script:DFToolRecordCache = @{}
    }
}

# The startup banner's coordinator
# (docs/superpowers/specs/2026-10-11-startup-banner-design.md).
Describe 'Startup banner' {
    BeforeEach {
        Set-DFTestXdg
        Reset-DFTestSession
        $script:DFToolDb = $null
        $script:DFToolRecordCache = @{}
        Remove-Item (Join-Path $TestDrive 'xdg') -Recurse -Force -ErrorAction Ignore
        $script:UserTools = Join-Path $Env:XDG_CONFIG_HOME 'dotforge' 'tools'
        New-Item -ItemType Directory -Force $script:UserTools | Out-Null
        Set-DFTestConfig @{ ShowBanner = $true; BannerLineDelay = 0; BannerWait = 300; BannerClear = $false }
        Mock Test-DFBannerHost { $true }
        $script:Printed = [System.Collections.Generic.List[string]]::new()
        Mock Write-DFBannerLines { foreach ($line in $Lines) { $script:Printed.Add(($line -replace "$([char]27)\[[0-9;]*m", '')) } }
        Mock Clear-Host { }
        Write-BannerPart body '{ "script": "body.banner.ps1", "body": true, "fills": ["ip"] }' @'
[pscustomobject]@{
    Style = { param($Context) @{ KeyColor = ''; OutputColor = ''; Separator = '  ' } }
    Work = { param($Context) @(@{ Name = 'ip'; ScriptBlock = { '9.9.9.9' }; ArgumentList = @() }) }
    Complete = { param($Results, $Context)
        [pscustomobject]@{ Body = @('OS  Win', 'Public IP  @DF:ip@', 'Disk  @DF:drives@')
            Fills = @{ ip = @(if ($Results['ip']) { [pscustomobject]@{ Key = $null; Value = "$($Results['ip'])"; Alert = $false } }) } } }
}
'@
        Write-BannerPart drives '{ "script": "drives.banner.ps1", "fills": ["drives"] }' @'
[pscustomobject]@{
    Work = { param($Context) @(@{ Name = 'drives'; ScriptBlock = { 'x' }; ArgumentList = @() }) }
    Complete = { param($Results, $Context)
        [pscustomobject]@{ Body = $null; Fills = @{ drives = @([pscustomobject]@{ Key = 'Disk A'; Value = 'ok'; Alert = $false }) } } }
}
'@
    }
    AfterEach {
        Set-DFTestConfig $null
        $script:DFToolDb = $null
        $script:DFToolRecordCache = @{}
        Restore-DFTestXdg
    }

    It 'prints the first line at once, then the body with placeholders filled' {
        $state = Start-DFBanner -Tools body, drives
        $script:Printed[0] | Should -Match '^DotForge  (\S+ · )?loading 2 tools'
        Show-DFBanner -State $state
        @($script:Printed)[1..3] | Should -Be @('OS  Win', 'Public IP  9.9.9.9', 'Disk A  ok')
    }
    It 'prints nothing and starts nothing when ShowBanner is off' {
        Set-DFTestConfig @{ ShowBanner = $false }
        Start-DFBanner -Tools body | Should -BeNullOrEmpty
        $script:Printed | Should -BeNullOrEmpty
    }
    It 'prints nothing in a non-interactive host' {
        Mock Test-DFBannerHost { $false }
        Start-DFBanner -Tools body | Should -BeNullOrEmpty
        $script:Printed | Should -BeNullOrEmpty
    }
    It 'clears the screen first unless BannerClear is false' {
        $null = Start-DFBanner -Tools body
        Should -Invoke Clear-Host -Times 0 -Exactly
        Reset-DFTestSession
        Set-DFTestConfig @{ ShowBanner = $true; BannerLineDelay = 0 }
        $null = Start-DFBanner -Tools body
        Should -Invoke Clear-Host -Times 1 -Exactly
    }
    It 'uses a cached fill, marked, when its job is not back in time, and removes a line with no fill at all' {
        Write-DFFileAtomic -Path (Get-DFBannerCachePath) -Value '{ "ip": { "at": "2026-10-11T00:00:00Z", "items": [ { "Key": null, "Value": "1.1.1.1", "Alert": false } ] } }'
        Write-BannerPart body '{ "script": "body.banner.ps1", "body": true, "fills": ["ip"] }' @'
[pscustomobject]@{
    Work = { param($Context) @(@{ Name = 'ip'; ScriptBlock = { Start-Sleep -Seconds 5 }; ArgumentList = @() }) }
    Complete = { param($Results, $Context) [pscustomobject]@{ Body = @('Public IP  @DF:ip@', 'Disk  @DF:drives@'); Fills = @{} } }
}
'@
        Show-DFBanner -State (Start-DFBanner -Tools body)
        @($script:Printed).Count | Should -Be 2
        $script:Printed[1] | Should -Be 'Public IP  1.1.1.1 (cached)'
    }
    It 'caches fills for the next shell' {
        Show-DFBanner -State (Start-DFBanner -Tools body, drives)
        (Get-Content (Get-DFBannerCachePath) -Raw | ConvertFrom-Json).ip.items[0].Value | Should -Be '9.9.9.9'
    }
    It 'still prints the rest when a part throws, with one warning' {
        Write-BannerPart drives '{ "script": "drives.banner.ps1", "fills": ["drives"] }' '[pscustomobject]@{ Work = { @() }; Complete = { throw "bad" } }'
        Show-DFBanner -State (Start-DFBanner -Tools body, drives) -WarningVariable warnings 3>$null
        @($script:Printed) | Should -Contain 'OS  Win'
        @($warnings).Count | Should -Be 1
    }
    It 'shows only the first line with no body part' {
        Show-DFBanner -State (Start-DFBanner -Tools drives)
        @($script:Printed).Count | Should -Be 1
    }
    It 'leaves out a tool that is not installed' {
        Mock Test-DFToolAvailable { $false }
        Show-DFBanner -State (Start-DFBanner -Tools body, drives)
        @($script:Printed).Count | Should -Be 1
    }
    It 'shows the banner once per shell' {
        Show-DFBanner -State (Start-DFBanner -Tools body)
        Start-DFBanner -Tools body | Should -BeNullOrEmpty
    }
    It 'Start-DFSession shows it around tool activation' {
        Set-DFTestConfig $null
        Mock Start-DFBanner { 'state' }
        Mock Show-DFBanner { }
        Start-DFSession -Config @{ Tools = @(); ShowBanner = $true } 3>$null
        Should -Invoke Start-DFBanner -Times 1 -Exactly
        Should -Invoke Show-DFBanner -Times 1 -Exactly -ParameterFilter { $State -eq 'state' }
    }
}

Describe 'The banner field in tool records' {
    It 'normalizes to script, body and fills' {
        $rec = ConvertTo-DFToolRecord ([pscustomobject]@{ name = 't'; executable = 't.exe'; banner = [pscustomobject]@{ script = 't.banner.ps1'; fills = @('x') } })
        $rec.banner.script | Should -Be 't.banner.ps1'
        $rec.banner.body | Should -BeFalse
        $rec.banner.fills | Should -Be @('x')
    }
    It 'is null when absent' {
        (ConvertTo-DFToolRecord ([pscustomobject]@{ name = 't'; executable = 't.exe' })).banner | Should -BeNullOrEmpty
    }
    It 'rejects a script that is not a .banner.ps1 file, a text body and a bad fill name' {
        $errors = (Test-DFToolSchema ([pscustomobject]@{ name = 't'; executable = 't.exe'; banner = [pscustomobject]@{ script = 't.ps1'; body = 'yes'; fills = @('a b') } })).Errors
        "$errors" | Should -Match 'banner.script'
        "$errors" | Should -Match 'banner.body'
        "$errors" | Should -Match 'banner.fills'
    }
}

Describe 'Only an interactive shell gets the banner' {
    It '<line> starts an interactive shell: <repl>' -ForEach @(
        @{ line = 'pwsh'; repl = $true }
        @{ line = 'pwsh -NoLogo'; repl = $true }
        @{ line = 'pwsh -l -wd C:\work'; repl = $true }
        @{ line = 'pwsh -ExecutionPolicy Bypass'; repl = $true }
        @{ line = 'pwsh -NoExit -Command Set-Location C:\'; repl = $true }
        @{ line = 'pwsh -c Get-Date'; repl = $false }
        @{ line = 'pwsh -Command Get-Date'; repl = $false }
        @{ line = 'pwsh -File build.ps1'; repl = $false }
        @{ line = 'pwsh build.ps1'; repl = $false }
        @{ line = 'pwsh -ec ZQBjAGgAbwA='; repl = $false }
        @{ line = 'pwsh -NoProfile -wd C:\x script.ps1'; repl = $false }
    ) {
        Test-DFReplStart -CommandLine ($line -split ' ') | Should -Be $repl
    }
}

Describe 'A banner body that is not ready in time' {
    BeforeEach {
        Set-DFTestXdg
        Reset-DFTestSession
        $script:DFToolDb = $null
        $script:DFToolRecordCache = @{}
        Remove-Item (Join-Path $TestDrive 'xdg') -Recurse -Force -ErrorAction Ignore
        $script:UserTools = Join-Path $Env:XDG_CONFIG_HOME 'dotforge' 'tools'
        New-Item -ItemType Directory -Force $script:UserTools | Out-Null
        Set-DFTestConfig @{ ShowBanner = $true; BannerLineDelay = 0; BannerWait = 100; BannerClear = $false }
        Mock Test-DFBannerHost { $true }
        $script:Printed = [System.Collections.Generic.List[string]]::new()
        Mock Write-DFBannerLines { foreach ($line in $Lines) { $script:Printed.Add(($line -replace "$([char]27)\[[0-9;]*m", '')) } }
    }
    AfterEach { Set-DFTestConfig $null; $script:DFToolDb = $null; $script:DFToolRecordCache = @{}; Restore-DFTestXdg }

    It 'says which tool was late and how to give it more time' {
        Write-BannerPart slowbody '{ "script": "slowbody.banner.ps1", "body": true }' @'
[pscustomobject]@{
    Work = { param($Context) @(@{ Name = 'body'; ScriptBlock = { Start-Sleep -Seconds 5; 'x' }; ArgumentList = @() }) }
    Complete = { param($Results, $Context) [pscustomobject]@{ Body = $(if ($Results.ContainsKey('body')) { @($Results['body']) }); Fills = @{} } }
}
'@
        Show-DFBanner -State (Start-DFBanner -Tools slowbody)
        @($script:Printed).Count | Should -Be 2
        $script:Printed[1] | Should -Match 'slowbody.*BannerWait'
    }
}

Describe 'Banner robustness' {
    BeforeEach {
        Set-DFTestXdg
        Reset-DFTestSession
        $script:DFToolDb = $null
        $script:DFToolRecordCache = @{}
        Remove-Item (Join-Path $TestDrive 'xdg') -Recurse -Force -ErrorAction Ignore
        $script:UserTools = Join-Path $Env:XDG_CONFIG_HOME 'dotforge' 'tools'
        New-Item -ItemType Directory -Force $script:UserTools | Out-Null
        Set-DFTestConfig @{ ShowBanner = $true; BannerLineDelay = 0; BannerWait = 300; BannerClear = $false }
        Mock Test-DFBannerHost { $true }
        $script:Printed = [System.Collections.Generic.List[string]]::new()
        Mock Write-DFBannerLines { foreach ($line in $Lines) { $script:Printed.Add(($line -replace "$([char]27)\[[0-9;]*m", '')) } }
        $global:DFTestDrivesWorkCalled = $false
        Write-BannerPart body '{ "script": "body.banner.ps1", "body": true, "fills": ["ip"] }' @'
[pscustomobject]@{
    Uses = { param($Context) @('ip', 'drives') }
    Work = { param($Context) @(@{ Name = 'ip'; ScriptBlock = { '9.9.9.9' }; ArgumentList = @() }) }
    Complete = { param($Results, $Context)
        [pscustomobject]@{ Body = @('OS  Win', 'Public IP  @DF:ip@', 'Disk  @DF:drives@')
            Fills = @{ ip = @(if ($Results['ip']) { [pscustomobject]@{ Key = $null; Value = "$($Results['ip'])"; Alert = $false } }) } } }
}
'@
        Write-BannerPart drives '{ "script": "drives.banner.ps1", "fills": ["drives"] }' @'
[pscustomobject]@{
    Work = { param($Context) $global:DFTestDrivesWorkCalled = $true; @() }
    Complete = { param($Results, $Context) [pscustomobject]@{ Body = $null; Fills = @{ drives = @('just a string', 42) } } }
}
'@
    }
    AfterEach {
        Set-StrictMode -Off
        Remove-Variable DFTestDrivesWorkCalled -Scope Global -ErrorAction Ignore
        Set-DFTestConfig $null; $script:DFToolDb = $null; $script:DFToolRecordCache = @{}; Restore-DFTestXdg
    }

    It 'keeps the rest when a part returns fill items of the wrong shape, even under StrictMode' {
        Set-StrictMode -Version Latest
        Show-DFBanner -State (Start-DFBanner -Tools body, drives) 3>$null
        Set-StrictMode -Off
        @($script:Printed) | Should -Contain 'OS  Win'
        @($script:Printed) | Should -Contain 'Public IP  9.9.9.9'
    }
    It 'ignores a malformed cache entry' {
        Write-DFFileAtomic -Path (Get-DFBannerCachePath) -Value '{ "drives": { "at": "x", "items": "not a list" } }'
        Write-BannerPart drives '{ "script": "drives.banner.ps1", "fills": ["drives"] }' '[pscustomobject]@{ Work = { @() }; Complete = { [pscustomobject]@{ Body = $null; Fills = @{} } } }'
        Set-StrictMode -Version Latest
        Show-DFBanner -State (Start-DFBanner -Tools body, drives) 3>$null
        Set-StrictMode -Off
        @($script:Printed) | Should -Contain 'OS  Win'
    }
    It 'does no work for a part whose lines no body uses' {
        Write-BannerPart body '{ "script": "body.banner.ps1", "body": true, "fills": ["ip"] }' @'
[pscustomobject]@{
    Uses = { param($Context) @('ip') }
    Work = { param($Context) @() }
    Complete = { param($Results, $Context) [pscustomobject]@{ Body = @('OS  Win'); Fills = @{} } }
}
'@
        Show-DFBanner -State (Start-DFBanner -Tools body, drives)
        $global:DFTestDrivesWorkCalled | Should -BeFalse
    }
    It 'does no work at all without a body part' {
        Show-DFBanner -State (Start-DFBanner -Tools drives)
        $global:DFTestDrivesWorkCalled | Should -BeFalse
    }
    It 'shows the banner only on the first Start-DFSession of the shell' {
        Set-DFTestConfig $null
        Mock Clear-Host { }
        Start-DFSession -Config @{ Tools = @() } 3>$null
        Start-DFSession -Config @{ Tools = @('body'); ShowBanner = $true } 3>$null
        Should -Invoke Clear-Host -Times 0 -Exactly
        @($script:Printed).Count | Should -Be 0
    }
    It 'closes the banner''s work when tool activation fails' {
        Set-DFTestConfig $null
        Mock Start-DFBanner { 'state' }
        Mock Show-DFBanner { }
        Mock Stop-DFBanner { }
        Mock Invoke-DFSessionActivation { throw 'boom' }
        { Start-DFSession -Config @{ Tools = @(); ShowBanner = $true } 3>$null } | Should -Throw '*boom*'
        Should -Invoke Stop-DFBanner -Times 1 -Exactly -ParameterFilter { $State -eq 'state' }
        Should -Invoke Show-DFBanner -Times 0 -Exactly
    }
}
