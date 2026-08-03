#Requires -Version 7.0
<#
.SYNOPSIS
    One-time application of a vocab-clustering pass's output (see
    docs/package-universe-review-guide.md and
    data/package-universe-vocab-clustering-history.jsonc): adds every
    finalCategories/existingVocabMappings entry's canonical term to the
    closed vocabulary, clears every cached classification any of their
    folded raw terms touched (so those tools re-classify against the grown
    vocabulary on the next Phase D run), and records every folded raw term
    (including rejectedTooRare) as a durable decision so none of them
    resurface as fresh vocab-gap candidates. Author-side tooling — never
    loaded by the DotForge module.
.PARAMETER HistoryPath
    Path to the clustering history jsonc (default:
    data/package-universe-vocab-clustering-history.jsonc).
.PARAMETER DatabasePath
    Path to the shared SQLite working database.
.PARAMETER DecisionsPath
    Path to the durable vocab-gap decision log (default:
    data/package-universe-vocab-decisions.jsonc). Overwritten wholesale —
    this script is meant to run once, from a fresh/empty decisions log.
.PARAMETER DomainsPath / TaxonomyPath
    Closed-vocabulary files (default: build/categories/{domains,taxonomy}.jsonc).
.OUTPUTS
    [pscustomobject] with CategoriesAdded, RowsCleared, and DecisionsRecorded.
.EXAMPLE
    ./build/Invoke-DFPackageUniverseVocabClusteringApply.ps1
#>
[CmdletBinding()]
param(
    [string]$HistoryPath = (Join-Path $PSScriptRoot '../data/package-universe-vocab-clustering-history.jsonc'),
    [string]$DatabasePath = (Join-Path $PSScriptRoot '.package-universe/universe.db'),
    [string]$DecisionsPath = (Join-Path $PSScriptRoot '../data/package-universe-vocab-decisions.jsonc'),
    [string]$DomainsPath = (Join-Path $PSScriptRoot 'categories/domains.jsonc'),
    [string]$TaxonomyPath = (Join-Path $PSScriptRoot 'categories/taxonomy.jsonc')
)

Set-StrictMode -Version Latest
if (-not (Get-Module -ListAvailable -Name 'PSSQLite')) { throw "Invoke-DFPackageUniverseVocabClusteringApply: PSSQLite not installed." }
Import-Module PSSQLite -ErrorAction Stop
Get-ChildItem -Path (Join-Path $PSScriptRoot 'Private') -Filter '*.ps1' | ForEach-Object { . $_.FullName }

if (-not (Test-Path $HistoryPath)) { throw "Invoke-DFPackageUniverseVocabClusteringApply: history file not found at '$HistoryPath'." }
if (-not (Test-Path $DatabasePath)) { throw "Invoke-DFPackageUniverseVocabClusteringApply: database not found at '$DatabasePath'." }

$raw = Get-Content -Raw -Path $HistoryPath
$stripped = [regex]::Replace($raw, '(?m)^\s*//.*$', '')
$history = $stripped | ConvertFrom-Json

$now = [datetime]::UtcNow.ToString('o')
$decisions = [System.Collections.Generic.List[object]]::new()
$conn = New-SQLiteConnection -DataSource $DatabasePath
$categoriesAdded = 0
$rowsCleared = 0

try {
    foreach ($cat in $history.finalCategories) {
        $path = if ($cat.axis -eq 'domain') { $DomainsPath } else { $TaxonomyPath }
        $added = Add-DFPackageUniverseVocabValue -Axis $cat.axis -Value $cat.term -Path $path
        if ($added) { $categoriesAdded++ }
        $rowsCleared += Remove-DFPackageUniverseVocabGapClassificationsBulk -Connection $conn -Terms @($cat.rawTermsFolded)
        foreach ($rawTerm in $cat.rawTermsFolded) {
            $decisions.Add([pscustomobject]@{ term = $rawTerm; verdict = 'promoted'; axis = $cat.axis; value = $cat.term; decidedAt = $now })
        }
        Write-Host "  + $($cat.term) [$($cat.axis)] <- $($cat.rawTermsFolded.Count) raw terms"
    }

    foreach ($m in $history.existingVocabMappings) {
        $rowsCleared += Remove-DFPackageUniverseVocabGapClassificationsBulk -Connection $conn -Terms @($m.rawTermsFolded)
        foreach ($rawTerm in $m.rawTermsFolded) {
            $decisions.Add([pscustomobject]@{ term = $rawTerm; verdict = 'promoted'; axis = $m.axis; value = $m.existingValue; decidedAt = $now })
        }
        Write-Host "  = $($m.existingValue) (existing) [$($m.axis)] <- $($m.rawTermsFolded.Count) raw terms"
    }

    foreach ($r in $history.rejectedTooRare) {
        foreach ($rawTerm in $r.rawTermsFolded) {
            $decisions.Add([pscustomobject]@{ term = $rawTerm; verdict = 'rejected'; axis = $null; value = $null; decidedAt = $now })
        }
    }
} finally { $conn.Close() }

[pscustomobject]@{ schemaVersion = 1; decisions = $decisions } | ConvertTo-Json -Depth 6 | Set-Content -Path $DecisionsPath -Encoding utf8

Write-Host ''
Write-Host 'Vocab clustering apply complete:'
Write-Host "  categories added to vocab           : $categoriesAdded / $($history.finalCategories.Count)"
Write-Host "  classification rows cleared         : $rowsCleared"
Write-Host "  decisions recorded (promoted+reject): $($decisions.Count)"

[pscustomobject]@{ CategoriesAdded = $categoriesAdded; RowsCleared = $rowsCleared; DecisionsRecorded = $decisions.Count }
