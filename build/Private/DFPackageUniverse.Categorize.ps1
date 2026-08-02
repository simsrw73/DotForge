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
    $domainProp = $Raw.PSObject.Properties['domain']
    $domainRaw = if ($domainProp) { [string]$domainProp.Value } else { $null }
    $domain = if (Test-DFPackageUniverseVocabValue -Value $domainRaw -Vocab $Vocab.Domain) { $domainRaw.ToLowerInvariant() } else { $null }
    $func = Keep -Values @(if ($Raw.PSObject.Properties['function']) { $Raw.function }) -Allowed $Vocab.Function
    $ww   = Keep -Values @(if ($Raw.PSObject.Properties['worksWith']) { $Raw.worksWith }) -Allowed $Vocab.WorksWith
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

    $ifProp = $Raw.PSObject.Properties['interface']
    [pscustomobject]@{
        Domain = $domain; Function = $func; WorksWith = $ww
        Interface = if ($ifProp) { [string]$ifProp.Value } else { $null }
        AlternativeTo = $alt; Confidence = $conf
        NothingFits = $nothingFits; SuggestedTerms = $suggested
    }
}

function ConvertFrom-DFPackageUniverseRateLimitDuration {
    <#
    .SYNOPSIS
        Parses a Go-style duration string -- as seen in OpenAI's "Please try
        again in <duration>" rate-limit error text (e.g. "8.64s", "6m0s",
        "1h2m3s", "2h") -- into total seconds. Returns $null for an empty or
        unparseable string, never throws.
    .PARAMETER Duration
        The duration string.
    .OUTPUTS
        [double] or $null.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param([AllowNull()][string]$Duration)
    if (-not $Duration) { return $null }
    $m = [regex]::Match($Duration, '^(?:(\d+)h)?(?:(\d+)m)?(?:(\d+(?:\.\d+)?)s)?$')
    if (-not $m.Success -or $m.Value -eq '') { return $null }
    $h  = if ($m.Groups[1].Success) { [double]$m.Groups[1].Value } else { 0 }
    $mi = if ($m.Groups[2].Success) { [double]$m.Groups[2].Value } else { 0 }
    $s  = if ($m.Groups[3].Success) { [double]$m.Groups[3].Value } else { 0 }
    if ($h -eq 0 -and $mi -eq 0 -and $s -eq 0) { return $null }
    ($h * 3600) + ($mi * 60) + $s
}

