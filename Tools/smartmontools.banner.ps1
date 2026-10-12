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
    # Every optional field is read through PSObject.Properties: a user's
    # Set-StrictMode reaches this code, and drives report different fields.
    $field = { param($Object, [string]$Name) if ($Object -is [psobject] -and $Object.PSObject.Properties[$Name]) { $Object.PSObject.Properties[$Name].Value } }
    $modelName = & $field $drive 'model_name'
    $status = & $field $drive 'smart_status'
    if (-not $modelName -or $null -eq $status) { return }
    $model = ("$modelName" -replace '^(Samsung SSD|Samsung|WDC|Western Digital|Seagate|Crucial|KINGSTON|INTEL|SanDisk|TOSHIBA|Micron)\s+', '').Trim()
    $attributes = @{}
    foreach ($attribute in @(& $field (& $field $drive 'ata_smart_attributes') 'table')) {
        $id = & $field $attribute 'id'
        if ($null -ne $id) { $attributes[[int]$id] = $attribute }
    }
    $nvme = & $field $drive 'nvme_smart_health_information_log'
    $facts = [System.Collections.Generic.List[string]]::new()
    $alerts = [System.Collections.Generic.List[string]]::new()
    if ((& $field $status 'passed') -eq $false) { $alerts.Add('self-check FAILED') }

    $life = $null
    if ($nvme) {
        $facts.Add('NVMe')
        $used = & $field $nvme 'percentage_used'
        if ($null -ne $used) { $life = 100 - [int]$used }
        $mediaErrors = & $field $nvme 'media_errors'
        if ([long]$mediaErrors -gt 0) { $alerts.Add("$mediaErrors media errors") }
    } elseif ($attributes.ContainsKey(3) -or $attributes.ContainsKey(10)) {
        $facts.Add('HDD')
    } else {
        $facts.Add('SSD')
        foreach ($id in 177, 231, 233) { if ($attributes.ContainsKey($id)) { $life = & $field $attributes[$id] 'value'; break } }
    }
    # A vendor scale that isn't 0-100 (some start at 200 or 253) says nothing as a percentage.
    if ($null -ne $life -and ([int]$life -lt 0 -or [int]$life -gt 100)) { $life = $null }
    if ($null -ne $life) { $facts.Add("$([int]$life)% life") }

    $badNames = @{ 5 = 'reallocated sectors'; 187 = 'uncorrectable errors'; 197 = 'pending sectors'; 198 = 'offline uncorrectable sectors' }
    $bad = @(foreach ($id in 5, 187, 197, 198) {
        if (-not $attributes.ContainsKey($id)) { continue }
        $count = & $field (& $field $attributes[$id] 'raw') 'value'
        if ([long]$count -gt 0) { "$count $($badNames[$id])" }
    })
    if ($facts[0] -eq 'HDD' -and -not $bad) { $facts.Add('no bad sectors') }
    foreach ($item in $bad) { $alerts.Add($item) }
    if ($null -ne $life -and [int]$life -lt 10) { $alerts.Add('under 10% life') }

    $temperature = & $field (& $field $drive 'temperature') 'current'
    if ($temperature) { $facts.Add("$temperature°C") }
    $hours = & $field (& $field $drive 'power_on_time') 'hours'
    if ($hours) { $facts.Add(('{0:N0} h' -f [long]$hours)) }
    $written = & $field $nvme 'data_units_written'
    if ($written) { $facts.Add(('{0:N0} TB written' -f ([double]$written * 512000 / 1e12))) }
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
