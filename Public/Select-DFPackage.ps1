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
    .OUTPUTS
        None — the selection is rendered via Find-DFPackage.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromRemainingArguments)]
        [string[]]$Query,

        [ValidateSet('scoop', 'winget', 'choco', 'npm', 'pypi', 'crates', 'psgallery')]
        [string[]]$Source,

        [switch]$Readme,

        [switch]$GitInfo
    )

    if ($Query) {
        $findArgs = @{ Query = $Query; AsObject = $true }
        if ($Source) { $findArgs.Source = $Source }
        $results = @(Find-DFPackage @findArgs)
        if (-not $results) {
            Write-Warning "DotForge: no matches for '$($Query -join ' ')'."
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

            Invoke-DFPicker -List { $lines }.GetNewClosure() `
                -Header 'Select package [Enter: full details]' `
                -Preview $previewCmd `
                -Delimiter "`t" -WithNth '3..' `
                -Parse { ($_ -split "`t")[1] } `
                -Action { param($qid) Find-DFPackage -Query $qid -Readme:$Readme -GitInfo:$GitInfo }.GetNewClosure()
        } finally {
            Remove-Item $previewDir -Recurse -Force -ErrorAction Ignore
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

Set-Alias -Name ftrifle -Value Select-DFPackage -Scope Global -Force
