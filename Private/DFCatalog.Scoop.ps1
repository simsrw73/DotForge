#Requires -Version 7.0

# Scoop catalog provider (snapshot kind). Never shells out to scoop.exe —
# buckets are locally cloned git repos of JSON manifests, so search reads them
# straight from disk; installed state comes from apps/<name>/current/manifest.json.

function Get-DFCatalogScoopRoot {
    <#
    .SYNOPSIS
        Resolves the scoop root: $Env:SCOOP, then scoop's config.json root_path,
        then ~\scoop.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if ($Env:SCOOP) { return $Env:SCOOP }

    $configHome = $Env:XDG_CONFIG_HOME ? $Env:XDG_CONFIG_HOME : (Join-Path $HOME '.config')
    $config = Join-Path $configHome 'scoop/config.json'
    if (Test-Path $config) {
        try {
            $rootPath = (Get-Content $config -Raw | ConvertFrom-Json).root_path
            if ($rootPath) { return $rootPath }
        } catch {
            Write-Verbose "DotForge: unreadable scoop config '$config': $_"
        }
    }

    Join-Path $HOME 'scoop'
}

function Get-DFCatalogScoopFingerprint {
    <#
    .SYNOPSIS
        Cheap change-detection fingerprint for scoop buckets: each bucket's git
        HEAD commit, read directly from .git files (no process spawn).
    .PARAMETER ScoopRoot
        The scoop root directory.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$ScoopRoot
    )

    $bucketsDir = Join-Path $ScoopRoot 'buckets'
    if (-not (Test-Path $bucketsDir)) { return '' }

    $parts = foreach ($bucket in Get-ChildItem $bucketsDir -Directory | Sort-Object Name) {
        $hash = $null
        $headFile = Join-Path $bucket.FullName '.git/HEAD'
        if (Test-Path $headFile) {
            $head = (Get-Content $headFile -Raw).Trim()
            if ($head -match '^ref:\s*(.+)$') {
                $refPath = Join-Path $bucket.FullName ".git/$($Matches[1])"
                if (Test-Path $refPath) {
                    $hash = (Get-Content $refPath -Raw).Trim()
                } else {
                    $packed = Join-Path $bucket.FullName '.git/packed-refs'
                    if (Test-Path $packed) {
                        $line = Get-Content $packed | Where-Object { $_ -match "\s$([regex]::Escape($Matches[1]))$" } | Select-Object -First 1
                        if ($line) { $hash = ($line -split '\s+')[0] }
                    }
                }
            } else {
                $hash = $head   # detached HEAD holds the commit directly
            }
        }
        if (-not $hash) { $hash = $bucket.LastWriteTimeUtc.Ticks }
        "$($bucket.Name):$hash"
    }

    $parts -join ','
}

function Build-DFCatalogScoopIndexData {
    <#
    .SYNOPSIS
        Projects all bucket manifests into flat index entries.
    .PARAMETER ScoopRoot
        The scoop root directory.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ScoopRoot
    )

    $bucketsDir = Join-Path $ScoopRoot 'buckets'
    if (-not (Test-Path $bucketsDir)) { return @() }

    # Hot loop over thousands of manifests: raw .NET file + JSON APIs.
    # Get-Content | ConvertFrom-Json per file costs ~50s across the default
    # buckets; this path does the same work in a couple of seconds.
    foreach ($bucket in Get-ChildItem $bucketsDir -Directory) {
        $manifestDir = Join-Path $bucket.FullName 'bucket'
        if (-not (Test-Path $manifestDir)) { continue }

        foreach ($file in [System.IO.Directory]::EnumerateFiles($manifestDir, '*.json')) {
            try {
                $doc = [System.Text.Json.JsonDocument]::Parse([System.IO.File]::ReadAllText($file))
            } catch {
                Write-Verbose "DotForge: skipping unreadable scoop manifest '$file'"
                continue
            }
            try {
                $root = $doc.RootElement
                $el = [System.Text.Json.JsonElement]::new()

                $version = if ($root.TryGetProperty('version', [ref]$el)) { $el.ToString() } else { $null }
                $homepage = if ($root.TryGetProperty('homepage', [ref]$el)) { $el.ToString() } else { $null }

                $description = $null
                if ($root.TryGetProperty('description', [ref]$el)) {
                    $description = if ($el.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
                        @($el.EnumerateArray() | ForEach-Object ToString) -join ' '
                    } else { $el.ToString() }
                }

                $license = $null
                if ($root.TryGetProperty('license', [ref]$el)) {
                    $license = if ($el.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
                        $id = [System.Text.Json.JsonElement]::new()
                        if ($el.TryGetProperty('identifier', [ref]$id)) { $id.ToString() } else { $null }
                    } else { $el.ToString() }
                }

                [pscustomobject]@{
                    name        = [System.IO.Path]::GetFileNameWithoutExtension($file)
                    bucket      = $bucket.Name
                    version     = $version
                    description = $description
                    homepage    = $homepage
                    license     = $license
                }
            } finally {
                $doc.Dispose()
            }
        }
    }
}