function ConvertTo-DFPackageUniverseRateLimitSignal {
    <#
    .SYNOPSIS
        Inspects a caught API-error message for a rate-limit or credit/quota
        exhaustion signal (either OpenAI or Anthropic's error text) and, if
        found, returns the DF_RATE_LIMITED::<resetAt>::<message> marker that
        Invoke-DFPackageUniverseCategorizeRun recognizes to stop a batch
        immediately instead of burning the rest of BudgetCalls on calls that
        are certain to fail -- the fix for the 2026-08-01 incident where
        OpenAI's daily cap was hit partway through a run and the loop kept
        deferring every remaining tool anyway.
    .DESCRIPTION
        Matches on "rate limit" (OpenAI's rate_limit_exceeded / Anthropic's
        rate_limit_error) or "credit balance is too low" (Anthropic
        insufficient-credit, which has no scheduled reset but is exactly as
        pointless to keep retrying against). When the message also contains
        OpenAI's "Please try again in <duration>" text, the duration is
        parsed (ConvertFrom-DFPackageUniverseRateLimitDuration) into an
        absolute UTC reset timestamp; otherwise resetAt is empty (unknown --
        e.g. Anthropic's credit-exhaustion message has no reset at all).
    .PARAMETER Message
        The stringified caught error (e.g. "$_" in a catch block).
    .OUTPUTS
        [string] the marker to throw, or $null when Message isn't a
        rate-limit/exhaustion signal (the caller should re-throw unchanged).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Message)
    if ($Message -notmatch '(?i)rate.?limit' -and $Message -notmatch '(?i)credit balance is too low') { return $null }
    $resetAt = ''
    # Structurally mirrors ConvertFrom-DFPackageUniverseRateLimitDuration's own grammar
    # (rather than an open [\d.hms]+ character class) so the capture stops right after a
    # valid unit letter and never swallows trailing sentence punctuation (e.g. the "."
    # after "...try again in 6m0s.").
    $dm = [regex]::Match($Message, '(?i)try\s+again\s+in\s+((?:\d+h)?(?:\d+m)?(?:\d+(?:\.\d+)?s)?)')
    if ($dm.Success) {
        $secs = ConvertFrom-DFPackageUniverseRateLimitDuration -Duration $dm.Groups[1].Value
        if ($secs) { $resetAt = [datetime]::UtcNow.AddSeconds($secs).ToString('o') }
    }
    "DF_RATE_LIMITED::$resetAt::$Message"
}

function Get-DFPackageUniverseClassifierSystemPrompt {
    <#
    .SYNOPSIS
        The classifier system prompt, shared verbatim by every provider seam
        (New-DFPackageUniverseClassifySeam, New-DFPackageUniverseClaudeClassifySeam)
        so the taxonomy instructions can never silently drift apart between
        providers -- factored out after the vcs-client mistagging fixes
        needed the exact same wording on both the bulk and escalation paths.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    'You classify a command-line tool into a FIXED taxonomy. Use only the provided enum values. If no function/worksWith value fits, set nothing_fits=true and put your suggested new term(s) in suggested_terms. interface is cli/tui/gui. alternativeTo lists classic commands this replaces (e.g. bat->cat). IMPORTANT: almost every tool''s docs are a README hosted on GitHub, so boilerplate like "git clone ...", "Pull Requests welcome", "Contributing", or github.com links is near-universal -- it describes how the PROJECT is developed, not what the TOOL does. Never treat that boilerplate as evidence for any classification, especially "vcs-client". Only use "vcs-client" for a tool whose primary END-USER purpose is acting as a client for version-control repository history itself (viewing diffs/log, committing, branching, merging, pushing/pulling) -- e.g. git, mercurial, jj, and GUI/TUI wrappers around them like lazygit, git-cola, gitkraken, tig. Do NOT use "vcs-client" for build tools, package managers, task runners, IaC/cloud CLIs, CI runners, torrent clients, decompilers, or any other tool merely because it is hosted on GitHub or its own docs mention git/contributing/cloning (e.g. sbt, uv, bicep, transmission, k9s, dnspy, mqtt-explorer, steamcmd are NOT vcs-clients). Also, the word "client" alone is NOT evidence -- most "client" software (chat clients, IRC clients, music/streaming clients, database clients, email clients, game clients) has nothing to do with version control (e.g. quassel, chatterino, spotify-tui, litecoin-core are NOT vcs-clients even though their docs call them "clients" or use words like "tree"/"staging" in an unrelated sense).'
}

function New-DFPackageUniverseClassifierSchema {
    <#
    .SYNOPSIS
        The JSON-schema object (domain/function/worksWith enums drawn from
        $Vocab) shared by every provider seam. Same rationale as
        Get-DFPackageUniverseClassifierSystemPrompt.
    .PARAMETER Vocab
        The closed vocabulary { Domain; Function; WorksWith }.
    .OUTPUTS
        [hashtable]
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Vocab)
    @{
        type = 'object'; additionalProperties = $false
        required = @('domain', 'function', 'worksWith', 'interface', 'alternativeTo', 'confidence', 'nothing_fits', 'suggested_terms')
        properties = @{
            domain      = @{ type = 'string'; enum = @($Vocab.Domain) }
            function    = @{ type = 'array'; items = @{ type = 'string'; enum = @($Vocab.Function) } }
            worksWith   = @{ type = 'array'; items = @{ type = 'string'; enum = @($Vocab.WorksWith) } }
            interface   = @{ type = 'string'; enum = @('cli', 'tui', 'gui') }
            alternativeTo = @{ type = 'array'; items = @{ type = 'string' } }
            confidence  = @{ type = 'number' }
            nothing_fits = @{ type = 'boolean' }
            suggested_terms = @{ type = 'array'; items = @{ type = 'string' } }
        }
    }
}

