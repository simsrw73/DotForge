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
}
