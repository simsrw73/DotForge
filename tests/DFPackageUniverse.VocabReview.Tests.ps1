BeforeAll {
    Set-StrictMode -Version Latest
    Import-Module PSSQLite
    . "$PSScriptRoot/../build/Private/DFPackageUniverse.Merge.ps1"
    . "$PSScriptRoot/../build/Private/DFPackageUniverse.CategorizeDb.ps1"
    . "$PSScriptRoot/../build/Private/DFPackageUniverse.VocabReview.ps1"

    function New-VocabDb {
        $db = Join-Path ([System.IO.Path]::GetTempPath()) ("vocab-" + [guid]::NewGuid().ToString('N') + ".db")
        Initialize-DFPackageUniverseCategorizeSchema -DatabasePath $db
        $db
    }
    function Add-Classification {
        param($Db, $Key, $NothingFits, $SuggestedTerms, $Status = 'done')
        Invoke-SqliteQuery -DataSource $Db -Query @'
INSERT INTO tool_classifications (cache_key, domain, function_json, works_with_json, interface, alternative_to_json, confidence, nothing_fits, suggested_terms_json, signal_source, model, status, classified_at)
VALUES (@k, NULL, '[]', '[]', NULL, '[]', 0.3, @nf, @st, 'readme', 'm', @s, '2026-08-01T00:00:00Z')
'@ -SqlParameters @{ k = $Key; nf = [int]$NothingFits; st = ($SuggestedTerms | ConvertTo-Json -Compress); s = $Status }
    }
}

