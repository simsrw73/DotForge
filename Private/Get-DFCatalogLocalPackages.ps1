#Requires -Version 7.0

function Get-DFCatalogLocalPackages {
    <#
    .SYNOPSIS
        Aggregates every locally cached catalog (scoop index, winget index,
        cached web queries, installed snapshot) into one entry per package name
        with merged sources — never touches the network.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    $cacheRoot = Get-DFCatalogCacheRoot
    if (-not $cacheRoot) { return }

    $aggregate = [ordered]@{}
    $add = {
        param($Name, $Source, $Description)
        if (-not $Name) { return }
        $key = ([string]$Name).ToLowerInvariant()
        if (-not $aggregate.Contains($key)) {
            $aggregate[$key] = @{
                Name        = [string]$Name
                Sources     = [System.Collections.Generic.HashSet[string]]::new()
                Description = ''
            }
        }
        $null = $aggregate[$key].Sources.Add([string]$Source)
        if (-not $aggregate[$key].Description -and $Description) {
            $aggregate[$key].Description = [string]$Description
        }
    }

    $scoopIndex = Read-DFCatalogCacheFile -Path (Join-Path $cacheRoot 'scoop/index.json') -Ttl ([timespan]::MaxValue)
    foreach ($entry in @($scoopIndex.Data)) { & $add $entry.name 'scoop' $entry.description }

    $wingetDb = Join-Path $cacheRoot 'winget/index.db'
    if (Test-Path $wingetDb) {
        foreach ($row in @(Invoke-DFSqliteQuery -Database $wingetDb -Query 'SELECT id, name FROM packages')) {
            & $add ($row.name ? $row.name : $row.id) 'winget' $null
        }
    }

    foreach ($provider in $script:DFCatalogOrder) {
        $queriesDir = Join-Path $cacheRoot "$provider/queries"
        if (-not (Test-Path $queriesDir)) { continue }
        foreach ($file in Get-ChildItem $queriesDir -Filter '*.json' -File) {
            $cached = Read-DFCatalogCacheFile -Path $file.FullName -Ttl ([timespan]::MaxValue)
            foreach ($entry in @($cached.Data)) { & $add $entry.Name $provider $entry.Description }
        }
    }

    $installed = Read-DFCatalogCacheFile -Path (Join-Path $cacheRoot 'installed.json') -Ttl ([timespan]::MaxValue)
    foreach ($entry in @($installed.Data)) { & $add $entry.Name $entry.Source $null }

    foreach ($value in $aggregate.Values) {
        [pscustomobject]@{
            Name        = $value.Name
            Sources     = @($value.Sources | Sort-Object) -join ','
            Description = $value.Description
        }
    }
}
