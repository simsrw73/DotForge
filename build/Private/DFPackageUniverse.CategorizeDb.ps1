#Requires -Version 7.0

# Phase D (categorization) DB layer: the PERSISTENT classification cache +
# fetch cache, plus jsonc export/import. Unlike Phases A-C this stage NEVER
# truncates its tables -- the cache is the resume state. See the design spec.

function Initialize-DFPackageUniverseCategorizeSchema {
    <#
    .SYNOPSIS
        Creates the Phase D cache tables if missing. Clears NOTHING -- the
        classification cache is durable resume state; wiping it would destroy
        paid LLM work. Idempotent (safe to call every run).
    .DESCRIPTION
        tool_classifications caches per-tool LLM classification results,
        keyed by a durable cache_key (see Get-DFPackageUniverseDurableKey),
        so a rerun after a partial failure or budget cutoff resumes instead
        of re-paying for tools already classified. fetch_cache caches fetched
        URLs (README/repo signal fetches) so reruns don't re-hit the network
        for content already retrieved. Both tables are created with
        CREATE TABLE IF NOT EXISTS only -- no DELETE, no DROP, ever -- because
        this function may run at the start of every categorization pass.
    .PARAMETER DatabasePath
        Path to the SQLite cache database.
    .EXAMPLE
        Initialize-DFPackageUniverseCategorizeSchema -DatabasePath ./data/categorize.db

        Ensures the cache tables exist, without disturbing any prior run's
        cached classifications or fetched content.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DatabasePath)

    Invoke-SqliteQuery -DataSource $DatabasePath -Query @'
CREATE TABLE IF NOT EXISTS tool_classifications (
  cache_key TEXT PRIMARY KEY,
  domain TEXT,
  function_json TEXT,
  works_with_json TEXT,
  interface TEXT,
  alternative_to_json TEXT,
  confidence REAL,
  nothing_fits INTEGER NOT NULL DEFAULT 0,
  suggested_terms_json TEXT,
  signal_source TEXT,
  model TEXT,
  status TEXT NOT NULL,          -- done | deferred
  classified_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS fetch_cache (
  url TEXT PRIMARY KEY,
  content TEXT,
  content_type TEXT,
  status TEXT,
  fetched_at TEXT NOT NULL
);
'@
}

function Save-DFPackageUniverseClassification {
    <#
    .SYNOPSIS
        Upserts one classification into the durable cache (arrays serialized to
        JSON, @()/-InputObject to avoid single-element unwrap). Status is
        'done' or 'deferred'.
    .DESCRIPTION
        Writes (or overwrites, by cache_key) one row into tool_classifications.
        Array-valued fields on the Classification object (Function, WorksWith,
        AlternativeTo, SuggestedTerms) are serialized to compact JSON with
        ConvertTo-Json -InputObject @(...) so a single-element array is not
        unwrapped to a bare scalar. This is the write path used both for
        live LLM classification results and for jsonc re-import.
    .PARAMETER Connection
        An open PSSQLite connection (from New-SQLiteConnection) to the cache
        database. The caller owns opening/closing this connection.
    .PARAMETER CacheKey
        The durable cache key identifying the classified tool (see
        Get-DFPackageUniverseDurableKey).
    .PARAMETER Classification
        An object with Domain, Function, WorksWith, Interface, AlternativeTo,
        Confidence, NothingFits, and SuggestedTerms properties.
    .PARAMETER SignalSource
        Free-text description of what signal drove the classification (e.g.
        'readme').
    .PARAMETER Model
        The LLM model identifier used to produce the classification.
    .PARAMETER Status
        One of 'done' or 'deferred'.
    .EXAMPLE
        Save-DFPackageUniverseClassification -Connection $conn -CacheKey 'repo:https://github.com/sharkdp/bat|bat' -Classification $cls -SignalSource 'readme' -Model 'gpt-test' -Status 'done'

        Upserts the classification for bat into tool_classifications.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Connection, [Parameter(Mandatory)][string]$CacheKey,
        [Parameter(Mandatory)]$Classification, [string]$SignalSource, [string]$Model,
        [Parameter(Mandatory)][ValidateSet('done', 'deferred')][string]$Status
    )
    $c = $Classification
    Invoke-SqliteQuery -SQLiteConnection $Connection -Query @'
INSERT OR REPLACE INTO tool_classifications
  (cache_key, domain, function_json, works_with_json, interface, alternative_to_json,
   confidence, nothing_fits, suggested_terms_json, signal_source, model, status, classified_at)
