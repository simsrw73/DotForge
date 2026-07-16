#Requires -Version 7.0

function Write-DFPackageUniverseTrace {
    <#
    .SYNOPSIS
        Appends one timestamped line to the verbose run log file. Deliberately
        never throws — a logging failure must not abort an acquisition run —
        and is a no-op when no log file is configured.
    .DESCRIPTION
        This is the "detailed transcript" channel: request-level timing, page
        counts, bucket boundaries, retries, cap-hits, bisections, budget usage,
        per-catalog summaries. It complements (does not replace) the structured
        pipeline_log rows in the database; every database log entry is also
        mirrored here, but many info-level trace lines appear here only.
    .PARAMETER LogFile
        Path to the run log file. When null/empty the call is a silent no-op.
    .PARAMETER Message
        The line to append (a UTC timestamp is prepended automatically).
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$LogFile,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message
    )

    if (-not $LogFile) { return }
    $line = "$([datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')) $Message"
    try {
        Add-Content -LiteralPath $LogFile -Value $line -Encoding utf8
    } catch {
        # Last-resort surfacing — the run continues regardless.
        Write-Warning "DFPackageUniverse: trace write to '$LogFile' failed: $_"
    }
}

function Initialize-DFPackageUniverseDb {
    <#
    .SYNOPSIS
        Creates the package-universe working database's tables if missing,
        then clears scoop/winget rows from raw_packages and this run's
        stage='acquire' pipeline_log rows, in preparation for a run.
    .DESCRIPTION
        pipeline_log is shared with future pipeline phases (link/merge/
        categorize per the design spec) — only this stage's own rows are
        cleared, so a rerun of acquisition never destroys another phase's log
        history. Truncation is per-source, not a blanket table wipe: scoop
        and winget are full rebuilds every run, but choco rows are never
        deleted here — choco acquisition persists across runs and upserts
        incrementally instead (see DFPackageUniverse.Choco.ps1).
    .PARAMETER DatabasePath
        Path to the SQLite working database. Parent directory is created via
        New-DFDirectory if missing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DatabasePath
    )

    New-DFDirectory (Split-Path $DatabasePath -Parent)

    Invoke-SqliteQuery -DataSource $DatabasePath -Query @'
CREATE TABLE IF NOT EXISTS raw_packages (
  id          INTEGER PRIMARY KEY,
  source      TEXT NOT NULL,
  package_id  TEXT NOT NULL,
  name        TEXT,
  version     TEXT,
  description TEXT,
  homepage    TEXT,
  license     TEXT,
  publisher   TEXT,
  tags        TEXT,
  extra       TEXT,
  fetched_at  TEXT NOT NULL,
  UNIQUE(source, package_id)
);
CREATE TABLE IF NOT EXISTS pipeline_log (
  id         INTEGER PRIMARY KEY,
  stage      TEXT NOT NULL,
  source     TEXT,
  package_id TEXT,
  level      TEXT NOT NULL,
  message    TEXT NOT NULL,
  logged_at  TEXT NOT NULL
);
'@

    # An earlier revision defined a sync_state table (a last_synced_at watermark
    # driving choco's incremental refresh). Incremental sync was deleted on
    # 2026-07-15 — a filtered "since X" query costs the same full-catalog walk
    # as fetching everything, so it bought nothing. Existing databases may still
    # carry the table; it is simply unused, and dropping it is left to whoever
    # cares to, since this database is regenerable anyway.

    Invoke-SqliteQuery -DataSource $DatabasePath -Query "DELETE FROM raw_packages WHERE source IN ('scoop', 'winget');"
    Invoke-SqliteQuery -DataSource $DatabasePath -Query "DELETE FROM pipeline_log WHERE stage = 'acquire';"
}

function Write-DFPackageUniverseRawPackage {
    <#
    .SYNOPSIS
        Upserts one normalized row into raw_packages via a parameterized
        query (safe for untrusted scraped text — descriptions/tags routinely
        contain quotes/apostrophes). Inserting a (source, package_id) that
        already exists updates the existing row rather than erroring — this
        is what makes choco's incremental re-delivery and its confirmed
        duplicate-page pagination quirk safe to write without per-row
        try/catch around a unique-constraint violation.
    .PARAMETER Connection
        An open PSSQLite connection (New-SQLiteConnection), reused across
        writes for the whole run.
    .PARAMETER Row
        A pscustomobject with source, package_id, name, version, description,
        homepage, license, publisher, tags, extra, fetched_at fields.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Connection,

        [Parameter(Mandatory)]
        [pscustomobject]$Row
    )

    Invoke-SqliteQuery -SQLiteConnection $Connection -Query @'
