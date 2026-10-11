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
        # Resolved here, through PATH only: started by bare name, smartctl would
        # also be looked for in the current folder first.
        $smartctl = (Get-Command smartctl.exe -CommandType Application -ErrorAction Ignore | Select-Object -First 1).Source
        if (-not $smartctl) { return @() }
        # Partial: the drives that answered in time are shown even while another is still being read.
        @(@{ Name = 'drives'; Partial = $true; ArgumentList = @($smartctl, 4000); ScriptBlock = {
            param([string]$Smartctl, [int]$TimeoutMs)
            $devices = @(foreach ($line in @(& $Smartctl --scan 2>$null)) {
                if ($line -match '^(\S+)\s+-d\s+(\S+)') { [pscustomobject]@{ Device = $Matches[1]; Type = $Matches[2] } }
            })
            [pscustomobject]@{ Kind = 'devices'; Devices = [string[]]@($devices.Device) }
            # Every drive at once, each its own process; each is output as it answers.
            $running = [System.Collections.Generic.List[object]]::new()
            foreach ($device in $devices) {
                $info = [Diagnostics.ProcessStartInfo]::new($Smartctl, "-j -a -d $($device.Type) $($device.Device)")
                $info.RedirectStandardOutput = $true
                $info.RedirectStandardError = $true
                $info.UseShellExecute = $false
                $info.CreateNoWindow = $true
                try {
                    $process = [Diagnostics.Process]::Start($info)
                    $running.Add([pscustomobject]@{ Device = $device.Device; Process = $process
                        Out = $process.StandardOutput.ReadToEndAsync(); Err = $process.StandardError.ReadToEndAsync() })
                } catch { [pscustomobject]@{ Kind = 'drive'; Device = $device.Device; Json = $null } }
            }
            $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
            while ($running.Count) {
                foreach ($entry in @($running)) {
                    $timedOut = [DateTime]::UtcNow -ge $deadline
                    if (-not $entry.Process.HasExited -and -not $timedOut) { continue }
                    $json = $null
                    if ($entry.Process.HasExited) { $json = $entry.Out.GetAwaiter().GetResult() }
                    else { try { $entry.Process.Kill($true) } catch { } }   # a hung drive: never leave it running
                    [pscustomobject]@{ Kind = 'drive'; Device = $entry.Device; Json = $json }
                    $entry.Process.Dispose()
                    $null = $running.Remove($entry)
                }
                if ($running.Count) { Start-Sleep -Milliseconds 20 }
            }
        } })
    }

    Complete = {
        param($Results, $Context)
        $items = @($Results['drives'])
        $devices = @($items | Where-Object { $_ -isnot [string] -and $_.Kind -eq 'devices' } | ForEach-Object Devices)
        $answered = @{}
        $lines = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $items) {
            # A plain JSON string is a drive with no device name (as recorded in tests).
            $json = if ($item -is [string]) { $item } elseif ($item.Kind -eq 'drive') { $item.Json } else { continue }
            if ($item -isnot [string]) { $answered[$item.Device] = $true }
            if (-not $json) { continue }
            try { $line = & $_smartLine $json } catch { $line = $null }
            if ($line) { $lines.Add($line) }
        }
        # A drive that didn't answer is named, not hidden behind an old healthy value.
        foreach ($device in $devices) {
            $missing = -not $answered.ContainsKey($device) -or -not @($items | Where-Object { $_ -isnot [string] -and $_.Kind -eq 'drive' -and $_.Device -eq $device -and $_.Json })
            if ($missing) { $lines.Add([pscustomobject]@{ Model = $device; Value = 'no answer yet'; Alert = $false }) }
        }
        $width = ($lines | ForEach-Object { $_.Model.Length } | Measure-Object -Maximum).Maximum
        [pscustomobject]@{
            Body  = $null
            Fills = @{ drives = @(foreach ($line in $lines) {
                [pscustomobject]@{ Key = 'Disk ' + $line.Model.PadRight($width); Value = $line.Value; Alert = $line.Alert }
            }) }
        }
    }.GetNewClosure()
}