VALUES (@k, @dom, @fn, @ww, @if, @alt, @conf, @nf, @st, @src, @model, @status, @at);
'@ -SqlParameters @{
        k = $CacheKey; dom = $c.Domain
        fn = (ConvertTo-Json -Compress -InputObject @($c.Function)); ww = (ConvertTo-Json -Compress -InputObject @($c.WorksWith))
        if = $c.Interface; alt = (ConvertTo-Json -Compress -InputObject @($c.AlternativeTo)); conf = $c.Confidence
        nf = [int][bool]$c.NothingFits; st = (ConvertTo-Json -Compress -InputObject @($c.SuggestedTerms))
        src = $SignalSource; model = $Model; status = $Status; at = [datetime]::UtcNow.ToString('o')
    }
}

function Export-DFPackageUniverseClassifications {
    <#
    .SYNOPSIS
        Writes all done classifications to the version-controlled JSONC (the
        source of truth that survives a universe.db rebuild).
    .DESCRIPTION
        Reads every tool_classifications row with status = 'done', in
        cache_key order for stable diffs, and writes them as a JSON document
        (schemaVersion + classifications array) to Path. Array-valued fields
        are re-parsed from their stored JSON columns and re-wrapped in @(...)
        so single-element arrays round-trip correctly. This file is meant to
        be committed to source control so classification work survives a
        universe.db rebuild.
    .PARAMETER DatabasePath
        Path to the SQLite cache database to read from.
    .PARAMETER Path
        Path to the JSONC file to write.
    .EXAMPLE
        Export-DFPackageUniverseClassifications -DatabasePath ./data/categorize.db -Path ./data/classifications.jsonc

        Writes all 'done' classifications to the version-controlled jsonc file.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DatabasePath, [Parameter(Mandatory)][string]$Path)
    $rows = @(Invoke-SqliteQuery -DataSource $DatabasePath -Query "SELECT * FROM tool_classifications WHERE status = 'done' ORDER BY cache_key")
    $out = @(foreach ($r in $rows) {
        [ordered]@{
            cacheKey = $r.cache_key; domain = $r.domain
            function = @(($r.function_json | ConvertFrom-Json)); worksWith = @(($r.works_with_json | ConvertFrom-Json))
            interface = $r.interface; alternativeTo = @(($r.alternative_to_json | ConvertFrom-Json))
            suggestedTerms = @(($r.suggested_terms_json | ConvertFrom-Json))
            confidence = $r.confidence; nothingFits = [bool]$r.nothing_fits
            signalSource = $r.signal_source; model = $r.model
        }
    })
    $doc = [ordered]@{ schemaVersion = 1; classifications = $out }
    ($doc | ConvertTo-Json -Depth 8) | Set-Content -Path $Path -Encoding utf8
}

function Import-DFPackageUniverseClassifications {
    <#
    .SYNOPSIS
        Loads the version-controlled JSONC into tool_classifications (rebuild
        survival). JSONC line/block comments stripped. Missing file is a no-op.
    .DESCRIPTION
        Strips // line comments and /* */ block comments from the JSONC file,
        parses the remainder as JSON, and upserts each classification entry
        into tool_classifications with status 'done'. This is the recovery
        path after a universe.db rebuild: the durable JSONC (produced by
        Export-DFPackageUniverseClassifications) is the source of truth, and
        importing it repopulates the cache so previously classified tools are
        not re-sent to the LLM. If Path does not exist, this is a silent no-op
        (a fresh universe with no prior classification history is valid).
    .PARAMETER DatabasePath
        Path to the SQLite cache database to load into.
    .PARAMETER Path
        Path to the JSONC file to read.
    .EXAMPLE
        Import-DFPackageUniverseClassifications -DatabasePath ./data/categorize.db -Path ./data/classifications.jsonc

        Repopulates tool_classifications from the version-controlled jsonc file.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DatabasePath, [Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { return }
    $t = Get-Content -Raw -Path $Path
    $t = [regex]::Replace($t, '(?m)^\s*//.*$', ''); $t = [regex]::Replace($t, '(?s)/\*.*?\*/', '')
    $doc = $t | ConvertFrom-Json
    $conn = New-SQLiteConnection -DataSource $DatabasePath
    try {
        foreach ($e in @($doc.classifications)) {
            Invoke-SqliteQuery -SQLiteConnection $conn -Query @'
INSERT OR REPLACE INTO tool_classifications
  (cache_key, domain, function_json, works_with_json, interface, alternative_to_json,
   confidence, nothing_fits, suggested_terms_json, signal_source, model, status, classified_at)
VALUES (@k, @dom, @fn, @ww, @if, @alt, @conf, @nf, @st, @src, @model, 'done', @at);
'@ -SqlParameters @{
                k = $e.cacheKey; dom = $e.domain
                fn = (ConvertTo-Json -Compress -InputObject @($e.function)); ww = (ConvertTo-Json -Compress -InputObject @($e.worksWith))
                if = $e.interface; alt = (ConvertTo-Json -Compress -InputObject @($e.alternativeTo)); conf = $e.confidence
                nf = [int][bool]$e.nothingFits; st = (ConvertTo-Json -Compress -InputObject @($e.suggestedTerms))
                src = $e.signalSource; model = $e.model; at = [datetime]::UtcNow.ToString('o')
            }
        }
    } finally { $conn.Close() }
}

