BeforeAll {
    Set-StrictMode -Version Latest
    Import-Module PSSQLite
    . "$PSScriptRoot/../build/Private/DFPackageUniverse.Merge.ps1"
    . "$PSScriptRoot/../build/Private/DFPackageUniverse.Categorize.ps1"
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
                    $row.function_json | Should -Be '["search"]'
                } finally { Remove-Item -Path $db2 -ErrorAction Ignore }
            } finally { Remove-Item -Path $db, $js -ErrorAction Ignore }
        }

        It 'preserves SuggestedTerms across the export/import round-trip (no data loss)' {
            $db = Join-Path ([System.IO.Path]::GetTempPath()) ("st-" + [guid]::NewGuid().ToString('N') + ".db")
            $js = Join-Path ([System.IO.Path]::GetTempPath()) ("st-" + [guid]::NewGuid().ToString('N') + ".jsonc")
            try {
                Initialize-DFPackageUniverseCategorizeSchema -DatabasePath $db
                $conn = New-SQLiteConnection -DataSource $db
                $cls = [pscustomobject]@{ Domain='dev'; Function=@('search'); WorksWith=@('text'); Interface='cli'; AlternativeTo=@(); Confidence=0.3; NothingFits=$true; SuggestedTerms=@('foo','bar') }
                try { Save-DFPackageUniverseClassification -Connection $conn -CacheKey 'pkg:scoop|main/x' -Classification $cls -SignalSource 'metadata' -Model 'm' -Status 'done' }
                finally { $conn.Close() }
                Export-DFPackageUniverseClassifications -DatabasePath $db -Path $js
                $db2 = Join-Path ([System.IO.Path]::GetTempPath()) ("st2-" + [guid]::NewGuid().ToString('N') + ".db")
                try {
                    Initialize-DFPackageUniverseCategorizeSchema -DatabasePath $db2
                    Import-DFPackageUniverseClassifications -DatabasePath $db2 -Path $js
                    $st = (Invoke-SqliteQuery -DataSource $db2 -Query "SELECT suggested_terms_json FROM tool_classifications WHERE cache_key='pkg:scoop|main/x'").suggested_terms_json
                    @($st | ConvertFrom-Json) | Should -Contain 'foo'
                    @($st | ConvertFrom-Json) | Should -Contain 'bar'
                } finally { Remove-Item -Path $db2 -ErrorAction Ignore }
            } finally { Remove-Item -Path $db, $js -ErrorAction Ignore }
        }
    }

    Context 'Update-DFPackageUniverseToolCategories' {
        It 'writes each tool the classification of its durable key' {
            $db = Join-Path ([System.IO.Path]::GetTempPath()) ("agg-" + [guid]::NewGuid().ToString('N') + ".db")
            try {
                Invoke-SqliteQuery -DataSource $db -Query @'
CREATE TABLE tools (tool_id INTEGER PRIMARY KEY, name TEXT, domain TEXT);
CREATE TABLE tool_packages (tool_id INTEGER, source TEXT, package_id TEXT, homepage TEXT, extra TEXT, PRIMARY KEY(source,package_id));
CREATE TABLE tool_categories (tool_id INTEGER, category TEXT, PRIMARY KEY(tool_id,category));
'@
                Initialize-DFPackageUniverseCategorizeSchema -DatabasePath $db
                Invoke-SqliteQuery -DataSource $db -Query "INSERT INTO tools (tool_id,name) VALUES (1,'bat')"
                Invoke-SqliteQuery -DataSource $db -Query "INSERT INTO tool_packages (tool_id,source,package_id,homepage) VALUES (1,'choco','bat','https://github.com/sharkdp/bat')"
                Invoke-SqliteQuery -DataSource $db -Query "INSERT INTO tool_classifications (cache_key,domain,function_json,works_with_json,interface,alternative_to_json,confidence,nothing_fits,suggested_terms_json,status,classified_at) VALUES ('repo:https://github.com/sharkdp/bat|bat','text','[`"file-viewing`"]','[`"text`"]','cli','[`"cat`"]',0.9,0,'[]','done','now')"
                Update-DFPackageUniverseToolCategories -DatabasePath $db
                (Invoke-SqliteQuery -DataSource $db -Query "SELECT domain FROM tools WHERE tool_id=1").domain | Should -Be 'text'
                @(Invoke-SqliteQuery -DataSource $db -Query "SELECT category FROM tool_categories WHERE tool_id=1").category | Should -Contain 'file-viewing'
            } finally { Remove-Item -Path $db -ErrorAction Ignore }
        }
    }
}
