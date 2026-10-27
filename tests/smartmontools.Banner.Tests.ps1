BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    $script:Part = . "$PSScriptRoot/../Tools/smartmontools.banner.ps1"
    $script:Fx = "$PSScriptRoot/fixtures/banner"
    function Get-DriveFill {
        param([string[]]$Json)
        (& $script:Part.Complete @{ drives = @($Json) } ([pscustomobject]@{})).Fills.drives
    }
    function Read-Fixture([string]$Name) { Get-Content (Join-Path $script:Fx $Name) -Raw }
}

# smartmontools' banner part: one health line per drive, from smartctl -j -a
# recorded on a real machine without admin rights.
Describe 'smartmontools banner part' {
    It 'shows NVMe life, temperature, hours and TB written' {
        (Get-DriveFill (Read-Fixture 'smartctl-nvme-990.json')).Value | Should -Match '^NVMe · 99% life · \d+°C · [\d,]+ h · [\d,]+ TB written$'
    }
    It 'shows a SATA SSD''s wear level as life' {
        (Get-DriveFill (Read-Fixture 'smartctl-ssd-860.json')).Value | Should -Match '^SSD · 97% life · \d+°C · [\d,]+ h$'
    }
    It 'shows a hard drive with no bad sectors' {
        (Get-DriveFill (Read-Fixture 'smartctl-hdd-wd.json')).Value | Should -Match '^HDD · no bad sectors · \d+°C · [\d,]+ h$'
    }
    It 'shortens the model name and pads the keys to line up' {
        $keys = @((Get-DriveFill (Read-Fixture 'smartctl-nvme-990.json'), (Read-Fixture 'smartctl-hdd-wd.json')).Key)
        $keys[0].TrimEnd() | Should -Be 'Disk 990 PRO 2TB'
        $keys[0].Length | Should -Be $keys[1].Length
        @((Get-DriveFill (Read-Fixture 'smartctl-hdd-wd.json')).Alert) | Should -Be @($false)
    }
    It 'turns a drive with reallocated sectors into an alert, with the count' {
        $j = Read-Fixture 'smartctl-hdd-wd.json' | ConvertFrom-Json
        ($j.ata_smart_attributes.table | Where-Object id -eq 5).raw.value = 8
        $fill = Get-DriveFill ($j | ConvertTo-Json -Depth 30)
        $fill.Alert | Should -BeTrue
        $fill.Value | Should -Match '8 reallocated sectors'
        $fill.Value | Should -Not -Match 'no bad sectors'
    }
    It 'turns a failed self-check into an alert' {
        $j = Read-Fixture 'smartctl-nvme-980.json' | ConvertFrom-Json
        $j.smart_status.passed = $false
        $fill = Get-DriveFill ($j | ConvertTo-Json -Depth 30)
        $fill.Alert | Should -BeTrue
        $fill.Value | Should -Match 'self-check FAILED'
    }
    It 'turns NVMe media errors and low life into an alert' {
        $j = Read-Fixture 'smartctl-nvme-980.json' | ConvertFrom-Json
        $j.nvme_smart_health_information_log.media_errors = 3
        $j.nvme_smart_health_information_log.percentage_used = 95
        $fill = Get-DriveFill ($j | ConvertTo-Json -Depth 30)
        $fill.Alert | Should -BeTrue
        $fill.Value | Should -Match '5% life'
        $fill.Value | Should -Match '3 media errors'
        $fill.Value | Should -Match 'under 10% life'
    }
    It 'leaves out a drive whose output lacks what it reads, and keeps the others' {
        $fill = Get-DriveFill '{ "device": {} }', 'not json', (Read-Fixture 'smartctl-nvme-990.json')
        @($fill).Count | Should -Be 1
    }
    It 'gives no drive lines when the job did not finish' {
        @((& $script:Part.Complete @{} ([pscustomobject]@{})).Fills.drives).Count | Should -Be 0
    }
    It 'asks for one background job' {
        Mock Get-Command { [pscustomobject]@{ Source = 'C:\tools\smartctl.exe' } } -ParameterFilter { $Name -eq 'smartctl.exe' }
        @((& $script:Part.Work ([pscustomobject]@{})).Name) | Should -Be @('drives')
    }
}

Describe 'Tools/smartmontools.json' {
    It 'declares the drives banner part and is in +core' {
        $rec = Get-Content "$PSScriptRoot/../Tools/smartmontools.json" -Raw | ConvertFrom-Json
        $rec.executable | Should -Be 'smartctl.exe'
        $rec.banner.fills | Should -Be @('drives')
        (Get-Content "$PSScriptRoot/../data/groups.json" -Raw | ConvertFrom-Json).core.tools | Should -Contain 'smartmontools'
        (Get-Content "$PSScriptRoot/../data/groups.json" -Raw | ConvertFrom-Json).core.tools | Should -Contain 'fastfetch'
    }
}