function Update-DFPackageUniverseToolCategories {
    <#
    .SYNOPSIS
        Writes each tool the classification cached under its durable key: sets
        tools.domain and replaces its Phase C first-pass tool_categories with the
        classifier's function facets. Idempotent. Requires
        Get-DFPackageUniverseDurableKey to be loaded (orchestrator dot-sources it).
    .DESCRIPTION
        For every row in tools, computes the tool's durable key from its merged
        tool_packages members (Get-DFPackageUniverseDurableKey) and looks up the
        cached 'done' classification for that key in tool_classifications. When
        found, writes the classification's domain onto tools.domain (a column
        added via ALTER TABLE on first call if not already present) and REPLACEs
        the tool's tool_categories rows with the classifier's function facets --
        so downstream discovery reads the richer classifier-derived categories
        instead of the Phase C first-pass ones. Tools with no members or no
        cached classification are left untouched. The whole pass is one
        transaction, rolled back on any failure. Safe to re-run.
    .PARAMETER DatabasePath
        Path to the SQLite database holding tools, tool_packages, tool_categories,
        and tool_classifications.
    .EXAMPLE
        Update-DFPackageUniverseToolCategories -DatabasePath ./data/universe.db

        Writes tools.domain and refreshes tool_categories for every tool with a
        cached classification.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DatabasePath)

    $cols = @(Invoke-SqliteQuery -DataSource $DatabasePath -Query "PRAGMA table_info(tools)").name
    if ($cols -notcontains 'domain') { Invoke-SqliteQuery -DataSource $DatabasePath -Query "ALTER TABLE tools ADD COLUMN domain TEXT" }

    $tools = @(Invoke-SqliteQuery -DataSource $DatabasePath -Query 'SELECT tool_id, name FROM tools')
    $members = @(Invoke-SqliteQuery -DataSource $DatabasePath -Query 'SELECT tool_id, source, package_id, homepage, extra FROM tool_packages')
    $byTool = @{}
    foreach ($m in $members) {
        $id = [int]$m.tool_id
        if (-not $byTool.ContainsKey($id)) { $byTool[$id] = [System.Collections.Generic.List[object]]::new() }
        $byTool[$id].Add([pscustomobject]@{ source = $m.source; package_id = $m.package_id; homepage = (ConvertFrom-DFDbNull $m.homepage); extra = (ConvertFrom-DFDbNull $m.extra) })
    }
    $conn = New-SQLiteConnection -DataSource $DatabasePath
    try {
        Invoke-SqliteQuery -SQLiteConnection $conn -Query 'BEGIN TRANSACTION;'
        foreach ($t in $tools) {
            $id = [int]$t.tool_id
            $mm = @($byTool[$id])
            if ($mm.Count -eq 0) { continue }
            $key = Get-DFPackageUniverseDurableKey -Members $mm -Name ([string]$t.name)
            $c = @(Invoke-SqliteQuery -SQLiteConnection $conn -Query "SELECT domain, function_json FROM tool_classifications WHERE cache_key=@k AND status='done'" -SqlParameters @{ k = $key })
            if ($c.Count -eq 0) { continue }
            Invoke-SqliteQuery -SQLiteConnection $conn -Query 'UPDATE tools SET domain=@d WHERE tool_id=@i' -SqlParameters @{ d = (ConvertFrom-DFDbNull $c[0].domain); i = $id }
            Invoke-SqliteQuery -SQLiteConnection $conn -Query 'DELETE FROM tool_categories WHERE tool_id=@i' -SqlParameters @{ i = $id }
            foreach ($fn in @(($c[0].function_json | ConvertFrom-Json))) {
                Invoke-SqliteQuery -SQLiteConnection $conn -Query 'INSERT OR IGNORE INTO tool_categories (tool_id, category) VALUES (@i, @c)' -SqlParameters @{ i = $id; c = $fn }
            }
        }
        Invoke-SqliteQuery -SQLiteConnection $conn -Query 'COMMIT;'
    } catch { Invoke-SqliteQuery -SQLiteConnection $conn -Query 'ROLLBACK;'; throw } finally { $conn.Close() }
}
