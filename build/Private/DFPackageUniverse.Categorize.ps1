#Requires -Version 7.0

# Phase D (categorization) engine helpers. Classifies merged tools into a
# closed taxonomy by reading their docs via an LLM, caching durably. See
# docs/superpowers/specs/2026-07-17-package-universe-categorization-design.md

function Resolve-DFPackageUniverseRepo {
    <#
    .SYNOPSIS
        Resolves a tool's source repository on ANY known forge (github, gitlab,
        bitbucket, codeberg, sr.ht), from source-repo fields in the extra JSON
        (choco ProjectSourceUrl/ProjectUrl, scoop checkver/autoupdate github ref)
        first, then the homepage. Returns { Host; Owner; Repo; Url } or $null.
        Url is canonical: https://<lower-host>/<owner>/<repo>, .git stripped.
    .DESCRIPTION
        Mines candidate URLs in priority order -- choco ProjectSourceUrl,
        ProjectUrl, scoop checkver (string or .github), scoop autoupdate --
        before falling back to Homepage, and returns the first candidate that
        matches a known git-forge URL shape. Strict-mode safe on $null inputs.
    .PARAMETER Homepage
        The tool's homepage URL, used as the fallback candidate.
    .PARAMETER Extra
        Raw JSON string holding source-specific extra fields (choco/scoop).
    .EXAMPLE
        Resolve-DFPackageUniverseRepo -Homepage 'https://github.com/sharkdp/bat'
        Returns @{ Host = 'github.com'; Owner = 'sharkdp'; Repo = 'bat'; Url = 'https://github.com/sharkdp/bat' }
    .OUTPUTS
        [pscustomobject] with Host, Owner, Repo, Url properties, or $null.
    #>
    [CmdletBinding()]
    param([AllowNull()][string]$Homepage, [AllowNull()][string]$Extra)

    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($Extra) {
        $doc = $null
        try { $doc = $Extra | ConvertFrom-Json } catch { $doc = $null }
        if ($doc) {
            foreach ($k in 'ProjectSourceUrl', 'ProjectUrl') {
                $p = $doc.PSObject.Properties[$k]; if ($p -and $p.Value) { $candidates.Add([string]$p.Value) }
            }
            $cv = $doc.PSObject.Properties['checkver']
            if ($cv -and $cv.Value) {
                if ($cv.Value -is [string]) { $candidates.Add($cv.Value) }
                else { $gh = $cv.Value.PSObject.Properties['github']; if ($gh -and $gh.Value) { $candidates.Add([string]$gh.Value) } }
            }
            $au = $doc.PSObject.Properties['autoupdate']
            if ($au -and $au.Value) { $candidates.Add((ConvertTo-Json -Compress -Depth 8 -InputObject $au.Value)) }
        }
    }
    if ($Homepage) { $candidates.Add([string]$Homepage) }

    $forges = @('github.com', 'gitlab.com', 'bitbucket.org', 'codeberg.org', 'git.sr.ht')
    foreach ($c in $candidates) {
        # Pull URL-shaped substrings out of each candidate -- handles bare URLs
        # AND URLs embedded in an autoupdate JSON blob.
        foreach ($m in [regex]::Matches([string]$c, 'https?://[^\s"''<>]+')) {
            $u = $null; try { $u = [uri]$m.Value } catch { continue }
            $forgeHost = $u.Host.ToLowerInvariant()
            if ($forgeHost -notin $forges) { continue }        # EXACT host, not substring
            $segs = @(($u.AbsolutePath.Trim('/') -split '/') | Where-Object { $_ })
            if ($segs.Count -lt 2) { continue }
            $owner = $segs[0].ToLowerInvariant()
            $repo = ($segs[1] -replace '\.git$', '').ToLowerInvariant()
            return [pscustomobject]@{ Host = $forgeHost; Owner = $owner; Repo = $repo; Url = "https://$forgeHost/$owner/$repo" }
        }
        # SSH scp-like form: git@host:owner/repo(.git)
        $ssh = [regex]::Match([string]$c, 'git@([^:\s]+):([^/\s]+)/([^/\s]+)')
        if ($ssh.Success -and ($ssh.Groups[1].Value.ToLowerInvariant() -in $forges)) {
            $forgeHost = $ssh.Groups[1].Value.ToLowerInvariant()
            $owner = $ssh.Groups[2].Value.ToLowerInvariant()
            $repo = ($ssh.Groups[3].Value -replace '\.git$', '').ToLowerInvariant()
            return [pscustomobject]@{ Host = $forgeHost; Owner = $owner; Repo = $repo; Url = "https://$forgeHost/$owner/$repo" }
        }
    }
    $null
}

