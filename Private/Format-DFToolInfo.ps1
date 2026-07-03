#Requires -Version 7.0

# Pure renderers for DotForge.ToolInfo — same "pure function + [bool]$Color"
# pattern as Format-DFCliHelpText. Find-DFPackage decides card vs table vs raw
# objects; these functions only turn objects into strings.

function Format-DFToolInfoAge {
    <#
    .SYNOPSIS
        Formats a cache age in minutes as a compact '5m' / '3h' / '2d' string.
    .PARAMETER Minutes
        Age in minutes.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [int]$Minutes
    )

    if ($Minutes -lt 1) { return '<1m' }
    if ($Minutes -lt 60) { return "${Minutes}m" }
    if ($Minutes -lt 1440) { return "$([math]::Round($Minutes / 60))h" }
    "$([math]::Round($Minutes / 1440))d"
}

function Format-DFToolInfoCard {
    <#
    .SYNOPSIS
        Renders a single DotForge.ToolInfo as a rich info card (string array).
    .PARAMETER Info
        The merged tool info object.
    .PARAMETER Color
        When false, plain text (NO_COLOR / non-VT passthrough).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        $Info,

        [Parameter(Mandatory)]
        [bool]$Color
    )

    $bold   = $Color ? "`e[1;36m" : ''
    $faint  = $Color ? "`e[2m"    : ''
    $green  = $Color ? "`e[32m"   : ''
    $reset  = $Color ? "`e[0m"    : ''

    $label = { param($text) "$faint$($text.PadRight(9))$reset  " }

    $lines = [System.Collections.Generic.List[string]]::new()

    $title = "$bold$($Info.Name)$reset"
    if ($Info.Description) { $title += " — $($Info.Description)" }
    $lines.Add($title)
    $lines.Add([string]('─' * 60))

    if ($Info.Installed) {
        $version = $Info.InstalledVersion ? " ($($Info.InstalledVersion))" : ''
        $lines.Add((& $label 'Installed') + "$green✓$reset $($Info.InstalledVia -join ', ')$version")
    } else {
        $lines.Add((& $label 'Installed') + '✗ not installed')
    }

    $sources = @($Info.Sources)
    if ($sources) {
        $srcW = ($sources.Source | Measure-Object Length -Maximum).Maximum
        $idW  = ($sources.PackageId | Measure-Object Length -Maximum).Maximum
        $indent = ' ' * 11
        for ($i = 0; $i -lt $sources.Count; $i++) {
            $s = $sources[$i]
            $prefix = $i -eq 0 ? (& $label 'Sources') : $indent
            $version = $s.LatestVersion ? "$green$($s.LatestVersion)$reset" : ''
            $lines.Add("$prefix$($s.Source.PadRight($srcW))  $($s.PackageId.PadRight($idW))  $version")
        }
    }

    if ($Info.Homepage) { $lines.Add((& $label 'Homepage') + $Info.Homepage) }
    if ($Info.License)  { $lines.Add((& $label 'License') + $Info.License) }

    $updated = @($sources | Where-Object PublishedAt | ForEach-Object {
        "$($_.Source) $($_.PublishedAt.ToString('yyyy-MM-dd'))"
    })
    if ($updated) { $lines.Add((& $label 'Updated') + ($updated -join ' · ')) }

    $ages = @($sources | ForEach-Object {
        "$($_.Source) $(Format-DFToolInfoAge -Minutes $_.CacheAgeMinutes)"
    })
    if ($ages) { $lines.Add((& $label 'Cache') + ($ages -join ' · ')) }

    $lines
}

function Format-DFToolInfoTable {
    <#
    .SYNOPSIS
        Renders multiple DotForge.ToolInfo objects as a compact match table
        (string array), width-truncated.
    .PARAMETER Infos
        The merged tool info objects.
    .PARAMETER Color
        When false, plain text.
    .PARAMETER Width
        Maximum row width (defaults to 120).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Infos,

        [Parameter(Mandatory)]
        [bool]$Color,

        [int]$Width = 120
    )

    $faint = $Color ? "`e[2m" : ''
    $green = $Color ? "`e[32m" : ''
    $reset = $Color ? "`e[0m" : ''

    $nameW = [math]::Min(25, [math]::Max(4, (@($Infos.Name) + 'Name' | Measure-Object Length -Maximum).Maximum))
    $srcStrings = @($Infos | ForEach-Object { @($_.Sources.Source) -join ',' })
    $srcW = [math]::Min(30, [math]::Max(7, (@($srcStrings) + 'Sources' | Measure-Object Length -Maximum).Maximum))
    $verW = 12

    $rows = [System.Collections.Generic.List[string]]::new()
    $rows.Add("$faint$('Name'.PadRight($nameW))  In  $('Sources'.PadRight($srcW))  $('Latest'.PadRight($verW))  Description$reset")

    for ($i = 0; $i -lt $Infos.Count; $i++) {
        $info = $Infos[$i]
        $name = $info.Name.Length -gt $nameW ? $info.Name.Substring(0, $nameW) : $info.Name.PadRight($nameW)
        $inst = $info.Installed ? "$green✓$reset " : '  '
        $src = $srcStrings[$i]
        $src = $src.Length -gt $srcW ? $src.Substring(0, $srcW) : $src.PadRight($srcW)
        $latest = ''
        if ($info.Latest -and $info.Latest.Count -gt 0) {
            $latest = [string]@($info.Latest.Values)[0]
        }
        $latest = $latest.Length -gt $verW ? $latest.Substring(0, $verW) : $latest.PadRight($verW)

        $row = "$name  $inst  $src  $latest  $($info.Description)"
        if ($row.Length -gt $Width) { $row = $row.Substring(0, $Width) }
        $rows.Add($row)
    }

    $rows
}