INSERT INTO raw_packages (source, package_id, name, version, description, homepage, license, publisher, tags, extra, fetched_at)
VALUES (@source, @package_id, @name, @version, @description, @homepage, @license, @publisher, @tags, @extra, @fetched_at)
ON CONFLICT(source, package_id) DO UPDATE SET
  name = excluded.name, version = excluded.version, description = excluded.description,
  homepage = excluded.homepage, license = excluded.license, publisher = excluded.publisher,
  tags = excluded.tags, extra = excluded.extra, fetched_at = excluded.fetched_at;
'@ -SqlParameters @{
        source      = $Row.source
        package_id  = $Row.package_id
        name        = $Row.name
        version     = $Row.version
        description = $Row.description
        homepage    = $Row.homepage
        license     = $Row.license
        publisher   = $Row.publisher
        tags        = $Row.tags
        extra       = $Row.extra
        fetched_at  = $Row.fetched_at
    }
}

function Get-DFPackageUniverseExistingPackageIds {
    <#
    .SYNOPSIS
        Returns the set of package_ids currently in raw_packages for one
        source. Used to prune stale rows after a full choco re-crawl (a
        package_id that existed before but wasn't seen in a fresh crawl has
        presumably been removed upstream).
    .PARAMETER Connection
        An open PSSQLite connection.
    .PARAMETER Source
        The catalog to scope the lookup to.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        $Connection,

        [Parameter(Mandatory)]
        [string]$Source
    )

    @(Invoke-SqliteQuery -SQLiteConnection $Connection -Query 'SELECT package_id FROM raw_packages WHERE source = @source;' -SqlParameters @{ source = $Source }).package_id
}

function Remove-DFPackageUniverseRawPackage {
    <#
    .SYNOPSIS
        Deletes one (source, package_id) row from raw_packages — used to
        prune packages no longer present in a fresh full choco crawl.
    .PARAMETER Connection
        An open PSSQLite connection.
    .PARAMETER Source
        The catalog the row belongs to.
    .PARAMETER PackageId
        The package_id to remove.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Connection,

        [Parameter(Mandatory)]
        [string]$Source,

        [Parameter(Mandatory)]
        [string]$PackageId
    )

    Invoke-SqliteQuery -SQLiteConnection $Connection -Query 'DELETE FROM raw_packages WHERE source = @source AND package_id = @package_id;' `
        -SqlParameters @{ source = $Source; package_id = $PackageId }
}

# Get-DFPackageUniverseSyncState / Set-DFPackageUniverseSyncState lived here.
# Both were deleted on 2026-07-15 with the incremental-sync design: choco now
# performs one unfiltered walk of the whole catalog every run, so there is no
# watermark to read or advance. See DFPackageUniverse.Choco.ps1's header.

function Write-DFPackageUniverseLogEntry {
    <#
    .SYNOPSIS
        Inserts one row into the shared pipeline_log table, tagged
        stage='acquire'.
    .PARAMETER Connection
        An open PSSQLite connection (New-SQLiteConnection), reused across
        writes for the whole run.
    .PARAMETER Level
        One of 'error' (a catalog or item totally failed), 'warning' (a
        single item was skipped), or 'review' (parsed fine but worth a human
        glance later).
    .PARAMETER Source
        Which catalog this entry concerns, if applicable. May be $null.
    .PARAMETER PackageId
        Which package this entry concerns, if applicable. May be $null.
    .PARAMETER Message
        Human-readable log message.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Connection,

        [Parameter(Mandatory)]
        [ValidateSet('error', 'warning', 'review')]
        [string]$Level,

        [string]$Source,

        [string]$PackageId,

        [Parameter(Mandatory)]
        [string]$Message
    )

    Invoke-SqliteQuery -SQLiteConnection $Connection -Query @'
INSERT INTO pipeline_log (stage, source, package_id, level, message, logged_at)
VALUES ('acquire', @source, @package_id, @level, @message, @logged_at);
'@ -SqlParameters @{
        source     = $Source
        package_id = $PackageId
        level      = $Level
        message    = $Message
        logged_at  = [datetime]::UtcNow.ToString('o')
    }
}
