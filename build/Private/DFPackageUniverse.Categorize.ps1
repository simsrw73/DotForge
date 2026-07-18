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

function Get-DFPackageUniverseClassifierInput {
    <#
    .SYNOPSIS
        Assembles the classifier input for one tool, best-signal-first: any-host
        repo README -> documentation/homepage page -> metadata only. Returns
        { Name; Publisher; Description; Tags; DocExcerpt; SignalSource }; DocExcerpt
        is truncated to 4000 chars. Fetches go through the cached $Http seam.
    .DESCRIPTION
        Tier 1 walks each member's homepage/extra through
        Resolve-DFPackageUniverseRepo; for the first member that resolves to a
        known forge, tries that forge's raw-README URL via the cached fetch
        seam and uses the first non-empty result (signal_source = readme).
        Tier 2, when no repo README was found, fetches the first member's
        homepage as a documentation page (signal_source = docs). Tier 3, when
        neither tier produced content, falls back to metadata-only
        (signal_source = metadata) using just Name/Publisher/Description/Tags.
    .PARAMETER Members
        The tool's merged package rows: objects with source, package_id,
        name, homepage, and extra properties.
    .PARAMETER Name
        The tool's canonical name, passed through to the returned object.
    .PARAMETER Publisher
        The tool's publisher, passed through to the returned object.
    .PARAMETER Description
        The tool's metadata description, passed through to the returned object.
    .PARAMETER Tags
        The tool's metadata tags, passed through to the returned object.
    .PARAMETER Connection
        An open PSSQLite connection (from New-SQLiteConnection) pointed at the
        Phase D categorize database, used for the fetch cache.
    .PARAMETER Http
        A scriptblock seam: param($Url) -> { Content; ContentType; Status }.
        Swapped for a mock in tests; a real implementation performs the
        network call.
    .EXAMPLE
        Get-DFPackageUniverseClassifierInput -Members $m -Name 'bat' -Publisher 'sharkdp' -Description 'd' -Tags $null -Connection $conn -Http $http

        Returns an object with DocExcerpt from bat's GitHub README and
        SignalSource = 'readme' when the fetch succeeds.
    .OUTPUTS
        [pscustomobject] with Name, Publisher, Description, Tags, DocExcerpt,
        and SignalSource properties.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Members,
        [AllowNull()][string]$Name, [AllowNull()][string]$Publisher,
        [AllowNull()][string]$Description, [AllowNull()][string]$Tags,
        [Parameter(Mandatory)]$Connection, [Parameter(Mandatory)][scriptblock]$Http
    )
    $excerpt = $null; $source = 'metadata'

    # Tier 1: repo README (any host) via a raw-README URL guess per forge.
    foreach ($m in $Members) {
        $repo = Resolve-DFPackageUniverseRepo -Homepage ([string]$m.homepage) -Extra ([string]$m.extra)
        if (-not $repo) { continue }
        $rawUrls = switch ($repo.Host) {
            'github.com' { @("https://raw.githubusercontent.com/$($repo.Owner)/$($repo.Repo)/HEAD/README.md") }
            'gitlab.com' { @("https://gitlab.com/$($repo.Owner)/$($repo.Repo)/-/raw/HEAD/README.md") }
            'codeberg.org' { @("https://codeberg.org/$($repo.Owner)/$($repo.Repo)/raw/branch/main/README.md") }
            'bitbucket.org' { @("https://bitbucket.org/$($repo.Owner)/$($repo.Repo)/raw/HEAD/README.md") }
            default { @() }
        }
        foreach ($u in $rawUrls) {
            $f = Get-DFPackageUniverseFetch -Url $u -Connection $Connection -Http $Http
            if ($f.Content) { $excerpt = $f.Content; $source = 'readme'; break }
        }
        if ($excerpt) { break }
    }

    # Tier 2: a documentation / homepage page.
    if (-not $excerpt) {
        $docUrl = @($Members | ForEach-Object { [string]$_.homepage } | Where-Object { $_ }) | Select-Object -First 1
        if ($docUrl) {
            $f = Get-DFPackageUniverseFetch -Url $docUrl -Connection $Connection -Http $Http
            if ($f.Content) { $excerpt = $f.Content; $source = 'docs' }
        }
    }

    if ($excerpt -and $excerpt.Length -gt 4000) { $excerpt = $excerpt.Substring(0, 4000) }
    [pscustomobject]@{
        Name = $Name; Publisher = $Publisher; Description = $Description; Tags = $Tags
        DocExcerpt = $excerpt; SignalSource = $source
    }
}