function Get-DFPackageUniverseClassifierUserPayload {
    <#
    .SYNOPSIS
        The compact JSON user-message payload (name/publisher/description/
        tags/docs) shared by every provider seam.
    .PARAMETER ClassifierInput
        The { Name; Publisher; Description; Tags; DocExcerpt } object from
        Get-DFPackageUniverseClassifierInput.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$ClassifierInput)
    @{ name = $ClassifierInput.Name; publisher = $ClassifierInput.Publisher; description = $ClassifierInput.Description; tags = $ClassifierInput.Tags; docs = $ClassifierInput.DocExcerpt } | ConvertTo-Json -Depth 5 -Compress
}

function New-DFPackageUniverseClassifySeam {
    <#
    .SYNOPSIS
        Builds the classifier seam (param($ClassifierInput,$Vocab) -> {Raw;Model;Usage}) for
        an OpenAI chat-completions call with JSON-schema structured output that
        constrains domain/function/worksWith to the closed vocabulary. The wire
        POST is delegated to $Rest (param($Uri,$Headers,$Body) -> parsed response)
        so it is unit-testable. The default $Rest uses Invoke-RestMethod.
    .DESCRIPTION
        The returned scriptblock builds a system/user chat-completions message
        pair from the classifier input, a json_schema response_format whose
        domain/function/worksWith enums are populated from $Vocab, and POSTs it
        via $Rest to the OpenAI chat-completions endpoint. $Rest is an
        injectable seam -- param($Uri,$Headers,$Body) -> parsed response --
        so tests can supply a canned response with no network call. The
        response's choices[0].message.content JSON string is parsed and
        returned alongside the model name and token usage.
    .PARAMETER ApiKey
        The OpenAI API key, sent as an Authorization: Bearer header.
    .PARAMETER Model
        The chat-completions model name. Defaults to 'gpt-4o-mini'.
    .PARAMETER Rest
        The injectable HTTP-POST seam: param($Uri,$Headers,$Body) -> parsed
        response, EITHER the bare response body (legacy/simple mocks) OR
        { Body; RateLimitRemaining; RateLimitResetRaw } to also report the
        provider's real-time remaining-requests/reset-duration (from
        x-ratelimit-remaining-requests / x-ratelimit-reset-requests) so the
        run loop can throttle proactively. Defaults to a real Invoke-RestMethod
        call that captures those headers.
    .EXAMPLE
        $seam = New-DFPackageUniverseClassifySeam -ApiKey $key -Model 'gpt-4o-mini'
        & $seam $classifierInput $vocab

        Returns { Raw; Model; Usage; RateLimitRemaining; RateLimitResetAt }
        from a live OpenAI classification call.
    .OUTPUTS
        [scriptblock] with signature param($ClassifierInput,$Vocab) ->
        { Raw; Model; Usage; RateLimitRemaining; RateLimitResetAt }.
        RateLimitRemaining/RateLimitResetAt are $null when the seam (real or
        injected) didn't report rate-limit info.
    #>
    [CmdletBinding()]
    [OutputType([scriptblock])]
    param(
        [Parameter(Mandatory)][string]$ApiKey,
        [string]$Model = 'gpt-4o-mini',
        [scriptblock]$Rest = {
            param($Uri, $Headers, $Body)
            $resp = Invoke-RestMethod -Uri $Uri -Method Post -Headers $Headers -Body $Body -ContentType 'application/json' -TimeoutSec 60 -ResponseHeadersVariable rlHeaders
            $remaining = $null
            if ($rlHeaders -and $rlHeaders['x-ratelimit-remaining-requests']) {
                $v = $rlHeaders['x-ratelimit-remaining-requests']; if ($v -is [array]) { $v = $v[0] }
                $remaining = [int]$v
            }
            $resetRaw = $null
            if ($rlHeaders -and $rlHeaders['x-ratelimit-reset-requests']) {
                $v = $rlHeaders['x-ratelimit-reset-requests']; if ($v -is [array]) { $v = $v[0] }
                $resetRaw = [string]$v
            }
            [pscustomobject]@{ Body = $resp; RateLimitRemaining = $remaining; RateLimitResetRaw = $resetRaw }
        }
    )
    # Captured as plain variables (not resolved by name inside the closure below) so the
    # returned scriptblock keeps working regardless of the caller's function-table scope
    # chain -- GetNewClosure() reliably snapshots variables, not sibling function visibility.
    $sysPrompt = Get-DFPackageUniverseClassifierSystemPrompt
    $buildSchema = ${function:New-DFPackageUniverseClassifierSchema}
    $buildPayload = ${function:Get-DFPackageUniverseClassifierUserPayload}
    $rateLimitSignal = ${function:ConvertTo-DFPackageUniverseRateLimitSignal}
    $parseDuration = ${function:ConvertFrom-DFPackageUniverseRateLimitDuration}
    {
        param($ClassifierInput, $Vocab)
        $schema = & $buildSchema -Vocab $Vocab
        $user = & $buildPayload -ClassifierInput $ClassifierInput
        $body = @{
            model = $Model
            messages = @(@{ role = 'system'; content = $sysPrompt }, @{ role = 'user'; content = $user })
            response_format = @{ type = 'json_schema'; json_schema = @{ name = 'tool_classification'; schema = $schema; strict = $true } }
        } | ConvertTo-Json -Depth 12
        $headers = @{ Authorization = "Bearer $ApiKey" }
        try {
            $restResult = & $Rest 'https://api.openai.com/v1/chat/completions' $headers $body
        } catch {
            $marker = & $rateLimitSignal -Message "$_"
            if ($marker) { throw $marker }
            throw
        }
        # $Rest may return the bare response body (legacy/simple mocks) or the
        # { Body; RateLimitRemaining; RateLimitResetRaw|RateLimitResetAt }
        # wrapper -- unwrap when present, otherwise treat the whole result as
        # the body and report no rate-limit info (both are valid, tested shapes).
        $resp = $restResult
        $rlRemaining = $null; $rlResetAt = $null
        if ($restResult -is [pscustomobject] -and $restResult.PSObject.Properties['Body']) {
            $resp = $restResult.Body
            if ($restResult.PSObject.Properties['RateLimitRemaining']) { $rlRemaining = $restResult.RateLimitRemaining }
            if ($restResult.PSObject.Properties['RateLimitResetAt'] -and $restResult.RateLimitResetAt) {
                $rlResetAt = $restResult.RateLimitResetAt
            } elseif ($restResult.PSObject.Properties['RateLimitResetRaw'] -and $restResult.RateLimitResetRaw) {
                $secs = & $parseDuration -Duration $restResult.RateLimitResetRaw
                if ($secs) { $rlResetAt = [datetime]::UtcNow.AddSeconds($secs).ToString('o') }
            }
        }
        $content = [string]$resp.choices[0].message.content
        [pscustomobject]@{ Raw = ($content | ConvertFrom-Json); Model = $Model; Usage = $resp.usage; RateLimitRemaining = $rlRemaining; RateLimitResetAt = $rlResetAt }
    }.GetNewClosure()
}

