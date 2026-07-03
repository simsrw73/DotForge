#Requires -Version 7.0

function Find-DFPackage {
    <#
    .SYNOPSIS
        Searches every installer catalog (scoop, winget, choco, npm, PyPI,
        crates.io, PSGallery) for a tool and returns a merged summary —
        description, installed status and source, per-catalog availability and
        versions, homepage, license, and cache age.
    .DESCRIPTION
        Cache-first for speed: answers come from local catalog caches instantly;
        stale or missing web-catalog entries are refreshed in the background so
        the NEXT query is current (use -Fresh to block on live data instead).

        Interactively, a confident single match renders a rich info card and
        ambiguous keyword searches render a compact table. When output is piped
        or redirected (or with -AsObject), raw DotForge.ToolInfo objects are
        emitted instead — pipeline-safe, no ANSI.
    .PARAMETER Query
        Command name or keywords. Multiple words may be passed unquoted:
        trifle static site generator
    .PARAMETER Source
        Restrict the search to these catalogs.
    .PARAMETER Fresh
        Block on live catalog fetches instead of serving cached data.
    .PARAMETER AsObject
        Emit DotForge.ToolInfo objects even at an interactive terminal.
        Use this when capturing: $x = trifle rg -AsObject (assignment looks
        interactive to pipeline-position detection, so the default would be
        rendered strings).
    .EXAMPLE
        trifle ripgrep
        Renders an info card: installed status, catalogs carrying it, versions.
    .EXAMPLE
        trifle json parser -Source scoop,winget
        Keyword search limited to two catalogs; renders a match table.
    .EXAMPLE
        Find-DFPackage ripgrep -AsObject | Select-Object Name, InstalledVia
        Pipeline-friendly object output.
    .OUTPUTS
        PSCustomObject (DotForge.ToolInfo) when piped or with -AsObject;
        rendered System.String lines otherwise.
    .NOTES
        Assigning without -AsObject captures rendered strings — pipeline
        position cannot distinguish assignment from a terminal.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromRemainingArguments)]
        [string[]]$Query,

        [ValidateSet('scoop', 'winget', 'choco', 'npm', 'pypi', 'crates', 'psgallery')]
        [string[]]$Source,

        [switch]$Fresh,

        [switch]$AsObject
    )

    $queryText = $Query -join ' '
    $normalized = (ConvertTo-DFCatalogQueryKey -Query $queryText).Normalized
    $providers = @(Get-DFCatalogProvider -Source $Source)

    # Fan out across catalogs (canonical order), then overlay installed state
    # from the cached unified snapshot (15-min TTL — avoids re-enumerating slow
    # sources like Get-Module -ListAvailable on every query). First runs can
    # spend a while on index builds and live fetches, so keep the user informed
    # via the progress stream (renders as a status line; never pollutes stdout).
    $progressId = 47
    try {
        $hits = [System.Collections.Generic.List[object]]::new()
        for ($i = 0; $i -lt $providers.Count; $i++) {
            $provider = $providers[$i]
            Write-Progress -Id $progressId -Activity 'trifle' `
                -Status "Searching $($provider.Name) catalog… (first run may build local indexes)" `
                -PercentComplete ([int](100 * $i / ($providers.Count + 1)))
            foreach ($hit in @(& $provider.Search $queryText $Fresh.IsPresent)) {
                if ($hit) { $hits.Add($hit) }
            }
        }

        Write-Progress -Id $progressId -Activity 'trifle' `
            -Status 'Reading installed packages…' `
            -PercentComplete ([int](100 * $providers.Count / ($providers.Count + 1)))
        $installedInfo = Get-DFCatalogInstalled
    } finally {
        Write-Progress -Id $progressId -Activity 'trifle' -Completed
    }
    $installedBySource = @{}
    foreach ($item in $installedInfo.Items) {
        if (-not $installedBySource.ContainsKey($item.Source)) { $installedBySource[$item.Source] = @{} }
        foreach ($key in @($item.Name, $item.PackageId)) {
            if ($key) { $installedBySource[$item.Source][([string]$key).ToLowerInvariant()] = $item.InstalledVersion }
        }
    }
    foreach ($hit in $hits) {
        $map = $installedBySource[$hit.Source]
        if (-not $map) { continue }
        foreach ($key in @($hit.Name, $hit.PackageId)) {
            $lookup = ([string]$key).ToLowerInvariant()
            if ($map.ContainsKey($lookup)) {
                $hit.Installed = $true
                $hit.InstalledVersion = $map[$lookup]
                break
            }
        }
    }

    Add-DFCatalogSeenQuery -Query $queryText

    # Merge per-catalog hits into one row per tool: identity-mapped hits
    # (Tools/*.json packages blocks) collapse under the DotForge tool name even
    # when catalogs name the package differently; the rest group by name.
    $dfToolNames = @{}
    foreach ($value in $installedInfo.IdentityMap.Values) { $dfToolNames[$value.ToLowerInvariant()] = $value }

    $resolveDFTool = {
        param($Hit)
        $id = $Hit.PackageId.ToLowerInvariant()
        $name = $installedInfo.IdentityMap["$($Hit.Source):$id"]
        if (-not $name -and $id.Contains('/')) {
            # scoop ids are bucket-qualified; the packages map holds bare names
            $name = $installedInfo.IdentityMap["$($Hit.Source):$(($id -split '/')[-1])"]
        }
        if (-not $name) {
            # No explicit mapping for this catalog, but the package shares a DF
            # tool's name — group it there so one tool never renders twice.
            $name = $dfToolNames[$Hit.Name.ToLowerInvariant()]
        }
        $name
    }

    $groups = [ordered]@{}
    $dfNames = @{}
    foreach ($hit in $hits) {
        $dfName = & $resolveDFTool $hit
        $key = $dfName ? "df:$dfName" : $hit.Name.ToLowerInvariant()
        if (-not $groups.Contains($key)) {
            $groups[$key] = [System.Collections.Generic.List[object]]::new()
            if ($dfName) { $dfNames[$key] = $dfName }
        }
        $groups[$key].Add($hit)
    }

    $merged = @(foreach ($entry in $groups.GetEnumerator()) {
        $sources = @($entry.Value)
        $dfTool = $dfNames[$entry.Key]
        $latest = [ordered]@{}
        foreach ($s in $sources) { if ($s.LatestVersion) { $latest[$s.Source] = $s.LatestVersion } }

        $installedSources = @($sources | Where-Object Installed)
        $matchKind = if ($sources.MatchKind -contains 'exact-id') { 'exact-id' }
                     elseif ($sources.MatchKind -contains 'exact-name') { 'exact-name' }
                     else { 'keyword' }

        New-DFToolInfo -Name ($dfTool ? $dfTool : $sources[0].Name) `
            -Description (@($sources.Description) -ne '' -ne $null | Select-Object -First 1) `
            -Installed:($installedSources.Count -gt 0) `
            -InstalledVia @($installedSources.Source) `
            -InstalledVersion (@($installedSources.InstalledVersion) | Select-Object -First 1) `
            -Sources $sources `
            -Latest $latest `
            -Homepage (@($sources.Homepage) -ne '' -ne $null | Select-Object -First 1) `
            -License (@($sources.License) -ne '' -ne $null | Select-Object -First 1) `
            -DFTool $dfTool `
            -MatchKind $matchKind `
            -CacheAge (@($sources.CacheAgeMinutes | Measure-Object -Maximum).Maximum)
    })

    # Best matches first: exact package-id, then exact name/moniker, then
    # keyword hits; installed tools win ties, then alphabetical.
    $matchRank = @{ 'exact-id' = 0; 'exact-name' = 1; 'keyword' = 2 }
    $merged = @($merged | Sort-Object `
        { $matchRank[$_.MatchKind] }, { -not $_.Installed }, Name)

    # PATH fallback: the command exists locally but no catalog claims it.
    if ($normalized -notmatch ' ') {
        $pathCommand = Get-Command -Name $normalized -ErrorAction Ignore | Select-Object -First 1
        if ($pathCommand) {
            foreach ($info in $merged) {
                if (-not $info.Installed -and $info.MatchKind -in 'exact-id', 'exact-name') {
                    $info.Installed = $true
                    $info.InstalledVia = @('PATH')
                    if ($pathCommand.Version) { $info.InstalledVersion = [string]$pathCommand.Version }
                }
            }
        }
    }

    if ($AsObject -or (Test-DFOutputPiped -Invocation $MyInvocation)) {
        return $merged
    }

    if ($merged.Count -eq 0) {
        return "No packages found matching '$queryText'."
    }

    $color = (-not $Env:NO_COLOR) -and $Host.UI.SupportsVirtualTerminal

    $confident = $merged.Count -eq 1 -and (
        $merged[0].Name -ieq $normalized -or
        @($merged[0].Sources | Where-Object { $_.PackageId -ieq $queryText }).Count -gt 0
    )
    if ($confident) {
        return Format-DFToolInfoCard -Info $merged[0] -Color $color
    }

    $width = 120
    try { if ($Host.UI.RawUI.WindowSize.Width -gt 0) { $width = $Host.UI.RawUI.WindowSize.Width } } catch {}
    Format-DFToolInfoTable -Infos $merged -Color $color -Width $width
}

Set-Alias -Name trifle -Value Find-DFPackage -Scope Global -Force
