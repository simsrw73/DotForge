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
        extra       = $null
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
        [scriptblock]$Log
    )

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
