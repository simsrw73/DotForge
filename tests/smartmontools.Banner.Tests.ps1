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