function Get-DFPackageUniverseDurableKey {
    <#
    .SYNOPSIS
        The stable cache key for a tool's classification, resolved by a ladder:
        repo (name-suffixed, so a family-split shared repo stays distinct) ->
        path-bearing homepage -> anchor (source|package_id). Independent of the
        volatile tool_id, so it survives re-clustering. Name-normalization:
        lowercase, non-alphanumeric stripped.
    .DESCRIPTION
        Walks the member rows in order for each rung of the ladder rather than
        picking a single "primary" member up front, so a repo or homepage
        found on any member is used. The repo rung is suffixed with the
        normalized tool name so that two distinct tools sharing one upstream
        repo (a family split) still get distinct durable keys. The anchor
        rung sorts members by source priority (winget > choco > scoop) then
        lexically by "source|package_id" for determinism.
    .PARAMETER Members
        The tool's merged package rows: objects with source, package_id,
        name, homepage, and extra properties.
    .PARAMETER Name
        The tool's canonical name, used for repo-rung disambiguation.
    .EXAMPLE
        Get-DFPackageUniverseDurableKey -Members $members -Name 'bat'
        Returns 'repo:https://github.com/sharkdp/bat|bat' when a member's
        homepage or extra resolves to that repo.
    .OUTPUTS
        [string] The durable cache key.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Members,
        [AllowNull()][string]$Name
    )
    $normName = if ($Name) { ($Name.ToLowerInvariant() -replace '[^a-z0-9]', '') } else { '' }

    foreach ($m in $Members) {
        $repo = Resolve-DFPackageUniverseRepo -Homepage ([string]$m.homepage) -Extra ([string]$m.extra)
        if ($repo) { return "repo:$($repo.Url)|$normName" }
    }
    foreach ($m in $Members) {
        if ($m.homepage) {
            $h = ([string]$m.homepage) -replace '^https?://', '' -replace '^www\.', '' -replace '/$', ''
            $h = $h.ToLowerInvariant()
            if ($h -notmatch '(github|gitlab|bitbucket|codeberg)\b' -and $h.Contains('/')) { return "home:$h" }
        }
    }
    $order = @{ winget = 0; choco = 1; scoop = 2 }
    $anchor = @($Members | Sort-Object @{ e = { $order[[string]$_.source] } }, @{ e = { "$($_.source)|$($_.package_id)" } })[0]
    "pkg:$($anchor.source)|$($anchor.package_id)"
}

function Get-DFPackageUniverseApiKey {
    <#
    .SYNOPSIS
        Reads NAME=value from a .env file (comments and blank lines ignored).
        Returns $null when the file or the key is absent.
    .DESCRIPTION
        Scans EnvPath line by line, skipping blank lines and lines starting
        with '#'. Splits each remaining line on the first '=' and compares
        the trimmed key against Name. The matched value is trimmed and has
        surrounding double quotes stripped.
    .PARAMETER EnvPath
        Path to the .env file. If it does not exist, returns $null.
    .PARAMETER Name
        The key to look up (exact match, case-sensitive as written).
    .EXAMPLE
        Get-DFPackageUniverseApiKey -EnvPath ./.env -Name 'OPENAI_API_KEY'

        Returns the value of OPENAI_API_KEY from ./.env, or $null if absent.
    .OUTPUTS
        [string] The key's value, or $null if the file or key is absent.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$EnvPath, [Parameter(Mandatory)][string]$Name)

    if (-not (Test-Path $EnvPath)) { return $null }
    foreach ($line in (Get-Content -Path $EnvPath)) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('#')) { continue }
        $eq = $t.IndexOf('=')
        if ($eq -lt 1) { continue }
        if ($t.Substring(0, $eq).Trim() -eq $Name) { return $t.Substring($eq + 1).Trim().Trim('"') }
    }
    $null
}

function Get-DFPackageUniverseFetch {
    <#
    .SYNOPSIS
        Cache-first document fetch. Returns the fetch_cache row if present; else
        invokes the injectable $Http seam (param($Url) -> {Content;ContentType;
        Status}), persists the result (success OR failure), and returns it. Never
        throws -- a failure caches {Content=$null; Status='error:...'} so a dead
        URL is fetched at most once.
    .DESCRIPTION
        Checks the fetch_cache table for Url first. On a cache hit, returns the
        stored row (DBNull cells coerced to $null via ConvertFrom-DFDbNull). On
        a miss, invokes Http, wraps any thrown error into a cached failure
        record instead of propagating it, persists the outcome via
        INSERT OR REPLACE, and returns the result. This makes network access
        an injectable seam for tests and guarantees a dead URL is retried at
        most once per cache lifetime.
    .PARAMETER Url
        The URL to fetch, used as the fetch_cache primary key.
    .PARAMETER Connection
        An open PSSQLite connection (from New-SQLiteConnection) pointed at the
        Phase D categorize database.
    .PARAMETER Http
        A scriptblock seam: param($Url) -> { Content; ContentType; Status }.
        Swapped for a mock in tests; a real implementation performs the
        network call.
    .EXAMPLE
        Get-DFPackageUniverseFetch -Url 'https://x/readme' -Connection $conn -Http $http

        Returns the cached row if 'https://x/readme' was fetched before;
        otherwise calls $http, caches, and returns the result.
    .OUTPUTS
        [pscustomobject] with Content, ContentType, and Status properties.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][scriptblock]$Http
    )
    $cached = @(Invoke-SqliteQuery -SQLiteConnection $Connection -Query 'SELECT content, content_type, status FROM fetch_cache WHERE url = @u' -SqlParameters @{ u = $Url })
    if ($cached.Count -gt 0) {
        $c = $cached[0]
        return [pscustomobject]@{ Content = (ConvertFrom-DFDbNull $c.content); ContentType = (ConvertFrom-DFDbNull $c.content_type); Status = (ConvertFrom-DFDbNull $c.status) }
    }
    $result = [pscustomobject]@{ Content = $null; ContentType = $null; Status = 'ok' }
    try {
        $r = & $Http $Url
        $result = [pscustomobject]@{ Content = [string]$r.Content; ContentType = [string]$r.ContentType; Status = [string]$r.Status }
    } catch {
        $result = [pscustomobject]@{ Content = $null; ContentType = $null; Status = "error: $_" }
    }
    Invoke-SqliteQuery -SQLiteConnection $Connection -Query @'
INSERT OR REPLACE INTO fetch_cache (url, content, content_type, status, fetched_at)
VALUES (@u, @c, @ct, @s, @at);
'@ -SqlParameters @{ u = $Url; c = $result.Content; ct = $result.ContentType; s = $result.Status; at = [datetime]::UtcNow.ToString('o') }
    $result
}
