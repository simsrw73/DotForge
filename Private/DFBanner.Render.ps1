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
        Key       = ConvertTo-DFAnsiColor $KeyColor
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
    $first = $true
    foreach ($line in $Lines) {
        if (-not $first -and $DelayMs -gt 0) { Start-Sleep -Milliseconds $DelayMs }
        [Console]::WriteLine($line)
        $first = $false
    }
}
