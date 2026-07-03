#Requires -Version 7.0

function Get-DFCatalogInstalled {
    <#
    .SYNOPSIS
        Unified installed-package snapshot across all catalog providers, plus
        the cross-catalog identity map derived from Tools/*.json packages blocks.
    .DESCRIPTION
        Provider GetInstalled enumeration can be slow (Get-Module -ListAvailable
        alone costs ~1s), so the snapshot is cached to catalogs/installed.json
        with a 15-minute TTL. The identity map is rebuilt on every call — it
        comes from the in-memory tool db and is cheap.

        Returns @{ Items; IdentityMap } where Items are per-source
        {Source, Name, PackageId, InstalledVersion} records and IdentityMap maps
        lowercase 'source:packageid' keys to the owning DotForge tool name.
    .PARAMETER Force
        Rebuild the snapshot even when the cache is fresh.
    .PARAMETER ToolsPath
        Override the tool db location (tests).
    #>
    [CmdletBinding()]
    param(
        [switch]$Force,

        [string]$ToolsPath
    )

    $identity = @{}
    $dbParams = @{}
    if ($ToolsPath) { $dbParams.ToolsPath = $ToolsPath }
    try { $db = Import-DFToolDb @dbParams } catch { $db = @{} }
    foreach ($tool in $db.Values) {
        $packages = $tool.PSObject.Properties['packages']?.Value
        if (-not $packages) { continue }
        foreach ($property in $packages.PSObject.Properties) {
            if ($property.Value) {
                $key = "$($property.Name.ToLowerInvariant()):$(([string]$property.Value).ToLowerInvariant())"
                $identity[$key] = $tool.name
            }
        }
    }

    $cacheRoot = Get-DFCatalogCacheRoot
    $file = $cacheRoot ? (Join-Path $cacheRoot 'installed.json') : $null

    if (-not $Force -and $file) {
        $cached = Read-DFCatalogCacheFile -Path $file -Ttl $script:DFCatalogTtl.installed
        if ($cached -and -not $cached.Stale) {
            return @{ Items = @($cached.Data); IdentityMap = $identity }
        }
    }

    $items = @(foreach ($provider in Get-DFCatalogProvider) {
        try { & $provider.GetInstalled } catch {
            Write-Verbose "DotForge: installed enumeration for '$($provider.Name)' failed: $_"
        }
    }) | Where-Object { $_ }

    if ($file) {
        Write-DFCatalogCacheFile -Path $file -Query '' -Results @($items)
    }
    @{ Items = @($items); IdentityMap = $identity }
}
