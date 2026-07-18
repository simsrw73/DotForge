# Package Universe Phase D — Plan 1: Categorization Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The core, resumable, budget-capped engine that classifies every merged tool into a curated closed taxonomy (coarse `domain` + `function`/`worksWith` facets + `interface`) by reading each tool's own docs via a small OpenAI model, caching each result durably so the work runs once per tool and survives re-runs.

**Architecture:** A new offline+online build stage (`stage='categorize'`) reading Phase C's `tools`/`tool_packages` from `universe.db`. Unlike Phases A–C, its tables are a **persistent cache** (never truncated) keyed on a **durable identity signal**, not the volatile `tool_id`. A run selects tools with no cached classification, gathers input (any-host README → doc page → metadata), classifies via an injectable model seam, persists per-tool, and stops at a budget — so it is resumable and resilient by construction.

**Tech Stack:** PowerShell 7+, PSSQLite, `Invoke-RestMethod` (OpenAI + multi-host HTTP), Pester 5. Mirrors Phase A–C build conventions; all network is behind injectable seams so tests never touch it.

**Scope:** This is **Plan 1** of Phase D — the classification engine against a *hand-curated base vocabulary*. Bottom-up vocab discovery, embeddings/related-alt, and the shipped-db export are **Plan 2** (written after this runs live). The classifier's `alternativeTo` output and the `nothing_fits`/`suggested_terms` accretion signals are captured now (cheap), but consuming them is Plan 2.

## Global Constraints

