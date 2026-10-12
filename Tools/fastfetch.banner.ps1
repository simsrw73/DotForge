# Banner part for fastfetch: the startup banner's body, its colors, and the public IP.
# Dot-sourced by Private/DFBanner.ps1 (and by Tools/fastfetch.ps1 for its colors);
# outputs the part object. See docs/superpowers/specs/2026-10-11-startup-banner-design.md.
#
# The public IP comes from https://api.ipify.org with a 2 s limit, in the
# background; fastfetch's own publicip module would block the whole banner.

# Captured now: inside the script blocks below, $PSScriptRoot isn't this file.
$_ffSeeded = Join-Path $PSScriptRoot 'fastfetch' 'config.jsonc'
$_ffConfigPath = {
    param($Tool)
    $raw = $Tool.settings.PSObject.Properties['configPath']?.Value ?? '${XDG_CONFIG_HOME}/fastfetch/config.jsonc'
    ConvertTo-DFPath (Expand-DFXdgPath $raw)
}

[pscustomobject]@{
    Style = {
        param($Context)
        $path = & $_ffConfigPath $Context.Tool
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $path = $_ffSeeded }
        try {
            $display = (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -ErrorAction Stop).display
            $separator = $display.PSObject.Properties['separator']?.Value
            @{
                KeyColor    = "$($display.color.keys)"
                OutputColor = "$($display.color.output)"
                Separator   = $(if ($separator) { $separator } else { '  ' })
            }
        } catch { @{} }
    }.GetNewClosure()

    # The placeholders the config in use has, so no work is started for lines it doesn't show.
    Uses = {
        param($Context)
        $path = & $_ffConfigPath $Context.Tool
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @() }
        @(Select-String -LiteralPath $path -Pattern '@DF:([\w-]+)@' -AllMatches | ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    }.GetNewClosure()

    Work = {
        param($Context)
        $path = & $_ffConfigPath $Context.Tool
        $configArgs = if (Test-Path -LiteralPath $path -PathType Leaf) { @('--config', $path) } else { @() }
        @(
            @{ Name = 'fastfetch'; ScriptBlock = { param($a) & fastfetch.exe @a --pipe false 2>$null }; ArgumentList = @(, $configArgs) }
            @{ Name = 'publicip'; ScriptBlock = { "$(Invoke-RestMethod 'https://api.ipify.org' -TimeoutSec 2)".Trim() }; ArgumentList = @() }
        )
    }.GetNewClosure()

    Complete = {
        param($Results, $Context)
        $ip = "$(@($Results['publicip'])[0])"
        [pscustomobject]@{
            Body  = if ($Results.ContainsKey('fastfetch')) { @($Results['fastfetch'] | ForEach-Object { "$_" }) } else { $null }
            Fills = @{ publicip = @(if ($ip -match '^[0-9a-fA-F:.]{3,45}$') { [pscustomobject]@{ Key = $null; Value = $ip; Alert = $false } }) }
        }
    }
}
