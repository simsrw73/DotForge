BeforeDiscovery {
    # -Skip: expressions evaluate during discovery, before BeforeAll runs.
    $script:HasSqlite = Test-Path "$Env:SystemRoot\System32\winsqlite3.dll"
}

BeforeAll {
    . "$PSScriptRoot/../Private/Invoke-DFSqliteQuery.ps1"
    $script:Fixture = Join-Path $PSScriptRoot 'fixtures/winget-index-v2.db'
}

Describe 'Invoke-DFSqliteQuery' {
    It 'queries rows from a SQLite database as PSCustomObjects' -Skip:(-not $script:HasSqlite) {
        $rows = @(Invoke-DFSqliteQuery -Database $script:Fixture -Query 'SELECT id, latest_version FROM packages ORDER BY id')
        $rows.Count | Should -Be 2
        $rows[0].id | Should -Be 'BurntSushi.ripgrep.MSVC'
        $rows[0].latest_version | Should -Be '15.1.0'
        $rows[1].id | Should -Be 'sharkdp.fd'
    }

    It 'reads the metadata version table' -Skip:(-not $script:HasSqlite) {
        $rows = @(Invoke-DFSqliteQuery -Database $script:Fixture -Query "SELECT value FROM metadata WHERE name = 'majorVersion'")
        $rows[0].value | Should -Be '2'
    }

    It 'returns $null for a missing database file' {
        Invoke-DFSqliteQuery -Database (Join-Path $TestDrive 'nope.db') -Query 'SELECT 1' |
            Should -BeNullOrEmpty
    }

    It 'returns $null for an invalid query instead of throwing' -Skip:(-not $script:HasSqlite) {
        Invoke-DFSqliteQuery -Database $script:Fixture -Query 'SELECT * FROM no_such_table' |
            Should -BeNullOrEmpty
    }
}