# The background job itself, against a stand-in smartctl (a .cmd file): the
# device list, one result per drive as it answers, and a hung drive killed.
Describe 'smartmontools banner job' -Skip:(-not $IsWindows) {
    BeforeAll {
        function New-FakeSmartctl([string[]]$ScanLines, [hashtable]$JsonByDevice, [string]$HangDevice) {
            $dir = Join-Path $TestDrive "fake-$([guid]::NewGuid())"
            New-Item -ItemType Directory -Force $dir | Out-Null
            $scan = Join-Path $dir 'scan.txt'
            Set-Content $scan $ScanLines
            $lines = @('@echo off', "if `"%1`"==`"--scan`" (type `"$scan`" & exit /b 0)")
            foreach ($device in $JsonByDevice.Keys) { $lines += "if `"%5`"==`"$device`" (type `"$($JsonByDevice[$device])`" & exit /b 0)" }
            if ($HangDevice) { $lines += "if `"%5`"==`"$HangDevice`" (ping -n 30 127.0.0.1 >nul & exit /b 0)" }
            $exe = Join-Path $dir 'smartctl.cmd'
            Set-Content $exe ($lines -join "`r`n")
            $exe
        }
        function Invoke-DrivesJob([string]$Exe, [int]$TimeoutMs = 4000) {
            Mock Get-Command { [pscustomobject]@{ Source = $Exe } } -ParameterFilter { $Name -eq 'smartctl.exe' }
            $job = @(& $script:Part.Work ([pscustomobject]@{}))[0]
            & $job.ScriptBlock $job.ArgumentList[0] $TimeoutMs
        }
        $script:Nvme = Join-Path $script:Fx 'smartctl-nvme-990.json'
        $script:Hdd = Join-Path $script:Fx 'smartctl-hdd-wd.json'
    }

    It 'checks the only drive of a one-drive machine' {
        $exe = New-FakeSmartctl -ScanLines '/dev/sda -d nvme # /dev/sda, NVMe device' -JsonByDevice @{ '/dev/sda' = $script:Nvme }
        $out = @(Invoke-DrivesJob $exe)
        @($out | Where-Object Kind -eq 'drive').Count | Should -Be 1
        $fill = (& $script:Part.Complete @{ drives = $out } ([pscustomobject]@{})).Fills.drives
        @($fill).Count | Should -Be 1
        $fill[0].Key.TrimEnd() | Should -Be 'Disk 990 PRO 2TB'
    }
    It 'checks every drive of a several-drive machine' {
        $exe = New-FakeSmartctl -ScanLines '/dev/sda -d nvme # a', '/dev/sdb -d ata # b' -JsonByDevice @{ '/dev/sda' = $script:Nvme; '/dev/sdb' = $script:Hdd }
        @((& $script:Part.Complete @{ drives = @(Invoke-DrivesJob $exe) } ([pscustomobject]@{})).Fills.drives).Count | Should -Be 2
    }
    It 'kills a drive that hangs, and still reports the others' {
        $exe = New-FakeSmartctl -ScanLines '/dev/sda -d nvme # a', '/dev/sdb -d ata # b' -JsonByDevice @{ '/dev/sda' = $script:Nvme } -HangDevice '/dev/sdb'
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $out = @(Invoke-DrivesJob $exe -TimeoutMs 800)
        $sw.ElapsedMilliseconds | Should -BeLessThan 5000
        $fill = (& $script:Part.Complete @{ drives = $out } ([pscustomobject]@{})).Fills.drives
        @($fill).Count | Should -Be 2
        ($fill | Where-Object { $_.Key -match '/dev/sdb' }).Value | Should -Match 'no answer'
    }
    It 'runs smartctl by its full path, and does nothing when it isn''t installed' {
        Mock Get-Command { [pscustomobject]@{ Source = 'C:\tools\smartctl.exe' } } -ParameterFilter { $Name -eq 'smartctl.exe' }
        @(& $script:Part.Work ([pscustomobject]@{}))[0].ArgumentList[0] | Should -Be 'C:\tools\smartctl.exe'
        Mock Get-Command { } -ParameterFilter { $Name -eq 'smartctl.exe' }
        @(& $script:Part.Work ([pscustomobject]@{})).Count | Should -Be 0
    }
}

Describe 'SATA wear values off the 0-100 scale' {
    It 'shows no life percentage for a vendor whose scale starts above 100' {
        $j = Get-Content (Join-Path "$PSScriptRoot/fixtures/banner" 'smartctl-ssd-860.json') -Raw | ConvertFrom-Json
        ($j.ata_smart_attributes.table | Where-Object id -eq 177).value = 200
        $value = (& $script:Part.Complete @{ drives = @($j | ConvertTo-Json -Depth 30) } ([pscustomobject]@{})).Fills.drives.Value
        $value | Should -Not -Match '% life'
        $value | Should -Match '^SSD · '
    }
    It 'reads a drive without smart_status.passed under StrictMode, without losing the others' {
        $j = Get-Content (Join-Path "$PSScriptRoot/fixtures/banner" 'smartctl-nvme-980.json') -Raw | ConvertFrom-Json
        $j.smart_status.PSObject.Properties.Remove('passed')
        Set-StrictMode -Version Latest
        try {
            $fill = (& $script:Part.Complete @{ drives = @(($j | ConvertTo-Json -Depth 30), (Get-Content (Join-Path "$PSScriptRoot/fixtures/banner" 'smartctl-nvme-990.json') -Raw)) } ([pscustomobject]@{})).Fills.drives
        } finally { Set-StrictMode -Off }
        @($fill).Count | Should -Be 2
    }
}

Describe 'Banner fills across the shipped tools' {
    It 'fills each placeholder from exactly one tool' {
        $owners = @{}
        foreach ($file in Get-ChildItem "$PSScriptRoot/../Tools/*.json") {
            $rec = Get-Content $file -Raw | ConvertFrom-Json
            foreach ($fill in @($rec.PSObject.Properties['banner']?.Value.fills)) { if ($fill) { $owners[$fill] = @($owners[$fill]) + $rec.name | Where-Object { $_ } } }
        }
        foreach ($name in $owners.Keys) { @($owners[$name]).Count | Should -Be 1 -Because "$name is filled by $($owners[$name] -join ', ')" }
        $owners.Keys | Should -Contain 'drives'
        $owners.Keys | Should -Contain 'publicip'
    }
}
