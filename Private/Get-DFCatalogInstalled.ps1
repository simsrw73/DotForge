#Requires -Version 7.2

# Provider name -> array of Private/*.ps1 filenames that provider's
# GetInstalled function needs dot-sourced first (never the whole module).
$script:DFCatalogInstalledDeps = @{
    scoop     = @('DFCatalog.Scoop.ps1')
    winget    = @('DFCatalog.Winget.ps1', 'Invoke-DFSqliteQuery.ps1')
    choco     = @('DFCatalog.Choco.ps1')
    npm       = @('DFCatalog.Npm.ps1')
    crates    = @('DFCatalog.Crates.ps1')
    psgallery = @('DFCatalog.PSGallery.ps1')
    pypi      = @('DFCatalog.Pypi.ps1')
}

# Provider name -> the function to call after dot-sourcing its dependencies.
$script:DFCatalogInstalledFn = @{
    scoop     = 'Get-DFCatalogScoopInstalled'
    winget    = 'Get-DFCatalogWingetInstalled'
    choco     = 'Get-DFCatalogChocoInstalled'
    npm       = 'Get-DFCatalogNpmInstalled'
    crates    = 'Get-DFCatalogCratesInstalled'
    psgallery = 'Get-DFCatalogPSGalleryInstalled'
    pypi      = 'Get-DFCatalogPypiInstalled'
}

function Invoke-DFCatalogInstalledFetch {
    <#
    .SYNOPSIS
        Runs every provider's installed-enumeration function in parallel,
        each in its own runspace, dot-sourcing only the private files that
        specific provider needs.
    .DESCRIPTION
        A provider's failure (missing dependency file, throwing function) is
        isolated to that one provider -- it degrades to zero items for that
        provider and never blanks the others. Bounded by -TimeoutSeconds so a
        hung provider (e.g. a stalled external process) cannot stall the
        whole fetch indefinitely.
    .PARAMETER Deps
        Hashtable: provider name -> array of private .ps1 filenames (relative
        to -PrivateRoot) that provider's function needs dot-sourced first.
    .PARAMETER FnNames
        Hashtable: provider name -> the function name to call after
        dot-sourcing its dependencies.
    .PARAMETER PrivateRoot
        Directory containing the files named in -Deps.
    .PARAMETER ThrottleLimit
        Max concurrent runspaces.
    .PARAMETER TimeoutSeconds
        Overall bound on the whole parallel batch.
    .EXAMPLE
        Invoke-DFCatalogInstalledFetch -Deps $script:DFCatalogInstalledDeps `
            -FnNames $script:DFCatalogInstalledFn -PrivateRoot $PSScriptRoot
        Runs the real shipped providers.
    .OUTPUTS
        [object[]] -- flattened, non-null items from every provider that
        succeeded.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Deps,

        [Parameter(Mandatory)]
        [hashtable]$FnNames,

        [Parameter(Mandatory)]
        [string]$PrivateRoot,

        [int]$ThrottleLimit = 8,

        [int]$TimeoutSeconds = 10
    )

    @($Deps.Keys | ForEach-Object -Parallel {
        $name        = $_
        $deps        = $using:Deps
        $fnNames     = $using:FnNames
        $privateRoot = $using:PrivateRoot

        try {
            foreach ($file in $deps[$name]) {
                . (Join-Path $privateRoot $file)
            }
            @(& (Get-Command $fnNames[$name]))
        } catch {
            Write-Verbose "DotForge: installed enumeration for '$name' failed: $_"
            @()
        }
    } -ThrottleLimit $ThrottleLimit -TimeoutSeconds $TimeoutSeconds) | Where-Object { $_ }
}

function Get-DFCatalogInstalled {
    <#
    .SYNOPSIS
        Unified installed-package snapshot across all catalog providers, plus
        the cross-catalog identity map derived from Tools/*.json packages blocks.
    .DESCRIPTION
        Always live -- every call runs all 7 providers' installed-enumeration
        functions fresh, in parallel (see Invoke-DFCatalogInstalledFetch),
        never cached. The identity map is rebuilt on every call too -- it
        comes from the in-memory tool db and is cheap.

        Returns @{ Items; IdentityMap } where Items are per-source
        {Source, Name, PackageId, InstalledVersion} records and IdentityMap maps
        lowercase 'source:packageid' keys to the owning DotForge tool name.
    .PARAMETER ToolsPath
        Override the tool db location (tests).
    .PARAMETER FetchItems
        Test seam: a scriptblock called with no arguments in place of the
        real parallel fetch. Defaults to the real
        Invoke-DFCatalogInstalledFetch call against the shipped provider
        tables.
    .EXAMPLE
        Get-DFCatalogInstalled
        Returns the live installed snapshot and identity map.
    .OUTPUTS
        [hashtable] -- @{ Items; IdentityMap }.
    #>
    [CmdletBinding()]
    param(
        [string]$ToolsPath,

        [scriptblock]$FetchItems
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

    $fetch = $FetchItems ? $FetchItems : {
        Invoke-DFCatalogInstalledFetch -Deps $script:DFCatalogInstalledDeps `
            -FnNames $script:DFCatalogInstalledFn -PrivateRoot $PSScriptRoot
    }
    $items = @(& $fetch)

    @{ Items = $items; IdentityMap = $identity }
}
