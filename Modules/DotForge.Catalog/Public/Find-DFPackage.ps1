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

        Network: queries go to the npm registry, PyPI, crates.io, the
        Chocolatey community feed and the PowerShell Gallery (scoop and winget
        are read from local files). -GitInfo and -Readme also call GitHub,
        through the gh CLI when it is installed and authenticated, otherwise the
        anonymous REST API. Only package names and search words are sent.
        Installed status is read from each manager's local files (scoop apps,
        winget's installed.db, choco's lib folder, npm's global node_modules,
        cargo's .crates2.json, installed modules); only pipx is run (pipx list).
        Caches live in $XDG_CACHE_HOME\dotforge\catalogs (default
        $HOME\.cache\dotforge\catalogs).
    .PARAMETER Query
        Command name or keywords. Multiple words may be passed unquoted:
        trifle static site generator
    .PARAMETER Source
        Restrict the search to these catalogs: scoop, winget, choco, npm, pypi,
        crates, psgallery. Default: all seven.
    .PARAMETER Fresh
        Block on live catalog fetches instead of serving cached data.
    .PARAMETER AsObject
        Emit DotForge.ToolInfo objects even at an interactive terminal.
        Use this when capturing: $x = trifle rg -AsObject (assignment looks
        interactive to pipeline-position detection, so the default would be
        rendered strings).
    .PARAMETER Category
        Filter by function category — see Get-DFCategoryList for valid
        values. Renders the match table (never the detail card); combine
        with -WorksWith to AND the two facets.
    .PARAMETER WorksWith
        Filter by what the tool works with — see Get-DFCategoryList for
        valid values.
    .PARAMETER All
        Always render the full match table, never the detail card — even on an
        otherwise-exact match. The table's Id column shows values usable as a
        qualified query: trifle <source>:<id>.
    .PARAMETER Readme
        After rendering the detail card, fetch and page the package's readme
        (npm registry readme, GitHub readme, or PyPI long description).
        Requires the detail path (a qualified id or an exact match); otherwise
        a warning is shown and the match table is rendered instead.
    .PARAMETER GitInfo
        Resolve the package's GitHub repository (from source details or the
        homepage) and add stars/latest release/activity to the detail card.
        Requires the detail path, like -Readme.
    .EXAMPLE
        trifle ripgrep

        Renders an info card: installed status, catalogs carrying it, versions.
    .EXAMPLE
        trifle json parser -Source scoop,winget

        Keyword search limited to two catalogs; renders a match table.
    .EXAMPLE
        Find-DFPackage ripgrep -AsObject | Select-Object Name, InstalledVia

        Pipeline-friendly object output.
    .EXAMPLE
        trifle winget:Zed.Zed

        Qualified source:id query — zeroes in on one package in one catalog
        and renders its detail card, bypassing keyword ranking entirely.
    .EXAMPLE
        trifle -Category search -WorksWith filesystem

        Facet search: every seed-db tool tagged 'search' AND 'filesystem', resolved
        through live catalog search (accurate installed state), rendered as a table.
    .OUTPUTS
        PSCustomObject (DotForge.ToolInfo) when piped or with -AsObject;
        rendered System.String lines otherwise.
    .NOTES
        Assigning without -AsObject captures rendered strings — pipeline
        position cannot distinguish assignment from a terminal.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/package-catalog.md
    #>
    [CmdletBinding(DefaultParameterSetName = 'Query')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromRemainingArguments, ParameterSetName = 'Query')]
        [string[]]$Query,

        [Parameter(ParameterSetName = 'Category')]
        [string[]]$Category,

        [Parameter(ParameterSetName = 'Category')]
        [string[]]$WorksWith,

        # The catalog list comes from the provider registry (Get-DFCatalogName).
        [ValidateScript({ if ($_ -in (Get-DFCatalogName)) { $true } else { throw "Unknown catalog '$_'. Known catalogs: $((Get-DFCatalogName) -join ', ')." } })]
        [ArgumentCompleter({ param($c, $p, $word) Get-DFCatalogName | Where-Object { $_ -like "$word*" } })]
        [string[]]$Source,

        [switch]$Fresh,

        [switch]$AsObject,

        [Parameter(ParameterSetName = 'Query')]
        [switch]$All,

        [switch]$Readme,

        [switch]$GitInfo
    )

    if ($PSCmdlet.ParameterSetName -eq 'Category') {
        if (-not $Category -and -not $WorksWith) {
            Write-Error 'DotForge: -Category and/or -WorksWith requires at least one value. Run Get-DFCategoryList to see valid terms.' -ErrorAction Stop
        }

        $db = Get-DFCategoryDb
        if (-not $db.Raw) {
            return 'Category database unavailable — run Update-DFCategoryDb or check the module install.'
        }

        $merged = @(Find-DFCatalogFacet -Database $db -Category $Category -WorksWith $WorksWith -Source $Source -Fresh:$Fresh)
        $qualified = $null
        $detailMode = $false
        $queryText = "-Category $($Category -join ',') -WorksWith $($WorksWith -join ',')".Trim()
    } else {
        $queryText = $Query -join ' '

        # Qualified id (source:packageId, from the -All table) → zero in on one
        # package in one catalog. Unknown prefixes stay ordinary keyword queries.
        $qualified = $null
        if ($queryText -match "^(?<src>$((Get-DFCatalogName) -join '|')):(?<id>.+)$") {
            $qualified = @{ Source = $Matches.src.ToLowerInvariant(); Id = $Matches.id.Trim() }
            # Cross-catalog searches use the bare trailing segment ONLY for scoop
            # ids, which are bucket-qualified (bucket/name). Other catalogs' ids
            # ARE the name — notably npm scoped packages (@scope/tool), where
            # splitting on '/' would search for the bare tool name and lose the
            # scope.
            $queryText = ($qualified.Source -eq 'scoop' -and $qualified.Id.Contains('/')) ? ($qualified.Id -split '/')[-1] : $qualified.Id
        }

        $normalized = (ConvertTo-DFCatalogQueryKey -Query $queryText).Normalized
        $merged = Resolve-DFCatalogQueryMerge -QueryText $queryText -Source $Source -Fresh:$Fresh

        if ($qualified) {
            # Keep only the group that actually contains the qualified package.
            $exact = @($merged | Where-Object {
                @($_.Sources | Where-Object { $_.Source -eq $qualified.Source -and $_.PackageId -ieq $qualified.Id }).Count -gt 0
            })
            if ($exact) {
                $merged = @($exact | Select-Object -First 1)
            } else {
                Write-Warning "DotForge: No package '$($qualified.Id)' found in $($qualified.Source) — showing matches for '$queryText'."
                $qualified = $null
            }
        }
    }

    # Detail path: a qualified id, or an exact top match without -All. Facet
    # mode (-Category/-WorksWith) always renders the table, so the exact-match
    # computation is skipped entirely there — an $All-less facet search whose
    # sole surviving hit resolves to an exact-id/exact-name match would
    # otherwise still read as "confident single match" and wrongly promote to
    # the detail card.
    $topExact = $PSCmdlet.ParameterSetName -ne 'Category' -and $merged.Count -gt 0 -and (
        $merged[0].MatchKind -in 'exact-id', 'exact-name' -or $merged[0].Name -ieq $normalized)
    $detailMode = [bool]$qualified -or (-not $All -and $topExact)

    if ($detailMode -and $merged.Count -gt 0) {
        $top = $merged[0]
        $top.Details = Get-DFToolInfoDetails -Info $top -Fresh:$Fresh
        $catDb = Get-DFCategoryDb
        $catEntry = Get-DFCategoryDbEntry -Info $top -Database $catDb
        if ($catEntry) {
            $top.Category = [pscustomobject]@{
                Entry   = $catEntry.Entry
                Related = Get-DFCategoryRelatedTools -Database $catDb -Key $catEntry.Key
            }
        }
        if ($GitInfo) {
            $repo = Resolve-DFGitHubRepoUrl -Info $top
            if ($repo) {
                $top.GitHub = Get-DFGitHubRepoInfo -Owner $repo.Owner -Repo $repo.Repo -Fresh:$Fresh
            }
        }
    }

    if ($AsObject -or (Test-DFOutputPiped -Invocation $MyInvocation)) {
        return $merged
    }

    if ($merged.Count -eq 0) {
        return "No packages found matching '$queryText'."
    }

    $color = Test-DFColorOutput

    if ($detailMode -and $merged.Count -gt 0) {
        $card = Format-DFToolDetailCard -Info $merged[0] -Color $color `
            -MoreMatches ($merged.Count - 1) -QueryText $queryText -GitHubRequested:$GitInfo
        if ($Readme) {
            $readmeLines = Get-DFPackageReadme -Info $merged[0] -Fresh:$Fresh
            if ($readmeLines) {
                $card
                return ($readmeLines | Invoke-DFWithPager)
            }
            Write-Warning "DotForge: no readme found for '$($merged[0].Name)'."
        }
        return $card
    }

    if (($Readme -or $GitInfo) -and -not $detailMode) {
        Write-Warning 'DotForge: -Readme/-GitInfo need an exact match — showing the match table instead.'
    }

    $width = 120
    try { if ($Host.UI.RawUI.WindowSize.Width -gt 0) { $width = $Host.UI.RawUI.WindowSize.Width } } catch {}
    Format-DFToolInfoTable -Infos $merged -Color $color -Width $width
}

