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
