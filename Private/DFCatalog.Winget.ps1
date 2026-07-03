#Requires -Version 7.0

# Winget catalog provider (snapshot kind). The winget CLI's slowness is process
# startup + MSIX verification, not the search — the catalog is just a SQLite
# database inside the locally cached source.msix. We extract Public/index.db
# once (keyed on msix mtime+size) and query it directly via winsqlite3.dll in
# milliseconds. Fallback when the schema is unreadable: parse `winget search`
# CLI output, cached through the query-cache engine (degraded mode).
#
# Verified index schema (V2): packages(id, name, moniker, latest_version) plus
# a metadata table carrying majorVersion. installed.db uses the V1 normalized
# layout (manifest joined to ids/names/versions). index.db carries no
# description/homepage/license — the merged card fills those from other catalogs.

function Get-DFCatalogWingetMsixPath {
    <#
    .SYNOPSIS
        Returns the expected location of winget's cached community source msix.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    Join-Path $Env:LOCALAPPDATA 'Microsoft\WinGet\State\defaultState\Microsoft.PreIndexed.Package\Microsoft.Winget.Source_8wekyb3d8bbwe\source.msix'
}

function Update-DFCatalogWingetIndex {
    <#
    .SYNOPSIS
        Extracts Public/index.db from winget's source.msix into the catalog
        cache, keyed on the msix's size + mtime so unchanged sources are never
        re-extracted.
    .PARAMETER MsixPath
        The source.msix location (defaults to the standard winget cache path).
    .PARAMETER Force
        Re-extract even when the msix is unchanged.
    #>
    [CmdletBinding()]
    param(
        [string]$MsixPath = (Get-DFCatalogWingetMsixPath),

        [switch]$Force
    )

    $cacheRoot = Get-DFCatalogCacheRoot
    if (-not $cacheRoot) { return }
    if (-not (Test-Path $MsixPath)) { return }

    $dir = Join-Path $cacheRoot 'winget'
    $indexFile = Join-Path $dir 'index.db'
    $metaFile = Join-Path $dir 'index.meta.json'
    $msix = Get-Item $MsixPath

    if (-not $Force -and (Test-Path $indexFile) -and (Test-Path $metaFile)) {
        try {
            $meta = Get-Content $metaFile -Raw | ConvertFrom-Json
            if ($meta.length -eq $msix.Length -and $meta.lastWriteTicks -eq $msix.LastWriteTimeUtc.Ticks) {
                return
            }
        } catch {}
    }

    New-DFDirectory $dir
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($msix.FullName)
    try {
        $entry = $zip.Entries | Where-Object FullName -eq 'Public/index.db' | Select-Object -First 1
        if (-not $entry) {
            Write-Verbose "DotForge: no Public/index.db inside $MsixPath"
            return
        }
        $tmp = "$indexFile.tmp.$PID"
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $tmp, $true)
        Move-Item -Path $tmp -Destination $indexFile -Force
    } finally {
        $zip.Dispose()
    }

    @{
        path           = $msix.FullName
        lastWriteTicks = $msix.LastWriteTimeUtc.Ticks
        length         = $msix.Length
    } | ConvertTo-Json | Set-Content -Path $metaFile -Encoding UTF8
}

function Get-DFCatalogWingetIndexPath {
    <#
    .SYNOPSIS
        Ensures the extracted winget index is current and returns its path,
        or $null when unavailable.
    .PARAMETER Force
        Force re-extraction first.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [switch]$Force
    )

    $cacheRoot = Get-DFCatalogCacheRoot
    if (-not $cacheRoot) { return $null }

    Update-DFCatalogWingetIndex -Force:$Force
    $indexFile = Join-Path $cacheRoot 'winget/index.db'
    (Test-Path $indexFile) ? $indexFile : $null
}

function Invoke-DFCatalogWingetCli {
    <#
    .SYNOPSIS
        Runs `winget search` and returns the raw output lines. Mockable seam
        for the CLI-parse fallback.
    .PARAMETER Query
        The search query.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Query
    )

    if (-not (Get-Command winget -ErrorAction Ignore)) {
        throw 'winget.exe is not available'
    }
    winget search --query $Query --source winget --disable-interactivity 2>$null
}

function Invoke-DFCatalogWingetCliSearch {
    <#
    .SYNOPSIS
        Degraded-mode winget search: parses the CLI's fixed-width column output
        using the header line's column offsets.
    .PARAMETER Query
        Normalized query text.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Query
    )

    $lines = @(Invoke-DFCatalogWingetCli -Query $Query)

    $headerIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^Name\s+Id\s+Version') { $headerIndex = $i; break }
    }
    if ($headerIndex -lt 0 -or $headerIndex + 2 -ge $lines.Count) { return @() }

    $header = $lines[$headerIndex]
    $idColumn = $header.IndexOf('Id')
    $versionColumn = $header.IndexOf('Version')

    foreach ($line in $lines[($headerIndex + 2)..($lines.Count - 1)]) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.Length -le $idColumn) { continue }

        $name = $line.Substring(0, $idColumn).Trim()
        $rest = $line.Substring($idColumn)
        $idWidth = $versionColumn - $idColumn
        $id = ($rest.Length -gt $idWidth) ? $rest.Substring(0, $idWidth).Trim() : $rest.Trim()
        $version = ($line.Length -gt $versionColumn) ? (($line.Substring($versionColumn) -split '\s{2,}')[0]).Trim() : ''
        if (-not $id) { continue }

        New-DFToolSourceInfo -Source 'winget' `
            -PackageId $id `
            -Name ($name ? $name : $id) `
            -LatestVersion $version `
            -MatchKind (($id -ieq $Query -or $name -ieq $Query) ? 'exact-id' : 'keyword')
    }
}

