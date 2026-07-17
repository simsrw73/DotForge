#Requires -Version 7.0
<#
.SYNOPSIS
    Phase B of the package-universe pipeline: cross-catalog identity clustering.
.DESCRIPTION
    Reads raw_packages (produced by Phase A / Build-DFPackageUniverseRaw.ps1)
    from the shared universe.db, derives a confidence-scored pairwise link graph
    (github repo > homepage > publisher+name > name-only, with a conflict tier),
    applies the version-controlled curation file (human-verified same/different),
    computes clusters by constrained union-find, and writes identity_links /
    identity_clusters / cluster_members / curated_links plus review candidates to
    pipeline_log (stage='link', level='review'). See
    docs/superpowers/specs/2026-07-16-package-universe-identity-clustering-design.md.

    Set-StrictMode -Version Latest is dynamically scoped over the dot-sourced
    helpers -- intended, not incidental.
.PARAMETER DatabasePath
    Path to the shared SQLite working database (default: the standard
    build/.package-universe/universe.db next to this script).
.PARAMETER CurationPath
    Path to the curation .jsonc (default: data/package-universe-curation.jsonc).
    A missing file means no curation yet; clustering still runs.
.PARAMETER Threshold
    Minimum edge confidence that forms a cluster (default 0.60).
.OUTPUTS
    A reconciliation summary object (RowsRead, Edges, Clusters, Members, Review).
.EXAMPLE
    ./build/Build-DFPackageUniverseLinks.ps1
#>
[CmdletBinding()]
param(
    [string]$DatabasePath = (Join-Path $PSScriptRoot '.package-universe/universe.db'),
    [string]$CurationPath = (Join-Path $PSScriptRoot '../data/package-universe-curation.jsonc'),
    [double]$Threshold = 0.60,
    [int]$FamilySizeThreshold = 5
)

Set-StrictMode -Version Latest

if (-not (Get-Module -ListAvailable -Name 'PSSQLite')) {
    throw "Build-DFPackageUniverseLinks: required module 'PSSQLite' is not installed. Install it with: Install-Module PSSQLite -Scope CurrentUser"
}
Import-Module PSSQLite -ErrorAction Stop

# Private/*.ps1 functions aren't exported; dot-source directly (mirroring
# Build-DFPackageUniverseRaw.ps1). ../Private supplies ConvertTo-DFNormalizedHomepage;
# ./Private supplies the DB helpers and the Phase B link helpers.
if (-not (Get-Command ConvertTo-DFNormalizedHomepage -ErrorAction Ignore)) {
    Get-ChildItem -Path (Join-Path $PSScriptRoot '../Private') -Filter '*.ps1' | ForEach-Object { . $_.FullName }
}
if (-not (Get-Command Invoke-DFPackageUniverseLinkBuild -ErrorAction Ignore)) {
    Get-ChildItem -Path (Join-Path $PSScriptRoot 'Private') -Filter '*.ps1' | ForEach-Object { . $_.FullName }
}

if (-not (Test-Path $DatabasePath)) {
    throw "Build-DFPackageUniverseLinks: database not found at '$DatabasePath'. Run Build-DFPackageUniverseRaw.ps1 (Phase A) first."
}

Initialize-DFPackageUniverseLinksSchema -DatabasePath $DatabasePath

$conn = New-SQLiteConnection -DataSource $DatabasePath
try {
    $summary = Invoke-DFPackageUniverseLinkBuild -Connection $conn -CurationPath $CurationPath -Threshold $Threshold -FamilySizeThreshold $FamilySizeThreshold
} finally {
    $conn.Close()
}

# Reconciliation: population found vs artifacts emitted, so a silent collapse is
# visible (design Error Handling rule). Edge breakdown by method comes from the DB.
$byMethod = @(Invoke-SqliteQuery -DataSource $DatabasePath -Query 'SELECT method, COUNT(*) n FROM identity_links GROUP BY method ORDER BY method')
Write-Host 'Phase B (identity clustering) complete:'
Write-Host "  raw_packages read : $($summary.RowsRead)"
Write-Host "  edges             : $($summary.Edges)"
foreach ($m in $byMethod) { Write-Host ('      {0,-16} {1}' -f $m.method, $m.n) }
Write-Host "  clusters          : $($summary.Clusters)"
Write-Host "  clustered members : $($summary.Members)"
Write-Host "  review candidates : $($summary.Review)"
Write-Host "  families (review) : $($summary.Families)"

$summary
