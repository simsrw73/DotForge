#Requires -Version 7.2

function Invoke-DFCatalogInstalledFetch {
    <#
    .SYNOPSIS
        Runs every provider's installed-enumeration function in parallel,
        each in its own runspace, dot-sourcing only the private files that
        specific provider's record lists.
    .DESCRIPTION
        A provider's failure (missing dependency file, throwing function) is
        isolated to that one provider -- it degrades to zero items for that
        provider and never blanks the others. Bounded by -TimeoutSeconds so a
        hung provider (e.g. a stalled external process) cannot stall the
        whole fetch indefinitely.
    .PARAMETER Providers
        One entry per provider with Name, Files (private .ps1 file names,
        relative to -PrivateRoot, to dot-source first) and InstalledFunction
        (the function to call). Provider records from the registry have this
        shape; only these three fields are passed to the runspaces, since
        -Parallel can't carry scriptblocks.
    .PARAMETER PrivateRoot
        Directory containing the files named in Files.
    .PARAMETER ThrottleLimit
        Max concurrent runspaces.
    .PARAMETER TimeoutSeconds
        Overall bound on the whole parallel batch.
    .EXAMPLE
        Invoke-DFCatalogInstalledFetch -Providers @($script:DFCatalogProviders.Values) -PrivateRoot $PSScriptRoot

        Runs the real shipped providers.
    .OUTPUTS
        [object[]] -- flattened, non-null items from every provider that
        succeeded.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Providers,

        [Parameter(Mandatory)]
        [string]$PrivateRoot,

        [int]$ThrottleLimit = 8,

        [int]$TimeoutSeconds = 10
    )

    $work = @($Providers | ForEach-Object {
        @{ Name = $_.Name; Files = @($_.Files); InstalledFunction = $_.InstalledFunction }
    })
    @($work | ForEach-Object -Parallel {
        $p = $_
        try {
            foreach ($file in $p.Files) {
                . (Join-Path $using:PrivateRoot $file)
            }
            @(& (Get-Command $p.InstalledFunction))
        } catch {
            Write-Verbose "DotForge: installed enumeration for '$($p.Name)' failed: $_"
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
        Invoke-DFCatalogInstalledFetch call against the registered providers.
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
        if (-not $tool.packages) { continue }
        foreach ($property in $tool.packages.PSObject.Properties) {
            $ref = Get-DFPackageRef $property.Value
            if ($ref) {
                $key = "$(ConvertTo-DFCatalogSource $property.Name):$($ref.Id.ToLowerInvariant())"
                $identity[$key] = $tool.name
            }
        }
    }

    $fetch = $FetchItems ? $FetchItems : {
        Invoke-DFCatalogInstalledFetch -Providers @($script:DFCatalogProviders.Values) -PrivateRoot $PSScriptRoot
    }
    $items = @(& $fetch)

    @{ Items = $items; IdentityMap = $identity }
}