function Search-DFCatalogWinget {
    <#
    .SYNOPSIS
        Searches the winget catalog: direct SQLite on the extracted index
        (milliseconds), degrading to cached CLI parsing when the index or its
        schema is unreadable.
    .PARAMETER Query
        Name, keywords, package id, or moniker (e.g. 'rg').
    .PARAMETER IndexPath
        Override the extracted index.db location (tests).
    .PARAMETER Fresh
        Force re-extraction / a live CLI fetch.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Query,

        [string]$IndexPath,

        [switch]$Fresh
    )

    $normalized = (ConvertTo-DFCatalogQueryKey -Query $Query).Normalized
    $ageMinutes = 0

    if (-not $IndexPath) {
        $IndexPath = Get-DFCatalogWingetIndexPath -Force:$Fresh
        if ($IndexPath) {
            $msixPath = Get-DFCatalogWingetMsixPath
            if (Test-Path $msixPath) {
                $ageMinutes = [int]([datetime]::UtcNow - (Get-Item $msixPath).LastWriteTimeUtc).TotalMinutes
            }
        }
    }

    if ($IndexPath) {
        # A readable metadata table proves the db is queryable, so an empty
        # search result below is a real no-match, not a failure.
        $major = @(Invoke-DFSqliteQuery -Database $IndexPath -Query "SELECT value FROM metadata WHERE name = 'majorVersion'")
        if ($major -and $major[0].value -eq '2') {
            $safe = $normalized -replace "'", "''"
            $words = $safe -split ' '
            $conditions = foreach ($word in $words) { "(lower(id) || ' ' || lower(name)) LIKE '%$word%'" }
            $where = $conditions -join ' AND '
            if ($words.Count -eq 1) { $where = "($where) OR lower(moniker) = '$safe'" }

            $exact = "lower(id) = '$safe' OR lower(name) = '$safe' OR lower(moniker) = '$safe'"
            $rows = @(Invoke-DFSqliteQuery -Database $IndexPath `
                -Query "SELECT id, name, moniker, latest_version FROM packages WHERE $where ORDER BY CASE WHEN $exact THEN 0 ELSE 1 END, id LIMIT 25")

            $timestamp = [datetime]::UtcNow.AddMinutes(-$ageMinutes)
            foreach ($row in $rows) {
                if (-not $row.id) { continue }
                $kind = if ($row.id.ToLowerInvariant() -eq $normalized) { 'exact-id' }
                        elseif (($row.name -and $row.name.ToLowerInvariant() -eq $normalized) -or
                                ($row.moniker -and $row.moniker.ToLowerInvariant() -eq $normalized)) { 'exact-name' }
                        else { 'keyword' }
                New-DFToolSourceInfo -Source 'winget' `
                    -PackageId $row.id `
                    -Name ($row.name ? $row.name : $row.id) `
                    -LatestVersion ([string]$row.latest_version) `
                    -MatchKind $kind `
                    -CacheTimestamp $timestamp `
                    -CacheAgeMinutes $ageMinutes
            }
            return
        }
        Write-Verbose 'DotForge: winget index schema unreadable — degrading to CLI parse'
    }

    Search-DFCatalogQueryCache -Provider 'winget' -Query $Query -Fresh:$Fresh `
        -Fetch { param($q) Invoke-DFCatalogWingetCliSearch -Query $q }
}

function Get-DFCatalogWingetInstalledDbPath {
    <#
    .SYNOPSIS
        Locates winget's installed-package tracking database. Mockable seam.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $candidates = @(
        (Join-Path $Env:LOCALAPPDATA 'Microsoft\WinGet\State\defaultState\Microsoft.Winget.Source_8wekyb3d8bbwe\installed.db'),
        (Join-Path $Env:LOCALAPPDATA 'Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState\Microsoft.Winget.Source_8wekyb3d8bbwe\installed.db')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) { return $candidate }
    }
    $null
}

function Get-DFCatalogWingetInstalled {
    <#
    .SYNOPSIS
        Lists winget-installed packages by querying the V1-layout installed.db
        (manifest joined to ids/names/versions) — no winget.exe invocation.
    #>
    [CmdletBinding()]
    param()

    $dbPath = Get-DFCatalogWingetInstalledDbPath
    if (-not $dbPath) { return }

    $rows = Invoke-DFSqliteQuery -Database $dbPath -Query @'
SELECT i.id AS pkg_id, n.name AS pkg_name, v.version AS pkg_version
FROM manifest m
JOIN ids i ON m.id = i.rowid
JOIN names n ON m.name = n.rowid
JOIN versions v ON m.version = v.rowid
'@

    foreach ($row in @($rows)) {
        if (-not $row.pkg_id) { continue }
        [pscustomobject]@{
            Source           = 'winget'
            Name             = $row.pkg_name ? $row.pkg_name : $row.pkg_id
            PackageId        = $row.pkg_id
            InstalledVersion = [string]$row.pkg_version
        }
    }
}

if (-not $script:DFCatalogProviders) { $script:DFCatalogProviders = @{} }
$script:DFCatalogProviders['winget'] = @{
    Name         = 'winget'
    Kind         = 'snapshot'
    Test         = { (Test-Path (Get-DFCatalogWingetMsixPath)) -or [bool](Get-Command winget -ErrorAction Ignore) }
    Search       = { param($Query, $Fresh) Search-DFCatalogWinget -Query $Query -Fresh:$Fresh }
    GetInstalled = { Get-DFCatalogWingetInstalled }
    Refresh      = { param($Query) Update-DFCatalogWingetIndex -Force }
}
