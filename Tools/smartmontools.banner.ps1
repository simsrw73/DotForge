# Banner part for smartmontools: one health line per drive, read without admin
# rights (smartctl 7.5 on Windows reports health, wear, temperature and hours
# unelevated). Dot-sourced by Private/DFBanner.ps1; outputs the part object.
# See docs/superpowers/specs/2026-10-11-startup-banner-design.md.
#
# Life: NVMe 100 - percentage_used; a SATA SSD's wear attribute (177, 231 or
# 233) normalized value. A hard drive has none; unelevated smartctl doesn't
# report rotation_rate, so it is recognized by its spin attributes (3, 10).
# An alert (shown in red): a failed self-check, NVMe media errors, any
# reallocated/uncorrectable/pending/offline-uncorrectable sector (5, 187, 197,
# 198), or under 10% life.

$_smartLine = {
    param([string]$Json)
    try { $drive = $Json | ConvertFrom-Json -ErrorAction Stop } catch { return }
    if (-not $drive.PSObject.Properties['model_name'] -or -not $drive.PSObject.Properties['smart_status']) { return }
    $model = ($drive.model_name -replace '^(Samsung SSD|Samsung|WDC|Western Digital|Seagate|Crucial|KINGSTON|INTEL|SanDisk|TOSHIBA|Micron)\s+', '').Trim()
    $attributes = @{}
    foreach ($attribute in @($drive.PSObject.Properties['ata_smart_attributes']?.Value.table)) {
        if ($attribute) { $attributes[[int]$attribute.id] = $attribute }
    }
    $nvme = $drive.PSObject.Properties['nvme_smart_health_information_log']?.Value
    $facts = [System.Collections.Generic.List[string]]::new()
    $alerts = [System.Collections.Generic.List[string]]::new()
    if (-not $drive.smart_status.passed) { $alerts.Add('self-check FAILED') }

    $life = $null
    if ($nvme) {
        $facts.Add('NVMe')
        $life = 100 - [int]$nvme.percentage_used
        if ([long]$nvme.media_errors -gt 0) { $alerts.Add("$($nvme.media_errors) media errors") }
    } elseif ($attributes.ContainsKey(3) -or $attributes.ContainsKey(10)) {
        $facts.Add('HDD')
    } else {
        $facts.Add('SSD')
        foreach ($id in 177, 231, 233) { if ($attributes.ContainsKey($id)) { $life = [int]$attributes[$id].value; break } }
    }
    if ($null -ne $life) { $facts.Add("$life% life") }

    $badNames = @{ 5 = 'reallocated sectors'; 187 = 'uncorrectable errors'; 197 = 'pending sectors'; 198 = 'offline uncorrectable sectors' }
    $bad = @(foreach ($id in 5, 187, 197, 198) {
        if ($attributes.ContainsKey($id) -and [long]$attributes[$id].raw.value -gt 0) { "$($attributes[$id].raw.value) $($badNames[$id])" }
    })
    if ($facts[0] -eq 'HDD' -and -not $bad) { $facts.Add('no bad sectors') }
    foreach ($item in $bad) { $alerts.Add($item) }
    if ($null -ne $life -and $life -lt 10) { $alerts.Add('under 10% life') }

    $temperature = $drive.PSObject.Properties['temperature']?.Value.current
    if ($temperature) { $facts.Add("$temperature°C") }
    $hours = $drive.PSObject.Properties['power_on_time']?.Value.hours
    if ($hours) { $facts.Add(('{0:N0} h' -f [long]$hours)) }
    if ($nvme -and $nvme.data_units_written) { $facts.Add(('{0:N0} TB written' -f ([double]$nvme.data_units_written * 512000 / 1e12))) }
    foreach ($alert in $alerts) { $facts.Add($alert) }
    [pscustomobject]@{ Model = $model; Value = $facts -join ' · '; Alert = [bool]$alerts.Count }
}

[pscustomobject]@{
    Work = {
        param($Context)
        @(@{ Name = 'drives'; ArgumentList = @(); ScriptBlock = {
            # Every drive at once: each smartctl is its own process.
            $devices = foreach ($line in @(smartctl --scan 2>$null)) {
                if ($line -match '^(\S+)\s+-d\s+(\S+)') { , @($Matches[1], $Matches[2]) }
            }
            $processes = foreach ($device in $devices) {
                $info = [Diagnostics.ProcessStartInfo]::new('smartctl', "-j -a -d $($device[1]) $($device[0])")
                $info.RedirectStandardOutput = $true
                $info.UseShellExecute = $false
                $info.CreateNoWindow = $true
                [Diagnostics.Process]::Start($info)
            }
            foreach ($process in $processes) { $process.StandardOutput.ReadToEnd(); $process.WaitForExit() }
        } })
    }

    Complete = {
        param($Results, $Context)
        $lines = @(foreach ($json in @($Results['drives'])) { if ($json) { & $_smartLine $json } })
        $width = ($lines | ForEach-Object { $_.Model.Length } | Measure-Object -Maximum).Maximum
        [pscustomobject]@{
            Body  = $null
            Fills = @{ drives = @(foreach ($line in $lines) {
                [pscustomobject]@{ Key = 'Disk ' + $line.Model.PadRight($width); Value = $line.Value; Alert = $line.Alert }
            }) }
        }
    }.GetNewClosure()
}
