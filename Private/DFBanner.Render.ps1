#Requires -Version 7.2

# Pure rendering for the startup banner (Private/DFBanner.ps1).
# See docs/superpowers/specs/2026-10-11-startup-banner-design.md.

function ConvertTo-DFAnsiColor {
    <#
    .SYNOPSIS
        A fastfetch color (#rrggbb, or ANSI codes like "35") as an escape prefix; '' for anything else.
    .PARAMETER Color
        The color.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Color)
    $e = [char]27
    if ($Color -match '^#([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})$') {
        return "$e[38;2;$([Convert]::ToInt32($Matches[1], 16));$([Convert]::ToInt32($Matches[2], 16));$([Convert]::ToInt32($Matches[3], 16))m"
    }
    if ($Color -match '^\d+(;\d+)*$') { return "$e[${Color}m" }
    # fastfetch's color names: the 8 standard colors, their bright_ forms, and default.
    $names = @{ black = 30; red = 31; green = 32; yellow = 33; blue = 34; magenta = 35; cyan = 36; white = 37; default = 39 }
    $name = "$Color".ToLowerInvariant()
    if ($names.ContainsKey($name)) { return "$e[$($names[$name])m" }
    if ($name -match '^bright_(\w+)$' -and $names.ContainsKey($Matches[1]) -and $Matches[1] -ne 'default') { return "$e[$($names[$Matches[1]] + 60)m" }
    ''
}

function New-DFBannerStyle {
    <#
    .SYNOPSIS
        The banner's colors and separator, as escape prefixes.
    .PARAMETER KeyColor
        Key color (fastfetch's display.color.keys).
    .PARAMETER OutputColor
        Value color (display.color.output).
    .PARAMETER Separator
        Text between key and value (display.separator).
    .OUTPUTS
        pscustomobject: Key, Output, Alert, Separator.
    #>
    [CmdletBinding()]
    param([string]$KeyColor, [string]$OutputColor, [string]$Separator = '  ')
    [pscustomobject]@{
        # Bold colored keys, as fastfetch prints them; no codes at all without a color.
        Key       = $(if ($keyColor = ConvertTo-DFAnsiColor $KeyColor) { "$([char]27)[1m$keyColor" } else { '' })
        Output    = ConvertTo-DFAnsiColor $OutputColor
        # catppuccin red: a failing drive line.
        Alert     = ConvertTo-DFAnsiColor '#f38ba8'
        Separator = $Separator
    }
}

function Format-DFBannerLine {
    <#
    .SYNOPSIS
        One banner line: colored key, separator, colored value.
    .PARAMETER Key
        The key.
    .PARAMETER Value
        The value.
    .PARAMETER Style
        New-DFBannerStyle result.
    .PARAMETER Alert
        Color the value with the alert color.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string]$Key, [AllowEmptyString()][string]$Value, [Parameter(Mandatory)]$Style, [switch]$Alert)
    $reset = "$([char]27)[0m"
    $paint = { param($prefix, $text) if ($prefix) { "$prefix$text$reset" } else { $text } }
    $valueColor = if ($Alert) { $Style.Alert } else { $Style.Output }
    "$(& $paint $Style.Key $Key)$($Style.Separator)$(& $paint $valueColor $Value)"
}

function Merge-DFBannerBody {
    <#
    .SYNOPSIS
        Replaces each @DF:<name>@ placeholder line in the body with that name's fill lines, or removes it.
    .DESCRIPTION
        A fill item has Key, Value and Alert; a $null Key takes the
        placeholder line's own key (its text before the separator, colors
        stripped). A name with no fill removes its line, so placeholder text
        never shows.
    .PARAMETER Body
        The body lines (fastfetch's output).
    .PARAMETER Fills
        Name -> fill items.
    .PARAMETER Style
        New-DFBannerStyle result.
    .OUTPUTS
        System.String[].
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowEmptyCollection()][string[]]$Body, [Parameter(Mandatory)][hashtable]$Fills, [Parameter(Mandatory)]$Style)
    $ansi = "$([char]27)\[[0-9;]*m"
    foreach ($line in $Body) {
        if ($line -notmatch '@DF:([\w-]+)@') { $line; continue }
        $name = $Matches[1]
        if (-not $Fills.ContainsKey($name)) { continue }
        $plain = $line -replace $ansi, ''
        $separatorAt = $plain.IndexOf($Style.Separator)
        $ownKey = if ($separatorAt -gt 0) { $plain.Substring(0, $separatorAt) } else { '' }
        foreach ($item in @($Fills[$name])) {
            $key = if ($null -ne $item.Key) { $item.Key } else { $ownKey }
            Format-DFBannerLine -Key $key -Value $item.Value -Style $Style -Alert:([bool]$item.Alert)
        }
    }
}

function Write-DFBannerLines {
    <#
    .SYNOPSIS
        Prints banner lines one at a time, like a printer.
    .PARAMETER Lines
        The lines.
    .PARAMETER DelayMs
        Pause between lines; 0 prints at once.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][string[]]$Lines, [int]$DelayMs)
    # A console that isn't UTF-8 shows the banner's ·, ° and … as garbage.
    $plain = [Console]::OutputEncoding.CodePage -ne 65001
    $first = $true
    foreach ($line in $Lines) {
        if (-not $first -and $DelayMs -gt 0) { Start-Sleep -Milliseconds $DelayMs }
        if ($plain) { $line = $line.Replace('·', '-').Replace('°', '').Replace('…', '...') }
        [Console]::WriteLine($line)
        $first = $false
    }
}
