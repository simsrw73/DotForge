#Requires -Version 7.0

# npm registry catalog provider (query-cache kind).

function Invoke-DFCatalogNpmFetch {
    <#
    .SYNOPSIS
        Live npm registry lookup: exact package doc first (single-word queries),
        then keyword search; results deduped by name.
    .PARAMETER Query
        Normalized query text.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Query
    )

    $results = [System.Collections.Generic.List[object]]::new()

    if ($Query -notmatch ' ') {
        try {
            $doc = Invoke-RestMethod -Uri "https://registry.npmjs.org/$([uri]::EscapeDataString($Query))" -TimeoutSec 10
            $version = [string]$doc.'dist-tags'.latest
            $published = $null
            if ($version -and $doc.time.$version) { try { $published = [datetime]$doc.time.$version } catch {} }
            $license = if ($doc.license -is [string]) { $doc.license } else { [string]$doc.license.type }

            $results.Add((New-DFToolSourceInfo -Source 'npm' `
                -PackageId $doc.name -Name $doc.name `
                -Description ([string]$doc.description) `
                -LatestVersion $version `
                -Homepage ([string]$doc.homepage) `
                -License $license `
                -PublishedAt $published `
                -MatchKind 'exact-name'))
        } catch {
            Write-Verbose "DotForge: npm exact lookup for '$Query' failed (probably not a package): $_"
        }
    }

    # Search failure propagates to the engine so it can fall back to cache.
    $response = Invoke-RestMethod -Uri "https://registry.npmjs.org/-/v1/search?text=$([uri]::EscapeDataString($Query))&size=15" -TimeoutSec 10
    foreach ($object in @($response.objects)) {
        $package = $object.package
        if (-not $package.name) { continue }
        if ($results | Where-Object Name -eq $package.name) { continue }

        $published = $null
        if ($package.date) { try { $published = [datetime]$package.date } catch {} }

        $results.Add((New-DFToolSourceInfo -Source 'npm' `
            -PackageId $package.name -Name $package.name `
            -Description ([string]$package.description) `
            -LatestVersion ([string]$package.version) `
            -Homepage ([string]$package.links.homepage) `
            -PublishedAt $published `
            -MatchKind ($package.name -eq $Query ? 'exact-name' : 'keyword')))
    }

    $results
}

function Search-DFCatalogNpm {
    <#
    .SYNOPSIS
        Cache-first npm registry search.
    .PARAMETER Query
        Name or keywords.
    .PARAMETER Fresh
        Block on a live fetch.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Query,

        [switch]$Fresh
    )

    Search-DFCatalogQueryCache -Provider 'npm' -Query $Query -Fresh:$Fresh `
        -Fetch { param($q) Invoke-DFCatalogNpmFetch -Query $q }
}

function Get-DFCatalogNpmInstalled {
    <#
    .SYNOPSIS
        Lists globally installed npm packages by enumerating the global
        node_modules directory — avoids the slow `npm ls -g` spawn.
    .PARAMETER NpmPrefix
        The npm global prefix (defaults to %APPDATA%\npm on Windows).
    #>
    [CmdletBinding()]
    param(
        [string]$NpmPrefix = ($Env:APPDATA ? (Join-Path $Env:APPDATA 'npm') : $null)
    )

    if (-not $NpmPrefix) { return }
    $modules = Join-Path $NpmPrefix 'node_modules'
    if (-not (Test-Path $modules)) { return }

    $readPackage = {
        param($Dir, $Name)
        $packageJson = Join-Path $Dir 'package.json'
        if (-not (Test-Path $packageJson)) { return }
        $version = $null
        try { $version = [string](Get-Content $packageJson -Raw | ConvertFrom-Json).version } catch {}
        [pscustomobject]@{
            Source           = 'npm'
            Name             = $Name
            PackageId        = $Name
            InstalledVersion = $version
        }
    }

    foreach ($dir in Get-ChildItem $modules -Directory | Where-Object Name -notlike '.*') {
        if ($dir.Name -like '@*') {
            foreach ($scoped in Get-ChildItem $dir.FullName -Directory) {
                & $readPackage $scoped.FullName "$($dir.Name)/$($scoped.Name)"
            }
        } else {
            & $readPackage $dir.FullName $dir.Name
        }
    }
}

if (-not $script:DFCatalogProviders) { $script:DFCatalogProviders = @{} }
$script:DFCatalogProviders['npm'] = @{
    Name         = 'npm'
    Kind         = 'query-cache'
    Test         = { $true }
    Search       = { param($Query, $Fresh) Search-DFCatalogNpm -Query $Query -Fresh:$Fresh }
    GetInstalled = { Get-DFCatalogNpmInstalled }
    Refresh      = { param($Query) if ($Query) { $null = Search-DFCatalogNpm -Query $Query -Fresh } }
}