- **PowerShell 7+**; every module file starts with `#Requires -Version 7.0`.
- **`Set-StrictMode -Version Latest`** in the orchestrator and every test's `BeforeAll`. Strict-safe access: `$obj.PSObject.Properties['Key']` probes, `@(x | Where-Object {...})` whole-pipeline wrapping, `$hash['Key']` index access, DBNull coerced to `$null`.
- **`DF` prefix** on all functions; build-phase helpers live in `build/Private/`.
- **`pipeline_log`** is shared: this stage uses `stage='categorize'` and only ever *appends* (never deletes another phase's rows).
- **PERSISTENT CACHE — do NOT truncate.** Unlike Phases A–C, `Initialize-...CategorizeSchema` creates tables `IF NOT EXISTS` and clears **nothing** in `tool_classifications`/`fetch_cache`. The cache is the resume state; wiping it destroys paid LLM work.
- **No network in any test.** HTTP and the model call are injectable scriptblock seams (`-Fetch`, `-Classify`); tests pass mocks.
- **API key** read from the gitignored `.env` (`OPENAI_API_KEY=...`) — never hardcoded, never committed. Absent key → a clear error before any run (but the *engine functions* take the key/seam as a parameter and are testable without it).
- **Pester 5:** no `<angle brackets>` in test names.
- **Durable-key discipline:** every cache row is keyed on the durable identity signal (repo/homepage/anchor package-id), never `tool_id`.
- **Coarse `domain` is single-valued; `function`/`worksWith` are arrays.** The classifier may only emit in-vocabulary values (validated); its escape hatch is `nothing_fits`.

---

## File Structure

- **Create** `build/Private/DFPackageUniverse.Categorize.ps1` — engine functions (durable key, resolver, input, classifier client, run loop, persistence).
- **Create** `build/Private/DFPackageUniverse.CategorizeDb.ps1` — schema + persistence + jsonc export/import (kept separate so the DB layer is testable and focused).
- **Create** `build/Build-DFPackageUniverseCategories.ps1` — thin orchestrator.
- **Create** `data/package-universe-classifications.jsonc` — durable export seed (`{ "schemaVersion": 1, "classifications": [] }`).
- **Create/extend** `build/categories/domains.jsonc` — the coarse `domain` vocabulary; and confirm the `function`/`worksWith` vocab is loadable (reuse the existing trifle taxonomy source).
- **Create** `build/Private/DFPackageUniverse.Vocab.ps1` — vocabulary loader/validator.
- **Create** `tests/DFPackageUniverse.Categorize.Tests.ps1` and `tests/DFPackageUniverse.CategorizeDb.Tests.ps1`.
- **Modify** `CHANGELOG.md` — `[Unreleased]` entry.

Reuses verbatim: `ConvertFrom-DFDbNull` (Phase C `DFPackageUniverse.Merge.ps1`), `Resolve-DFGitHubRepoUrl`'s regex idea (but generalized to any host here).

---

## Task 1: Any-host repo resolver

**Files:** Create `build/Private/DFPackageUniverse.Categorize.ps1`; Test `tests/DFPackageUniverse.Categorize.Tests.ps1`.

**Interfaces:**
- Produces `Resolve-DFPackageUniverseRepo([string]$Homepage, [string]$Extra) -> { Host; Owner; Repo; Url } | $null` — recognizes github/gitlab/bitbucket/codeberg/sr.ht + a generic `*.git`/known-forge fallback; normalizes to a canonical `https://<host>/<owner>/<repo>` (lowercased host, `.git` stripped). `Extra` is the raw JSON string; the resolver mines source-repo fields (`ProjectSourceUrl`, scoop `checkver`/`autoupdate`) plus the homepage.

- [ ] **Step 1: Write the failing test**

```powershell
BeforeAll {
    Set-StrictMode -Version Latest
    Import-Module PSSQLite
    . "$PSScriptRoot/../build/Private/DFPackageUniverse.Merge.ps1"       # ConvertFrom-DFDbNull
    . "$PSScriptRoot/../build/Private/DFPackageUniverse.Categorize.ps1"
}

Describe 'DFPackageUniverse.Categorize' {
    Context 'Resolve-DFPackageUniverseRepo' {
        It 'resolves a GitHub homepage' {
            $r = Resolve-DFPackageUniverseRepo -Homepage 'https://github.com/sharkdp/bat'
            $r.Host | Should -Be 'github.com'; $r.Owner | Should -Be 'sharkdp'; $r.Repo | Should -Be 'bat'
            $r.Url | Should -Be 'https://github.com/sharkdp/bat'
        }
        It 'resolves a GitLab homepage and strips .git' {
            (Resolve-DFPackageUniverseRepo -Homepage 'https://gitlab.com/Owner/Repo.git').Url | Should -Be 'https://gitlab.com/owner/repo'
        }
        It 'resolves a Codeberg homepage' {
            (Resolve-DFPackageUniverseRepo -Homepage 'https://codeberg.org/a/b/').Url | Should -Be 'https://codeberg.org/a/b'
        }
        It 'prefers choco ProjectSourceUrl in extra over a non-repo homepage' {
            $extra = ConvertTo-Json -Compress @{ ProjectSourceUrl = 'https://gitlab.com/x/y' }
            (Resolve-DFPackageUniverseRepo -Homepage 'https://vanity.example/tool' -Extra $extra).Url | Should -Be 'https://gitlab.com/x/y'
        }
        It 'returns null for a non-repo homepage with no repo in extra' {
            Resolve-DFPackageUniverseRepo -Homepage 'https://vanity.example/tool' | Should -BeNullOrEmpty
        }
        It 'does not throw under strict on null inputs' {
            { Resolve-DFPackageUniverseRepo -Homepage $null -Extra $null } | Should -Not -Throw
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/DFPackageUniverse.Categorize.Tests.ps1 -Output Detailed"`
Expected: FAIL — `'Resolve-DFPackageUniverseRepo' is not recognized`.

- [ ] **Step 3: Write minimal implementation**

Create `build/Private/DFPackageUniverse.Categorize.ps1`:

```powershell
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
    #>
    [CmdletBinding()]
    param([AllowNull()][string]$Homepage, [AllowNull()][string]$Extra)

    $hosts = 'github\.com', 'gitlab\.com', 'bitbucket\.org', 'codeberg\.org', 'git\.sr\.ht'
    $pattern = "(?:$($hosts -join '|'))[/:]([^/#?\s]+)/([^/#?\s]+)"

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

    foreach ($c in $candidates) {
        $m = [regex]::Match($c, $pattern)
        if ($m.Success) {
            $forgeHost = ([regex]::Match($m.Value, '(?:github|gitlab|bitbucket|codeberg|sr)\.[a-z]+')).Value.ToLowerInvariant()
            if ($forgeHost -eq 'sr.ht') { $forgeHost = 'git.sr.ht' }
            $owner = $m.Groups[1].Value.ToLowerInvariant()
            $repo = ($m.Groups[2].Value -replace '\.git$', '').ToLowerInvariant()
            return [pscustomobject]@{ Host = $forgeHost; Owner = $owner; Repo = $repo; Url = "https://$forgeHost/$owner/$repo" }
        }
    }
    $null
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/DFPackageUniverse.Categorize.Tests.ps1 -Output Detailed"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add build/Private/DFPackageUniverse.Categorize.ps1 tests/DFPackageUniverse.Categorize.Tests.ps1
git commit -m "feat(package-universe): Phase D any-host repo resolver"
```

---

## Task 2: Durable identity key

**Files:** Modify `build/Private/DFPackageUniverse.Categorize.ps1`; Test same file.

**Interfaces:**
- Consumes `Resolve-DFPackageUniverseRepo` (Task 1).
- Produces `Get-DFPackageUniverseDurableKey([object[]]$Members, [string]$Name) -> [string]`. Ladder: (1) `repo:<url>|<normname>` when any member resolves a repo (name-suffixed so a family-split shared repo yields distinct keys); (2) `home:<normalized-homepage-with-path>`; (3) `pkg:<source>|<package_id>` of the anchor member (winget>choco>scoop, then lexical). Member row shape: `{ source; package_id; name; homepage; extra }`. `Name` is the tool's canonical name (for the repo-share disambiguation + normalization).

- [ ] **Step 1: Write the failing test**

```powershell
    Context 'Get-DFPackageUniverseDurableKey' {
        function Mem($s, $p, $home = $null, $extra = $null) {
            [pscustomobject]@{ source = $s; package_id = $p; name = $p; homepage = $home; extra = $extra }
        }
        It 'keys on the repo (name-suffixed) when a member resolves a repo' {
            $m = @( (Mem 'choco' 'bat' 'https://github.com/sharkdp/bat') )
            Get-DFPackageUniverseDurableKey -Members $m -Name 'bat' | Should -Be 'repo:https://github.com/sharkdp/bat|bat'
        }
        It 'gives two tools sharing one repo but different names distinct keys' {
            $a = @( (Mem 'winget' 'OpenDsc.Lcm' 'https://github.com/opendsc/opendsc') )
            $b = @( (Mem 'winget' 'OpenDsc.Server' 'https://github.com/opendsc/opendsc') )
            (Get-DFPackageUniverseDurableKey -Members $a -Name 'OpenDsc Lcm') |
                Should -Not -Be (Get-DFPackageUniverseDurableKey -Members $b -Name 'OpenDsc Server')
        }
        It 'falls back to a path-bearing homepage when no repo' {
            $m = @( (Mem 'winget' 'X.Y' 'https://vendor.example/tool') )
            Get-DFPackageUniverseDurableKey -Members $m -Name 'tool' | Should -Be 'home:vendor.example/tool'
        }
        It 'falls back to the anchor source|package_id for a repo-less, homepage-less singleton' {
            $m = @( (Mem 'scoop' 'main/thing') )
            Get-DFPackageUniverseDurableKey -Members $m -Name 'thing' | Should -Be 'pkg:scoop|main/thing'
        }
        It 'picks the winget anchor over choco/scoop deterministically' {
            $m = @( (Mem 'scoop' 'main/x'), (Mem 'winget' 'A.X'), (Mem 'choco' 'x') )
            Get-DFPackageUniverseDurableKey -Members $m -Name 'x' | Should -Be 'pkg:winget|A.X'
        }
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run the file. Expected: FAIL — `'Get-DFPackageUniverseDurableKey' is not recognized`.

- [ ] **Step 3: Write minimal implementation**

Append to `build/Private/DFPackageUniverse.Categorize.ps1`:

```powershell
function Get-DFPackageUniverseDurableKey {
    <#
    .SYNOPSIS
        The stable cache key for a tool's classification, resolved by a ladder:
        repo (name-suffixed, so a family-split shared repo stays distinct) ->
        path-bearing homepage -> anchor (source|package_id). Independent of the
        volatile tool_id, so it survives re-clustering. Name-normalization:
        lowercase, non-alphanumeric stripped.
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
```

- [ ] **Step 4: Run test to verify it passes**

Run the file. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add build/Private/DFPackageUniverse.Categorize.ps1 tests/DFPackageUniverse.Categorize.Tests.ps1
git commit -m "feat(package-universe): Phase D durable identity key"
```

---

## Task 3: Persistent cache schema

**Files:** Create `build/Private/DFPackageUniverse.CategorizeDb.ps1`; Test `tests/DFPackageUniverse.CategorizeDb.Tests.ps1`.

**Interfaces:**
- Produces `Initialize-DFPackageUniverseCategorizeSchema([string]$DatabasePath)` — `CREATE TABLE IF NOT EXISTS` for `tool_classifications` and `fetch_cache`; clears **nothing** (persistent cache). Idempotent.

- [ ] **Step 1: Write the failing test**

```powershell
BeforeAll {
    Set-StrictMode -Version Latest
    Import-Module PSSQLite
    . "$PSScriptRoot/../build/Private/DFPackageUniverse.CategorizeDb.ps1"
}
Describe 'DFPackageUniverse.CategorizeDb' {
    Context 'Initialize-DFPackageUniverseCategorizeSchema' {
        It 'creates the cache tables and preserves existing rows on re-init' {
            $db = Join-Path ([System.IO.Path]::GetTempPath()) ("catdb-" + [guid]::NewGuid().ToString('N') + ".db")
            try {
                Initialize-DFPackageUniverseCategorizeSchema -DatabasePath $db
                Invoke-SqliteQuery -DataSource $db -Query "INSERT INTO tool_classifications (cache_key, status, classified_at) VALUES ('repo:x|y', 'done', 'now')"
                Initialize-DFPackageUniverseCategorizeSchema -DatabasePath $db   # re-init must NOT wipe
                (Invoke-SqliteQuery -DataSource $db -Query "SELECT COUNT(*) n FROM tool_classifications").n | Should -Be 1
                $tables = @(Invoke-SqliteQuery -DataSource $db -Query "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name").name
                $tables | Should -Contain 'tool_classifications'
                $tables | Should -Contain 'fetch_cache'
            } finally { Remove-Item -Path $db -ErrorAction Ignore }
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/DFPackageUniverse.CategorizeDb.Tests.ps1 -Output Detailed"`
Expected: FAIL — function not recognized.

- [ ] **Step 3: Write minimal implementation**

Create `build/Private/DFPackageUniverse.CategorizeDb.ps1`:

```powershell
#Requires -Version 7.0

# Phase D (categorization) DB layer: the PERSISTENT classification cache +
# fetch cache, plus jsonc export/import. Unlike Phases A-C this stage NEVER
# truncates its tables -- the cache is the resume state. See the design spec.

function Initialize-DFPackageUniverseCategorizeSchema {
    <#
    .SYNOPSIS
        Creates the Phase D cache tables if missing. Clears NOTHING -- the
        classification cache is durable resume state; wiping it would destroy
        paid LLM work. Idempotent (safe to call every run).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DatabasePath)

    Invoke-SqliteQuery -DataSource $DatabasePath -Query @'
CREATE TABLE IF NOT EXISTS tool_classifications (
  cache_key TEXT PRIMARY KEY,
  domain TEXT,
  function_json TEXT,
  works_with_json TEXT,
  interface TEXT,
  alternative_to_json TEXT,
  confidence REAL,
  nothing_fits INTEGER NOT NULL DEFAULT 0,
  suggested_terms_json TEXT,
  signal_source TEXT,
  model TEXT,
  status TEXT NOT NULL,          -- done | deferred
  classified_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS fetch_cache (
  url TEXT PRIMARY KEY,
  content TEXT,
  content_type TEXT,
  status TEXT,
  fetched_at TEXT NOT NULL
);
'@
}
```

- [ ] **Step 4: Run test to verify it passes**

Run the file. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add build/Private/DFPackageUniverse.CategorizeDb.ps1 tests/DFPackageUniverse.CategorizeDb.Tests.ps1
git commit -m "feat(package-universe): Phase D persistent cache schema"
```

---

## Task 4: API key reader + cached fetch seam

**Files:** Modify `build/Private/DFPackageUniverse.Categorize.ps1`; Test `tests/DFPackageUniverse.Categorize.Tests.ps1`.

**Interfaces:**
- Produces:
  - `Get-DFPackageUniverseApiKey([string]$EnvPath, [string]$Name) -> [string] | $null` — reads `Name=value` from a `.env` file (ignores comments/blank lines); `$null` if absent.
  - `Get-DFPackageUniverseFetch([string]$Url, $Connection, [scriptblock]$Http) -> { Content; ContentType; Status }` — cache-first: returns the `fetch_cache` row if present, else invokes `$Http` (the injectable network seam: `param($Url) -> { Content; ContentType; Status }`), persists it, returns it. Never throws — a fetch failure returns `{ Content=$null; Status='error:...' }` and is cached (so a dead URL is not retried every run).

- [ ] **Step 1: Write the failing test**

```powershell
    Context 'Get-DFPackageUniverseApiKey' {
        It 'reads a key from a .env, ignoring comments and blanks' {
            $f = Join-Path ([System.IO.Path]::GetTempPath()) ("env-" + [guid]::NewGuid().ToString('N'))
            try {
                Set-Content -Path $f -Value @('# comment', '', 'OPENAI_API_KEY=sk-abc123', 'OTHER=x')
                Get-DFPackageUniverseApiKey -EnvPath $f -Name 'OPENAI_API_KEY' | Should -Be 'sk-abc123'
                Get-DFPackageUniverseApiKey -EnvPath $f -Name 'MISSING' | Should -BeNullOrEmpty
            } finally { Remove-Item -Path $f -ErrorAction Ignore }
        }
    }
    Context 'Get-DFPackageUniverseFetch' {
        BeforeAll { Import-Module PSSQLite; . "$PSScriptRoot/../build/Private/DFPackageUniverse.CategorizeDb.ps1" }
        It 'fetches once, then serves from cache without re-calling Http' {
            $db = Join-Path ([System.IO.Path]::GetTempPath()) ("fetch-" + [guid]::NewGuid().ToString('N') + ".db")
            try {
                Initialize-DFPackageUniverseCategorizeSchema -DatabasePath $db
                $conn = New-SQLiteConnection -DataSource $db
                $script:calls = 0
                $http = { param($Url) $script:calls++; [pscustomobject]@{ Content = 'README!'; ContentType = 'text/markdown'; Status = 'ok' } }
                try {
                    (Get-DFPackageUniverseFetch -Url 'https://x/readme' -Connection $conn -Http $http).Content | Should -Be 'README!'
                    (Get-DFPackageUniverseFetch -Url 'https://x/readme' -Connection $conn -Http $http).Content | Should -Be 'README!'
                } finally { $conn.Close() }
                $script:calls | Should -Be 1
            } finally { Remove-Item -Path $db -ErrorAction Ignore }
        }
        It 'caches a failed fetch so it is not retried' {
            $db = Join-Path ([System.IO.Path]::GetTempPath()) ("fetch2-" + [guid]::NewGuid().ToString('N') + ".db")
            try {
                Initialize-DFPackageUniverseCategorizeSchema -DatabasePath $db
                $conn = New-SQLiteConnection -DataSource $db
                $script:calls2 = 0
                $http = { param($Url) $script:calls2++; throw '404' }
                try {
                    (Get-DFPackageUniverseFetch -Url 'https://dead/x' -Connection $conn -Http $http).Content | Should -BeNullOrEmpty
                    Get-DFPackageUniverseFetch -Url 'https://dead/x' -Connection $conn -Http $http | Out-Null
                } finally { $conn.Close() }
                $script:calls2 | Should -Be 1
            } finally { Remove-Item -Path $db -ErrorAction Ignore }
        }
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run the Categorize test file. Expected: FAIL — functions not recognized.

- [ ] **Step 3: Write minimal implementation**

Append to `build/Private/DFPackageUniverse.Categorize.ps1`:

```powershell
function Get-DFPackageUniverseApiKey {
    <#
    .SYNOPSIS
        Reads NAME=value from a .env file (comments and blank lines ignored).
        Returns $null when the file or the key is absent.
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
```

- [ ] **Step 4: Run test to verify it passes**

Run the Categorize test file. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add build/Private/DFPackageUniverse.Categorize.ps1 tests/DFPackageUniverse.Categorize.Tests.ps1
git commit -m "feat(package-universe): Phase D env key reader + cached fetch seam"
```

---

## Task 5: Vocabulary loader + coarse domain vocab

**Files:** Create `build/Private/DFPackageUniverse.Vocab.ps1`, `build/categories/domains.jsonc`; Test `tests/DFPackageUniverse.Categorize.Tests.ps1`.

**Interfaces:**
- Produces `Import-DFPackageUniverseVocab([string]$DomainsPath, [string]$TaxonomyPath) -> { Domain [string[]]; Function [string[]]; WorksWith [string[]] }`. `DomainsPath` is the new coarse `domains.jsonc`; `TaxonomyPath` is the existing `data/tool-categories.json` (its `taxonomy.function`/`taxonomy.worksWith`). JSONC comments stripped (anchored). Also `Test-DFPackageUniverseVocabValue([string]$Value, [string[]]$Vocab) -> [bool]`.

- [ ] **Step 1: Write the failing test**

```powershell
    Context 'vocabulary' {
        BeforeAll {
            . "$PSScriptRoot/../build/Private/DFPackageUniverse.Vocab.ps1"
            $script:dom = Join-Path ([System.IO.Path]::GetTempPath()) ("dom-" + [guid]::NewGuid().ToString('N') + ".jsonc")
            @'
{ // coarse top-level domains
  "schemaVersion": 1,
  "domain": ["dev", "system", "network", "text", "media", "security", "data", "productivity"]
}
'@ | Set-Content -Path $script:dom -Encoding utf8
            $script:tax = Join-Path ([System.IO.Path]::GetTempPath()) ("tax-" + [guid]::NewGuid().ToString('N') + ".json")
            (@{ taxonomy = @{ function = @('search', 'editor'); worksWith = @('text', 'json') } } | ConvertTo-Json -Depth 5) | Set-Content -Path $script:tax -Encoding utf8
        }
        AfterAll { Remove-Item $script:dom, $script:tax -ErrorAction Ignore }
        It 'loads the three axes' {
            $v = Import-DFPackageUniverseVocab -DomainsPath $script:dom -TaxonomyPath $script:tax
            $v.Domain | Should -Contain 'network'; $v.Function | Should -Contain 'search'; $v.WorksWith | Should -Contain 'json'
        }
        It 'validates membership' {
            $v = Import-DFPackageUniverseVocab -DomainsPath $script:dom -TaxonomyPath $script:tax
            Test-DFPackageUniverseVocabValue -Value 'search' -Vocab $v.Function | Should -BeTrue
            Test-DFPackageUniverseVocabValue -Value 'nope' -Vocab $v.Function | Should -BeFalse
        }
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run the Categorize test file. Expected: FAIL — `Import-DFPackageUniverseVocab` not recognized.

- [ ] **Step 3: Write minimal implementation**

Create `build/categories/domains.jsonc`:

```jsonc
{
  // Phase D coarse top-level "domain" axis (single-valued per tool). The finer
  // function/worksWith facets live in the trifle taxonomy (data/tool-categories.json).
  // Grown deliberately via human-gated discovery; keep it small (~10-15).
  "schemaVersion": 1,
  "domain": [
    "dev", "system", "network", "text", "media", "security",
    "data", "productivity", "cloud", "gaming", "science", "hardware"
  ]
}
```

Create `build/Private/DFPackageUniverse.Vocab.ps1`:

```powershell
#Requires -Version 7.0

# Phase D closed-vocabulary loader: the coarse domain axis (build/categories/
# domains.jsonc) + the existing trifle function/worksWith taxonomy. See spec.

function Import-DFPackageUniverseVocab {
    <#
    .SYNOPSIS
        Loads the closed classification vocabulary { Domain; Function; WorksWith }
        from the coarse domains.jsonc and the trifle taxonomy JSON. JSONC line/
        block comments stripped (line comments anchored to line start).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DomainsPath, [Parameter(Mandatory)][string]$TaxonomyPath)

    function Read-Jsonc([string]$Path) {
        $t = Get-Content -Raw -Path $Path
        $t = [regex]::Replace($t, '(?m)^\s*//.*$', '')
        $t = [regex]::Replace($t, '(?s)/\*.*?\*/', '')
        $t | ConvertFrom-Json
    }
    $dom = Read-Jsonc $DomainsPath
    $tax = (Read-Jsonc $TaxonomyPath).taxonomy
    [pscustomobject]@{
        Domain    = @($dom.domain)
        Function  = @($tax.function)
        WorksWith = @($tax.worksWith)
    }
}

function Test-DFPackageUniverseVocabValue {
    <#
    .SYNOPSIS
        True when $Value is in the closed $Vocab list (case-insensitive).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][string]$Value, [AllowEmptyCollection()][string[]]$Vocab)
    if (-not $Value) { return $false }
    [bool](@($Vocab) -contains $Value.ToLowerInvariant() -or @($Vocab | ForEach-Object { $_.ToLowerInvariant() }) -contains $Value.ToLowerInvariant())
}
```

- [ ] **Step 4: Run test to verify it passes**

Run the file. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add build/Private/DFPackageUniverse.Vocab.ps1 build/categories/domains.jsonc tests/DFPackageUniverse.Categorize.Tests.ps1
git commit -m "feat(package-universe): Phase D vocabulary loader + coarse domain axis"
```

---

## Task 6: Input gathering (tiers)

**Files:** Modify `build/Private/DFPackageUniverse.Categorize.ps1`; Test same.

**Interfaces:**
- Consumes `Resolve-DFPackageUniverseRepo`, `Get-DFPackageUniverseFetch`.
- Produces `Get-DFPackageUniverseClassifierInput([object[]]$Members, [string]$Name, [string]$Publisher, [string]$Description, [string]$Tags, $Connection, [scriptblock]$Http) -> { Name; Publisher; Description; Tags; DocExcerpt; SignalSource }`. Tiers: README (any-host, resolved → raw URL → fetch) → doc/homepage page → metadata-only. `DocExcerpt` is the fetched text truncated to 4000 chars; `SignalSource` records which tier produced it.

- [ ] **Step 1: Write the failing test**

```powershell
    Context 'Get-DFPackageUniverseClassifierInput' {
        BeforeAll { Import-Module PSSQLite; . "$PSScriptRoot/../build/Private/DFPackageUniverse.CategorizeDb.ps1" }
        It 'uses the repo README when available and records signal_source=readme' {
            $db = Join-Path ([System.IO.Path]::GetTempPath()) ("in-" + [guid]::NewGuid().ToString('N') + ".db")
            try {
                Initialize-DFPackageUniverseCategorizeSchema -DatabasePath $db
                $conn = New-SQLiteConnection -DataSource $db
                $http = { param($Url) [pscustomobject]@{ Content = "# bat`nA cat clone with wings"; ContentType = 'text/markdown'; Status = 'ok' } }
                $m = @( [pscustomobject]@{ source='choco'; package_id='bat'; name='bat'; homepage='https://github.com/sharkdp/bat'; extra=$null } )
                try {
                    $in = Get-DFPackageUniverseClassifierInput -Members $m -Name 'bat' -Publisher 'sharkdp' -Description 'd' -Tags $null -Connection $conn -Http $http
                    $in.SignalSource | Should -Be 'readme'
                    $in.DocExcerpt | Should -Match 'cat clone'
                } finally { $conn.Close() }
            } finally { Remove-Item -Path $db -ErrorAction Ignore }
        }
        It 'falls back to metadata-only when no repo/doc and records signal_source=metadata' {
            $db = Join-Path ([System.IO.Path]::GetTempPath()) ("in2-" + [guid]::NewGuid().ToString('N') + ".db")
            try {
                Initialize-DFPackageUniverseCategorizeSchema -DatabasePath $db
                $conn = New-SQLiteConnection -DataSource $db
                $http = { param($Url) throw 'no network' }
                $m = @( [pscustomobject]@{ source='winget'; package_id='A.X'; name='x'; homepage=$null; extra=$null } )
                try {
                    $in = Get-DFPackageUniverseClassifierInput -Members $m -Name 'x' -Publisher 'A' -Description 'thin' -Tags $null -Connection $conn -Http $http
                    $in.SignalSource | Should -Be 'metadata'
                } finally { $conn.Close() }
            } finally { Remove-Item -Path $db -ErrorAction Ignore }
        }
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run. Expected: FAIL — function not recognized.

- [ ] **Step 3: Write minimal implementation**

Append to `build/Private/DFPackageUniverse.Categorize.ps1`:

```powershell
function Get-DFPackageUniverseClassifierInput {
    <#
    .SYNOPSIS
        Assembles the classifier input for one tool, best-signal-first: any-host
        repo README -> documentation/homepage page -> metadata only. Returns
        { Name; Publisher; Description; Tags; DocExcerpt; SignalSource }; DocExcerpt
        is truncated to 4000 chars. Fetches go through the cached $Http seam.
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
```

- [ ] **Step 4: Run test to verify it passes**

Run. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add build/Private/DFPackageUniverse.Categorize.ps1 tests/DFPackageUniverse.Categorize.Tests.ps1
git commit -m "feat(package-universe): Phase D tiered classifier input gathering"
```

---

## Task 7: Classifier — validate + normalize the model's output

**Files:** Modify `build/Private/DFPackageUniverse.Categorize.ps1`; Test same.

**Interfaces:**
- Produces `ConvertTo-DFPackageUniverseClassification($Raw, $Vocab) -> { Domain; Function[]; WorksWith[]; Interface; AlternativeTo[]; Confidence; NothingFits [bool]; SuggestedTerms[] }`. `$Raw` is the parsed model output object; this **enforces the closed vocabulary** — out-of-vocab domain/function/worksWith values are dropped (and if that empties everything, `NothingFits` is forced true). This is the trust boundary between the model and the cache.

- [ ] **Step 1: Write the failing test**

```powershell
    Context 'ConvertTo-DFPackageUniverseClassification' {
        BeforeAll {
            $script:vocab = [pscustomobject]@{ Domain = @('dev','text'); Function = @('search','editor'); WorksWith = @('text','json') }
        }
        It 'keeps in-vocab values and drops out-of-vocab ones' {
            $raw = [pscustomobject]@{ domain='text'; function=@('search','bogus'); worksWith=@('text'); interface='cli'; alternativeTo=@('grep'); confidence=0.9; nothing_fits=$false; suggested_terms=@() }
            $c = ConvertTo-DFPackageUniverseClassification -Raw $raw -Vocab $script:vocab
            $c.Domain | Should -Be 'text'
            $c.Function | Should -Be @('search')        # 'bogus' dropped
            $c.AlternativeTo | Should -Be @('grep')
            $c.NothingFits | Should -BeFalse
        }
        It 'forces NothingFits when the model output has no in-vocab facet at all' {
            $raw = [pscustomobject]@{ domain='nope'; function=@('nope'); worksWith=@(); interface='cli'; confidence=0.2; nothing_fits=$false; suggested_terms=@('newthing') }
            $c = ConvertTo-DFPackageUniverseClassification -Raw $raw -Vocab $script:vocab
            $c.NothingFits | Should -BeTrue
            $c.SuggestedTerms | Should -Contain 'newthing'
        }
        It 'honors an explicit nothing_fits from the model' {
            $raw = [pscustomobject]@{ domain='dev'; function=@('search'); worksWith=@('text'); interface='cli'; confidence=0.3; nothing_fits=$true; suggested_terms=@() }
            (ConvertTo-DFPackageUniverseClassification -Raw $raw -Vocab $script:vocab).NothingFits | Should -BeTrue
        }
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run. Expected: FAIL — function not recognized.

- [ ] **Step 3: Write minimal implementation**

Append to `build/Private/DFPackageUniverse.Categorize.ps1`:

```powershell
function ConvertTo-DFPackageUniverseClassification {
    <#
    .SYNOPSIS
        The trust boundary between the model and the cache: validates a raw model
        output against the closed vocabulary, dropping out-of-vocab domain/
        function/worksWith values. Forces NothingFits when nothing in-vocab
        survived (or the model set nothing_fits). Returns the normalized record.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Raw, [Parameter(Mandatory)]$Vocab)

    function Keep([object[]]$Values, [string[]]$Allowed) {
        @(@($Values) | ForEach-Object { [string]$_ } | Where-Object { Test-DFPackageUniverseVocabValue -Value $_ -Vocab $Allowed })
    }
    $domainRaw = [string]$Raw.PSObject.Properties['domain'].Value
    $domain = if (Test-DFPackageUniverseVocabValue -Value $domainRaw -Vocab $Vocab.Domain) { $domainRaw.ToLowerInvariant() } else { $null }
    $func = Keep -Values @($Raw.function) -Allowed $Vocab.Function
    $ww   = Keep -Values @($Raw.worksWith) -Allowed $Vocab.WorksWith
    $altProp = $Raw.PSObject.Properties['alternativeTo']
    $alt = if ($altProp) { @(@($altProp.Value) | ForEach-Object { [string]$_ } | Where-Object { $_ }) } else { @() }
    $stProp = $Raw.PSObject.Properties['suggested_terms']
    $suggested = if ($stProp) { @(@($stProp.Value) | ForEach-Object { [string]$_ } | Where-Object { $_ }) } else { @() }
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
```

- [ ] **Step 4: Run test to verify it passes**

Run. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add build/Private/DFPackageUniverse.Categorize.ps1 tests/DFPackageUniverse.Categorize.Tests.ps1
git commit -m "feat(package-universe): Phase D classification validation (closed-vocab trust boundary)"
```

---

## Task 8: OpenAI classifier call (default seam implementation)

**Files:** Modify `build/Private/DFPackageUniverse.Categorize.ps1`; Test same.

**Interfaces:**
- Produces `New-DFPackageUniverseClassifySeam([string]$ApiKey, [string]$Model, [scriptblock]$Rest) -> [scriptblock]`. The returned seam has signature `param($Input, $Vocab) -> { Raw; Model; Usage }`: it builds the OpenAI chat-completions request (JSON-schema structured output constraining domain/function/worksWith to `$Vocab`), calls `$Rest` (the injectable HTTP-POST seam: `param($Uri, $Headers, $Body) -> parsed response`), and returns the parsed model object + token usage. Keeping the wire call behind `$Rest` makes it unit-testable with a canned response.

- [ ] **Step 1: Write the failing test**

```powershell
    Context 'New-DFPackageUniverseClassifySeam' {
        It 'builds a request with the vocab-constrained schema and parses the response' {
            $vocab = [pscustomobject]@{ Domain=@('text'); Function=@('search'); WorksWith=@('text') }
            $captured = $null
            $rest = {
                param($Uri, $Headers, $Body)
                $script:captured = [pscustomobject]@{ Uri=$Uri; Headers=$Headers; Body=$Body }
                # Mimic OpenAI chat-completions shape with a JSON string in message content.
                [pscustomobject]@{ choices=@([pscustomobject]@{ message=[pscustomobject]@{ content='{"domain":"text","function":["search"],"worksWith":["text"],"interface":"cli","alternativeTo":["grep"],"confidence":0.9,"nothing_fits":false,"suggested_terms":[]}' } }); usage=[pscustomobject]@{ total_tokens=321 } }
            }
            $seam = New-DFPackageUniverseClassifySeam -ApiKey 'sk-test' -Model 'gpt-test' -Rest $rest
            $in = [pscustomobject]@{ Name='bat'; Publisher='sharkdp'; Description='cat clone'; Tags=$null; DocExcerpt='# bat'; SignalSource='readme' }
            $out = & $seam $in $vocab
            $out.Raw.domain | Should -Be 'text'
            $out.Usage.total_tokens | Should -Be 321
            $script:captured.Headers['Authorization'] | Should -Be 'Bearer sk-test'
            $script:captured.Uri | Should -Match 'openai\.com'
            ($script:captured.Body | ConvertFrom-Json).model | Should -Be 'gpt-test'
        }
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run. Expected: FAIL — function not recognized.

- [ ] **Step 3: Write minimal implementation**

Append to `build/Private/DFPackageUniverse.Categorize.ps1`:

```powershell
function New-DFPackageUniverseClassifySeam {
    <#
    .SYNOPSIS
        Builds the classifier seam (param($Input,$Vocab) -> {Raw;Model;Usage}) for
        an OpenAI chat-completions call with JSON-schema structured output that
        constrains domain/function/worksWith to the closed vocabulary. The wire
        POST is delegated to $Rest (param($Uri,$Headers,$Body) -> parsed response)
        so it is unit-testable. The default $Rest uses Invoke-RestMethod.
    #>
    [CmdletBinding()]
    [OutputType([scriptblock])]
    param(
        [Parameter(Mandatory)][string]$ApiKey,
        [string]$Model = 'gpt-4o-mini',
        [scriptblock]$Rest = {
            param($Uri, $Headers, $Body)
            Invoke-RestMethod -Uri $Uri -Method Post -Headers $Headers -Body $Body -ContentType 'application/json' -TimeoutSec 60
        }
    )
    {
        param($Input, $Vocab)
        $schema = @{
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
        $sys = 'You classify a command-line tool into a FIXED taxonomy. Use only the provided enum values. If no function/worksWith value fits, set nothing_fits=true and put your suggested new term(s) in suggested_terms. interface is cli/tui/gui. alternativeTo lists classic commands this replaces (e.g. bat->cat).'
        $user = @{ name = $Input.Name; publisher = $Input.Publisher; description = $Input.Description; tags = $Input.Tags; docs = $Input.DocExcerpt } | ConvertTo-Json -Depth 5 -Compress
        $body = @{
            model = $Model
            messages = @(@{ role = 'system'; content = $sys }, @{ role = 'user'; content = $user })
            response_format = @{ type = 'json_schema'; json_schema = @{ name = 'tool_classification'; schema = $schema; strict = $true } }
        } | ConvertTo-Json -Depth 12
        $headers = @{ Authorization = "Bearer $ApiKey" }
        $resp = & $Rest 'https://api.openai.com/v1/chat/completions' $headers $body
        $content = [string]$resp.choices[0].message.content
        [pscustomobject]@{ Raw = ($content | ConvertFrom-Json); Model = $Model; Usage = $resp.usage }
    }.GetNewClosure()
}
```

- [ ] **Step 4: Run test to verify it passes**

Run. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add build/Private/DFPackageUniverse.Categorize.ps1 tests/DFPackageUniverse.Categorize.Tests.ps1
git commit -m "feat(package-universe): Phase D OpenAI classifier seam (structured output)"
```

---

## Task 9: Persist + jsonc export/import (durable survival)

**Files:** Modify `build/Private/DFPackageUniverse.CategorizeDb.ps1`; Test `tests/DFPackageUniverse.CategorizeDb.Tests.ps1`.

**Interfaces:**
- Produces:
  - `Save-DFPackageUniverseClassification($Connection, [string]$CacheKey, $Classification, [string]$SignalSource, [string]$Model, [string]$Status)` — upsert one row (arrays → JSON).
  - `Export-DFPackageUniverseClassifications([string]$DatabasePath, [string]$Path)` — write all `done` rows to the version-controlled JSONC.
  - `Import-DFPackageUniverseClassifications([string]$DatabasePath, [string]$Path)` — load the JSONC into the table (rebuild survival). Round-trip lossless.

- [ ] **Step 1: Write the failing test**

```powershell
    Context 'persist + export/import round-trip' {
        It 'saves, exports to jsonc, and re-imports losslessly' {
            $db = Join-Path ([System.IO.Path]::GetTempPath()) ("rt-" + [guid]::NewGuid().ToString('N') + ".db")
            $js = Join-Path ([System.IO.Path]::GetTempPath()) ("rt-" + [guid]::NewGuid().ToString('N') + ".jsonc")
            try {
                Initialize-DFPackageUniverseCategorizeSchema -DatabasePath $db
                $conn = New-SQLiteConnection -DataSource $db
                $cls = [pscustomobject]@{ Domain='text'; Function=@('search'); WorksWith=@('text'); Interface='cli'; AlternativeTo=@('grep'); Confidence=0.9; NothingFits=$false; SuggestedTerms=@() }
                try { Save-DFPackageUniverseClassification -Connection $conn -CacheKey 'repo:https://github.com/sharkdp/bat|bat' -Classification $cls -SignalSource 'readme' -Model 'gpt-test' -Status 'done' }
                finally { $conn.Close() }
                Export-DFPackageUniverseClassifications -DatabasePath $db -Path $js
                (Get-Content -Raw $js) | Should -Match 'sharkdp/bat'

                $db2 = Join-Path ([System.IO.Path]::GetTempPath()) ("rt2-" + [guid]::NewGuid().ToString('N') + ".db")
                try {
                    Initialize-DFPackageUniverseCategorizeSchema -DatabasePath $db2
                    Import-DFPackageUniverseClassifications -DatabasePath $db2 -Path $js
                    $row = Invoke-SqliteQuery -DataSource $db2 -Query "SELECT domain, function_json FROM tool_classifications WHERE cache_key = 'repo:https://github.com/sharkdp/bat|bat'"
                    $row.domain | Should -Be 'text'
                    ($row.function_json | ConvertFrom-Json) | Should -Contain 'search'
                } finally { Remove-Item -Path $db2 -ErrorAction Ignore }
            } finally { Remove-Item -Path $db, $js -ErrorAction Ignore }
        }
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run the CategorizeDb file. Expected: FAIL — functions not recognized.

- [ ] **Step 3: Write minimal implementation**

Append to `build/Private/DFPackageUniverse.CategorizeDb.ps1`:

```powershell
function Save-DFPackageUniverseClassification {
    <#
    .SYNOPSIS
        Upserts one classification into the durable cache (arrays serialized to
        JSON, @()/-InputObject to avoid single-element unwrap). Status is
        'done' or 'deferred'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Connection, [Parameter(Mandatory)][string]$CacheKey,
        [Parameter(Mandatory)]$Classification, [string]$SignalSource, [string]$Model,
        [Parameter(Mandatory)][ValidateSet('done', 'deferred')][string]$Status
    )
    $c = $Classification
    Invoke-SqliteQuery -SQLiteConnection $Connection -Query @'
INSERT OR REPLACE INTO tool_classifications
  (cache_key, domain, function_json, works_with_json, interface, alternative_to_json,
   confidence, nothing_fits, suggested_terms_json, signal_source, model, status, classified_at)
VALUES (@k, @dom, @fn, @ww, @if, @alt, @conf, @nf, @st, @src, @model, @status, @at);
'@ -SqlParameters @{
        k = $CacheKey; dom = $c.Domain
        fn = (ConvertTo-Json -Compress -InputObject @($c.Function)); ww = (ConvertTo-Json -Compress -InputObject @($c.WorksWith))
        if = $c.Interface; alt = (ConvertTo-Json -Compress -InputObject @($c.AlternativeTo)); conf = $c.Confidence
        nf = [int][bool]$c.NothingFits; st = (ConvertTo-Json -Compress -InputObject @($c.SuggestedTerms))
        src = $SignalSource; model = $Model; status = $Status; at = [datetime]::UtcNow.ToString('o')
    }
}

function Export-DFPackageUniverseClassifications {
    <#
    .SYNOPSIS
        Writes all done classifications to the version-controlled JSONC (the
        source of truth that survives a universe.db rebuild).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DatabasePath, [Parameter(Mandatory)][string]$Path)
    $rows = @(Invoke-SqliteQuery -DataSource $DatabasePath -Query "SELECT * FROM tool_classifications WHERE status = 'done' ORDER BY cache_key")
    $out = @(foreach ($r in $rows) {
        [ordered]@{
            cacheKey = $r.cache_key; domain = $r.domain
            function = @(($r.function_json | ConvertFrom-Json)); worksWith = @(($r.works_with_json | ConvertFrom-Json))
            interface = $r.interface; alternativeTo = @(($r.alternative_to_json | ConvertFrom-Json))
            confidence = $r.confidence; nothingFits = [bool]$r.nothing_fits
            signalSource = $r.signal_source; model = $r.model
        }
    })
    $doc = [ordered]@{ schemaVersion = 1; classifications = $out }
    ($doc | ConvertTo-Json -Depth 8) | Set-Content -Path $Path -Encoding utf8
}

function Import-DFPackageUniverseClassifications {
    <#
    .SYNOPSIS
        Loads the version-controlled JSONC into tool_classifications (rebuild
        survival). JSONC line/block comments stripped. Missing file is a no-op.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DatabasePath, [Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { return }
    $t = Get-Content -Raw -Path $Path
    $t = [regex]::Replace($t, '(?m)^\s*//.*$', ''); $t = [regex]::Replace($t, '(?s)/\*.*?\*/', '')
    $doc = $t | ConvertFrom-Json
    $conn = New-SQLiteConnection -DataSource $DatabasePath
    try {
        foreach ($e in @($doc.classifications)) {
            Invoke-SqliteQuery -SQLiteConnection $conn -Query @'
INSERT OR REPLACE INTO tool_classifications
  (cache_key, domain, function_json, works_with_json, interface, alternative_to_json,
   confidence, nothing_fits, suggested_terms_json, signal_source, model, status, classified_at)
VALUES (@k, @dom, @fn, @ww, @if, @alt, @conf, @nf, '[]', @src, @model, 'done', @at);
'@ -SqlParameters @{
                k = $e.cacheKey; dom = $e.domain
                fn = (ConvertTo-Json -Compress -InputObject @($e.function)); ww = (ConvertTo-Json -Compress -InputObject @($e.worksWith))
                if = $e.interface; alt = (ConvertTo-Json -Compress -InputObject @($e.alternativeTo)); conf = $e.confidence
                nf = [int][bool]$e.nothingFits; src = $e.signalSource; model = $e.model; at = [datetime]::UtcNow.ToString('o')
            }
        }
    } finally { $conn.Close() }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run the CategorizeDb file. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add build/Private/DFPackageUniverse.CategorizeDb.ps1 tests/DFPackageUniverse.CategorizeDb.Tests.ps1
git commit -m "feat(package-universe): Phase D persist + durable jsonc export/import"
```

---

## Task 10: Run loop — resume, budget, resilience, escalation, reconciliation

**Files:** Modify `build/Private/DFPackageUniverse.Categorize.ps1`; Test `tests/DFPackageUniverse.Categorize.Tests.ps1`.

**Interfaces:**
- Consumes all prior. Produces `Invoke-DFPackageUniverseCategorizeRun($Connection, $Vocab, [scriptblock]$Http, [scriptblock]$Classify, [scriptblock]$Escalate, [int]$BudgetCalls, [scriptblock]$Log) -> { Processed; Classified; Escalated; Deferred; NothingFits; Remaining }`. Reads tools+members from the DB, computes each tool's durable key, **skips keys already in `tool_classifications`** (resume), processes in signal-rich order, classifies (escalating on low-confidence/nothing-fits via `$Escalate`), persists per-tool, stops at `BudgetCalls`, marks a tool `deferred` on any error (input/classify) without aborting. `$Classify`/`$Escalate` are the model seams (Task 8).

- [ ] **Step 1: Write the failing test**

```powershell
    Context 'Invoke-DFPackageUniverseCategorizeRun' {
        BeforeAll { Import-Module PSSQLite; . "$PSScriptRoot/../build/Private/DFPackageUniverse.CategorizeDb.ps1"; . "$PSScriptRoot/../build/Private/DFPackageUniverse.Vocab.ps1" }
        function New-CatRunDb {
            $db = Join-Path ([System.IO.Path]::GetTempPath()) ("run-" + [guid]::NewGuid().ToString('N') + ".db")
            Invoke-SqliteQuery -DataSource $db -Query @'
CREATE TABLE tools (tool_id INTEGER PRIMARY KEY, name TEXT, cluster_id INTEGER, source_count INTEGER);
CREATE TABLE tool_packages (tool_id INTEGER, source TEXT, package_id TEXT, homepage TEXT, extra TEXT, PRIMARY KEY(source,package_id));
CREATE TABLE pipeline_log (id INTEGER PRIMARY KEY, stage TEXT, source TEXT, package_id TEXT, level TEXT, message TEXT, logged_at TEXT);
'@
            Initialize-DFPackageUniverseCategorizeSchema -DatabasePath $db
            $db
        }
        function Add-Tool { param($Db,$Id,$Name,$Src,$Pid,$Home)
            Invoke-SqliteQuery -DataSource $Db -Query "INSERT INTO tools (tool_id,name,source_count) VALUES (@i,@n,1)" -SqlParameters @{i=$Id;n=$Name}
            Invoke-SqliteQuery -DataSource $Db -Query "INSERT INTO tool_packages (tool_id,source,package_id,homepage) VALUES (@i,@s,@p,@h)" -SqlParameters @{i=$Id;s=$Src;p=$Pid;h=$Home}
        }
        $vocab = [pscustomobject]@{ Domain=@('text','dev'); Function=@('search'); WorksWith=@('text') }
        $goodClassify = { param($Input,$Vocab) [pscustomobject]@{ Raw=[pscustomobject]@{ domain='text'; function=@('search'); worksWith=@('text'); interface='cli'; alternativeTo=@(); confidence=0.9; nothing_fits=$false; suggested_terms=@() }; Model='m'; Usage=[pscustomobject]@{ total_tokens=10 } } }
        $http = { param($Url) [pscustomobject]@{ Content='# readme'; ContentType='text/markdown'; Status='ok' } }
        $log = { param($Level,$Src,$Pid,$Msg) }

        It 'classifies unprocessed tools and is idempotent on a second run (resume)' {
            $db = New-CatRunDb
            try {
                Add-Tool -Db $db -Id 1 -Name 'bat' -Src 'choco' -Pid 'bat' -Home 'https://github.com/sharkdp/bat'
                $conn = New-SQLiteConnection -DataSource $db
                try {
                    $r1 = Invoke-DFPackageUniverseCategorizeRun -Connection $conn -Vocab $vocab -Http $http -Classify $goodClassify -BudgetCalls 100 -Log $log
                    $r1.Classified | Should -Be 1
                    $script:secondCalls = 0
                    $countingClassify = { param($Input,$Vocab) $script:secondCalls++; & $using:goodClassify $Input $Vocab }.GetNewClosure()
                    $r2 = Invoke-DFPackageUniverseCategorizeRun -Connection $conn -Vocab $vocab -Http $http -Classify $countingClassify -BudgetCalls 100 -Log $log
                    $r2.Classified | Should -Be 0    # already cached -> resume skips it
                } finally { $conn.Close() }
                (Invoke-SqliteQuery -DataSource $db -Query "SELECT COUNT(*) n FROM tool_classifications WHERE status='done'").n | Should -Be 1
            } finally { Remove-Item -Path $db -ErrorAction Ignore }
        }

        It 'stops at the budget, leaving the rest unprocessed for a later run' {
            $db = New-CatRunDb
            try {
                1..3 | ForEach-Object { Add-Tool -Db $db -Id $_ -Name "t$_" -Src 'scoop' -Pid "main/t$_" -Home $null }
                $conn = New-SQLiteConnection -DataSource $db
                try {
                    $r = Invoke-DFPackageUniverseCategorizeRun -Connection $conn -Vocab $vocab -Http $http -Classify $goodClassify -BudgetCalls 2 -Log $log
                    $r.Classified | Should -Be 2; $r.Remaining | Should -BeGreaterThan 0
                } finally { $conn.Close() }
            } finally { Remove-Item -Path $db -ErrorAction Ignore }
        }

        It 'marks a tool deferred (not done) when classify throws, without aborting the batch' {
            $db = New-CatRunDb
            try {
                Add-Tool -Db $db -Id 1 -Name 'bad' -Src 'scoop' -Pid 'main/bad' -Home $null
                Add-Tool -Db $db -Id 2 -Name 'good' -Src 'scoop' -Pid 'main/good' -Home $null
                $mixed = { param($Input,$Vocab) if ($Input.Name -eq 'bad') { throw 'boom' }; & $using:goodClassify $Input $Vocab }.GetNewClosure()
                $conn = New-SQLiteConnection -DataSource $db
                try { $r = Invoke-DFPackageUniverseCategorizeRun -Connection $conn -Vocab $vocab -Http $http -Classify $mixed -BudgetCalls 100 -Log $log } finally { $conn.Close() }
                (Invoke-SqliteQuery -DataSource $db -Query "SELECT status FROM tool_classifications WHERE cache_key='pkg:scoop|main/bad'").status | Should -Be 'deferred'
                (Invoke-SqliteQuery -DataSource $db -Query "SELECT status FROM tool_classifications WHERE cache_key='pkg:scoop|main/good'").status | Should -Be 'done'
            } finally { Remove-Item -Path $db -ErrorAction Ignore }
        }

        It 'escalates a low-confidence result to the Escalate seam' {
            $db = New-CatRunDb
            try {
                Add-Tool -Db $db -Id 1 -Name 'x' -Src 'scoop' -Pid 'main/x' -Home $null
                $lowConf = { param($Input,$Vocab) [pscustomobject]@{ Raw=[pscustomobject]@{ domain='text'; function=@('search'); worksWith=@('text'); interface='cli'; alternativeTo=@(); confidence=0.2; nothing_fits=$false; suggested_terms=@() }; Model='small'; Usage=[pscustomobject]@{total_tokens=5} } }
                $script:escalated = 0
                $esc = { param($Input,$Vocab) $script:escalated++; [pscustomobject]@{ Raw=[pscustomobject]@{ domain='dev'; function=@('search'); worksWith=@('text'); interface='cli'; alternativeTo=@(); confidence=0.95; nothing_fits=$false; suggested_terms=@() }; Model='strong'; Usage=[pscustomobject]@{total_tokens=8} } }
                $conn = New-SQLiteConnection -DataSource $db
                try { $r = Invoke-DFPackageUniverseCategorizeRun -Connection $conn -Vocab $vocab -Http $http -Classify $lowConf -Escalate $esc -BudgetCalls 100 -Log $log } finally { $conn.Close() }
                $script:escalated | Should -Be 1
                (Invoke-SqliteQuery -DataSource $db -Query "SELECT model FROM tool_classifications WHERE cache_key='pkg:scoop|main/x'").model | Should -Be 'strong'
            } finally { Remove-Item -Path $db -ErrorAction Ignore }
        }
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run the Categorize file. Expected: FAIL — `Invoke-DFPackageUniverseCategorizeRun` not recognized.

- [ ] **Step 3: Write minimal implementation**

Append to `build/Private/DFPackageUniverse.Categorize.ps1`:

```powershell
function Invoke-DFPackageUniverseCategorizeRun {
    <#
    .SYNOPSIS
        The Phase D run loop: for each tool whose durable key is not yet cached
        (resume), gather input, classify (escalating low-confidence/nothing-fits),
        persist per-tool, stop at the call budget. A tool whose input/classify
        throws is marked 'deferred' (retried next run) and never aborts the batch.
        Signal-rich tools (has-repo, higher source_count) are processed first.
        Returns a reconciliation summary.
    .PARAMETER EscalateThreshold
        Confidence below which (or on nothing_fits) the Escalate seam is used.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Connection, [Parameter(Mandatory)]$Vocab,
        [Parameter(Mandatory)][scriptblock]$Http, [Parameter(Mandatory)][scriptblock]$Classify,
        [scriptblock]$Escalate, [int]$BudgetCalls = [int]::MaxValue,
        [double]$EscalateThreshold = 0.5, [Parameter(Mandatory)][scriptblock]$Log
    )
    $De = { param($v) if ($v -is [DBNull]) { $null } else { $v } }
    $rawTools = @(Invoke-SqliteQuery -SQLiteConnection $Connection -Query 'SELECT tool_id, name, source_count FROM tools')
    $members = @(Invoke-SqliteQuery -SQLiteConnection $Connection -Query 'SELECT tool_id, source, package_id, homepage, extra FROM tool_packages')
    $byTool = @{}
    foreach ($m in $members) {
        $id = [int]$m.tool_id
        if (-not $byTool.ContainsKey($id)) { $byTool[$id] = [System.Collections.Generic.List[object]]::new() }
        $byTool[$id].Add([pscustomobject]@{ source = $m.source; package_id = $m.package_id; homepage = (& $De $m.homepage); extra = (& $De $m.extra); name = $m.name })
    }
    # Signal-rich first: has-homepage/repo, then higher source_count.
    $ordered = @($rawTools | Sort-Object `
        @{ e = { $mm = $byTool[[int]$_.tool_id]; if ($mm -and @($mm | Where-Object { $_.homepage }).Count) { 0 } else { 1 } } }, `
        @{ e = { - [int]$_.source_count } }, @{ e = { [int]$_.tool_id } })

    $processed = 0; $classified = 0; $escalated = 0; $deferred = 0; $nothing = 0; $calls = 0
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
            if ($Escalate -and ($cls.Confidence -lt $EscalateThreshold -or $cls.NothingFits)) {
                $calls++; $escalated++
                $out2 = & $Escalate $in $Vocab
                $cls = ConvertTo-DFPackageUniverseClassification -Raw $out2.Raw -Vocab $Vocab
                $model = [string]$out2.Model
            }
            Save-DFPackageUniverseClassification -Connection $Connection -CacheKey $key -Classification $cls -SignalSource $in.SignalSource -Model $model -Status 'done'
            $classified++
            if ($cls.NothingFits) { $nothing++ ; & $Log 'review' $anchor.source $anchor.package_id "nothing-fits: suggested $($cls.SuggestedTerms -join ',')" }
            elseif ($cls.Confidence -lt $EscalateThreshold) { & $Log 'review' $anchor.source $anchor.package_id "low-confidence $($cls.Confidence)" }
        } catch {
            $deferred++
            & $Log 'warning' $mm[0].source $mm[0].package_id "categorize deferred: $_"
            Save-DFPackageUniverseClassification -Connection $Connection -CacheKey $key -Classification ([pscustomobject]@{ Domain=$null; Function=@(); WorksWith=@(); Interface=$null; AlternativeTo=@(); Confidence=0.0; NothingFits=$false; SuggestedTerms=@() }) -SignalSource 'error' -Model $null -Status 'deferred'
        }
    }
    $remaining = @($ordered | Where-Object {
        $k = Get-DFPackageUniverseDurableKey -Members @($byTool[[int]$_.tool_id]) -Name ([string]$_.name)
        @(Invoke-SqliteQuery -SQLiteConnection $Connection -Query 'SELECT 1 FROM tool_classifications WHERE cache_key=@k AND status=''done''' -SqlParameters @{ k = $k }).Count -eq 0
    }).Count

    [pscustomobject]@{ Processed = $processed; Classified = $classified; Escalated = $escalated; Deferred = $deferred; NothingFits = $nothing; Remaining = $remaining }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run the Categorize file. Expected: PASS (all four run-loop tests).

- [ ] **Step 5: Commit**

```bash
git add build/Private/DFPackageUniverse.Categorize.ps1 tests/DFPackageUniverse.Categorize.Tests.ps1
git commit -m "feat(package-universe): Phase D run loop (resume + budget + resilience + escalation)"
```

---

## Task 11: Aggregate classifications onto the tools

**Files:** Modify `build/Private/DFPackageUniverse.CategorizeDb.ps1`; Test `tests/DFPackageUniverse.CategorizeDb.Tests.ps1`.

**Interfaces:**
- Produces `Update-DFPackageUniverseToolCategories([string]$DatabasePath)` — for every tool, compute its durable key, look up the cached classification, and write `domain`/`function`/`worksWith`/`interface`/`alternativeTo` onto the tool. Creates a `tool_domain` column on `tools` (via `ALTER TABLE ... ADD COLUMN IF NOT EXISTS`-equivalent guard) and replaces the Phase C first-pass `tool_categories` rows for that tool with the classifier's `function` values (so discovery reads the richer set). Idempotent.

- [ ] **Step 1: Write the failing test**

```powershell
    Context 'Update-DFPackageUniverseToolCategories' {
        It 'writes each tool the classification of its durable key' {
            $db = Join-Path ([System.IO.Path]::GetTempPath()) ("agg-" + [guid]::NewGuid().ToString('N') + ".db")
            try {
                Invoke-SqliteQuery -DataSource $db -Query @'
CREATE TABLE tools (tool_id INTEGER PRIMARY KEY, name TEXT, domain TEXT);
CREATE TABLE tool_packages (tool_id INTEGER, source TEXT, package_id TEXT, homepage TEXT, extra TEXT, PRIMARY KEY(source,package_id));
CREATE TABLE tool_categories (tool_id INTEGER, category TEXT, PRIMARY KEY(tool_id,category));
'@
                Initialize-DFPackageUniverseCategorizeSchema -DatabasePath $db
                Invoke-SqliteQuery -DataSource $db -Query "INSERT INTO tools (tool_id,name) VALUES (1,'bat')"
                Invoke-SqliteQuery -DataSource $db -Query "INSERT INTO tool_packages (tool_id,source,package_id,homepage) VALUES (1,'choco','bat','https://github.com/sharkdp/bat')"
                Invoke-SqliteQuery -DataSource $db -Query "INSERT INTO tool_classifications (cache_key,domain,function_json,works_with_json,interface,alternative_to_json,confidence,nothing_fits,suggested_terms_json,status,classified_at) VALUES ('repo:https://github.com/sharkdp/bat|bat','text','[\"file-viewing\"]','[\"text\"]','cli','[\"cat\"]',0.9,0,'[]','done','now')"
                Update-DFPackageUniverseToolCategories -DatabasePath $db
                (Invoke-SqliteQuery -DataSource $db -Query "SELECT domain FROM tools WHERE tool_id=1").domain | Should -Be 'text'
                @(Invoke-SqliteQuery -DataSource $db -Query "SELECT category FROM tool_categories WHERE tool_id=1").category | Should -Contain 'file-viewing'
            } finally { Remove-Item -Path $db -ErrorAction Ignore }
        }
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run the CategorizeDb file. Expected: FAIL — function not recognized.

- [ ] **Step 3: Write minimal implementation**

Append to `build/Private/DFPackageUniverse.CategorizeDb.ps1` (note: it dot-sources the durable-key helper at call time — the orchestrator loads both files):

```powershell
function Update-DFPackageUniverseToolCategories {
    <#
    .SYNOPSIS
        Writes each tool the classification cached under its durable key: sets
        tools.domain and replaces its Phase C first-pass tool_categories with the
        classifier's function facets. Idempotent. Requires
        Get-DFPackageUniverseDurableKey to be loaded (orchestrator dot-sources it).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DatabasePath)

    $cols = @(Invoke-SqliteQuery -DataSource $DatabasePath -Query "PRAGMA table_info(tools)").name
    if ($cols -notcontains 'domain') { Invoke-SqliteQuery -DataSource $DatabasePath -Query "ALTER TABLE tools ADD COLUMN domain TEXT" }

    $De = { param($v) if ($v -is [DBNull]) { $null } else { $v } }
    $tools = @(Invoke-SqliteQuery -DataSource $DatabasePath -Query 'SELECT tool_id, name FROM tools')
    $members = @(Invoke-SqliteQuery -DataSource $DatabasePath -Query 'SELECT tool_id, source, package_id, homepage, extra FROM tool_packages')
    $byTool = @{}
    foreach ($m in $members) {
        $id = [int]$m.tool_id
        if (-not $byTool.ContainsKey($id)) { $byTool[$id] = [System.Collections.Generic.List[object]]::new() }
        $byTool[$id].Add([pscustomobject]@{ source = $m.source; package_id = $m.package_id; homepage = (& $De $m.homepage); extra = (& $De $m.extra) })
    }
    $conn = New-SQLiteConnection -DataSource $DatabasePath
    try {
        Invoke-SqliteQuery -SQLiteConnection $conn -Query 'BEGIN TRANSACTION;'
        foreach ($t in $tools) {
            $id = [int]$t.tool_id
            $mm = @($byTool[$id])
            if ($mm.Count -eq 0) { continue }
            $key = Get-DFPackageUniverseDurableKey -Members $mm -Name ([string]$t.name)
            $c = @(Invoke-SqliteQuery -SQLiteConnection $conn -Query "SELECT domain, function_json FROM tool_classifications WHERE cache_key=@k AND status='done'" -SqlParameters @{ k = $key })
            if ($c.Count -eq 0) { continue }
            Invoke-SqliteQuery -SQLiteConnection $conn -Query 'UPDATE tools SET domain=@d WHERE tool_id=@i' -SqlParameters @{ d = (& $De $c[0].domain); i = $id }
            Invoke-SqliteQuery -SQLiteConnection $conn -Query 'DELETE FROM tool_categories WHERE tool_id=@i' -SqlParameters @{ i = $id }
            foreach ($fn in @(($c[0].function_json | ConvertFrom-Json))) {
                Invoke-SqliteQuery -SQLiteConnection $conn -Query 'INSERT OR IGNORE INTO tool_categories (tool_id, category) VALUES (@i, @c)' -SqlParameters @{ i = $id; c = $fn }
            }
        }
        Invoke-SqliteQuery -SQLiteConnection $conn -Query 'COMMIT;'
    } catch { Invoke-SqliteQuery -SQLiteConnection $conn -Query 'ROLLBACK;'; throw } finally { $conn.Close() }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run the CategorizeDb file (its `BeforeAll` must also dot-source `DFPackageUniverse.Merge.ps1` + `DFPackageUniverse.Categorize.ps1` for `Get-DFPackageUniverseDurableKey`/`Resolve-DFPackageUniverseRepo`). Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add build/Private/DFPackageUniverse.CategorizeDb.ps1 tests/DFPackageUniverse.CategorizeDb.Tests.ps1
git commit -m "feat(package-universe): Phase D aggregate classifications onto tools"
```

---

## Task 12: Orchestrator script + CHANGELOG

**Files:** Create `build/Build-DFPackageUniverseCategories.ps1`; Modify `CHANGELOG.md`; Test `tests/DFPackageUniverse.Categorize.Tests.ps1`.

**Interfaces:**
- A runnable script that: checks PSSQLite; dot-sources `build/Private/*.ps1`; requires the DB + `tools`/`tool_packages` (throws "run Phase C first" if absent); reads `OPENAI_API_KEY` from `.env` (throws if absent unless `-Classify` seam supplied); imports the durable jsonc into the cache; initializes the cache schema; builds the real classify seam (Task 8); runs the loop with `-BudgetCalls`; aggregates (Task 11); exports the durable jsonc; prints a reconciliation summary; returns it. Accepts `-BudgetCalls`, `-DatabasePath`, `-EnvPath`, `-ClassificationsPath`, and test seams `-Http`/`-Classify`/`-Escalate`.

- [ ] **Step 1: Write the failing test**

```powershell
    Context 'Build-DFPackageUniverseCategories.ps1' {
        BeforeAll { Import-Module PSSQLite; . "$PSScriptRoot/../build/Private/DFPackageUniverse.CategorizeDb.ps1"; . "$PSScriptRoot/../build/Private/DFPackageUniverse.Vocab.ps1" }
        It 'runs end-to-end against a prepared DB with injected seams and returns a summary' {
            $db = Join-Path ([System.IO.Path]::GetTempPath()) ("orch-" + [guid]::NewGuid().ToString('N') + ".db")
            $js = Join-Path ([System.IO.Path]::GetTempPath()) ("orch-" + [guid]::NewGuid().ToString('N') + ".jsonc")
            try {
                Invoke-SqliteQuery -DataSource $db -Query @'
CREATE TABLE tools (tool_id INTEGER PRIMARY KEY, name TEXT, source_count INTEGER);
CREATE TABLE tool_packages (tool_id INTEGER, source TEXT, package_id TEXT, homepage TEXT, extra TEXT, PRIMARY KEY(source,package_id));
CREATE TABLE tool_categories (tool_id INTEGER, category TEXT, PRIMARY KEY(tool_id,category));
CREATE TABLE pipeline_log (id INTEGER PRIMARY KEY, stage TEXT, source TEXT, package_id TEXT, level TEXT, message TEXT, logged_at TEXT);
'@
                Invoke-SqliteQuery -DataSource $db -Query "INSERT INTO tools (tool_id,name,source_count) VALUES (1,'bat',1)"
                Invoke-SqliteQuery -DataSource $db -Query "INSERT INTO tool_packages (tool_id,source,package_id,homepage) VALUES (1,'choco','bat','https://github.com/sharkdp/bat')"
                '{ "schemaVersion":1, "classifications":[] }' | Set-Content -Path $js
                $http = { param($Url) [pscustomobject]@{ Content='# bat'; ContentType='text/markdown'; Status='ok' } }
                $classify = { param($Input,$Vocab) [pscustomobject]@{ Raw=[pscustomobject]@{ domain='text'; function=@('file-viewing'); worksWith=@('text'); interface='cli'; alternativeTo=@('cat'); confidence=0.9; nothing_fits=$false; suggested_terms=@() }; Model='m'; Usage=[pscustomobject]@{total_tokens=10} } }
                $summary = & "$PSScriptRoot/../build/Build-DFPackageUniverseCategories.ps1" -DatabasePath $db -ClassificationsPath $js -Http $http -Classify $classify -BudgetCalls 100 6>$null
                $summary.Classified | Should -Be 1
                (Invoke-SqliteQuery -DataSource $db -Query "SELECT domain FROM tools WHERE tool_id=1").domain | Should -Be 'text'
                (Get-Content -Raw $js) | Should -Match 'sharkdp/bat'
            } finally { Remove-Item -Path $db, $js -ErrorAction Ignore }
        }
        It 'throws when tool_packages is missing (Phase C not run)' {
            $db = Join-Path ([System.IO.Path]::GetTempPath()) ("noc-" + [guid]::NewGuid().ToString('N') + ".db")
            try {
                Invoke-SqliteQuery -DataSource $db -Query "CREATE TABLE tools (tool_id INTEGER PRIMARY KEY)"
                { & "$PSScriptRoot/../build/Build-DFPackageUniverseCategories.ps1" -DatabasePath $db -Http {} -Classify {} 6>$null } | Should -Throw '*tool_packages*'
            } finally { Remove-Item -Path $db -ErrorAction Ignore }
        }
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run the Categorize file. Expected: FAIL — script does not exist.

- [ ] **Step 3: Write minimal implementation**

Create `build/Build-DFPackageUniverseCategories.ps1`:

```powershell
#Requires -Version 7.0
<#
.SYNOPSIS
    Phase D of the package-universe pipeline: categorization (Plan 1 engine).
.DESCRIPTION
    Classifies every merged tool into a closed taxonomy by reading its docs via
    an LLM, caching each result durably (survives re-runs and re-clustering).
    Resumable and budget-capped: re-run to continue where the last stop left off.
    See docs/superpowers/specs/2026-07-17-package-universe-categorization-design.md.
.PARAMETER BudgetCalls
    Max model calls this run (stop-and-resume budget). Default: unlimited.
.PARAMETER Http / Classify / Escalate
    Injectable seams (tests + custom models); defaults use the real network.
.OUTPUTS
    A reconciliation summary object.
.EXAMPLE
    ./build/Build-DFPackageUniverseCategories.ps1 -BudgetCalls 500
#>
[CmdletBinding()]
param(
    [string]$DatabasePath = (Join-Path $PSScriptRoot '.package-universe/universe.db'),
    [string]$EnvPath = (Join-Path $PSScriptRoot '../.env'),
    [string]$ClassificationsPath = (Join-Path $PSScriptRoot '../data/package-universe-classifications.jsonc'),
    [string]$DomainsPath = (Join-Path $PSScriptRoot 'categories/domains.jsonc'),
    [string]$TaxonomyPath = (Join-Path $PSScriptRoot '../data/tool-categories.json'),
    [string]$Model = 'gpt-4o-mini',
    [int]$BudgetCalls = [int]::MaxValue,
    [double]$EscalateThreshold = 0.5,
    [scriptblock]$Http,
    [scriptblock]$Classify,
    [scriptblock]$Escalate
)

Set-StrictMode -Version Latest
if (-not (Get-Module -ListAvailable -Name 'PSSQLite')) { throw "Build-DFPackageUniverseCategories: PSSQLite not installed." }
Import-Module PSSQLite -ErrorAction Stop
if (-not (Get-Command Invoke-DFPackageUniverseCategorizeRun -ErrorAction Ignore)) {
    Get-ChildItem -Path (Join-Path $PSScriptRoot 'Private') -Filter '*.ps1' | ForEach-Object { . $_.FullName }
}

if (-not (Test-Path $DatabasePath)) { throw "Build-DFPackageUniverseCategories: database not found at '$DatabasePath'. Run Phase A-C first." }
$hasPkgs = @(Invoke-SqliteQuery -DataSource $DatabasePath -Query "SELECT name FROM sqlite_master WHERE type='table' AND name='tool_packages';")
if ($hasPkgs.Count -eq 0) { throw "Build-DFPackageUniverseCategories: tool_packages not found. Run Build-DFPackageUniverseTools.ps1 (Phase C) first." }

$vocab = Import-DFPackageUniverseVocab -DomainsPath $DomainsPath -TaxonomyPath $TaxonomyPath

if (-not $Classify) {
    $key = Get-DFPackageUniverseApiKey -EnvPath $EnvPath -Name 'OPENAI_API_KEY'
    if (-not $key) { throw "Build-DFPackageUniverseCategories: OPENAI_API_KEY not found in '$EnvPath' (and no -Classify seam supplied)." }
    $Classify = New-DFPackageUniverseClassifySeam -ApiKey $key -Model $Model
    if (-not $Escalate) { $Escalate = $Classify }   # Plan 1: escalate to the same model; Plan 2 wires a stronger one.
}
if (-not $Http) {
    $Http = { param($Url) $c = Invoke-RestMethod -Uri $Url -TimeoutSec 20 -Headers @{ 'User-Agent' = 'DotForge package-universe (+https://github.com/simsrw73/DotForge)' }; [pscustomobject]@{ Content = [string]$c; ContentType = 'text'; Status = 'ok' } }
}

Initialize-DFPackageUniverseCategorizeSchema -DatabasePath $DatabasePath
Import-DFPackageUniverseClassifications -DatabasePath $DatabasePath -Path $ClassificationsPath

$conn = New-SQLiteConnection -DataSource $DatabasePath
$log = { param($Level, $Src, $Pid, $Msg) Invoke-SqliteQuery -SQLiteConnection $conn -Query "INSERT INTO pipeline_log (stage,source,package_id,level,message,logged_at) VALUES ('categorize',@s,@p,@l,@m,@at)" -SqlParameters @{ s = $Src; p = $Pid; l = $Level; m = $Msg; at = [datetime]::UtcNow.ToString('o') } }
try {
    $summary = Invoke-DFPackageUniverseCategorizeRun -Connection $conn -Vocab $vocab -Http $Http -Classify $Classify -Escalate $Escalate -BudgetCalls $BudgetCalls -EscalateThreshold $EscalateThreshold -Log $log
} finally { $conn.Close() }

Update-DFPackageUniverseToolCategories -DatabasePath $DatabasePath
Export-DFPackageUniverseClassifications -DatabasePath $DatabasePath -Path $ClassificationsPath

Write-Host 'Phase D (categorization) run complete:'
Write-Host "  processed    : $($summary.Processed)"
Write-Host "  classified   : $($summary.Classified)"
Write-Host "  escalated    : $($summary.Escalated)"
Write-Host "  deferred     : $($summary.Deferred)"
Write-Host "  nothing-fits : $($summary.NothingFits)"
Write-Host "  remaining    : $($summary.Remaining)  (re-run to continue)"

$summary
```

- [ ] **Step 4: Run test to verify it passes**

Run the Categorize file. Expected: PASS.

- [ ] **Step 5: Update CHANGELOG**

Add under `[Unreleased] > ### Added` in `CHANGELOG.md`:

```markdown
- **Package-universe Phase D — categorization engine (Plan 1)** — `build/Build-DFPackageUniverseCategories.ps1` classifies every merged tool into a closed taxonomy (coarse `domain` + `function`/`worksWith` facets + `interface`, plus `alternativeTo`) by reading each tool's own docs (any-host README → doc page → metadata) via a small OpenAI model. Each result is cached durably (keyed on a stable identity signal, not the volatile tool_id) and exported to a version-controlled `data/package-universe-classifications.jsonc`, so the run is resumable, budget-capped, and survives DB rebuilds and re-clustering. Build-only; no public module surface change.
```

- [ ] **Step 6: Run the full suite**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/ -Output Detailed"`
Expected: all pass (the Clipboard test may flake under the full run — re-run in isolation to confirm the known flake).

- [ ] **Step 7: Commit**

```bash
git add build/Build-DFPackageUniverseCategories.ps1 tests/DFPackageUniverse.Categorize.Tests.ps1 CHANGELOG.md data/package-universe-classifications.jsonc
git commit -m "feat(package-universe): Phase D categorization orchestrator (Build-DFPackageUniverseCategories)"
```

Also create the seed `data/package-universe-classifications.jsonc` in this task:
```jsonc
{
  // Durable, version-controlled classification export (source of truth; the
  // universe.db tool_classifications table is a working mirror). Survives DB
  // rebuilds. Regenerated by Build-DFPackageUniverseCategories.ps1.
  "schemaVersion": 1,
  "classifications": []
}
```

---

## Post-implementation: live run (user-run, staged over days)

The engine is designed to grind incrementally. Typical use:

```powershell
# First, curate the base vocabulary (domains.jsonc + confirm data/tool-categories.json
# has a good function/worksWith set). Put OPENAI_API_KEY=... in the gitignored .env.
./build/Build-DFPackageUniverseCategories.ps1 -BudgetCalls 500     # a first slice
# ...inspect data/package-universe-classifications.jsonc + the review queue...
Invoke-SqliteQuery -DataSource ./build/.package-universe/universe.db -Query "SELECT level, COUNT(*) FROM pipeline_log WHERE stage='categorize' GROUP BY level"
./build/Build-DFPackageUniverseCategories.ps1 -BudgetCalls 2000    # resume; only unprocessed tools cost calls
```

Signal-rich tools are done first, so an early stop still yields the most useful categories. Re-running after a B→C re-cluster re-uses every cached classification whose durable key is unchanged.

---

## Self-Review (completed during authoring)

- **Spec coverage (Plan-1 scope):** durable-key cache (Tasks 2,3,9) ✓; any-host repo resolver + back-fill (Task 1) ✓; tiered input README→docs→metadata (Task 6) ✓; small-OpenAI structured-output classifier with closed-vocab trust boundary (Tasks 7,8) ✓; escalation seam (Tasks 8,10) ✓; resumable + budget-capped + resilient run (Task 10) ✓; persistent-never-truncated cache (Task 3) ✓; durable jsonc export/import survival (Task 9) ✓; aggregation onto tools, superseding Phase C keyword categories (Task 11) ✓; orchestrator + guards + CHANGELOG (Task 12) ✓; `.env` key (Task 4) ✓; coarse `domain` axis (Task 5) ✓. **Deferred to Plan 2 (per spec + scope):** bottom-up vocab discovery bootstrap, embeddings/`relatedTo`, gated web-search tier, shipped-db export. The `alternativeTo`, `nothing_fits`, and `suggested_terms` signals are *captured* now (cheap) but *consumed* in Plan 2.
- **Type consistency:** the member-row shape `{source;package_id;homepage;extra(;name)}`, the classification record `{Domain;Function;WorksWith;Interface;AlternativeTo;Confidence;NothingFits;SuggestedTerms}`, the vocab `{Domain;Function;WorksWith}`, and the classify-seam return `{Raw;Model;Usage}` are used identically across producer/consumer tasks (Task 7 producer ↔ Task 9 persister ↔ Task 10 loop; Task 8 seam ↔ Task 10 loop).
- **Placeholder scan:** none — every step has complete code and a concrete run/expected line.
- **Note for the implementer:** `tests/DFPackageUniverse.CategorizeDb.Tests.ps1` must dot-source `DFPackageUniverse.Merge.ps1` (for `ConvertFrom-DFDbNull`) and `DFPackageUniverse.Categorize.ps1` (for `Get-DFPackageUniverseDurableKey`/`Resolve-DFPackageUniverseRepo`) in its `BeforeAll` from Task 11 onward, since aggregation depends on the durable key.
