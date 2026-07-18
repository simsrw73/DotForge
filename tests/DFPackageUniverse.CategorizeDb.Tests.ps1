BeforeAll {
    Set-StrictMode -Version Latest
    Import-Module PSSQLite
    . "$PSScriptRoot/../build/Private/DFPackageUniverse.CategorizeDb.ps1"
}
Describe 'DFPackageUniverse.CategorizeDb' {
    Context 'Initialize-DFPackageUniverseCategorizeSchema' {
        It 'creates the cache tables and preserves existing rows on re-init' {
            $db = Join-Path ([System.IO.Path]::GetTempPath()) ("catdb-" + [guid]::NewGuid().ToString('N') + ".db")
            try {
                Initialize-DFPackageUniverseCategorizeSchema -DatabasePath $db
                Invoke-SqliteQuery -DataSource $db -Query "INSERT INTO tool_classifications (cache_key, status, classified_at) VALUES ('repo:x|y', 'done', 'now')"
                Initialize-DFPackageUniverseCategorizeSchema -DatabasePath $db   # re-init must NOT wipe
                (Invoke-SqliteQuery -DataSource $db -Query "SELECT COUNT(*) n FROM tool_classifications").n | Should -Be 1
                $tables = @(Invoke-SqliteQuery -DataSource $db -Query "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name").name
                $tables | Should -Contain 'tool_classifications'
                $tables | Should -Contain 'fetch_cache'
            } finally { Remove-Item -Path $db -ErrorAction Ignore }
        }
    }

    Context 'persist + export/import round-trip' {
        It 'saves, exports to jsonc, and re-imports losslessly' {
            $db = Join-Path ([System.IO.Path]::GetTempPath()) ("rt-" + [guid]::NewGuid().ToString('N') + ".db")
            $js = Join-Path ([System.IO.Path]::GetTempPath()) ("rt-" + [guid]::NewGuid().ToString('N') + ".jsonc")
            try {
                Initialize-DFPackageUniverseCategorizeSchema -DatabasePath $db
                $conn = New-SQLiteConnection -DataSource $db
                $cls = [pscustomobject]@{ Domain='text'; Function=@('search'); WorksWith=@('text'); Interface='cli'; AlternativeTo=@('grep'); Confidence=0.9; NothingFits=$false; SuggestedTerms=@() }
                try { Save-DFPackageUniverseClassification -Connection $conn -CacheKey 'repo:https://github.com/sharkdp/bat|bat' -Classification $cls -SignalSource 'readme' -Model 'gpt-test' -Status 'done' }
                finally { $conn.Close() }
                Export-DFPackageUniverseClassifications -DatabasePath $db -Path $js
                (Get-Content -Raw $js) | Should -Match 'sharkdp/bat'

                $db2 = Join-Path ([System.IO.Path]::GetTempPath()) ("rt2-" + [guid]::NewGuid().ToString('N') + ".db")
                try {
                    Initialize-DFPackageUniverseCategorizeSchema -DatabasePath $db2
                    Import-DFPackageUniverseClassifications -DatabasePath $db2 -Path $js
                    $row = Invoke-SqliteQuery -DataSource $db2 -Query "SELECT domain, function_json FROM tool_classifications WHERE cache_key = 'repo:https://github.com/sharkdp/bat|bat'"
                    $row.domain | Should -Be 'text'
                    ($row.function_json | ConvertFrom-Json) | Should -Contain 'search'
                } finally { Remove-Item -Path $db2 -ErrorAction Ignore }
            } finally { Remove-Item -Path $db, $js -ErrorAction Ignore }
        }
    }
}