Describe 'DFPackageUniverse.VocabReview' {
    Context 'Get-DFPackageUniverseVocabGapCandidates' {
        It 'aggregates suggested_terms by frequency, case-insensitively, across nothing_fits rows' {
            $db = New-VocabDb
            try {
                Add-Classification -Db $db -Key 'a' -NothingFits $true -SuggestedTerms @('browser-extension', 'font-manager')
                Add-Classification -Db $db -Key 'b' -NothingFits $true -SuggestedTerms @('Browser-Extension')
                Add-Classification -Db $db -Key 'c' -NothingFits $true -SuggestedTerms @('browser-extension')
                Add-Classification -Db $db -Key 'd' -NothingFits $false -SuggestedTerms @('should-not-count')
                $conn = New-SQLiteConnection -DataSource $db
                try { $candidates = @(Get-DFPackageUniverseVocabGapCandidates -Connection $conn -DecidedTerms @()) } finally { $conn.Close() }
                $candidates.Count | Should -Be 2
                $candidates[0].Term | Should -Be 'browser-extension'
                $candidates[0].Count | Should -Be 3
                $candidates[1].Term | Should -Be 'font-manager'
                $candidates[1].Count | Should -Be 1
                @($candidates.Term) | Should -Not -Contain 'should-not-count'
            } finally { Remove-Item -Path $db -ErrorAction Ignore }
        }
        It 'excludes already-decided terms, case-insensitively' {
            $db = New-VocabDb
            try {
                Add-Classification -Db $db -Key 'a' -NothingFits $true -SuggestedTerms @('browser-extension')
                Add-Classification -Db $db -Key 'b' -NothingFits $true -SuggestedTerms @('font-manager')
                $conn = New-SQLiteConnection -DataSource $db
                try { $candidates = @(Get-DFPackageUniverseVocabGapCandidates -Connection $conn -DecidedTerms @('Browser-Extension')) } finally { $conn.Close() }
                $candidates.Count | Should -Be 1
                $candidates[0].Term | Should -Be 'font-manager'
            } finally { Remove-Item -Path $db -ErrorAction Ignore }
        }
        It 'returns an empty array (not $null) when there is nothing to review' {
            $db = New-VocabDb
            try {
                $conn = New-SQLiteConnection -DataSource $db
                try { $candidates = @(Get-DFPackageUniverseVocabGapCandidates -Connection $conn -DecidedTerms @()) } finally { $conn.Close() }
                $candidates.Count | Should -Be 0
            } finally { Remove-Item -Path $db -ErrorAction Ignore }
        }
    }

    Context 'Get-DFPackageUniverseVocabDecisions / Save-DFPackageUniverseVocabDecision' {
        It 'returns an empty array when the decisions file does not exist yet' {
            $p = Join-Path ([System.IO.Path]::GetTempPath()) ("dec-" + [guid]::NewGuid().ToString('N') + ".jsonc")
            @(Get-DFPackageUniverseVocabDecisions -Path $p).Count | Should -Be 0
        }
        It 'saves and reloads a decision, and a re-decision replaces (not duplicates) the prior entry for the same term' {
            $p = Join-Path ([System.IO.Path]::GetTempPath()) ("dec-" + [guid]::NewGuid().ToString('N') + ".jsonc")
            try {
                Save-DFPackageUniverseVocabDecision -Path $p -Term 'browser-extension' -Verdict 'rejected'
                Save-DFPackageUniverseVocabDecision -Path $p -Term 'font-manager' -Verdict 'promoted' -Axis 'function' -Value 'font-manager'
                Save-DFPackageUniverseVocabDecision -Path $p -Term 'Browser-Extension' -Verdict 'promoted' -Axis 'function' -Value 'browser-extension'
                $decisions = @(Get-DFPackageUniverseVocabDecisions -Path $p)
                $decisions.Count | Should -Be 2
                ($decisions | Where-Object { $_.term -eq 'browser-extension' }).verdict | Should -Be 'promoted'
            } finally { Remove-Item -Path $p -ErrorAction Ignore }
        }
    }

    Context 'Add-DFPackageUniverseVocabValue' {
        BeforeAll {
            $script:fixture = @'
{
  // header comment must survive
  "schemaVersion": 1,
  "domain": [
    "dev", "system", "network"
  ]
}
'@
        }
        It 'inserts a new value while preserving comments and existing entries' {
            $p = Join-Path ([System.IO.Path]::GetTempPath()) ("dom-" + [guid]::NewGuid().ToString('N') + ".jsonc")
            try {
                Set-Content -Path $p -Value $script:fixture -Encoding utf8 -NoNewline
                $added = Add-DFPackageUniverseVocabValue -Axis 'domain' -Value 'gaming' -Path $p
                $added | Should -BeTrue
                $raw = Get-Content -Raw -Path $p
                $raw | Should -Match 'header comment must survive'
                $raw | Should -Match '"gaming"'
                $raw | Should -Match '"dev"'
                # Must still be valid JSON once comments are stripped the same way the reader does.
                $stripped = [regex]::Replace($raw, '(?m)^\s*//.*$', '')
                { $stripped | ConvertFrom-Json } | Should -Not -Throw
                (($stripped | ConvertFrom-Json).domain) | Should -Contain 'gaming'
            } finally { Remove-Item -Path $p -ErrorAction Ignore }
        }
        It 'is idempotent -- adding an already-present value is a no-op' {
            $p = Join-Path ([System.IO.Path]::GetTempPath()) ("dom-" + [guid]::NewGuid().ToString('N') + ".jsonc")
            try {
                Set-Content -Path $p -Value $script:fixture -Encoding utf8 -NoNewline
                Add-DFPackageUniverseVocabValue -Axis 'domain' -Value 'dev' -Path $p | Should -BeFalse
                (Get-Content -Raw -Path $p) | Should -Be $script:fixture
            } finally { Remove-Item -Path $p -ErrorAction Ignore }
        }
        It 'inserts into the correct array when the file has multiple axes (function vs worksWith)' {
            $taxFixture = @'
{
  "function": ["search", "editor"],
  "worksWith": ["text", "json"]
}
'@
            $p = Join-Path ([System.IO.Path]::GetTempPath()) ("tax-" + [guid]::NewGuid().ToString('N') + ".jsonc")
            try {
                Set-Content -Path $p -Value $taxFixture -Encoding utf8 -NoNewline
                Add-DFPackageUniverseVocabValue -Axis 'worksWith' -Value 'audio' -Path $p | Should -BeTrue
                $raw = Get-Content -Raw -Path $p
                $stripped = [regex]::Replace($raw, '(?m)^\s*//.*$', '')
                $parsed = $stripped | ConvertFrom-Json
                $parsed.worksWith | Should -Contain 'audio'
                $parsed.function | Should -Not -Contain 'audio'
                $parsed.function | Should -Be @('search', 'editor')   # untouched
            } finally { Remove-Item -Path $p -ErrorAction Ignore }
        }
        It 'throws a clear error when the requested axis key is not found in the file' {
            $p = Join-Path ([System.IO.Path]::GetTempPath()) ("bad-" + [guid]::NewGuid().ToString('N') + ".jsonc")
            try {
                Set-Content -Path $p -Value '{ "domain": ["dev"] }' -Encoding utf8
                { Add-DFPackageUniverseVocabValue -Axis 'function' -Value 'x' -Path $p } | Should -Throw '*function*'
            } finally { Remove-Item -Path $p -ErrorAction Ignore }
        }
    }

    Context 'Remove-DFPackageUniverseVocabGapClassifications' {
        It 'deletes only rows whose suggested_terms exactly contain the term (case-insensitive), leaving others untouched' {
            $db = New-VocabDb
            try {
                Add-Classification -Db $db -Key 'a' -NothingFits $true -SuggestedTerms @('browser-extension', 'other')
                Add-Classification -Db $db -Key 'b' -NothingFits $true -SuggestedTerms @('Browser-Extension')
                Add-Classification -Db $db -Key 'c' -NothingFits $true -SuggestedTerms @('font-manager')          # unrelated, must survive
                Add-Classification -Db $db -Key 'd' -NothingFits $true -SuggestedTerms @('browser-extension-ish') # substring, must NOT match
                $conn = New-SQLiteConnection -DataSource $db
                try {
                    $n = Remove-DFPackageUniverseVocabGapClassifications -Connection $conn -Term 'Browser-Extension'
                } finally { $conn.Close() }
                $n | Should -Be 2
                @(Invoke-SqliteQuery -DataSource $db -Query "SELECT cache_key FROM tool_classifications ORDER BY cache_key").cache_key | Should -Be @('c', 'd')
            } finally { Remove-Item -Path $db -ErrorAction Ignore }
        }
    }

    Context 'Remove-DFPackageUniverseVocabGapClassificationsBulk' {
        It 'deletes rows matching ANY of several terms, in one pass, leaving unrelated rows untouched' {
            $db = New-VocabDb
            try {
                Add-Classification -Db $db -Key 'a' -NothingFits $true -SuggestedTerms @('static-analysis')
                Add-Classification -Db $db -Key 'b' -NothingFits $true -SuggestedTerms @('Dependency-Management')
                Add-Classification -Db $db -Key 'c' -NothingFits $true -SuggestedTerms @('version-manager', 'other')
                Add-Classification -Db $db -Key 'd' -NothingFits $true -SuggestedTerms @('font-manager')            # unrelated, must survive
                Add-Classification -Db $db -Key 'e' -NothingFits $true -SuggestedTerms @('static-analysis-ish')     # substring, must NOT match
                $conn = New-SQLiteConnection -DataSource $db
                try {
                    $n = Remove-DFPackageUniverseVocabGapClassificationsBulk -Connection $conn -Terms @('static-analysis', 'dependency-management', 'version-manager')
                } finally { $conn.Close() }
                $n | Should -Be 3
                @(Invoke-SqliteQuery -DataSource $db -Query "SELECT cache_key FROM tool_classifications ORDER BY cache_key").cache_key | Should -Be @('d', 'e')
            } finally { Remove-Item -Path $db -ErrorAction Ignore }
        }
        It 'does not double-count or double-delete a row that matches more than one of the given terms' {
            $db = New-VocabDb
            try {
                Add-Classification -Db $db -Key 'a' -NothingFits $true -SuggestedTerms @('static-analysis', 'dependency-management')
                $conn = New-SQLiteConnection -DataSource $db
                try {
                    $n = Remove-DFPackageUniverseVocabGapClassificationsBulk -Connection $conn -Terms @('static-analysis', 'dependency-management')
                } finally { $conn.Close() }
                $n | Should -Be 1
                (Invoke-SqliteQuery -DataSource $db -Query "SELECT COUNT(*) n FROM tool_classifications").n | Should -Be 0
            } finally { Remove-Item -Path $db -ErrorAction Ignore }
        }
        It 'returns 0 and does not throw when Terms is empty' {
            $db = New-VocabDb
            try {
                Add-Classification -Db $db -Key 'a' -NothingFits $true -SuggestedTerms @('static-analysis')
                $conn = New-SQLiteConnection -DataSource $db
                try {
                    { Remove-DFPackageUniverseVocabGapClassificationsBulk -Connection $conn -Terms @() } | Should -Not -Throw
                    Remove-DFPackageUniverseVocabGapClassificationsBulk -Connection $conn -Terms @() | Should -Be 0
                } finally { $conn.Close() }
            } finally { Remove-Item -Path $db -ErrorAction Ignore }
        }
    }

    Context 'Invoke-DFPackageUniverseVocabReview.ps1 (end-to-end, injected Prompt)' {
        It 'promotes one term, rejects another, clears affected rows, records both decisions, and stops when nothing remains' {
            $db = New-VocabDb
            $decisions = Join-Path ([System.IO.Path]::GetTempPath()) ("dec-" + [guid]::NewGuid().ToString('N') + ".jsonc")
            $domains = Join-Path ([System.IO.Path]::GetTempPath()) ("dom-" + [guid]::NewGuid().ToString('N') + ".jsonc")
            $taxonomy = Join-Path ([System.IO.Path]::GetTempPath()) ("tax-" + [guid]::NewGuid().ToString('N') + ".jsonc")
            try {
                Add-Classification -Db $db -Key 'a' -NothingFits $true -SuggestedTerms @('browser-extension')
                Add-Classification -Db $db -Key 'b' -NothingFits $true -SuggestedTerms @('browser-extension')
                Add-Classification -Db $db -Key 'c' -NothingFits $true -SuggestedTerms @('font-manager')
                Set-Content -Path $domains -Value '{ "domain": ["dev", "system"] }' -Encoding utf8
                Set-Content -Path $taxonomy -Value '{ "function": ["search", "editor"], "worksWith": ["text"] }' -Encoding utf8

                # Neither $script:step nor a .GetNewClosure()-captured local variable survives
                # being invoked from inside a DIFFERENT script file's execution context (the
                # orchestrator .ps1) with mutations persisting across calls -- verified by
                # direct repro. $Global: is the one scope that's unambiguous regardless of
                # which script is executing, so it's what actually works here.
                $Global:__vocabReviewTestStep = 0
                $mockPrompt = {
                    param($Message, $Options)
                    $Global:__vocabReviewTestStep++
                    switch ($Global:__vocabReviewTestStep) {
                        1 { @($Options | Where-Object { $_ -like 'browser-extension*' })[0] }
                        2 { 'function' }
                        3 { $Options[0] }   # keep the default value (= the term itself)
                        4 { @($Options | Where-Object { $_ -like 'font-manager*' })[0] }
                        5 { 'reject' }
                        default { $null }
                    }
                }

                $summary = & "$PSScriptRoot/../build/Invoke-DFPackageUniverseVocabReview.ps1" -DatabasePath $db -DecisionsPath $decisions -DomainsPath $domains -TaxonomyPath $taxonomy -Prompt $mockPrompt 6>$null

                $summary.Promoted | Should -Be 1
                $summary.Rejected | Should -Be 1
                $summary.ClassificationsCleared | Should -Be 2   # both browser-extension rows

                $taxParsed = Get-Content -Raw -Path $taxonomy | ConvertFrom-Json
                $taxParsed.function | Should -Contain 'browser-extension'

                $decisionRows = @(Get-DFPackageUniverseVocabDecisions -Path $decisions)
                $decisionRows.Count | Should -Be 2
                ($decisionRows | Where-Object { $_.term -eq 'browser-extension' }).verdict | Should -Be 'promoted'
                ($decisionRows | Where-Object { $_.term -eq 'font-manager' }).verdict | Should -Be 'rejected'

                # The two promoted rows were cleared; re-running the picker now finds nothing left.
                @(Invoke-SqliteQuery -DataSource $db -Query "SELECT COUNT(*) n FROM tool_classifications WHERE cache_key IN ('a','b')").n | Should -Be 0
                (Invoke-SqliteQuery -DataSource $db -Query "SELECT COUNT(*) n FROM tool_classifications WHERE cache_key = 'c'").n | Should -Be 1   # rejected row untouched
            } finally {
                Remove-Item -Path $db, $decisions, $domains, $taxonomy -ErrorAction Ignore
                Remove-Variable -Name __vocabReviewTestStep -Scope Global -ErrorAction Ignore
            }
        }
        It 'throws when the database does not exist (Phase D not run yet)' {
            $missing = Join-Path ([System.IO.Path]::GetTempPath()) ("nodb-" + [guid]::NewGuid().ToString('N') + ".db")
            { & "$PSScriptRoot/../build/Invoke-DFPackageUniverseVocabReview.ps1" -DatabasePath $missing -Prompt { $null } 6>$null } | Should -Throw '*database not found*'
        }
    }
}
