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

function Format-DFToolDetailCount {
    <#
    .SYNOPSIS
        Formats a count as a compact '998' / '12.3k' / '1.2M' string.
    .PARAMETER Count
        The raw count.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [long]$Count
    )

    if ($Count -lt 1000) { return [string]$Count }
    $k = [math]::Round($Count / 1000, 1)
    if ($k -lt 1000) { return "${k}k" }
    "$([math]::Round($Count / 1000000, 1))M"
}

function Format-DFToolDetailCard {
    <#
    .SYNOPSIS
        Renders a DotForge.ToolInfo WITH populated Details/GitHub as the full
        detail card: the basic card followed by Publisher / Deps / Tags /
        Downloads / Install / Notes / GitHub sections and an optional
        more-matches footer. Sections without data are omitted.
    .PARAMETER Info
        The merged tool info (Details: ordered dict source → detail, values
        may be $null for failed fetches; GitHub: DotForge.RepoInfo or $null).
    .PARAMETER Color
        When false, plain text.
    .PARAMETER MoreMatches
        Count of suppressed keyword matches (renders the -All footer when > 0).
    .PARAMETER QueryText
        The original query, for the footer's suggested command.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        $Info,

        [Parameter(Mandatory)]
        [bool]$Color,

        [int]$MoreMatches = 0,

        [string]$QueryText = ''
    )

    $faint = $Color ? "`e[2m" : ''
    $reset = $Color ? "`e[0m" : ''
    $label = { param($text) ($Color ? "`e[2m" : '') + $text.PadRight(9) + ($Color ? "`e[0m" : '') + '  ' }
    $indent = ' ' * 11

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.AddRange([string[]](Format-DFToolInfoCard -Info $Info -Color $Color))

    $details = @()
    $failed = @()
    if ($Info.Details) {
        foreach ($key in $Info.Details.Keys) {
            if ($null -ne $Info.Details[$key]) { $details += $Info.Details[$key] }
            else { $failed += $key }
        }
    }

    $publisher = @($details | ForEach-Object { $_.Publisher } | Where-Object { $_ }) | Select-Object -First 1
    if (-not $publisher) {
        $publisher = @($details | ForEach-Object { @($_.Maintainers) -join ', ' } | Where-Object { $_ }) | Select-Object -First 1
    }
    if ($publisher) { $lines.Add((& $label 'Publisher') + $publisher) }

    $first = $true
    foreach ($d in $details) {
        $deps = @($d.Dependencies) -ne '' -ne $null
        if (-not $deps) { continue }
        $shown = @($deps | Select-Object -First 8)
        $suffix = $deps.Count -gt 8 ? " +$($deps.Count - 8) more" : ''
        $prefix = $first ? (& $label 'Deps') : $indent
        $lines.Add("$prefix$($d.Source): $($shown -join ', ')$suffix")
        $first = $false
    }

    $tags = @($details | ForEach-Object { @($_.Tags) } | Where-Object { $_ } | Select-Object -Unique -First 10)
    if ($tags) { $lines.Add((& $label 'Tags') + ($tags -join ' · ')) }

    $downloads = @($details | Where-Object { $_.Downloads } | ForEach-Object {
        "$($_.Source) $(Format-DFToolDetailCount -Count $_.Downloads)"
    })
    if ($downloads) { $lines.Add((& $label 'Downloads') + ($downloads -join ' · ')) }

    $hints = @($details | ForEach-Object { $_.InstallHint } | Where-Object { $_ })
    for ($i = 0; $i -lt $hints.Count; $i++) {
        $lines.Add(($i -eq 0 ? (& $label 'Install') : $indent) + $hints[$i])
    }

    $notes = @($details | ForEach-Object { $_.Notes } | Where-Object { $_ }) | Select-Object -First 1
    if ($notes) { $lines.Add((& $label 'Notes') + $notes) }

    if ($Info.Category) {
        $cat = $Info.Category.Entry
        $catParts = [System.Collections.Generic.List[string]]::new()
        $catParts.AddRange([string[]]@($cat.function))
        if ($cat.worksWith) { $catParts.Add("works with: $(@($cat.worksWith) -join ', ')") }
        $lines.Add((& $label 'Category') + ($catParts -join ' · '))

        $related = @($Info.Category.Related)
        if ($related) { $lines.Add((& $label 'Related') + ($related -join ' · ')) }

        if ($cat.alternativeTo) { $lines.Add((& $label 'Alt to') + (@($cat.alternativeTo) -join ', ')) }
    }

    if ($Info.GitHub) {
        $gh = $Info.GitHub
        $parts = [System.Collections.Generic.List[string]]::new()
        $parts.Add("★ $(Format-DFToolDetailCount -Count $gh.Stars)")
        if ($gh.PushedAt) { $parts.Add("updated $($gh.PushedAt.ToString('yyyy-MM-dd'))") }
        if ($gh.LatestRelease) {
            $when = $gh.LatestReleaseAt ? " ($($gh.LatestReleaseAt.ToString('yyyy-MM-dd')))" : ''
            $parts.Add("release $($gh.LatestRelease)$when")
        }
        $parts.Add("$(Format-DFToolDetailCount -Count $gh.OpenIssues) issues")
        if ($gh.Archived) { $parts.Add('ARCHIVED') }
        $lines.Add((& $label 'GitHub') + ($parts -join ' · '))
        if ($gh.Description) { $lines.Add($indent + "$faint$($gh.Description)$reset") }
    }

    if ($failed) {
        $lines.Add("$faint(details unavailable: $($failed -join ', '))$reset")
    }

    if ($MoreMatches -gt 0) {
        $lines.Add("$faint+ $MoreMatches more matches — trifle $QueryText -All$reset")
    }

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
    $idStrings = @($Infos | ForEach-Object {
        $s = @($_.Sources) | Select-Object -First 1
        $s ? "$($s.Source):$($s.PackageId)" : ''
    })
    $idW = [math]::Min(34, [math]::Max(2, (@($idStrings) + 'Id' | Measure-Object Length -Maximum).Maximum))
    $srcStrings = @($Infos | ForEach-Object { @($_.Sources.Source) -join ',' })
    $srcW = [math]::Min(30, [math]::Max(7, (@($srcStrings) + 'Sources' | Measure-Object Length -Maximum).Maximum))
    $verW = 12

    $rows = [System.Collections.Generic.List[string]]::new()
    $rows.Add("$faint$('Name'.PadRight($nameW))  In  $('Sources'.PadRight($srcW))  $('Id'.PadRight($idW))  $('Latest'.PadRight($verW))  Description$reset")

    for ($i = 0; $i -lt $Infos.Count; $i++) {
        $info = $Infos[$i]
        $name = $info.Name.Length -gt $nameW ? $info.Name.Substring(0, $nameW) : $info.Name.PadRight($nameW)
        $inst = $info.Installed ? "$green✓$reset " : '  '
        $src = $srcStrings[$i]
        $src = $src.Length -gt $srcW ? $src.Substring(0, $srcW) : $src.PadRight($srcW)
        $id = $idStrings[$i]
        $id = $id.Length -gt $idW ? $id.Substring(0, $idW) : $id.PadRight($idW)
        $latest = ''
        if ($info.Latest -and $info.Latest.Count -gt 0) {
            $latest = [string]@($info.Latest.Values)[0]
        }
        $latest = $latest.Length -gt $verW ? $latest.Substring(0, $verW) : $latest.PadRight($verW)

        $row = "$name  $inst  $src  $id  $latest  $($info.Description)"
        if ($row.Length -gt $Width) { $row = $row.Substring(0, $Width) }
        $rows.Add($row)
    }

    $rows
}