function ConvertTo-DFPackageUniverseClassification {
    <#
    .SYNOPSIS
        The trust boundary between the model and the cache: validates a raw model
        output against the closed vocabulary, dropping out-of-vocab domain/
        function/worksWith values. Forces NothingFits when nothing in-vocab
        survived (or the model set nothing_fits). Returns the normalized record.
    .DESCRIPTION
        Reads $Raw's properties strict-safely via PSObject.Properties probes
        (the model's JSON may omit fields). domain/function/worksWith values
        are each checked against the corresponding $Vocab list via
        Test-DFPackageUniverseVocabValue and dropped when out-of-vocab.
        NothingFits is forced true when the model explicitly set nothing_fits,
        OR when domain is $null AND Function is empty AND WorksWith is empty
        after filtering -- i.e. nothing in-vocab survived. This is the trust
        boundary between the model and the durable cache: no out-of-vocab
        value is ever persisted as a classification facet.
    .PARAMETER Raw
        The parsed model output object (e.g. from ConvertFrom-Json).
    .PARAMETER Vocab
        The closed vocabulary object { Domain; Function; WorksWith }, as
        returned by Import-DFPackageUniverseVocab.
    .EXAMPLE
        ConvertTo-DFPackageUniverseClassification -Raw $raw -Vocab $vocab

        Returns a normalized classification with out-of-vocab values dropped.
    .OUTPUTS
        [pscustomobject] with Domain, Function, WorksWith, Interface,
        AlternativeTo, Confidence, NothingFits, and SuggestedTerms properties.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Raw, [Parameter(Mandatory)]$Vocab)

    function Keep([object[]]$Values, [string[]]$Allowed) {
        # ,$result (not a bare @()) -- a function's natural output is enumerated
        # onto the pipeline, so a bare empty array collapses to $null at the
        # call site. The unary comma prevents that unwrap.
        $result = @(@($Values) | ForEach-Object { [string]$_ } | Where-Object { Test-DFPackageUniverseVocabValue -Value $_ -Vocab $Allowed })
        , $result
    }
    $domainRaw = [string]$Raw.PSObject.Properties['domain'].Value
    $domain = if (Test-DFPackageUniverseVocabValue -Value $domainRaw -Vocab $Vocab.Domain) { $domainRaw.ToLowerInvariant() } else { $null }
    $func = Keep -Values @($Raw.function) -Allowed $Vocab.Function
    $ww   = Keep -Values @($Raw.worksWith) -Allowed $Vocab.WorksWith
    # Same unwrap hazard as Keep above: an if/else block's output is also
    # enumerated onto the pipeline, so the true-branch needs the same ,@(...)
    # guard whenever its pipeline can filter down to zero items.
    $altProp = $Raw.PSObject.Properties['alternativeTo']
    $alt = if ($altProp) { , @(@($altProp.Value) | ForEach-Object { [string]$_ } | Where-Object { $_ }) } else { @() }
    $stProp = $Raw.PSObject.Properties['suggested_terms']
    $suggested = if ($stProp) { , @(@($stProp.Value) | ForEach-Object { [string]$_ } | Where-Object { $_ }) } else { @() }
    $confProp = $Raw.PSObject.Properties['confidence']
    $conf = if ($confProp -and $null -ne $confProp.Value) { [double]$confProp.Value } else { 0.0 }
    $modelSaysNothing = [bool]($Raw.PSObject.Properties['nothing_fits'] -and $Raw.nothing_fits)
    $nothingFits = $modelSaysNothing -or (-not $domain -and $func.Count -eq 0 -and $ww.Count -eq 0)

    [pscustomobject]@{
        Domain = $domain; Function = $func; WorksWith = $ww
        Interface = [string]$Raw.PSObject.Properties['interface'].Value
        AlternativeTo = $alt; Confidence = $conf
        NothingFits = $nothingFits; SuggestedTerms = $suggested
    }
}
