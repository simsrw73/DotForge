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

    It 'binds a single -Parameters value into a placeholder' -Skip:(-not $script:HasSqlite) {
        $rows = @(Invoke-DFSqliteQuery -Database $script:Fixture `
            -Query 'SELECT latest_version FROM packages WHERE id = ?' `
            -Parameters @('BurntSushi.ripgrep.MSVC'))
        $rows[0].latest_version | Should -Be '15.1.0'
    }

    It 'binds multiple -Parameters values in left-to-right order' -Skip:(-not $script:HasSqlite) {
        $rows = @(Invoke-DFSqliteQuery -Database $script:Fixture `
            -Query 'SELECT id FROM packages WHERE id = ? OR id = ? ORDER BY id' `
            -Parameters @('sharkdp.fd', 'BurntSushi.ripgrep.MSVC'))
        $rows.Count | Should -Be 2
        $rows[0].id | Should -Be 'BurntSushi.ripgrep.MSVC'
        $rows[1].id | Should -Be 'sharkdp.fd'
    }

    It 'binds a repeated -Parameters entry to each of its placeholders' -Skip:(-not $script:HasSqlite) {
        # The same value bound at three separate `?`s, matching the shape
        # DFCatalog.Winget.ps1's exact-match clause needs (id = ? OR name = ?
        # OR moniker = ?, all the same search term).
        $rows = @(Invoke-DFSqliteQuery -Database $script:Fixture `
            -Query 'SELECT id FROM packages WHERE id = ? OR id = ? OR id = ?' `
            -Parameters @('BurntSushi.ripgrep.MSVC', 'BurntSushi.ripgrep.MSVC', 'BurntSushi.ripgrep.MSVC'))
        $rows.Count | Should -Be 1
    }

    It 'treats a bound value as literal data, never as SQL' -Skip:(-not $script:HasSqlite) {
        # A classic injection payload: if it were concatenated instead of
        # bound, "id = 'x' OR '1'='1'" would match every row. Bound, it must
        # only ever match a row whose id is literally that whole string.
        $rows = @(Invoke-DFSqliteQuery -Database $script:Fixture `
            -Query 'SELECT id FROM packages WHERE id = ?' `
            -Parameters @("x' OR '1'='1"))
        $rows.Count | Should -Be 0
    }
}
