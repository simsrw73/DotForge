#Requires -Version 7.0

function Select-DFPackage {
    <#
    .SYNOPSIS
        Fuzzy-browse packages with fzf. With a query: searches every catalog
        (like trifle) and previews each result's info card; Enter renders the
        full detail card. Without a query: browses all locally cached packages.
    .DESCRIPTION
        Query mode pre-renders each result's basic info card to a temp file so
        the fzf preview is instant — no subprocess module loads, no network
        while scrolling. The selection re-enters Find-DFPackage via its
        qualified source:packageId, which fetches full per-catalog details.

        Browse mode (no query) reads only local caches (scoop/winget indexes,
        cached web queries, the installed snapshot) so the list opens
        instantly — run Update-DFPackageCache (or any first trifle query) to
        populate it.
    .PARAMETER Query
        Search terms. When present, the list is live search results with a
        detail-card pipeline; when absent, the local-cache browser.
    .PARAMETER Categories
        Browse the full taxonomy vocabulary (every function/works-with value,
        live tool counts); Enter drills into the picked facet.
    .PARAMETER Category
        Search this specific function value directly — same preview/selection
        flow as -Query.
    .PARAMETER WorksWith
        Search this specific works-with value directly — same preview/selection
        flow as -Query. Set internally when -Categories recurses into a
        picked works-with row; also usable directly.
    .PARAMETER Source
        Restrict to packages known to these catalogs.
    .PARAMETER Readme
        After selection, also fetch and page the package readme.
    .PARAMETER GitInfo
        After selection, include GitHub stars/release/activity on the card.
    .EXAMPLE
        ftrifle zed
        Search all catalogs for 'zed', preview cards while scrolling, Enter
        shows the full detail card.
    .EXAMPLE
        ftrifle
        Browse all locally known packages; Enter renders the info card.
    .EXAMPLE
        ftrifle -Categories
        Pick a category or works-with value from the full vocabulary; Enter drills
        into that facet's tools with the same preview/selection flow as a query.
    .OUTPUTS
        None — the selection is rendered via Find-DFPackage.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromRemainingArguments)]
        [string[]]$Query,

        [switch]$Categories,

        [string]$Category,

        [string]$WorksWith,

        [ValidateSet('scoop', 'winget', 'choco', 'npm', 'pypi', 'crates', 'psgallery')]
        [string[]]$Source,

        [switch]$Readme,

        [switch]$GitInfo
    )

    if ($Categories) {
        $db = Get-DFCategoryDb
        if (-not $db.Raw) {
            Write-Warning 'DotForge: category database unavailable — run Update-DFCategoryDb.'
            return
        }
        $catLines = @($db.Raw.taxonomy.function | Sort-Object | ForEach-Object {
            "$_`t$(@($db.FacetIndex["function:$_"]).Count) tools`tfunction"
        })
        $wwLines = @($db.Raw.taxonomy.worksWith | Sort-Object | ForEach-Object {
            "$_`t$(@($db.FacetIndex["worksWith:$_"]).Count) tools`tworksWith"
        })
        $pickLines = @($catLines) + @('— browse by works-with —') + @($wwLines)

        $picked = Invoke-DFPicker -List { $pickLines }.GetNewClosure() `
            -Header 'Select a category or works-with facet' `
            -Delimiter "`t" -WithNth '1,2'
        if (-not $picked -or $picked -like '— browse by works-with —*') { return }

        $parts = $picked -split "`t"
        $facetArgs = ($parts[2] -eq 'worksWith') ? @{ WorksWith = $parts[0] } : @{ Category = $parts[0] }
        if ($Source) { $facetArgs.Source = $Source }
        Select-DFPackage @facetArgs -Readme:$Readme -GitInfo:$GitInfo
        return
    }

    if ($Query -or $Category -or $WorksWith) {
        $findArgs = if ($Category) { @{ Category = $Category; AsObject = $true } }
            elseif ($WorksWith) { @{ WorksWith = $WorksWith; AsObject = $true } }
            else { @{ Query = $Query; AsObject = $true } }
        if ($Source) { $findArgs.Source = $Source }
        $results = @(Find-DFPackage @findArgs)
        if (-not $results) {
            $what = if ($Category) { "category '$Category'" }
                elseif ($WorksWith) { "works-with '$WorksWith'" }
                else { "'$($Query -join ' ')'" }
            Write-Warning "DotForge: no matches for $what."
            return
        }

        # Pre-render each result's card for the fzf preview. The preview file
        # path is field 1 because fzf quotes {1} itself — a path assembled
        # around the placeholder would break on the inserted quotes.
        $previewDir = Join-Path ([System.IO.Path]::GetTempPath()) "dotforge-preview-$PID"
        New-DFDirectory $previewDir
        try {
            $lines = @(for ($i = 0; $i -lt $results.Count; $i++) {
                $info = $results[$i]
                $file = Join-Path $previewDir "$i.txt"
                (Format-DFToolInfoCard -Info $info -Color $true) -join "`n" | Set-Content -Path $file -Encoding UTF8
                $best = @($info.Sources) | Select-Object -First 1
                $qualifiedId = "$($best.Source):$($best.PackageId)"
                "$file`t$qualifiedId`t$($info.Name)`t$(@($info.Sources.Source) -join ',')`t$($info.Description)"
            })

            $previewCmd = $IsWindows ? 'type {1}' : 'cat {1}'

            $qualifiedId = Invoke-DFPicker -List { $lines }.GetNewClosure() `
                -Header 'Select package [Enter: full details]' `
                -Preview $previewCmd `
                -Delimiter "`t" -WithNth '3..' `
                -Parse { ($_ -split "`t")[1] }
        } finally {
            Remove-Item $previewDir -Recurse -Force -ErrorAction Ignore
        }
        if ($qualifiedId) {
            Find-DFPackage -Query $qualifiedId -Readme:$Readme -GitInfo:$GitInfo
        }
        return
    }

    $packages = @(Get-DFCatalogLocalPackages)
    if ($Source) {
        $packages = @($packages | Where-Object {
            @($_.Sources -split ',') | Where-Object { $_ -in $Source }
        })
    }
    if (-not $packages) {
        Write-Warning 'DotForge: no local catalog data yet — run Update-DFPackageCache or a first trifle query.'
        return
    }

    $browseLines = @($packages | ForEach-Object { "$($_.Name)`t$($_.Sources)`t$($_.Description)" })

    Invoke-DFPicker -List { $browseLines }.GetNewClosure() `
        -Header 'Select package [Enter: info card]' `
        -Delimiter "`t" -WithNth '1,3' `
        -Parse { ($_ -split "`t")[0] } `
        -Action { param($name) Find-DFPackage -Query $name }
}

Set-Alias -Name ftrifle -Value Select-DFPackage