function New-DFPackageUniverseClaudeClassifySeam {
    <#
    .SYNOPSIS
        Builds the classifier seam (param($ClassifierInput,$Vocab) -> {Raw;Model;Usage}) for
        an Anthropic Messages API call, using forced tool-use for structured
        output that constrains domain/function/worksWith to the closed
        vocabulary via the tool's input_schema. Intended as the escalation
        seam (-Escalate) in Build-DFPackageUniverseCategories.ps1: a stronger
        model for the low-confidence/nothing_fits tail, per the Phase D design.
    .DESCRIPTION
        Shares the exact system prompt, JSON schema, and user payload with
        New-DFPackageUniverseClassifySeam (Get-DFPackageUniverseClassifierSystemPrompt,
        New-DFPackageUniverseClassifierSchema, Get-DFPackageUniverseClassifierUserPayload)
        so the two providers cannot silently classify against different
        taxonomies. The wire POST is delegated to $Rest (param($Uri,$Headers,$Body)
        -> parsed response) so it is unit-testable; the default $Rest uses
        Invoke-RestMethod. The response's tool_use content block's `input` is
        already a structured object (Claude does not return a JSON string to
        re-parse, unlike the OpenAI seam).
    .PARAMETER ApiKey
        The Anthropic API key, sent as an x-api-key header.
    .PARAMETER Model
        The Claude model name. Defaults to 'claude-haiku-4-5-20251001'.
    .PARAMETER Rest
        The injectable HTTP-POST seam: param($Uri,$Headers,$Body) -> parsed
        response, EITHER the bare response body (legacy/simple mocks) OR
        { Body; RateLimitRemaining; RateLimitResetAt } to also report the
        provider's real-time remaining-requests/reset time (from
        anthropic-ratelimit-requests-remaining / -reset, which -- unlike
        OpenAI's -- is already an absolute timestamp) so the run loop can
        throttle proactively. Defaults to a real Invoke-RestMethod call that
        captures those headers.
    .EXAMPLE
        $seam = New-DFPackageUniverseClaudeClassifySeam -ApiKey $key
        & $seam $classifierInput $vocab

        Returns { Raw; Model; Usage; RateLimitRemaining; RateLimitResetAt }
        from a live Claude classification call.
    .OUTPUTS
        [scriptblock] with signature param($ClassifierInput,$Vocab) ->
        { Raw; Model; Usage; RateLimitRemaining; RateLimitResetAt }.
        RateLimitRemaining/RateLimitResetAt are $null when the seam (real or
        injected) didn't report rate-limit info.
    #>
    [CmdletBinding()]
    [OutputType([scriptblock])]
    param(
        [Parameter(Mandatory)][string]$ApiKey,
        [string]$Model = 'claude-haiku-4-5-20251001',
        [scriptblock]$Rest = {
            param($Uri, $Headers, $Body)
            $resp = Invoke-RestMethod -Uri $Uri -Method Post -Headers $Headers -Body $Body -ContentType 'application/json' -TimeoutSec 60 -ResponseHeadersVariable rlHeaders
            $remaining = $null
            if ($rlHeaders -and $rlHeaders['anthropic-ratelimit-requests-remaining']) {
                $v = $rlHeaders['anthropic-ratelimit-requests-remaining']; if ($v -is [array]) { $v = $v[0] }
                $remaining = [int]$v
            }
            $resetAt = $null
            if ($rlHeaders -and $rlHeaders['anthropic-ratelimit-requests-reset']) {
                $v = $rlHeaders['anthropic-ratelimit-requests-reset']; if ($v -is [array]) { $v = $v[0] }
                $resetAt = [string]$v
            }
            [pscustomobject]@{ Body = $resp; RateLimitRemaining = $remaining; RateLimitResetAt = $resetAt }
        }
    )
    # See the matching comment in New-DFPackageUniverseClassifySeam for why these are
    # captured as plain variables rather than resolved by name inside the closure.
    $sysPrompt = Get-DFPackageUniverseClassifierSystemPrompt
    $buildSchema = ${function:New-DFPackageUniverseClassifierSchema}
    $buildPayload = ${function:Get-DFPackageUniverseClassifierUserPayload}
    $rateLimitSignal = ${function:ConvertTo-DFPackageUniverseRateLimitSignal}
    {
        param($ClassifierInput, $Vocab)
        $schema = & $buildSchema -Vocab $Vocab
        $user = & $buildPayload -ClassifierInput $ClassifierInput
        $body = @{
            model = $Model
            max_tokens = 1024
            system = $sysPrompt
            messages = @(@{ role = 'user'; content = $user })
            tools = @(@{ name = 'tool_classification'; description = 'Emit the tool classification.'; input_schema = $schema })
            tool_choice = @{ type = 'tool'; name = 'tool_classification' }
        } | ConvertTo-Json -Depth 12
        $headers = @{ 'x-api-key' = $ApiKey; 'anthropic-version' = '2023-06-01' }
        try {
            $restResult = & $Rest 'https://api.anthropic.com/v1/messages' $headers $body
        } catch {
            $marker = & $rateLimitSignal -Message "$_"
            if ($marker) { throw $marker }
            throw
        }
        # See the matching comment in New-DFPackageUniverseClassifySeam. Anthropic's reset
        # header is already absolute (unlike OpenAI's duration), so no parsing is needed here.
        $resp = $restResult
        $rlRemaining = $null; $rlResetAt = $null
        if ($restResult -is [pscustomobject] -and $restResult.PSObject.Properties['Body']) {
            $resp = $restResult.Body
            if ($restResult.PSObject.Properties['RateLimitRemaining']) { $rlRemaining = $restResult.RateLimitRemaining }
            if ($restResult.PSObject.Properties['RateLimitResetAt']) { $rlResetAt = $restResult.RateLimitResetAt }
        }
        $toolUse = @($resp.content | Where-Object { $_.type -eq 'tool_use' })[0]
        [pscustomobject]@{ Raw = $toolUse.input; Model = $Model; Usage = $resp.usage; RateLimitRemaining = $rlRemaining; RateLimitResetAt = $rlResetAt }
    }.GetNewClosure()
}

