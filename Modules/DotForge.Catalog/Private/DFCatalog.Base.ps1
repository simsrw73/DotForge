#Requires -Version 7.0

# The catalog provider registry. Each Private/DFCatalog.<Stem>.ps1 registers one
# provider with Register-DFCatalogProvider when it is loaded, and everything that
# needs "which catalogs exist, in what order" asks this registry (Get-DFCatalogName)
# instead of keeping its own list.
#
# Load order: DotForge.psm1 dot-sources Private/*.ps1 alphabetically, and this
# file's name sorts before every DFCatalog.<Stem>.ps1, so the registry exists when
# they register. Invoke-DFCatalogInstalledFetch loads this file first in its
# runspaces for the same reason.

if (-not (Get-Variable -Name DFCatalogProviders -Scope Script -ErrorAction Ignore)) { $script:DFCatalogProviders = @{} }

function Register-DFCatalogProvider {
    <#
    .SYNOPSIS
        Adds a catalog provider to the registry, binding its hooks by naming convention.
    .DESCRIPTION
        A provider defined in DFCatalog.<Stem>.ps1 implements
        Search-DFCatalog<Stem> (-Query, -Fresh), Get-DFCatalog<Stem>Installed and
        Get-DFCatalog<Stem>Detail (-PackageId, -Fresh). This builds the
        provider record's hooks from those names, so a provider file only states
        what is particular to it. -Test, -Refresh and -Detail override the
        defaults: Test is "always available", and Refresh re-runs the search
        live (the query-cache behavior).

        The record also lists the files the provider needs (its own plus
        -ExtraFiles), which Invoke-DFCatalogInstalledFetch dot-sources in its
        parallel runspaces.
    .PARAMETER Name
        The catalog name users type with -Source, e.g. 'choco'.
    .PARAMETER Kind
        'query-cache' (web API, per-query cache) or 'snapshot' (local index).
    .PARAMETER Order
        Position in the canonical catalog order; lower comes first.
    .PARAMETER SourceFile
        The provider's own file; pass $PSCommandPath.
    .PARAMETER ExtraFiles
        Other Private files the provider's functions need, by file name.
    .PARAMETER Test
        Availability probe. Default: always available.
    .PARAMETER Refresh
        Re-warm hook, param($Query). Default: re-run the search with -Fresh.
    .PARAMETER Detail
        Detail hook, param($PackageId, $Fresh). Default: Get-DFCatalog<Stem>Detail.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('query-cache', 'snapshot')][string]$Kind,
        [Parameter(Mandatory)][int]$Order,
        [Parameter(Mandatory)][string]$SourceFile,
        [string[]]$ExtraFiles = @(),
        [scriptblock]$Test = { $true },
        [scriptblock]$Refresh,
        [scriptblock]$Detail
    )
    $stem      = [IO.Path]::GetFileNameWithoutExtension($SourceFile) -replace '^DFCatalog\.'
    $search    = "Search-DFCatalog$stem"
    $installed = "Get-DFCatalog${stem}Installed"
    # Built from strings so they bind where they're invoked (module scope), like
    # the literal scriptblocks they replace, and reach the private functions.
    $script:DFCatalogProviders[$Name] = @{
        Name              = $Name
        Kind              = $Kind
        Order             = $Order
        # This file first, so a runspace that loads only these files can register.
        Files             = @('DFCatalog.Base.ps1', (Split-Path $SourceFile -Leaf)) + $ExtraFiles
        InstalledFunction = $installed
        Test              = $Test
        Search            = [scriptblock]::Create("param(`$Query, `$Fresh) $search -Query `$Query -Fresh:`$Fresh")
        GetInstalled      = [scriptblock]::Create($installed)
        Refresh           = $Refresh ?? [scriptblock]::Create("param(`$Query) if (`$Query) { `$null = $search -Query `$Query -Fresh }")
        Detail            = $Detail ?? [scriptblock]::Create("param(`$PackageId, `$Fresh) Get-DFCatalog${stem}Detail -PackageId `$PackageId -Fresh:`$Fresh")
    }
}

function ConvertTo-DFCatalogSource {
    <#
    .SYNOPSIS
        Normalizes a packages-block key or catalog name to the catalog source name.
    .DESCRIPTION
        Tool records key packages by source (scoop, winget, choco, npm, crates,
        psgallery), the same names the catalog providers use, so this only
        lowercases. Every identity index built from a packages block goes
        through it, so the two vocabularies can't drift apart again.
    .PARAMETER Name
        The packages-block key or catalog name.
    .EXAMPLE
        ConvertTo-DFCatalogSource Crates

        Returns 'crates'.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name)
    $Name.ToLowerInvariant()
}

function Get-DFIdentityKeys {
    <#
    .SYNOPSIS
        Returns the identity-map keys to try for one catalog package, most specific first.
    .DESCRIPTION
        Keys are 'source:packageid', lowercased. Scoop ids are bucket-qualified
        at runtime ('main/fd') while tool records and the identity guide store
        bare names ('fd'), so a scoop id also yields the bare-name key. Only
        scoop: in other catalogs a '/' is part of the name (npm's '@scope/pkg'),
        and stripping it would match a different package.
    .PARAMETER Source
        Catalog name.
    .PARAMETER PackageId
        The package id as that catalog reports it.
    .OUTPUTS
        System.String[].
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$PackageId
    )
    "$Source`:$PackageId".ToLowerInvariant()
    if ($Source -eq 'scoop' -and $PackageId.Contains('/')) {
        "scoop:$(($PackageId -split '/')[-1])".ToLowerInvariant()
    }
}

function Get-DFCatalogName {
    <#
    .SYNOPSIS
        Returns the registered catalog names in canonical order.
    .DESCRIPTION
        The one list of catalogs: parameter validation, tab completion, the
        qualified source:id syntax and every per-catalog loop use it. A record
        without an Order (a test stand-in) sorts last, by name.
    .OUTPUTS
        System.String[].
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    @($script:DFCatalogProviders.Values |
        Sort-Object { $o = $_['Order']; if ($null -eq $o) { [int]::MaxValue } else { $o } }, { $_['Name'] } |
        ForEach-Object { $_['Name'] })
}
