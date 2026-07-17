#Requires -Version 7.0

function ConvertTo-DFPackageUniverseScoopRow {
    <#
    .SYNOPSIS
        Maps one Build-DFCatalogScoopIndexData entry (name, bucket, version,
        description, homepage, license) to a raw_packages row.
    .PARAMETER Entry
        One entry as returned by Build-DFCatalogScoopIndexData.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Entry
    )

    # Full-fidelity capture: the scoop manifest is already clean JSON, so store
    # it verbatim (checkver/autoupdate frequently name the real GitHub repo even
    # when homepage is a vanity domain; bin/depends/suggest/notes come along too).
    # Strict-safe probe: a raw-less entry (runtime-shaped, or a test fixture)
    # yields $null rather than throwing under Set-StrictMode.
    $rawProp = $Entry.PSObject.Properties['raw']
    $extra = if ($rawProp -and $rawProp.Value) { [string]$rawProp.Value } else { $null }

    [pscustomobject]@{
        source      = 'scoop'
        package_id  = "$($Entry.bucket)/$($Entry.name)"
        name        = $Entry.name
        version     = $Entry.version
        description = $Entry.description
        homepage    = $Entry.homepage
        license     = $Entry.license
        publisher   = $null
        tags        = $null
        extra       = $extra
        fetched_at  = [datetime]::UtcNow.ToString('o')
    }
}

function Get-DFPackageUniverseScoopRows {
    <#
    .SYNOPSIS
        Acquires raw_packages rows for every locally-added scoop bucket
        manifest. Logs an error (no rows) or a warning per unmappable entry
        rather than throwing, so one bad manifest never aborts the crawl.
    .PARAMETER ScoopRoot
        The scoop root directory passed to FetchItems.
    .PARAMETER FetchItems
        Scriptblock: param($ScoopRoot) -> manifest entries. Defaults to
        Build-DFCatalogScoopIndexData; tests inject canned entries here.
    .PARAMETER ScoopUpdate
        Optional scriptblock run before acquisition to refresh the local buckets
        (git-pull), so the snapshot reflects current upstream manifests rather
        than whatever was last on disk -- scoop, unlike the winget snapshot
        re-download and the live choco walk, reads local bucket clones. A failure
        here (scoop not installed, offline) logs a warning and acquisition
        proceeds against the on-disk buckets. Omit to skip the refresh.
    .PARAMETER Log
        Scriptblock: param($Level, $PackageId, $Message) -> logs to
        pipeline_log.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ScoopRoot,

        [Parameter(Mandatory)]
        [scriptblock]$FetchItems,

        [Parameter(Mandatory)]
        [scriptblock]$Log,

        [scriptblock]$ScoopUpdate
    )

    if ($ScoopUpdate) {
        try { & $ScoopUpdate }
        catch { & $Log 'warning' $null "scoop: bucket refresh ('scoop update') failed; reading buckets as-is: $_" }
    }

    $items = @(& $FetchItems $ScoopRoot)
    if ($items.Count -eq 0) {
        & $Log 'error' $null 'scoop: no manifests found (no buckets added, or buckets directory missing)'
        return @()
    }

    foreach ($entry in $items) {
        try {
            ConvertTo-DFPackageUniverseScoopRow -Entry $entry
        } catch {
            & $Log 'warning' "$($entry.bucket)/$($entry.name)" "unmappable scoop entry: $_"
        }
    }
}
