BeforeAll {
    Set-StrictMode -Version Latest
    Import-Module PSSQLite
    . "$PSScriptRoot/../build/Private/DFPackageUniverse.Merge.ps1"
    . "$PSScriptRoot/../build/Private/DFPackageUniverse.Categorize.ps1"
    . "$PSScriptRoot/../build/Private/DFPackageUniverse.CategoryDbPreviewExport.ps1"

    function New-PreviewDb {
        $db = Join-Path ([System.IO.Path]::GetTempPath()) ("preview-" + [guid]::NewGuid().ToString('N') + ".db")
        Invoke-SqliteQuery -DataSource $db -Query @'
CREATE TABLE tools (tool_id INTEGER PRIMARY KEY, name TEXT, source_count INTEGER);
CREATE TABLE tool_packages (tool_id INTEGER, source TEXT, package_id TEXT, homepage TEXT, extra TEXT, PRIMARY KEY(source,package_id));
CREATE TABLE tool_classifications (
  cache_key TEXT PRIMARY KEY, domain TEXT, function_json TEXT, works_with_json TEXT,
  interface TEXT, alternative_to_json TEXT, confidence REAL, nothing_fits INTEGER,
  suggested_terms_json TEXT, signal_source TEXT, model TEXT, status TEXT, classified_at TEXT
);
'@
        $db
    }
    function Add-Tool { param($Db, $Id, $Name, $SourceCount, $Src, $PackageId, $HomepageUrl = $null)
        Invoke-SqliteQuery -DataSource $Db -Query "INSERT INTO tools (tool_id,name,source_count) VALUES (@i,@n,@sc)" -SqlParameters @{ i = $Id; n = $Name; sc = $SourceCount }
        Invoke-SqliteQuery -DataSource $Db -Query "INSERT INTO tool_packages (tool_id,source,package_id,homepage) VALUES (@i,@s,@p,@h)" -SqlParameters @{ i = $Id; s = $Src; p = $PackageId; h = $HomepageUrl }
    }
    function Add-Classification { param($Db, $Key, $Domain, $Function, $WorksWith, $Interface, $AlternativeTo = @())
        Invoke-SqliteQuery -DataSource $Db -Query @'
INSERT INTO tool_classifications (cache_key, domain, function_json, works_with_json, interface, alternative_to_json, confidence, nothing_fits, suggested_terms_json, signal_source, model, status, classified_at)
VALUES (@k, @d, @fn, @ww, @if, @alt, 0.9, 0, '[]', 'readme', 'm', 'done', '2026-08-01T00:00:00Z')
'@ -SqlParameters @{ k = $Key; d = $Domain; fn = (ConvertTo-Json -Compress -InputObject @($Function)); ww = (ConvertTo-Json -Compress -InputObject @($WorksWith)); if = $Interface; alt = (ConvertTo-Json -Compress -InputObject @($AlternativeTo)) }
    }
    $script:vocab = [pscustomobject]@{ Function = @('file-viewing', 'editor'); WorksWith = @('text', 'code') }
}

