#Requires -Version 7.0

function Update-DFPackageCache {
    <#
    .SYNOPSIS
        Refreshes all catalog caches used by Find-DFPackage (trifle) — and does
        nothing else. Designed to run from Task Scheduler so interactive queries
        always answer from warm caches.
    .DESCRIPTION
        Runs synchronously and sequentially (it IS the background work):
        rebuilds snapshot indexes (scoop bucket index, winget SQLite extraction),
        refreshes the unified installed-package snapshot, then re-fetches every
        recently seen query plus the exact name of every installed tool against
        each web catalog. Safe to run while an interactive session is open —
        all cache writes are atomic renames, so last writer wins and both stay
        valid.
    .PARAMETER Source
        Restrict the refresh to these catalogs.
    .PARAMETER Quiet
        Suppress progress output (Task Scheduler mode); warnings still flow.
    .EXAMPLE
        Update-DFPackageCache
        Full refresh with progress messages.
    .EXAMPLE
        pwsh -NoProfile -Command "winget source update; Import-Module DotForge; Update-DFPackageCache -Quiet"
        The Task Scheduler action for a nightly catalog refresh. `winget source
        update` runs first — see NOTES for why.
    .OUTPUTS
        None.
    .NOTES
        Winget caveat: the winget catalog is read from the source.msix that
        winget itself downloads, and winget only refreshes that file when
        winget runs. This command re-extracts whatever msix is present — it
        cannot make winget download a newer one. On machines that rarely invoke
        winget the index silently ages (the card's Cache line shows e.g.
        'winget 61d'). Include `winget source update` (~5s) in the scheduled
        action, before Update-DFPackageCache, to keep it bounded.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('scoop', 'winget', 'choco', 'npm', 'pypi', 'crates', 'psgallery')]
        [string[]]$Source,

        [switch]$Quiet
    )

    $providers = @(Get-DFCatalogProvider -Source $Source)

    foreach ($provider in $providers | Where-Object Kind -eq 'snapshot') {
        if (-not $Quiet) { Write-Host "Refreshing $($provider.Name) index…" }
        try { & $provider.Refresh $null } catch {
            Write-Warning "DotForge: $($provider.Name) index refresh failed: $_"
        }
    }

    if (-not $Quiet) { Write-Host 'Refreshing installed-package snapshot…' }
    $installed = Get-DFCatalogInstalled -Force

    # Re-warm targets: recently seen queries + names of everything installed.
    $queries = [System.Collections.Generic.List[string]]::new()
    $cacheRoot = Get-DFCatalogCacheRoot
    if ($cacheRoot) {
        $seenFile = Join-Path $cacheRoot 'seen-queries.json'
        if (Test-Path $seenFile) {
            try {
                foreach ($entry in @(Get-Content $seenFile -Raw | ConvertFrom-Json)) {
                    if ($entry.query) { $queries.Add([string]$entry.query) }
                }
            } catch {}
        }
    }
    foreach ($item in $installed.Items) {
        if ($item.Name) { $queries.Add(([string]$item.Name).ToLowerInvariant()) }
    }
    $queries = @($queries | Select-Object -Unique)

    $webProviders = @($providers | Where-Object Kind -eq 'query-cache')
    foreach ($query in $queries) {
        foreach ($provider in $webProviders) {
            try { & $provider.Refresh $query } catch {
                Write-Warning "DotForge: $($provider.Name) re-warm of '$query' failed: $_"
            }
        }
    }

    if (-not $Quiet) {
        Write-Host "Re-warmed $($queries.Count) queries across $($webProviders.Count) web catalogs."
    }
}
