BeforeAll {
    Set-StrictMode -Version Latest
    Import-Module PSSQLite
    . "$PSScriptRoot/../build/Private/DFPackageUniverse.Merge.ps1"
    . "$PSScriptRoot/../build/Private/DFPackageUniverse.CategorizeDb.ps1"
    . "$PSScriptRoot/../build/Private/DFPackageUniverse.VocabReview.ps1"
}

Describe 'Invoke-DFPackageUniverseVocabClusteringApply.ps1' {
    It 'clears matched rows AND re-exports classifications.jsonc, so a subsequent Phase D run''s own Import step cannot silently restore the stale pre-clear data' {
        # Regression test for the 2026-08-03 incident: the apply script cleared
        # rows in the live DB but never re-exported classifications.jsonc, so
        # Build-DFPackageUniverseCategories.ps1's own opening
        # Import-DFPackageUniverseClassifications call (which upserts every
        # entry in the committed jsonc back into the DB, unconditionally)
        # silently restored the stale, just-cleared rows before the next run's
        # classify loop ever started -- 2,543 tools got wrongly re-marked
        # 'done' with their old wrong data instead of being reprocessed.
        $db = Join-Path ([System.IO.Path]::GetTempPath()) ("apply-" + [guid]::NewGuid().ToString('N') + ".db")
        $history = Join-Path ([System.IO.Path]::GetTempPath()) ("apply-hist-" + [guid]::NewGuid().ToString('N') + ".jsonc")
        $classifications = Join-Path ([System.IO.Path]::GetTempPath()) ("apply-class-" + [guid]::NewGuid().ToString('N') + ".jsonc")
        $decisions = Join-Path ([System.IO.Path]::GetTempPath()) ("apply-dec-" + [guid]::NewGuid().ToString('N') + ".jsonc")
        $domains = Join-Path ([System.IO.Path]::GetTempPath()) ("apply-dom-" + [guid]::NewGuid().ToString('N') + ".jsonc")
        $taxonomy = Join-Path ([System.IO.Path]::GetTempPath()) ("apply-tax-" + [guid]::NewGuid().ToString('N') + ".jsonc")
        try {
            Initialize-DFPackageUniverseCategorizeSchema -DatabasePath $db

            # A tool that will match a finalCategories entry and must get cleared + dropped from the export.
            Invoke-SqliteQuery -DataSource $db -Query @'
INSERT INTO tool_classifications (cache_key, domain, function_json, works_with_json, interface, alternative_to_json, confidence, nothing_fits, suggested_terms_json, signal_source, model, status, classified_at)
VALUES ('pkg:choco|nubrub', NULL, '[]', '[]', NULL, '[]', 0.3, 1, '["static-analysis","style-checker"]', 'readme', 'm', 'done', '2026-08-01T00:00:00Z')
'@
            # An unrelated tool that must survive the clear untouched, and stay exported.
            Invoke-SqliteQuery -DataSource $db -Query @'
INSERT INTO tool_classifications (cache_key, domain, function_json, works_with_json, interface, alternative_to_json, confidence, nothing_fits, suggested_terms_json, signal_source, model, status, classified_at)
VALUES ('pkg:choco|survivor', 'dev', '["editor"]', '[]', 'cli', '[]', 0.9, 0, '[]', 'readme', 'm', 'done', '2026-08-01T00:00:00Z')
'@

            @'
{ "schemaVersion": 1,
  "finalCategories": [ { "term": "developer-code-tooling", "axis": "function", "supportCount": 1, "rawTermsFolded": ["static-analysis"] } ],
  "existingVocabMappings": [ { "existingValue": "linter", "axis": "function", "rawTermsFolded": ["style-checker"] } ],
  "rejectedTooRare": [] }
'@ | Set-Content -Path $history -Encoding utf8

            Set-Content -Path $domains -Value '{ "domain": ["dev"] }' -Encoding utf8
            Set-Content -Path $taxonomy -Value '{ "function": ["editor"], "worksWith": [] }' -Encoding utf8

            $summary = & "$PSScriptRoot/../build/Invoke-DFPackageUniverseVocabClusteringApply.ps1" -HistoryPath $history -DatabasePath $db -ClassificationsPath $classifications -DecisionsPath $decisions -DomainsPath $domains -TaxonomyPath $taxonomy

            $summary.RowsCleared | Should -Be 1

            # DB itself: the matched row is gone, the unrelated one survives.
            (Invoke-SqliteQuery -DataSource $db -Query "SELECT COUNT(*) n FROM tool_classifications WHERE cache_key='pkg:choco|nubrub'").n | Should -Be 0
            (Invoke-SqliteQuery -DataSource $db -Query "SELECT COUNT(*) n FROM tool_classifications WHERE cache_key='pkg:choco|survivor'").n | Should -Be 1

            # The export must exist and must NOT contain the cleared row -- this is the actual regression check:
            # without the fix, the script left the stale pre-run export in place (or none at all), so a later
            # Phase D run's Import step would have re-inserted the cleared row right back as 'done'.
            Test-Path $classifications | Should -BeTrue
            $exported = Get-Content -Raw -Path $classifications | ConvertFrom-Json
            @($exported.classifications.cacheKey) | Should -Not -Contain 'pkg:choco|nubrub'
            @($exported.classifications.cacheKey) | Should -Contain 'pkg:choco|survivor'
        } finally {
            Remove-Item -Path $db, $history, $classifications, $decisions, $domains, $taxonomy -ErrorAction Ignore
        }
    }
}