Describe 'DFPackageUniverse.CategoryDbPreviewExport' {
    Context 'ConvertTo-DFPackageUniverseCategoryDbPreview' {
        It 'builds a schema-valid document from a classified tool' {
            . "$PSScriptRoot/../Private/Test-DFCategoryDbSchema.ps1"
            $db = New-PreviewDb
            try {
                Add-Tool -Db $db -Id 1 -Name 'bat' -SourceCount 3 -Src 'choco' -PackageId 'bat' -HomepageUrl 'https://github.com/sharkdp/bat'
                Add-Classification -Db $db -Key (Get-DFPackageUniverseDurableKey -Members @([pscustomobject]@{ source='choco'; package_id='bat'; homepage='https://github.com/sharkdp/bat'; extra=$null }) -Name 'bat') -Domain 'text' -Function @('file-viewing') -WorksWith @('text', 'code') -Interface 'cli' -AlternativeTo @('cat')
                $conn = New-SQLiteConnection -DataSource $db
                try { $doc = ConvertTo-DFPackageUniverseCategoryDbPreview -Connection $conn -Vocab $script:vocab -Now '2026-08-05T00:00:00Z' } finally { $conn.Close() }

                $doc.schemaVersion | Should -Be 1
                $doc.updated | Should -Be '2026-08-05T00:00:00Z'
                $doc.taxonomy.function | Should -Be @('file-viewing', 'editor')
                $doc.tools.bat.function | Should -Contain 'file-viewing'
                $doc.tools.bat.worksWith | Should -Contain 'text'
                $doc.tools.bat.interface | Should -Be 'cli'
                $doc.tools.bat.alternativeTo | Should -Contain 'cat'
                $doc.tools.bat.ids.choco | Should -Be 'bat'
                $doc.tools.bat.popularity | Should -Be 3

                $errs = $null
                Test-DFCategoryDbSchema -Database $doc -Errors ([ref]$errs) | Should -BeTrue
            } finally { Remove-Item -Path $db -ErrorAction Ignore }
        }

        It 'excludes a tool with no cached classification' {
            $db = New-PreviewDb
            try {
                Add-Tool -Db $db -Id 1 -Name 'unclassified' -SourceCount 1 -Src 'scoop' -PackageId 'unclassified'
                $conn = New-SQLiteConnection -DataSource $db
                try { $doc = ConvertTo-DFPackageUniverseCategoryDbPreview -Connection $conn -Vocab $script:vocab -Now '2026-08-05T00:00:00Z' } finally { $conn.Close() }
                @($doc.tools.PSObject.Properties | ForEach-Object { $_.Name }) | Should -Not -Contain 'unclassified'
            } finally { Remove-Item -Path $db -ErrorAction Ignore }
        }

        It 'excludes a tool with an empty function array (unclassifiable input)' {
            $db = New-PreviewDb
            try {
                Add-Tool -Db $db -Id 1 -Name 'blankfn' -SourceCount 1 -Src 'scoop' -PackageId 'blankfn'
                Add-Classification -Db $db -Key 'pkg:scoop|blankfn' -Domain $null -Function @() -WorksWith @() -Interface 'cli'
                $conn = New-SQLiteConnection -DataSource $db
                try { $doc = ConvertTo-DFPackageUniverseCategoryDbPreview -Connection $conn -Vocab $script:vocab -Now '2026-08-05T00:00:00Z' } finally { $conn.Close() }
                @($doc.tools.PSObject.Properties | ForEach-Object { $_.Name }) | Should -Not -Contain 'blankfn'
            } finally { Remove-Item -Path $db -ErrorAction Ignore }
        }

        It 'excludes a tool with an invalid interface value (data-quality artifact)' {
            $db = New-PreviewDb
            try {
                Add-Tool -Db $db -Id 1 -Name 'badinterface' -SourceCount 1 -Src 'scoop' -PackageId 'badinterface'
                Add-Classification -Db $db -Key 'pkg:scoop|badinterface' -Domain 'text' -Function @('editor') -WorksWith @() -Interface 'gui</antml parameter>'
                $conn = New-SQLiteConnection -DataSource $db
                try { $doc = ConvertTo-DFPackageUniverseCategoryDbPreview -Connection $conn -Vocab $script:vocab -Now '2026-08-05T00:00:00Z' } finally { $conn.Close() }
                @($doc.tools.PSObject.Properties | ForEach-Object { $_.Name }) | Should -Not -Contain 'badinterface'
            } finally { Remove-Item -Path $db -ErrorAction Ignore }
        }

        It 'disambiguates colliding tool names (case-insensitive) so no data is silently dropped' {
            $db = New-PreviewDb
            try {
                Add-Tool -Db $db -Id 1 -Name 'signal' -SourceCount 1 -Src 'winget' -PackageId 'Signal.Signal' -HomepageUrl 'https://github.com/signalapp/Signal-Desktop'
                Add-Tool -Db $db -Id 2 -Name 'Signal' -SourceCount 1 -Src 'winget' -PackageId 'SomeOther.Signal' -HomepageUrl 'https://github.com/other/signal'
                Add-Classification -Db $db -Key (Get-DFPackageUniverseDurableKey -Members @([pscustomobject]@{ source='winget'; package_id='Signal.Signal'; homepage='https://github.com/signalapp/Signal-Desktop'; extra=$null }) -Name 'signal') -Domain 'productivity' -Function @('editor') -WorksWith @() -Interface 'gui'
                Add-Classification -Db $db -Key (Get-DFPackageUniverseDurableKey -Members @([pscustomobject]@{ source='winget'; package_id='SomeOther.Signal'; homepage='https://github.com/other/signal'; extra=$null }) -Name 'Signal') -Domain 'dev' -Function @('file-viewing') -WorksWith @() -Interface 'cli'
                $conn = New-SQLiteConnection -DataSource $db
                try { $doc = ConvertTo-DFPackageUniverseCategoryDbPreview -Connection $conn -Vocab $script:vocab -Now '2026-08-05T00:00:00Z' } finally { $conn.Close() }

                $keys = @($doc.tools.PSObject.Properties.Name)
                $keys.Count | Should -Be 2
                # No bare, un-disambiguated 'signal'/'Signal' key -- both collided and both got a suffix.
                @($keys | Where-Object { $_ -eq 'signal' -or $_ -eq 'Signal' }) | Should -BeNullOrEmpty
                # Both tools' real data is still present somewhere under a unique key.
                $funcs = @($doc.tools.PSObject.Properties | ForEach-Object { $_.Value.function })
                $funcs | Should -Contain 'editor'
                $funcs | Should -Contain 'file-viewing'
            } finally { Remove-Item -Path $db -ErrorAction Ignore }
        }

        It 'does not disambiguate a tool whose name has no collision' {
            $db = New-PreviewDb
            try {
                Add-Tool -Db $db -Id 1 -Name 'uniquetool' -SourceCount 2 -Src 'choco' -PackageId 'uniquetool'
                Add-Classification -Db $db -Key 'pkg:choco|uniquetool' -Domain 'dev' -Function @('editor') -WorksWith @() -Interface 'cli'
                $conn = New-SQLiteConnection -DataSource $db
                try { $doc = ConvertTo-DFPackageUniverseCategoryDbPreview -Connection $conn -Vocab $script:vocab -Now '2026-08-05T00:00:00Z' } finally { $conn.Close() }
                $doc.tools.PSObject.Properties.Name | Should -Be @('uniquetool')
            } finally { Remove-Item -Path $db -ErrorAction Ignore }
        }

        It 'clamps popularity from source_count into the schema-valid 0-3 range' {
            $db = New-PreviewDb
            try {
                Add-Tool -Db $db -Id 1 -Name 'popular' -SourceCount 7 -Src 'choco' -PackageId 'popular'
                Add-Classification -Db $db -Key 'pkg:choco|popular' -Domain 'dev' -Function @('editor') -WorksWith @() -Interface 'cli'
                $conn = New-SQLiteConnection -DataSource $db
                try { $doc = ConvertTo-DFPackageUniverseCategoryDbPreview -Connection $conn -Vocab $script:vocab -Now '2026-08-05T00:00:00Z' } finally { $conn.Close() }
                $doc.tools.popular.popularity | Should -Be 3
            } finally { Remove-Item -Path $db -ErrorAction Ignore }
        }
    }

    Context 'Export-DFPackageUniversePreviewCategoryDb.ps1 (end-to-end)' {
        BeforeAll {
            Import-Module PSSQLite
            . "$PSScriptRoot/../Private/Test-DFCategoryDbSchema.ps1"

            function New-ExportFixtureDb {
                $db = Join-Path ([System.IO.Path]::GetTempPath()) ("export-" + [guid]::NewGuid().ToString('N') + ".db")
                Invoke-SqliteQuery -DataSource $db -Query @'
CREATE TABLE tools (tool_id INTEGER PRIMARY KEY, name TEXT, source_count INTEGER);
CREATE TABLE tool_packages (tool_id INTEGER, source TEXT, package_id TEXT, homepage TEXT, extra TEXT, PRIMARY KEY(source,package_id));
CREATE TABLE tool_classifications (
  cache_key TEXT PRIMARY KEY, domain TEXT, function_json TEXT, works_with_json TEXT,
  interface TEXT, alternative_to_json TEXT, confidence REAL, nothing_fits INTEGER,
  suggested_terms_json TEXT, signal_source TEXT, model TEXT, status TEXT, classified_at TEXT
);
'@
                Invoke-SqliteQuery -DataSource $db -Query "INSERT INTO tools (tool_id,name,source_count) VALUES (1,'bat',2)"
                Invoke-SqliteQuery -DataSource $db -Query "INSERT INTO tool_packages (tool_id,source,package_id,homepage) VALUES (1,'choco','bat','https://github.com/sharkdp/bat')"
                Invoke-SqliteQuery -DataSource $db -Query @'
INSERT INTO tool_classifications (cache_key, domain, function_json, works_with_json, interface, alternative_to_json, confidence, nothing_fits, suggested_terms_json, signal_source, model, status, classified_at)
VALUES ('repo:https://github.com/sharkdp/bat|bat', 'text', '["file-viewing"]', '["text"]', 'cli', '["cat"]', 0.9, 0, '[]', 'readme', 'm', 'done', '2026-08-01T00:00:00Z')
'@
                $db
            }
            $script:domains = Join-Path ([System.IO.Path]::GetTempPath()) ("export-dom-" + [guid]::NewGuid().ToString('N') + ".jsonc")
            $script:taxonomy = Join-Path ([System.IO.Path]::GetTempPath()) ("export-tax-" + [guid]::NewGuid().ToString('N') + ".jsonc")
            Set-Content -Path $script:domains -Value '{ "domain": ["text"] }' -Encoding utf8
            # Wrapped shape (matching data/tool-categories.json) -- Import-DFPackageUniverseVocab
            # always expects .taxonomy.function/.worksWith, never a flat top-level shape.
            Set-Content -Path $script:taxonomy -Value '{ "taxonomy": { "function": ["file-viewing"], "worksWith": ["text"] } }' -Encoding utf8
        }
        AfterAll { Remove-Item -Path $script:domains, $script:taxonomy -ErrorAction Ignore }

        It 'writes a schema-valid preview db to -OutPath' {
            $db = New-ExportFixtureDb
            $out = Join-Path ([System.IO.Path]::GetTempPath()) ("export-out-" + [guid]::NewGuid().ToString('N') + ".json")
            try {
                $result = & "$PSScriptRoot/../build/Export-DFPackageUniversePreviewCategoryDb.ps1" -DatabasePath $db -DomainsPath $script:domains -TaxonomyPath $script:taxonomy -OutPath $out
                $result.ToolCount | Should -Be 1
                Test-Path $out | Should -BeTrue
                $doc = Get-Content -Raw -Path $out | ConvertFrom-Json
                $doc.tools.bat.function | Should -Contain 'file-viewing'
                $errs = $null
                Test-DFCategoryDbSchema -Database $doc -Errors ([ref]$errs) | Should -BeTrue
            } finally { Remove-Item -Path $db, $out -ErrorAction Ignore }
        }

        It 'throws a clear error when XDG_DATA_HOME is unset and -OutPath is not given' {
            $db = New-ExportFixtureDb
            $saved = $Env:XDG_DATA_HOME
            try {
                $Env:XDG_DATA_HOME = $null
                { & "$PSScriptRoot/../build/Export-DFPackageUniversePreviewCategoryDb.ps1" -DatabasePath $db -DomainsPath $script:domains -TaxonomyPath $script:taxonomy } |
                    Should -Throw '*XDG_DATA_HOME*'
            } finally { $Env:XDG_DATA_HOME = $saved; Remove-Item -Path $db -ErrorAction Ignore }
        }

        It 'throws when the database does not exist' {
            $missing = Join-Path ([System.IO.Path]::GetTempPath()) ("nodb-" + [guid]::NewGuid().ToString('N') + ".db")
            { & "$PSScriptRoot/../build/Export-DFPackageUniversePreviewCategoryDb.ps1" -DatabasePath $missing -DomainsPath $script:domains -TaxonomyPath $script:taxonomy -OutPath 'unused.json' } |
                Should -Throw '*database not found*'
        }
    }
}
