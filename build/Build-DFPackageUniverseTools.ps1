#Requires -Version 7.0
<#
.SYNOPSIS
    Phase C of the package-universe pipeline: tool merge (cluster flattening).
.DESCRIPTION
    Reads raw_packages (Phase A) and cluster_members (Phase B) from the shared
    universe.db and flattens them into the master tools table: one row per
    real-world tool across the whole corpus (clusters + singletons), lossless
    (per-catalog rows preserved in tool_packages), with per-field priority picks,
    a license conflict flag, a tag union, and first-pass categories. Writes
    tools / tool_packages / tool_tags / tool_categories plus review rows to
    pipeline_log (stage='merge'). See
    docs/superpowers/specs/2026-07-16-package-universe-tool-merge-design.md.
.PARAMETER DatabasePath
    Path to the shared SQLite working database (default: the standard
    build/.package-universe/universe.db next to this script).
.PARAMETER CategoryRulesPath
    Path to the keyword->category rule file (default: data/package-universe-categories.jsonc).
.OUTPUTS
    A reconciliation summary object (RowsRead, Tools, Packages, Singletons, Tags,
    Categories, Review).
.EXAMPLE
    ./build/Build-DFPackageUniverseTools.ps1
#>
[CmdletBinding()]
param(
    [string]$DatabasePath = (Join-Path $PSScriptRoot '.package-universe/universe.db'),
    [string]$CategoryRulesPath = (Join-Path $PSScriptRoot '../data/package-universe-categories.jsonc')
)

Set-StrictMode -Version Latest

if (-not (Get-Module -ListAvailable -Name 'PSSQLite')) {
    throw "Build-DFPackageUniverseTools: required module 'PSSQLite' is not installed. Install it with: Install-Module PSSQLite -Scope CurrentUser"
}
Import-Module PSSQLite -ErrorAction Stop

# Private/*.ps1 functions aren't exported; dot-source directly (mirroring the
# Phase A/B scripts). build/Private supplies the DB helpers, the Phase B repo-key
# helper reused here, and the Phase C merge helpers.
if (-not (Get-Command Invoke-DFPackageUniverseToolMerge -ErrorAction Ignore)) {
    Get-ChildItem -Path (Join-Path $PSScriptRoot 'Private') -Filter '*.ps1' | ForEach-Object { . $_.FullName }
}

if (-not (Test-Path $DatabasePath)) {
    throw "Build-DFPackageUniverseTools: database not found at '$DatabasePath'. Run Build-DFPackageUniverseRaw.ps1 (Phase A) and Build-DFPackageUniverseLinks.ps1 (Phase B) first."
}

$hasMembers = @(Invoke-SqliteQuery -DataSource $DatabasePath -Query "SELECT name FROM sqlite_master WHERE type='table' AND name='cluster_members';")
if ($hasMembers.Count -eq 0) {
    throw "Build-DFPackageUniverseTools: cluster_members table not found. Run Build-DFPackageUniverseLinks.ps1 (Phase B) first."
}

Initialize-DFPackageUniverseToolsSchema -DatabasePath $DatabasePath

$conn = New-SQLiteConnection -DataSource $DatabasePath
try {
    $summary = Invoke-DFPackageUniverseToolMerge -Connection $conn -CategoryRulesPath $CategoryRulesPath
} finally {
    $conn.Close()
}

Write-Host 'Phase C (tool merge) complete:'
Write-Host "  raw_packages read : $($summary.RowsRead)"
Write-Host "  tools             : $($summary.Tools)"
Write-Host "  ‣ singletons      : $($summary.Singletons)"
Write-Host "  tool_packages     : $($summary.Packages)"
Write-Host "  tags              : $($summary.Tags)"
Write-Host "  categories        : $($summary.Categories)"
Write-Host "  review (license)  : $($summary.Review)"

$summary
