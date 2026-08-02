#Requires -Version 7.0
<#
.SYNOPSIS
    Interactive Phase D vocab-gap review: walks the aggregated,
    already-decided-excluded backlog of `suggested_terms` a nothing_fits
    classification leaves behind, lets a human promote each term into the
    closed vocabulary (build/categories/domains.jsonc or taxonomy.jsonc) or
    reject it, and clears the cached classifications a promoted term
    affects so those tools get re-classified on the next Phase D run.
    Author-side tooling — never loaded by the DotForge module. See
    docs/package-universe-review-guide.md.
.DESCRIPTION
    Candidates are aggregated by frequency (the same term recurs across many
    unrelated tools far more often than it appears once), so a review
    session works through a short list of distinct terms, not thousands of
    individual rows. Every decision — promote or reject — is recorded
    durably in DecisionsPath so it never resurfaces in a later session; only
    "skip (decide later)" leaves a term undecided.
.PARAMETER DatabasePath
    Path to the shared SQLite working database (default: the standard
    build/.package-universe/universe.db next to this script).
.PARAMETER DecisionsPath
    Path to the durable, version-controlled decision log (default:
    data/package-universe-vocab-decisions.jsonc).
.PARAMETER DomainsPath
    Path to the coarse domain vocabulary (default: build/categories/domains.jsonc).
.PARAMETER TaxonomyPath
    Path to the function/worksWith taxonomy (default: build/categories/taxonomy.jsonc).
.PARAMETER Prompt
    Injectable menu seam: param($Message, $Options) -> the selected option
    (an element of $Options) or $null for quit/cancel. Defaults to a real
    numbered-menu prompt over Read-Host. Tests inject a scripted seam.
.OUTPUTS
    [pscustomobject] with Promoted, Rejected, and ClassificationsCleared
    counts for the session.
.EXAMPLE
    ./build/Invoke-DFPackageUniverseVocabReview.ps1
#>
[CmdletBinding()]
param(
    [string]$DatabasePath = (Join-Path $PSScriptRoot '.package-universe/universe.db'),
    [string]$DecisionsPath = (Join-Path $PSScriptRoot '../data/package-universe-vocab-decisions.jsonc'),
    [string]$DomainsPath = (Join-Path $PSScriptRoot 'categories/domains.jsonc'),
    [string]$TaxonomyPath = (Join-Path $PSScriptRoot 'categories/taxonomy.jsonc'),
    [scriptblock]$Prompt = {
        param($Message, $Options)
        Write-Host ''
        Write-Host $Message -ForegroundColor Cyan
        for ($i = 0; $i -lt $Options.Count; $i++) { Write-Host "  [$($i + 1)] $($Options[$i])" }
        Write-Host '  [q] quit'
        $ans = Read-Host 'Choice'
        if (-not $ans -or $ans -eq 'q') { return $null }
        $idx = 0
        if ([int]::TryParse($ans, [ref]$idx) -and $idx -ge 1 -and $idx -le $Options.Count) { return $Options[$idx - 1] }
        $null
    }
)

Set-StrictMode -Version Latest
if (-not (Get-Module -ListAvailable -Name 'PSSQLite')) { throw "Invoke-DFPackageUniverseVocabReview: PSSQLite not installed." }
Import-Module PSSQLite -ErrorAction Stop
if (-not (Get-Command Get-DFPackageUniverseVocabGapCandidates -ErrorAction Ignore)) {
    Get-ChildItem -Path (Join-Path $PSScriptRoot 'Private') -Filter '*.ps1' | ForEach-Object { . $_.FullName }
}

if (-not (Test-Path $DatabasePath)) { throw "Invoke-DFPackageUniverseVocabReview: database not found at '$DatabasePath'. Run Phase D (Build-DFPackageUniverseCategories.ps1) first." }

$conn = New-SQLiteConnection -DataSource $DatabasePath
$promoted = 0; $rejected = 0; $clearedTotal = 0
try {
    while ($true) {
        $decided = @(Get-DFPackageUniverseVocabDecisions -Path $DecisionsPath | ForEach-Object { [string]$_.term })
        $candidates = @(Get-DFPackageUniverseVocabGapCandidates -Connection $conn -DecidedTerms $decided)
        if ($candidates.Count -eq 0) {
            Write-Host 'No undecided vocab-gap candidates remain.'
            break
        }
        $labels = @($candidates | ForEach-Object { "$($_.Term)  ($($_.Count) tools)" })
        $picked = & $Prompt "Vocab-gap candidates ($($candidates.Count) remaining):" $labels
        if (-not $picked) { break }
        $term = $candidates[$labels.IndexOf($picked)].Term

        $verdict = & $Prompt "'$term' -- promote to which axis, or reject?" @('domain', 'function', 'worksWith', 'reject', 'skip (decide later)')
        if (-not $verdict -or $verdict -like 'skip*') { continue }

        if ($verdict -eq 'reject') {
            Save-DFPackageUniverseVocabDecision -Path $DecisionsPath -Term $term -Verdict 'rejected'
            $rejected++
            Write-Host "Rejected '$term'."
            continue
        }

        $valueOptions = @($term, 'type a different value')
        $valueChoice = & $Prompt "Value to add to the '$verdict' vocabulary (default: '$term'):" $valueOptions
        $value = if (-not $valueChoice -or $valueChoice -eq $term) { $term } else { Read-Host 'Value' }
        if (-not $value) { $value = $term }

        $path = if ($verdict -eq 'domain') { $DomainsPath } else { $TaxonomyPath }
        $added = Add-DFPackageUniverseVocabValue -Axis $verdict -Value $value -Path $path
        $cleared = Remove-DFPackageUniverseVocabGapClassifications -Connection $conn -Term $term
        Save-DFPackageUniverseVocabDecision -Path $DecisionsPath -Term $term -Verdict 'promoted' -Axis $verdict -Value $value
        $promoted++; $clearedTotal += $cleared
        $note = if ($added) { '' } else { ' (value was already present in the vocab)' }
        Write-Host "Promoted '$term' -> ${verdict}: `"$value`" in $path$note. Cleared $cleared cached classification(s) for re-run."
    }
} finally { $conn.Close() }

Write-Host ''
Write-Host 'Vocab review session complete:'
Write-Host "  promoted                           : $promoted"
Write-Host "  rejected                           : $rejected"
Write-Host "  classifications cleared for re-run : $clearedTotal"
if ($promoted -gt 0) {
    Write-Host "Next: commit $DecisionsPath and the updated vocab file(s), then re-run ./build/Build-DFPackageUniverseCategories.ps1 to re-classify the cleared tools."
}

[pscustomobject]@{ Promoted = $promoted; Rejected = $rejected; ClassificationsCleared = $clearedTotal }