function Invoke-DFPackageUniverseCategorizeRun {
    <#
    .SYNOPSIS
        The Phase D run loop: for each tool whose durable key is not yet cached
        (resume), gather input, classify (escalating low-confidence/nothing-fits),
        persist per-tool, stop at the call budget. A tool whose input/classify
        throws is marked 'deferred' (retried next run) and never aborts the batch.
        Signal-rich tools (has-repo, higher source_count) are processed first.
        Returns a reconciliation summary.
    .DESCRIPTION
        Reads every tool + its merged tool_packages members from Connection,
        computes each tool's durable key (Get-DFPackageUniverseDurableKey), and
        skips any key already 'done' in tool_classifications -- this is the
        resume behavior that makes reruns idempotent and cheap. Remaining tools
        are ordered signal-rich-first (has a homepage, then higher
        source_count, then tool_id for determinism) so the budget is spent on
        the tools most likely to classify well. For each tool this assembles
        the classifier input (Get-DFPackageUniverseClassifierInput), invokes
        the injectable $Classify seam, validates the result against the closed
        vocabulary (ConvertTo-DFPackageUniverseClassification), and escalates
        to $Escalate when confidence is below EscalateThreshold or the model
        reported nothing_fits. The classification is persisted per-tool
        (Save-DFPackageUniverseClassification) as soon as it is produced, so a
        crash or budget cutoff loses at most the in-flight tool. A thrown error
        from gathering input or classifying is caught, logged via $Log, and the
        tool is persisted with status 'deferred' so the NEXT run retries it --
        the batch itself never aborts. The loop stops once BudgetCalls model
        calls (classify + any escalate) have been spent. Returns a
        reconciliation summary of what happened this run.
    .PARAMETER Connection
        An open PSSQLite connection (from New-SQLiteConnection) pointed at the
        Phase D categorize database, and also holding the merged tools /
        tool_packages tables from earlier phases.
    .PARAMETER Vocab
        The closed vocabulary object { Domain; Function; WorksWith }, as
        returned by Import-DFPackageUniverseVocab.
    .PARAMETER Http
        A scriptblock seam: param($Url) -> { Content; ContentType; Status },
        passed through to Get-DFPackageUniverseClassifierInput's fetch cache.
    .PARAMETER Classify
        The classifier seam: param($ClassifierInput,$Vocab) -> { Raw; Model; Usage }
        (see New-DFPackageUniverseClassifySeam).
    .PARAMETER Escalate
        An optional stronger-model seam with the same signature as Classify,
        used when the initial result's confidence is below EscalateThreshold
        or it reported nothing_fits. When omitted, no escalation happens.
    .PARAMETER BudgetCalls
        The maximum number of model calls (classify + escalate) to spend this
        run. Defaults to unlimited. The loop stops as soon as the budget is
        exhausted, leaving remaining tools for a later run.
    .PARAMETER EscalateThreshold
        Confidence below which (or on nothing_fits) the Escalate seam is used.
    .PARAMETER RateLimitSafetyMargin
        Proactive throttle: after a SUCCESSFUL classify/escalate call, if the
        seam reported RateLimitRemaining and it is below this margin, the
        batch stops immediately (after saving that tool's good result) rather
        than attempting one more call that's likely to fail -- the same
        stop-early behavior as a DF_RATE_LIMITED marker, just triggered
        proactively from the provider's real-time remaining-requests count
        instead of reactively from an actual failure. Default 20 (a small
        buffer, since other usage on the same account can consume from the
        same shared daily pool between our checks). Ignored for a seam that
        doesn't report RateLimitRemaining (e.g. an injected mock without it).
    .PARAMETER Log
        A scriptblock seam: param($Level,$Source,$PackageId,$Message), used to
        record review-worthy outcomes (nothing-fits, low-confidence, deferred).
    .EXAMPLE
        Invoke-DFPackageUniverseCategorizeRun -Connection $conn -Vocab $vocab -Http $http -Classify $classify -BudgetCalls 500 -Log $log

        Classifies up to 500 model-calls' worth of not-yet-cached tools,
        resuming automatically on the next call.
    .OUTPUTS
        [pscustomobject] with Processed, Classified, Escalated, Deferred,
        NothingFits, Remaining, RateLimited, and RateLimitResetAt properties.
        RateLimited is $true when the run stopped early because a seam threw
        a DF_RATE_LIMITED::<resetAt>::<message> marker (see the real seams'
        default $Rest); RateLimitResetAt is that reset timestamp/duration
        string, or $null if the provider didn't supply one.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Connection, [Parameter(Mandatory)]$Vocab,
        [Parameter(Mandatory)][scriptblock]$Http, [Parameter(Mandatory)][scriptblock]$Classify,
        [scriptblock]$Escalate, [int]$BudgetCalls = [int]::MaxValue,
        [double]$EscalateThreshold = 0.5, [int]$RateLimitSafetyMargin = 20,
        [Parameter(Mandatory)][scriptblock]$Log
    )
    $De = { param($v) if ($v -is [DBNull]) { $null } else { $v } }
    $rawTools = @(Invoke-SqliteQuery -SQLiteConnection $Connection -Query 'SELECT tool_id, name, source_count FROM tools')
    $members = @(Invoke-SqliteQuery -SQLiteConnection $Connection -Query 'SELECT tool_id, source, package_id, homepage, extra FROM tool_packages')
    $byTool = @{}
    foreach ($m in $members) {
        $id = [int]$m.tool_id
        if (-not $byTool.ContainsKey($id)) { $byTool[$id] = [System.Collections.Generic.List[object]]::new() }
        $byTool[$id].Add([pscustomobject]@{ source = $m.source; package_id = $m.package_id; homepage = (& $De $m.homepage); extra = (& $De $m.extra) })
    }
    # Signal-rich first: has-homepage/repo, then higher source_count.
    $ordered = @($rawTools | Sort-Object `
        @{ e = { $mm = $byTool[[int]$_.tool_id]; if ($mm -and @($mm | Where-Object { $_.homepage }).Count) { 0 } else { 1 } } }, `
        @{ e = { - [int]$_.source_count } }, @{ e = { [int]$_.tool_id } })

    $processed = 0; $classified = 0; $escalated = 0; $deferred = 0; $nothing = 0; $calls = 0
    $rateLimited = $false; $rateLimitResetAt = $null
    foreach ($t in $ordered) {
        if ($calls -ge $BudgetCalls) { break }
        $id = [int]$t.tool_id
        $mm = @($byTool[$id])
        $key = Get-DFPackageUniverseDurableKey -Members $mm -Name ([string]$t.name)
        $exists = @(Invoke-SqliteQuery -SQLiteConnection $Connection -Query 'SELECT 1 FROM tool_classifications WHERE cache_key = @k AND status = ''done''' -SqlParameters @{ k = $key })
        if ($exists.Count -gt 0) { continue }
        $processed++
        try {
            $anchor = $mm[0]
            $in = Get-DFPackageUniverseClassifierInput -Members $mm -Name ([string]$t.name) -Publisher $null -Description $null -Tags $null -Connection $Connection -Http $Http
            $calls++
            $out = & $Classify $in $Vocab
            $cls = ConvertTo-DFPackageUniverseClassification -Raw $out.Raw -Vocab $Vocab
            $model = [string]$out.Model
            # StrictMode-safe: mocks (and seam outputs) that don't report rate-limit info
            # simply lack these properties -- probe via PSObject rather than dotting in,
            # which would throw PropertyNotFoundException under Set-StrictMode.
            $remaining = $out.PSObject.Properties['RateLimitRemaining']
            $lowestRemaining = if ($remaining -and $null -ne $remaining.Value) { [int]$remaining.Value } else { $null }
            $resetProp = $out.PSObject.Properties['RateLimitResetAt']
            $lowestRemainingReset = if ($resetProp) { $resetProp.Value } else { $null }
            if ($Escalate -and ($cls.Confidence -lt $EscalateThreshold -or $cls.NothingFits)) {
                $calls++; $escalated++
                $out2 = & $Escalate $in $Vocab
                $cls = ConvertTo-DFPackageUniverseClassification -Raw $out2.Raw -Vocab $Vocab
                $model = [string]$out2.Model
                $remaining2 = $out2.PSObject.Properties['RateLimitRemaining']
                if ($remaining2 -and $null -ne $remaining2.Value -and ($null -eq $lowestRemaining -or [int]$remaining2.Value -lt $lowestRemaining)) {
                    $lowestRemaining = [int]$remaining2.Value
                    $resetProp2 = $out2.PSObject.Properties['RateLimitResetAt']
                    $lowestRemainingReset = if ($resetProp2) { $resetProp2.Value } else { $null }
                }
            }
            Save-DFPackageUniverseClassification -Connection $Connection -CacheKey $key -Classification $cls -SignalSource $in.SignalSource -Model $model -Status 'done'
            $classified++
            if ($cls.NothingFits) { $nothing++ ; & $Log 'review' $anchor.source $anchor.package_id "nothing-fits: suggested $($cls.SuggestedTerms -join ',')" }
            elseif ($cls.Confidence -lt $EscalateThreshold) { & $Log 'review' $anchor.source $anchor.package_id "low-confidence $($cls.Confidence)" }
            # Proactive throttle: the provider told us (on a SUCCESSFUL call) how many
            # requests are left. Stop here -- after saving this tool's good result --
            # rather than attempting one more call we can already see is likely to fail.
            if ($null -ne $lowestRemaining -and $lowestRemaining -lt $RateLimitSafetyMargin) {
                $rateLimited = $true
                $rateLimitResetAt = $lowestRemainingReset
                & $Log 'warning' $anchor.source $anchor.package_id "categorize stopping proactively: only $lowestRemaining requests remain (safety margin $RateLimitSafetyMargin)"
                break
            }
        } catch {
            $deferred++
            & $Log 'warning' $mm[0].source $mm[0].package_id "categorize deferred: $_"
            Save-DFPackageUniverseClassification -Connection $Connection -CacheKey $key -Classification ([pscustomobject]@{ Domain = $null; Function = @(); WorksWith = @(); Interface = $null; AlternativeTo = @(); Confidence = 0.0; NothingFits = $false; SuggestedTerms = @() }) -SignalSource 'error' -Model $null -Status 'deferred'
            # A rate-limit signal means every remaining tool this run is also
            # guaranteed to fail (the seam that just threw is shared across the
            # whole batch) -- stop immediately rather than burning the rest of
            # BudgetCalls on calls we already know will fail. See the real
            # seams' default $Rest (New-DFPackageUniverseClassifySeam /
            # -Claude...) for what throws this marker and why.
            if ("$_" -like 'DF_RATE_LIMITED::*') {
                $parts = "$_".Split('::', 3)
                $rateLimited = $true
                $rateLimitResetAt = if ($parts.Count -ge 2 -and $parts[1]) { $parts[1] } else { $null }
                break
            }
        }
    }
    $remaining = @($ordered | Where-Object {
        $k = Get-DFPackageUniverseDurableKey -Members @($byTool[[int]$_.tool_id]) -Name ([string]$_.name)
        @(Invoke-SqliteQuery -SQLiteConnection $Connection -Query 'SELECT 1 FROM tool_classifications WHERE cache_key=@k AND status=''done''' -SqlParameters @{ k = $k }).Count -eq 0
    }).Count

    [pscustomobject]@{ Processed = $processed; Classified = $classified; Escalated = $escalated; Deferred = $deferred; NothingFits = $nothing; Remaining = $remaining; RateLimited = $rateLimited; RateLimitResetAt = $rateLimitResetAt }
}