function Update-DFCatalogScoopIndex {
    <#
    .SYNOPSIS
        Rebuilds the on-disk scoop index (catalogs/scoop/index.json) and its
        bucket-HEAD fingerprint key. No-op when catalog caching is disabled.
    .PARAMETER ScoopRoot
        The scoop root directory (defaults to Get-DFCatalogScoopRoot).
    #>
    [CmdletBinding()]
    param(
        [string]$ScoopRoot = (Get-DFCatalogScoopRoot)
    )

    $cacheRoot = Get-DFCatalogCacheRoot
    if (-not $cacheRoot) { return }

    $dir = Join-Path $cacheRoot 'scoop'
    $data = @(Build-DFCatalogScoopIndexData -ScoopRoot $ScoopRoot)

    Write-DFCatalogCacheFile -Path (Join-Path $dir 'index.json') -Query '' -Results $data
    Set-Content -Path (Join-Path $dir 'index.key') `
        -Value (Get-DFCatalogScoopFingerprint -ScoopRoot $ScoopRoot) -Encoding UTF8
}

function Get-DFCatalogScoopIndex {
    <#
    .SYNOPSIS
        Returns @{Data; AgeMinutes} for the scoop index, rebuilding the disk
        cache when the bucket fingerprint changed, or building in memory when
        caching is disabled.
    .PARAMETER ScoopRoot
        The scoop root directory.
    .PARAMETER Force
        Rebuild even when the fingerprint matches.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ScoopRoot,

        [switch]$Force
    )

    $cacheRoot = Get-DFCatalogCacheRoot
    if ($cacheRoot) {
        $indexFile = Join-Path $cacheRoot 'scoop/index.json'
        $keyFile   = Join-Path $cacheRoot 'scoop/index.key'

        $fingerprint = Get-DFCatalogScoopFingerprint -ScoopRoot $ScoopRoot
        $valid = -not $Force -and
                 (Test-Path $indexFile) -and
                 (Test-Path $keyFile)   -and
                 ((Get-Content $keyFile -Raw).Trim() -eq $fingerprint)

        if (-not $valid) { Update-DFCatalogScoopIndex -ScoopRoot $ScoopRoot }

        $cached = Read-DFCatalogCacheFile -Path $indexFile -Ttl ([timespan]::MaxValue)
        if ($cached) { return $cached }
    }

    # Caching disabled or unreadable — build in memory for this call only.
    @{
        Data       = @(Build-DFCatalogScoopIndexData -ScoopRoot $ScoopRoot)
        AgeMinutes = 0
        Stale      = $false
    }
}

function Search-DFCatalogScoop {
    <#
    .SYNOPSIS
        Searches the scoop index. Exact name matches report MatchKind exact-name;
        otherwise every query word must appear in the name or description.
    .PARAMETER Query
        Name or keywords.
    .PARAMETER ScoopRoot
        The scoop root directory (defaults to Get-DFCatalogScoopRoot).
    .PARAMETER Fresh
        Force an index rebuild before searching.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Query,

        [string]$ScoopRoot = (Get-DFCatalogScoopRoot),

        [switch]$Fresh
    )

    $index = Get-DFCatalogScoopIndex -ScoopRoot $ScoopRoot -Force:$Fresh
    $normalized = (ConvertTo-DFCatalogQueryKey -Query $Query).Normalized
    $words = $normalized -split ' '
    $cacheTimestamp = [datetime]::UtcNow.AddMinutes(-$index.AgeMinutes)

    foreach ($entry in $index.Data) {
        $matchKind =
            if ($entry.name -eq $normalized) { 'exact-name' }
            else {
                $haystack = "$($entry.name) $($entry.description)"
                $all = $true
                foreach ($word in $words) {
                    if ($haystack -notlike "*$word*") { $all = $false; break }
                }
                if ($all) { 'keyword' } else { $null }
            }
        if (-not $matchKind) { continue }

        New-DFToolSourceInfo -Source 'scoop' `
            -PackageId "$($entry.bucket)/$($entry.name)" `
            -Name $entry.name `
            -Description $entry.description `
            -LatestVersion $entry.version `
            -Homepage $entry.homepage `
            -License $entry.license `
            -MatchKind $matchKind `
            -CacheTimestamp $cacheTimestamp `
            -CacheAgeMinutes $index.AgeMinutes
    }
}

function Get-DFCatalogScoopInstalled {
    <#
    .SYNOPSIS
        Lists scoop-installed apps and versions by reading
        apps/<name>/current/manifest.json — no scoop.exe invocation.
    .PARAMETER ScoopRoot
        The scoop root directory (defaults to Get-DFCatalogScoopRoot).
    #>
    [CmdletBinding()]
    param(
        [string]$ScoopRoot = (Get-DFCatalogScoopRoot)
    )

    $appsDir = Join-Path $ScoopRoot 'apps'
    if (-not (Test-Path $appsDir)) { return }

    foreach ($app in Get-ChildItem $appsDir -Directory) {
        $manifestFile = Join-Path $app.FullName 'current/manifest.json'
        if (-not (Test-Path $manifestFile)) { continue }

        $version = $null
        try { $version = [string](Get-Content $manifestFile -Raw | ConvertFrom-Json).version } catch {}

        [pscustomobject]@{
            Source           = 'scoop'
            Name             = $app.Name
            PackageId        = $app.Name
            InstalledVersion = $version
        }
    }
}

if (-not $script:DFCatalogProviders) { $script:DFCatalogProviders = @{} }
$script:DFCatalogProviders['scoop'] = @{
    Name         = 'scoop'
    Kind         = 'snapshot'
    Test         = { [bool](Get-Command scoop -ErrorAction Ignore) -or (Test-Path (Join-Path (Get-DFCatalogScoopRoot) 'buckets')) }
    Search       = { param($Query, $Fresh) Search-DFCatalogScoop -Query $Query -Fresh:$Fresh }
    GetInstalled = { Get-DFCatalogScoopInstalled }
    Refresh      = { param($Query) Update-DFCatalogScoopIndex }
}
