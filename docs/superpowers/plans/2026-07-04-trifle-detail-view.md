# trifle Detail View Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let trifle zero in on one package and show everything every catalog knows about it — detailed card on exact match, `source:packageId` qualified queries, `-All` table with Id column, `ftrifle <query>` fzf preview, opt-in `-GitInfo` / `-Readme`.

**Architecture:** Each catalog provider gains a `Detail` scriptblock hook returning a normalized `DotForge.ToolSourceDetail`; a new cache-first engine (`Get-DFCatalogDetailCache`, mirroring `Search-DFCatalogQueryCache`) serves them from `catalogs/<provider>/details/`. `Find-DFPackage` attaches the merged details to the existing `DotForge.ToolInfo` (`Details` ordered dict + `GitHub`), and a new pure renderer `Format-DFToolDetailCard` draws the card.

**Tech Stack:** PowerShell 7+, Pester 5, existing DotForge catalog plumbing (`Private/DFCatalog.ps1`), fzf via `Invoke-DFPicker`/`Invoke-DFFzf`, GitHub REST (via `gh` when available).

**Spec:** `docs/superpowers/specs/2026-07-04-trifle-detail-view-design.md`

## Global Constraints

- All public functions use the `DF` prefix; private helpers too, but live in `Private/` and are not exported.
- No `$ErrorActionPreference = 'Stop'` in any module file.
- All directory creation goes through `New-DFDirectory`, never raw `New-Item`.
- `DotForge.psm1` auto-dot-sources `Private/*.ps1` and `Public/*.ps1` alphabetically — new private files load automatically; provider files load BEFORE `DFCatalog.ps1`, so any file touching `$script:DFCatalogProviders` must guard-init it (`if (-not $script:DFCatalogProviders) { $script:DFCatalogProviders = @{} }`).
- No new public functions or aliases in this plan → **no `DotForge.psd1` changes** except docs steps say otherwise.
- Every public function whose params change must get updated comment-based help (`.PARAMETER` per param, verified with `Get-Help <fn> -Full`).
- Run tests from `pwsh -NoProfile` to avoid profile interference: `pwsh -NoProfile -Command "Invoke-Pester tests/<file> -Output Detailed"`.
- PowerShell regex on CLI output: use `-creplace` for case-sensitive matching and `\r?$` instead of `$` (CRLF on Windows).
- `$Env:XDG_CACHE_HOME` gates all catalog caching; tests set it to `Join-Path $TestDrive 'cache'` and restore in `AfterEach` (copy the harness in `tests/Find-DFPackage.Tests.ps1`).
- crates.io requires the descriptive User-Agent header already used in `DFCatalog.Crates.ps1`; reuse it verbatim for all crates and GitHub anonymous calls.
- Existing sort/PATH-fallback/identity-map behavior in `Find-DFPackage` must not regress — the whole existing test file must stay green after every task.

---

### Task 1: Detail object + cache-first detail engine

**Files:**
- Modify: `Private/DFCatalog.ps1` (append after `New-DFToolInfo`; also extend `New-DFToolInfo` itself)
- Modify: `Private/Start-DFCatalogRefreshJob.ps1`
- Test: `tests/DFCatalogDetail.Tests.ps1` (new)

**Interfaces:**
- Consumes: `ConvertTo-DFCatalogQueryKey`, `Get-DFCatalogCacheRoot`, `Read-DFCatalogCacheFile`, `Write-DFCatalogCacheFile`, `$script:DFCatalogTtl`, `$script:DFCatalogProviders`.
- Produces (later tasks rely on these exact signatures):
  - `New-DFToolSourceDetail -Source <string> -PackageId <string> [-Publisher <string>] [-Maintainers <string[]>] [-Dependencies <string[]>] [-Tags <string[]>] [-Downloads <nullable[long]>] [-ReleaseNotes <string>] [-ReleaseNotesUrl <string>] [-RepositoryUrl <string>] [-DocsUrl <string>] [-InstallHint <string>] [-Notes <string>] [-Readme <string>] [-Extra <OrderedDictionary>]` → `PSCustomObject` (PSTypeName `DotForge.ToolSourceDetail`)
  - `Get-DFCatalogDetailCache -Provider <string> -PackageId <string> -Fetch <scriptblock> [-Fresh]` → detail object or `$null` (fetch scriptblock receives the raw PackageId, returns one object or `$null`)
  - `Get-DFCatalogDetail -Source <string> -PackageId <string> [-Fresh]` → detail object or `$null` (dispatcher over `$script:DFCatalogProviders[<source>].Detail`)
  - `Start-DFCatalogRefreshJob -Provider <string> -Query <string> [-Kind query|detail]` (existing callers unchanged — `query` is the default)
  - `New-DFToolInfo` gains optional `-Details <OrderedDictionary>` and `-GitHub <object>` params; the emitted `DotForge.ToolInfo` ALWAYS carries `Details` and `GitHub` properties (both `$null` by default).

- [ ] **Step 1: Write the failing tests**

Create `tests/DFCatalogDetail.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/DFCatalog.ps1"
    . "$PSScriptRoot/../Private/Start-DFCatalogRefreshJob.ps1"   # must exist for Mock
}

Describe 'New-DFToolSourceDetail' {
    It 'builds a typed object with all fields' {
        $d = New-DFToolSourceDetail -Source npm -PackageId left-pad `
            -Publisher 'npm, Inc.' -Maintainers @('alice') -Dependencies @('lodash@^4') `
            -Tags @('cli') -Downloads 12345 -RepositoryUrl 'https://github.com/x/y' `
            -InstallHint 'npm install -g left-pad' -Readme '# hi'
        $d.PSObject.TypeNames[0] | Should -Be 'DotForge.ToolSourceDetail'
        $d.Source | Should -Be 'npm'
        $d.Downloads | Should -Be 12345
        $d.Maintainers | Should -Be @('alice')
        $d.Readme | Should -Be '# hi'
    }
    It 'defaults optional fields to empty/null' {
        $d = New-DFToolSourceDetail -Source scoop -PackageId 'main/rg'
        $d.Downloads | Should -BeNullOrEmpty
        @($d.Tags).Count | Should -Be 0
    }
}

Describe 'Get-DFCatalogDetailCache' {
    BeforeEach {
        $script:SavedXdgCache = $Env:XDG_CACHE_HOME
        $Env:XDG_CACHE_HOME = Join-Path $TestDrive 'cache'
    }
    AfterEach { $Env:XDG_CACHE_HOME = $script:SavedXdgCache }

    It 'fetches live on miss and writes the cache file' {
        $d = Get-DFCatalogDetailCache -Provider npm -PackageId left-pad -Fetch { param($id)
            New-DFToolSourceDetail -Source npm -PackageId $id -Publisher 'p' }
        $d.Publisher | Should -Be 'p'
        $key = (ConvertTo-DFCatalogQueryKey -Query 'left-pad').Key
        Test-Path (Join-Path $Env:XDG_CACHE_HOME "dotforge/catalogs/npm/details/$key.json") | Should -BeTrue
    }

    It 'serves a fresh cache hit without invoking Fetch' {
        $null = Get-DFCatalogDetailCache -Provider npm -PackageId left-pad -Fetch { param($id)
            New-DFToolSourceDetail -Source npm -PackageId $id -Publisher 'cached' }
        $d = Get-DFCatalogDetailCache -Provider npm -PackageId left-pad -Fetch { throw 'must not fetch' }
        $d.Publisher | Should -Be 'cached'
    }

    It 'stores the RAW PackageId in the envelope query field (for re-warm)' {
        $null = Get-DFCatalogDetailCache -Provider scoop -PackageId 'Extras/Zed' -Fetch { param($id)
            New-DFToolSourceDetail -Source scoop -PackageId $id }
        $key = (ConvertTo-DFCatalogQueryKey -Query 'Extras/Zed').Key
        $file = Join-Path $Env:XDG_CACHE_HOME "dotforge/catalogs/scoop/details/$key.json"
        (Get-Content $file -Raw | ConvertFrom-Json).query | Should -BeExactly 'Extras/Zed'
    }

    It 'kicks a background detail re-warm on a stale hit' {
        Mock Start-DFCatalogRefreshJob { }
        $null = Get-DFCatalogDetailCache -Provider npm -PackageId left-pad -Fetch { param($id)
            New-DFToolSourceDetail -Source npm -PackageId $id }
        $script:DFCatalogTtl['npm'] = [timespan]::FromMinutes(-1)   # force stale
        try {
            $d = Get-DFCatalogDetailCache -Provider npm -PackageId left-pad -Fetch { throw 'no inline fetch' }
            $d | Should -Not -BeNullOrEmpty
            Should -Invoke Start-DFCatalogRefreshJob -ParameterFilter { $Kind -eq 'detail' -and $Query -eq 'left-pad' }
        } finally { $script:DFCatalogTtl.Remove('npm') }
    }

    It 'falls back to stale cache when the live fetch throws' {
        $null = Get-DFCatalogDetailCache -Provider npm -PackageId left-pad -Fetch { param($id)
            New-DFToolSourceDetail -Source npm -PackageId $id -Publisher 'old' }
        $d = Get-DFCatalogDetailCache -Provider npm -PackageId left-pad -Fresh -Fetch { throw 'api down' }
        $d.Publisher | Should -Be 'old'
    }

    It 'returns null (no throw, no cache write) when fetch returns nothing' {
        $d = Get-DFCatalogDetailCache -Provider npm -PackageId nope -Fetch { $null }
        $d | Should -BeNullOrEmpty
    }
}

Describe 'Get-DFCatalogDetail dispatcher' {
    BeforeEach {
        $script:SavedProviders = $script:DFCatalogProviders
        $script:DFCatalogProviders = @{
            npm = @{ Name = 'npm'; Detail = { param($Id, $Fresh)
                New-DFToolSourceDetail -Source npm -PackageId $Id -Publisher "fresh=$Fresh" } }
            bare = @{ Name = 'bare' }   # no Detail hook
        }
    }
    AfterEach { $script:DFCatalogProviders = $script:SavedProviders }

    It 'invokes the provider Detail hook with id and fresh flag' {
        (Get-DFCatalogDetail -Source npm -PackageId x -Fresh).Publisher | Should -Be 'fresh=True'
    }
    It 'returns null for providers without a Detail hook' {
        Get-DFCatalogDetail -Source bare -PackageId x | Should -BeNullOrEmpty
    }
    It 'swallows a throwing hook and returns null' {
        $script:DFCatalogProviders.npm.Detail = { throw 'boom' }
        Get-DFCatalogDetail -Source npm -PackageId x | Should -BeNullOrEmpty
    }
}

Describe 'New-DFToolInfo Details/GitHub properties' {
    It 'always carries Details and GitHub (null by default)' {
        $i = New-DFToolInfo -Name x -Sources @()
        $i.PSObject.Properties.Name | Should -Contain 'Details'
        $i.PSObject.Properties.Name | Should -Contain 'GitHub'
        $i.Details | Should -BeNullOrEmpty
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/DFCatalogDetail.Tests.ps1 -Output Detailed"`
Expected: FAIL — `New-DFToolSourceDetail` / `Get-DFCatalogDetailCache` / `Get-DFCatalogDetail` not recognized; `Details` property missing.

- [ ] **Step 3: Implement in `Private/DFCatalog.ps1`**

3a. Extend `New-DFToolInfo`: add two params at the end of its `param()` block and two entries to its output hashtable:

```powershell
        [System.Collections.Specialized.OrderedDictionary]$Details,
        [object]$GitHub
```

```powershell
        Details          = $Details
        GitHub           = $GitHub
```

3b. Append these functions after `New-DFToolInfo`:

```powershell
function New-DFToolSourceDetail {
    <#
    .SYNOPSIS
        Constructs a DotForge.ToolSourceDetail — one catalog's deep view of a
        package (detail-endpoint data, beyond what search returns).
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$PackageId,
        [string]$Publisher,
        [string[]]$Maintainers = @(),
        [string[]]$Dependencies = @(),
        [string[]]$Tags = @(),
        [nullable[long]]$Downloads,
        [string]$ReleaseNotes,
        [string]$ReleaseNotesUrl,
        [string]$RepositoryUrl,
        [string]$DocsUrl,
        [string]$InstallHint,
        [string]$Notes,
        [string]$Readme,
        [System.Collections.Specialized.OrderedDictionary]$Extra
    )

    [pscustomobject]@{
        PSTypeName      = 'DotForge.ToolSourceDetail'
        Source          = $Source
        PackageId       = $PackageId
        Publisher       = $Publisher
        Maintainers     = $Maintainers
        Dependencies    = $Dependencies
        Tags            = $Tags
        Downloads       = $Downloads
        ReleaseNotes    = $ReleaseNotes
        ReleaseNotesUrl = $ReleaseNotesUrl
        RepositoryUrl   = $RepositoryUrl
        DocsUrl         = $DocsUrl
        InstallHint     = $InstallHint
        Notes           = $Notes
        Readme          = $Readme
        Extra           = $Extra
    }
}

function Get-DFCatalogDetailCache {
    <#
    .SYNOPSIS
        Cache-first engine for per-package detail lookups — the detail-side
        mirror of Search-DFCatalogQueryCache.
    .DESCRIPTION
        Fresh hit → served instantly. Stale hit → served instantly while a
        background job re-warms it. Miss or -Fresh → inline fetch, falling back
        to any cached data when the fetch fails. A fetch that returns nothing
        (package has no detail) is NOT cached, so transient failures don't
        poison the cache. Cache-hit rehydration returns plain PSCustomObjects —
        consumers must be duck-typed, not PSTypeName-typed.
    .PARAMETER Provider
        Provider name (cache subdirectory and TTL key). 'github' is valid here
        too — the GitHub enrichment reuses this engine.
    .PARAMETER PackageId
        The raw package id (stored verbatim in the envelope's query field so
        Update-DFPackageCache can re-warm with the exact id).
    .PARAMETER Fetch
        Scriptblock taking the raw PackageId, returning ONE object or $null.
    .PARAMETER Fresh
        Force an inline live fetch.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Provider,

        [Parameter(Mandatory)]
        [string]$PackageId,

        [Parameter(Mandatory)]
        [scriptblock]$Fetch,

        [switch]$Fresh
    )

    $keyInfo = ConvertTo-DFCatalogQueryKey -Query $PackageId
    $ttl = $script:DFCatalogTtl.ContainsKey($Provider) ? $script:DFCatalogTtl[$Provider] : $script:DFCatalogTtl.default

    $cacheRoot = Get-DFCatalogCacheRoot
    $file = $cacheRoot ? (Join-Path $cacheRoot "$Provider/details/$($keyInfo.Key).json") : $null
    $cached = $file ? (Read-DFCatalogCacheFile -Path $file -Ttl $ttl) : $null

    if (-not $Fresh -and $cached) {
        if ($cached.Stale) {
            Start-DFCatalogRefreshJob -Provider $Provider -Query $PackageId -Kind detail
        }
        return @($cached.Data) | Select-Object -First 1
    }

    try {
        $result = & $Fetch $PackageId
    } catch {
        Write-Verbose "DotForge: live $Provider detail fetch for '$PackageId' failed: $_"
        if ($cached) { return @($cached.Data) | Select-Object -First 1 }
        return $null
    }

    if ($null -eq $result) { return $null }

    if ($file) {
        Write-DFCatalogCacheFile -Path $file -Query $PackageId -Results @($result)
    }
    $result
}

function Get-DFCatalogDetail {
    <#
    .SYNOPSIS
        Dispatches a detail lookup to a provider's Detail hook. Returns $null
        when the provider has no hook or the hook fails — detail failures
        never block the caller.
    .PARAMETER Source
        Provider name.
    .PARAMETER PackageId
        Raw package id as reported by that provider's search.
    .PARAMETER Fresh
        Force a live fetch.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Source,

        [Parameter(Mandatory)]
        [string]$PackageId,

        [switch]$Fresh
    )

    $provider = $script:DFCatalogProviders[$Source]
    if (-not $provider -or -not $provider.Detail) { return $null }
    try {
        & $provider.Detail $PackageId $Fresh.IsPresent
    } catch {
        Write-Verbose "DotForge: $Source detail hook for '$PackageId' failed: $_"
        $null
    }
}
```

3c. In `Private/Start-DFCatalogRefreshJob.ps1`, add a `-Kind` parameter and branch the worker. Full new version of the function body (param block + job name + scriptblock):

```powershell
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Provider,

        [Parameter(Mandatory)]
        [string]$Query,

        [ValidateSet('query', 'detail')]
        [string]$Kind = 'query'
    )

    $key = (ConvertTo-DFCatalogQueryKey -Query $Query).Key
    $jobName = "DotForge.Catalog.$Provider.$Kind.$key"

    Get-Job -Name 'DotForge.Catalog.*' -ErrorAction Ignore |
        Where-Object { $_.State -in 'Completed', 'Failed', 'Stopped' } |
        Remove-Job -Force
    if (Get-Job -Name $jobName -ErrorAction Ignore) { return }

    $manifest = Join-Path $PSScriptRoot '..' 'DotForge.psd1'
    $null = Start-ThreadJob -Name $jobName -ThrottleLimit 4 -ArgumentList $manifest, $Provider, $Query, $Kind -ScriptBlock {
        param($Manifest, $Provider, $Query, $Kind)
        try {
            Import-Module $Manifest -Force
            & (Get-Module DotForge) {
                param($p, $q, $k)
                $prov = $script:DFCatalogProviders[$p]
                if (-not $prov) { return }
                if ($k -eq 'detail') {
                    if ($prov.Detail) { $null = & $prov.Detail $q $true }
                } else {
                    $null = & $prov.Search $q $true
                }
            } $Provider $Query $Kind
        } catch {
            # Background refresh is best-effort; the stale cache stays serveable.
        }
    }
```

(Keep the existing comment-based help; add `.PARAMETER Kind` documenting the two modes.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/DFCatalogDetail.Tests.ps1 -Output Detailed"`
Expected: PASS (all Describe blocks).

Also run the existing suite to confirm no regression:
`pwsh -NoProfile -Command "Invoke-Pester tests/Find-DFPackage.Tests.ps1, tests/Update-DFPackageCache.Tests.ps1 -Output Detailed"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Private/DFCatalog.ps1 Private/Start-DFCatalogRefreshJob.ps1 tests/DFCatalogDetail.Tests.ps1
git commit -m "feat(trifle): detail object, cache-first detail engine, detail re-warm jobs"
```

---

### Task 2: scoop + winget detail providers

**Files:**
- Modify: `Private/DFCatalog.Scoop.ps1` (add `Get-DFCatalogScoopDetail`; add `Detail` entry to registration)
- Modify: `Private/DFCatalog.Winget.ps1` (add `Invoke-DFCatalogWingetShowCli`, `ConvertFrom-DFCatalogWingetShow`, `Get-DFCatalogWingetDetail`; add `Detail` entry)
- Test: `tests/DFCatalogDetailProviders.Scoop.Winget.Tests.ps1` (new)

**Interfaces:**
- Consumes: `New-DFToolSourceDetail`, `Get-DFCatalogDetailCache` (Task 1), `Get-DFCatalogScoopRoot` (existing).
- Produces: provider registrations gain `Detail = { param($PackageId, $Fresh) ... }` returning `DotForge.ToolSourceDetail` or `$null`. Scoop reads the local manifest directly (no cache); winget shells `winget show` through the detail cache.

- [ ] **Step 1: Write the failing tests**

Create `tests/DFCatalogDetailProviders.Scoop.Winget.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/DFCatalog.Scoop.ps1"
    . "$PSScriptRoot/../Private/DFCatalog.Winget.ps1"
    . "$PSScriptRoot/../Private/DFCatalog.ps1"
    . "$PSScriptRoot/../Private/Start-DFCatalogRefreshJob.ps1"
}

Describe 'Get-DFCatalogScoopDetail' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive 'scoop'
        $bucket = Join-Path $script:Root 'buckets/extras/bucket'
        New-Item -ItemType Directory -Path $bucket -Force | Out-Null
        @'
{
  "version": "0.191.6",
  "description": "code editor",
  "homepage": "https://zed.dev",
  "license": "GPL-3.0-or-later",
  "notes": ["First note.", "Second note."],
  "depends": "extras/vcredist2022",
  "suggest": { "extras": "windows-terminal" },
  "bin": [["zed.exe", "zed"], "zeditor.cmd"]
}
'@ | Set-Content (Join-Path $bucket 'zed.json')
    }

    It 'reads the full manifest for a bucket-qualified id' {
        $d = Get-DFCatalogScoopDetail -PackageId 'extras/zed' -ScoopRoot $script:Root
        $d.PSObject.TypeNames[0] | Should -Be 'DotForge.ToolSourceDetail'
        $d.Notes | Should -Be 'First note. Second note.'
        $d.Dependencies | Should -Be @('extras/vcredist2022')
        $d.InstallHint | Should -Be 'scoop install extras/zed'
        $d.Extra['bin'] | Should -Be @('zed', 'zeditor.cmd')
        $d.Extra['suggest'] | Should -Be @('extras: windows-terminal')
    }

    It 'searches all buckets for a bare name' {
        $d = Get-DFCatalogScoopDetail -PackageId 'zed' -ScoopRoot $script:Root
        $d.PackageId | Should -Be 'extras/zed'
    }

    It 'returns null for a missing manifest' {
        Get-DFCatalogScoopDetail -PackageId 'extras/nope' -ScoopRoot $script:Root | Should -BeNullOrEmpty
    }
}

Describe 'ConvertFrom-DFCatalogWingetShow' {
    It 'parses Key: value output including indented continuations' {
        $lines = @(
            'Found Zed [Zed.Zed]'
            'Version: 0.191.6'
            'Publisher: Zed Industries, Inc.'
            'Moniker: zed'
            'Description:'
            '  A high-performance editor.'
            '  Built in Rust.'
            'Homepage: https://zed.dev'
            'License: GPL-3.0'
            'Release Notes Url: https://zed.dev/releases'
            'Tags:'
            '  editor'
            '  rust'
            'Installer:'
            '  Installer Type: zip'
        )
        $d = ConvertFrom-DFCatalogWingetShow -Lines $lines -PackageId 'Zed.Zed'
        $d.Publisher | Should -Be 'Zed Industries, Inc.'
        $d.ReleaseNotesUrl | Should -Be 'https://zed.dev/releases'
        $d.Tags | Should -Be @('editor', 'rust')
        $d.Notes | Should -Be 'A high-performance editor. Built in Rust.'
        $d.InstallHint | Should -Be 'winget install --id Zed.Zed --exact'
    }

    It 'returns null when no Key: value lines are present (package not found)' {
        ConvertFrom-DFCatalogWingetShow -Lines @('No package found matching input criteria.') -PackageId 'X.Y' |
            Should -BeNullOrEmpty
    }
}

Describe 'winget Detail hook wiring' {
    BeforeEach {
        $script:SavedXdgCache = $Env:XDG_CACHE_HOME
        $Env:XDG_CACHE_HOME = Join-Path $TestDrive 'cache'
    }
    AfterEach { $Env:XDG_CACHE_HOME = $script:SavedXdgCache }

    It 'caches winget show output through the detail engine' {
        Mock Invoke-DFCatalogWingetShowCli { @('Version: 1.0', 'Publisher: P') }
        $d1 = Get-DFCatalogWingetDetail -PackageId 'X.Y'
        $d2 = Get-DFCatalogWingetDetail -PackageId 'X.Y'
        $d2.Publisher | Should -Be 'P'
        Should -Invoke Invoke-DFCatalogWingetShowCli -Times 1 -Exactly
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/DFCatalogDetailProviders.Scoop.Winget.Tests.ps1 -Output Detailed"`
Expected: FAIL — functions not defined.

- [ ] **Step 3: Implement scoop detail** (append to `Private/DFCatalog.Scoop.ps1` before the registration block)

```powershell
function Get-DFCatalogScoopDetail {
    <#
    .SYNOPSIS
        Deep detail for a scoop package: the full bucket manifest (notes,
        depends, suggest, bin) read straight from the local bucket clone.
        Local disk is free — no detail cache involved.
    .PARAMETER PackageId
        'bucket/name' as reported by Search-DFCatalogScoop, or a bare name
        (all buckets searched).
    .PARAMETER ScoopRoot
        The scoop root directory (defaults to Get-DFCatalogScoopRoot).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$PackageId,

        [string]$ScoopRoot = (Get-DFCatalogScoopRoot)
    )

    $bucket, $name = $PackageId -split '/', 2
    if (-not $name) { $name = $bucket; $bucket = $null }

    $manifestFile = $null
    if ($bucket) {
        $candidate = Join-Path $ScoopRoot "buckets/$bucket/bucket/$name.json"
        if (Test-Path $candidate) { $manifestFile = $candidate }
    } else {
        $bucketsDir = Join-Path $ScoopRoot 'buckets'
        if (Test-Path $bucketsDir) {
            foreach ($dir in Get-ChildItem $bucketsDir -Directory) {
                $candidate = Join-Path $dir.FullName "bucket/$name.json"
                if (Test-Path $candidate) { $manifestFile = $candidate; $bucket = $dir.Name; break }
            }
        }
    }
    if (-not $manifestFile) { return $null }

    try { $manifest = Get-Content $manifestFile -Raw | ConvertFrom-Json } catch {
        Write-Verbose "DotForge: unreadable scoop manifest '$manifestFile': $_"
        return $null
    }

    # scoop manifest fields are string-or-array; flatten uniformly.
    $flat = { param($v) if ($null -eq $v) { @() } else { @($v | ForEach-Object { [string]$_ }) } }

    # bin entries are string | [exe, alias, args...]; the shim name is the
    # alias when present, else the exe's basename.
    $shims = @(foreach ($entry in @($manifest.bin)) {
        if ($null -eq $entry) { continue }
        if ($entry -is [array]) {
            $entry.Count -ge 2 ? [string]$entry[1] : [System.IO.Path]::GetFileNameWithoutExtension([string]$entry[0])
        } else { [string]$entry }
    })

    $suggest = @()
    if ($manifest.suggest) {
        $suggest = @($manifest.suggest.PSObject.Properties | ForEach-Object { "$($_.Name): $(@($_.Value) -join ', ')" })
    }

    $extra = [ordered]@{}
    if ($shims) { $extra['bin'] = $shims }
    if ($suggest) { $extra['suggest'] = $suggest }

    $license = if ($manifest.license -is [string]) { $manifest.license } else { [string]$manifest.license.identifier }

    New-DFToolSourceDetail -Source 'scoop' `
        -PackageId "$bucket/$name" `
        -Dependencies (& $flat $manifest.depends) `
        -RepositoryUrl ((([string]$manifest.homepage) -match 'github\.com') ? [string]$manifest.homepage : '') `
        -InstallHint "scoop install $bucket/$name" `
        -Notes ((& $flat $manifest.notes) -join ' ') `
        -Extra $extra
}
```

Add to the scoop registration hashtable (after `Refresh`):

```powershell
    Detail       = { param($PackageId, $Fresh) Get-DFCatalogScoopDetail -PackageId $PackageId }
```

- [ ] **Step 4: Implement winget detail** (append to `Private/DFCatalog.Winget.ps1` before the registration block)

```powershell
function Invoke-DFCatalogWingetShowCli {
    <#
    .SYNOPSIS
        Runs `winget show` for an exact package id and returns the raw output
        lines. Mockable seam.
    .PARAMETER PackageId
        The winget package id.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$PackageId
    )

    if (-not (Get-Command winget -ErrorAction Ignore)) {
        throw 'winget.exe is not available'
    }
    winget show --id $PackageId --exact --source winget --disable-interactivity 2>$null
}

function ConvertFrom-DFCatalogWingetShow {
    <#
    .SYNOPSIS
        Parses `winget show` Key: value output into a DotForge.ToolSourceDetail.
        Indented lines continue the previous key; the Tags block becomes the
        Tags array. Returns $null when no keys parse (package not found).
        Limitation: key labels are localized — non-English systems degrade to
        an empty parse (null), which the card renders as details-unavailable.
    .PARAMETER Lines
        Raw winget show output lines.
    .PARAMETER PackageId
        The id the lookup was for.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [string[]]$Lines = @(),

        [Parameter(Mandatory)]
        [string]$PackageId
    )

    $map = [ordered]@{}
    $currentKey = $null
    foreach ($line in @($Lines)) {
        if ($null -eq $line) { continue }
        if ($line -cmatch '^([A-Z][A-Za-z ]*?):\s*(.*?)\r?$') {
            $currentKey = $Matches[1].Trim()
            $map[$currentKey] = @()
            if ($Matches[2].Trim()) { $map[$currentKey] = @($Matches[2].Trim()) }
        } elseif ($currentKey -and $line -match '^\s+(\S.*?)\r?$') {
            $map[$currentKey] = @($map[$currentKey]) + $Matches[1].Trim()
        }
    }
    if ($map.Count -eq 0) { return $null }

    $joined = { param($k) (@($map[$k]) -join ' ') }

    New-DFToolSourceDetail -Source 'winget' `
        -PackageId $PackageId `
        -Publisher (& $joined 'Publisher') `
        -Maintainers @(@(& $joined 'Author') -ne '') `
        -Tags @($map['Tags']) `
        -ReleaseNotes (& $joined 'Release Notes') `
        -ReleaseNotesUrl (& $joined 'Release Notes Url') `
        -RepositoryUrl (((& $joined 'Homepage') -match 'github\.com') ? (& $joined 'Homepage') : '') `
        -InstallHint "winget install --id $PackageId --exact" `
        -Notes (& $joined 'Description')
}

function Get-DFCatalogWingetDetail {
    <#
    .SYNOPSIS
        Cache-first winget detail: `winget show` is a slow process spawn, so
        results go through the detail cache engine.
    .PARAMETER PackageId
        The winget package id.
    .PARAMETER Fresh
        Force a live winget show.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$PackageId,

        [switch]$Fresh
    )

    Get-DFCatalogDetailCache -Provider 'winget' -PackageId $PackageId -Fresh:$Fresh -Fetch {
        param($id)
        ConvertFrom-DFCatalogWingetShow -Lines @(Invoke-DFCatalogWingetShowCli -PackageId $id) -PackageId $id
    }
}
```

Add to the winget registration hashtable (after `Refresh`):

```powershell
    Detail       = { param($PackageId, $Fresh) Get-DFCatalogWingetDetail -PackageId $PackageId -Fresh:$Fresh }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/DFCatalogDetailProviders.Scoop.Winget.Tests.ps1 -Output Detailed"`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Private/DFCatalog.Scoop.ps1 Private/DFCatalog.Winget.ps1 tests/DFCatalogDetailProviders.Scoop.Winget.Tests.ps1
git commit -m "feat(trifle): scoop and winget detail providers"
```

---

### Task 3: npm + pypi + crates detail providers

**Files:**
- Modify: `Private/DFCatalog.Npm.ps1`, `Private/DFCatalog.Pypi.ps1`, `Private/DFCatalog.Crates.ps1` (each: one fetch function, one cached `Get-DFCatalog<P>Detail`, one `Detail` registration entry)
- Test: `tests/DFCatalogDetailProviders.Web.Tests.ps1` (new)

**Interfaces:**
- Consumes: `New-DFToolSourceDetail`, `Get-DFCatalogDetailCache` (Task 1).
- Produces: `Get-DFCatalogNpmDetail / Get-DFCatalogPypiDetail / Get-DFCatalogCratesDetail -PackageId <string> [-Fresh]` → `DotForge.ToolSourceDetail` or `$null`. npm's detail carries `Readme` (used by Task 6) and `Extra['dist-tags']`. pypi's carries `Extra['description']` + `Extra['description_content_type']` (Task 6 fallback).

- [ ] **Step 1: Write the failing tests**

Create `tests/DFCatalogDetailProviders.Web.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/DFCatalog.Npm.ps1"
    . "$PSScriptRoot/../Private/DFCatalog.Pypi.ps1"
    . "$PSScriptRoot/../Private/DFCatalog.Crates.ps1"
    . "$PSScriptRoot/../Private/DFCatalog.ps1"
    . "$PSScriptRoot/../Private/Start-DFCatalogRefreshJob.ps1"
}

Describe 'web detail providers' {
    BeforeEach {
        $script:SavedXdgCache = $Env:XDG_CACHE_HOME
        $Env:XDG_CACHE_HOME = Join-Path $TestDrive 'cache'
    }
    AfterEach { $Env:XDG_CACHE_HOME = $script:SavedXdgCache }

    It 'npm: maps the registry doc (deps, maintainers, dist-tags, readme)' {
        Mock Invoke-RestMethod {
            [pscustomobject]@{
                name = 'left-pad'
                'dist-tags' = [pscustomobject]@{ latest = '1.3.0'; next = '2.0.0-rc1' }
                versions = [pscustomobject]@{
                    '1.3.0' = [pscustomobject]@{ dependencies = [pscustomobject]@{ lodash = '^4.17.0' } }
                }
                maintainers = @([pscustomobject]@{ name = 'alice' }, [pscustomobject]@{ name = 'bob' })
                repository = [pscustomobject]@{ url = 'git+https://github.com/left-pad/left-pad.git' }
                keywords = @('string', 'pad')
                readme = '# left-pad'
            }
        }
        $d = Get-DFCatalogNpmDetail -PackageId 'left-pad' -Fresh
        $d.Dependencies | Should -Be @('lodash@^4.17.0')
        $d.Maintainers | Should -Be @('alice', 'bob')
        $d.RepositoryUrl | Should -Be 'git+https://github.com/left-pad/left-pad.git'
        $d.Tags | Should -Be @('string', 'pad')
        $d.Readme | Should -Be '# left-pad'
        $d.InstallHint | Should -Be 'npm install -g left-pad'
        $d.Extra['dist-tags'] | Should -Contain 'latest: 1.3.0'
    }

    It 'pypi: maps the JSON API doc' {
        Mock Invoke-RestMethod {
            [pscustomobject]@{
                info = [pscustomobject]@{
                    name = 'httpie'; author = 'Jakub'; requires_python = '>=3.7'
                    keywords = 'http,cli'
                    project_urls = [pscustomobject]@{ Source = 'https://github.com/httpie/cli'; Documentation = 'https://httpie.io/docs' }
                    description = 'long readme'; description_content_type = 'text/markdown'
                }
            }
        }
        $d = Get-DFCatalogPypiDetail -PackageId 'httpie' -Fresh
        $d.Publisher | Should -Be 'Jakub'
        $d.Tags | Should -Be @('http', 'cli')
        $d.RepositoryUrl | Should -Be 'https://github.com/httpie/cli'
        $d.DocsUrl | Should -Be 'https://httpie.io/docs'
        $d.InstallHint | Should -Be 'pipx install httpie'
        $d.Extra['requires_python'] | Should -Be '>=3.7'
        $d.Extra['description_content_type'] | Should -Be 'text/markdown'
    }

    It 'crates: maps the crate doc (downloads, keywords, categories)' {
        Mock Invoke-RestMethod {
            [pscustomobject]@{
                crate = [pscustomobject]@{
                    name = 'ripgrep'; downloads = 1234567; recent_downloads = 54321
                    keywords = @('grep', 'search'); categories = @('command-line-utilities')
                    repository = 'https://github.com/BurntSushi/ripgrep'
                    documentation = 'https://docs.rs/ripgrep'
                }
            }
        }
        $d = Get-DFCatalogCratesDetail -PackageId 'ripgrep' -Fresh
        $d.Downloads | Should -Be 1234567
        $d.Tags | Should -Be @('grep', 'search', 'command-line-utilities')
        $d.RepositoryUrl | Should -Be 'https://github.com/BurntSushi/ripgrep'
        $d.DocsUrl | Should -Be 'https://docs.rs/ripgrep'
        $d.InstallHint | Should -Be 'cargo install ripgrep'
        $d.Extra['recent_downloads'] | Should -Be 54321
    }

    It 'registers Detail hooks on all three providers' {
        foreach ($p in 'npm', 'pypi', 'crates') {
            $script:DFCatalogProviders[$p].Detail | Should -Not -BeNullOrEmpty
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/DFCatalogDetailProviders.Web.Tests.ps1 -Output Detailed"`
Expected: FAIL — detail functions not defined.

- [ ] **Step 3: Implement npm detail** (append to `Private/DFCatalog.Npm.ps1` before the registration block)

```powershell
function Invoke-DFCatalogNpmDetailFetch {
    <#
    .SYNOPSIS
        Live npm registry full-doc lookup, mapped to DotForge.ToolSourceDetail.
    .PARAMETER PackageId
        The npm package name.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$PackageId
    )

    $doc = Invoke-RestMethod -Uri "https://registry.npmjs.org/$([uri]::EscapeDataString($PackageId))" -TimeoutSec 10
    if (-not $doc.name) { return $null }

    $latest = [string]$doc.'dist-tags'.latest
    $deps = @()
    if ($latest -and $doc.versions.$latest.dependencies) {
        $deps = @($doc.versions.$latest.dependencies.PSObject.Properties | ForEach-Object { "$($_.Name)@$($_.Value)" })
    }
    $distTags = @()
    if ($doc.'dist-tags') {
        $distTags = @($doc.'dist-tags'.PSObject.Properties | ForEach-Object { "$($_.Name): $($_.Value)" })
    }

    $extra = [ordered]@{}
    if ($distTags) { $extra['dist-tags'] = $distTags }

    New-DFToolSourceDetail -Source 'npm' `
        -PackageId $doc.name `
        -Maintainers @(@($doc.maintainers) | ForEach-Object { [string]$_.name }) `
        -Dependencies $deps `
        -Tags @(@($doc.keywords) | ForEach-Object { [string]$_ }) `
        -RepositoryUrl ([string]$doc.repository.url) `
        -InstallHint "npm install -g $($doc.name)" `
        -Readme ([string]$doc.readme) `
        -Extra $extra
}

function Get-DFCatalogNpmDetail {
    <#
    .SYNOPSIS
        Cache-first npm detail lookup.
    .PARAMETER PackageId
        The npm package name.
    .PARAMETER Fresh
        Force a live fetch.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$PackageId,

        [switch]$Fresh
    )

    Get-DFCatalogDetailCache -Provider 'npm' -PackageId $PackageId -Fresh:$Fresh `
        -Fetch { param($id) Invoke-DFCatalogNpmDetailFetch -PackageId $id }
}
```

Registration entry: `Detail = { param($PackageId, $Fresh) Get-DFCatalogNpmDetail -PackageId $PackageId -Fresh:$Fresh }`

- [ ] **Step 4: Implement pypi detail** (append to `Private/DFCatalog.Pypi.ps1` before the registration block)

```powershell
function Invoke-DFCatalogPypiDetailFetch {
    <#
    .SYNOPSIS
        Live PyPI JSON-API detail lookup, mapped to DotForge.ToolSourceDetail.
    .PARAMETER PackageId
        The PyPI package name.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$PackageId
    )

    $doc = Invoke-RestMethod -Uri "https://pypi.org/pypi/$([uri]::EscapeDataString($PackageId))/json" -TimeoutSec 10
    $info = $doc.info
    if (-not $info.name) { return $null }

    $urls = $info.project_urls
    $repo = [string]($urls.Repository ? $urls.Repository : ($urls.Source ? $urls.Source : ((([string]$urls.Homepage) -match 'github\.com') ? $urls.Homepage : '')))
    $docsUrl = [string]($urls.Documentation ? $urls.Documentation : $urls.Docs)

    $extra = [ordered]@{}
    if ($info.requires_python) { $extra['requires_python'] = [string]$info.requires_python }
    if ($info.description) {
        $extra['description'] = [string]$info.description
        $extra['description_content_type'] = [string]$info.description_content_type
    }

    New-DFToolSourceDetail -Source 'pypi' `
        -PackageId $info.name `
        -Publisher ([string]($info.author ? $info.author : $info.maintainer)) `
        -Tags @(([string]$info.keywords) -split '[,\s]+' -ne '') `
        -RepositoryUrl $repo `
        -DocsUrl $docsUrl `
        -InstallHint "pipx install $($info.name)" `
        -Extra $extra
}

function Get-DFCatalogPypiDetail {
    <#
    .SYNOPSIS
        Cache-first PyPI detail lookup.
    .PARAMETER PackageId
        The PyPI package name.
    .PARAMETER Fresh
        Force a live fetch.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$PackageId,

        [switch]$Fresh
    )

    Get-DFCatalogDetailCache -Provider 'pypi' -PackageId $PackageId -Fresh:$Fresh `
        -Fetch { param($id) Invoke-DFCatalogPypiDetailFetch -PackageId $id }
}
```

Registration entry: `Detail = { param($PackageId, $Fresh) Get-DFCatalogPypiDetail -PackageId $PackageId -Fresh:$Fresh }`

- [ ] **Step 5: Implement crates detail** (append to `Private/DFCatalog.Crates.ps1` before the registration block)

```powershell
function Invoke-DFCatalogCratesDetailFetch {
    <#
    .SYNOPSIS
        Live crates.io crate-detail lookup, mapped to DotForge.ToolSourceDetail.
    .PARAMETER PackageId
        The crate name.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$PackageId
    )

    $headers = @{ 'User-Agent' = 'DotForge PowerShell module (+https://github.com/simsrw73/DotForge)' }
    $doc = Invoke-RestMethod -Uri "https://crates.io/api/v1/crates/$([uri]::EscapeDataString($PackageId))" -Headers $headers -TimeoutSec 10
    $crate = $doc.crate
    if (-not $crate.name) { return $null }

    $extra = [ordered]@{}
    if ($crate.recent_downloads) { $extra['recent_downloads'] = [long]$crate.recent_downloads }

    New-DFToolSourceDetail -Source 'crates' `
        -PackageId $crate.name `
        -Tags (@(@($crate.keywords) + @($crate.categories)) | ForEach-Object { [string]$_ }) `
        -Downloads ([nullable[long]]$crate.downloads) `
        -RepositoryUrl ([string]$crate.repository) `
        -DocsUrl ([string]$crate.documentation) `
        -InstallHint "cargo install $($crate.name)" `
        -Extra $extra
}

function Get-DFCatalogCratesDetail {
    <#
    .SYNOPSIS
        Cache-first crates.io detail lookup.
    .PARAMETER PackageId
        The crate name.
    .PARAMETER Fresh
        Force a live fetch.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$PackageId,

        [switch]$Fresh
    )

    Get-DFCatalogDetailCache -Provider 'crates' -PackageId $PackageId -Fresh:$Fresh `
        -Fetch { param($id) Invoke-DFCatalogCratesDetailFetch -PackageId $id }
}
```

Registration entry: `Detail = { param($PackageId, $Fresh) Get-DFCatalogCratesDetail -PackageId $PackageId -Fresh:$Fresh }`

- [ ] **Step 6: Run tests to verify they pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/DFCatalogDetailProviders.Web.Tests.ps1 -Output Detailed"`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Private/DFCatalog.Npm.ps1 Private/DFCatalog.Pypi.ps1 Private/DFCatalog.Crates.ps1 tests/DFCatalogDetailProviders.Web.Tests.ps1
git commit -m "feat(trifle): npm, pypi, crates detail providers"
```

---

### Task 4: choco + psgallery detail providers (shared OData detail mapper)

**Files:**
- Modify: `Private/DFCatalog.Choco.ps1` (add `ConvertFrom-DFCatalogODataDetailEntry` next to the existing `ConvertFrom-DFCatalogODataEntry`, plus `Invoke-DFCatalogChocoDetailFetch`, `Get-DFCatalogChocoDetail`, `Detail` entry)
- Modify: `Private/DFCatalog.PSGallery.ps1` (add `Invoke-DFCatalogPSGalleryDetailFetch`, `Get-DFCatalogPSGalleryDetail`, `Detail` entry)
- Test: `tests/DFCatalogDetailProviders.OData.Tests.ps1` (new)

**Interfaces:**
- Consumes: `New-DFToolSourceDetail`, `Get-DFCatalogDetailCache` (Task 1).
- Produces: `ConvertFrom-DFCatalogODataDetailEntry -Source <string> -Entry <object> -InstallHint <string>` → detail or `$null`; `Get-DFCatalogChocoDetail / Get-DFCatalogPSGalleryDetail -PackageId <string> [-Fresh]`.
- OData note: typed elements (`m:type` attribute, e.g. `DownloadCount`) come back as XmlElement with a `'#text'` property — handle exactly like the existing `ConvertFrom-DFCatalogODataEntry` does for `Published`. Dependency strings look like `id:ver:fx|id2:ver2:fx` → keep `id (ver)` pairs.

- [ ] **Step 1: Write the failing tests**

Create `tests/DFCatalogDetailProviders.OData.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/DFCatalog.Choco.ps1"
    . "$PSScriptRoot/../Private/DFCatalog.PSGallery.ps1"
    . "$PSScriptRoot/../Private/DFCatalog.ps1"
    . "$PSScriptRoot/../Private/Start-DFCatalogRefreshJob.ps1"

    function New-FakeODataEntry {
        param($Id, $Downloads)
        # Mimics Invoke-RestMethod's XML projection: plain strings for
        # untyped elements, '#text'-wrapped objects for m:typed ones.
        [pscustomobject]@{
            properties = [pscustomobject]@{
                Id            = $Id
                Version       = '14.1.1'
                Authors       = 'BurntSushi'
                ProjectUrl    = 'https://github.com/BurntSushi/ripgrep'
                Tags          = 'search grep cli'
                ReleaseNotes  = 'Fixed things.'
                DownloadCount = [pscustomobject]@{ '#text' = "$Downloads" }
                Dependencies  = 'chocolatey-core.extension:1.3.3:|other:2.0:'
                DocsUrl       = 'https://example.org/docs'
            }
        }
    }
}

Describe 'ConvertFrom-DFCatalogODataDetailEntry' {
    It 'maps a full OData entry' {
        $d = ConvertFrom-DFCatalogODataDetailEntry -Source choco -Entry (New-FakeODataEntry -Id ripgrep -Downloads 998877) `
            -InstallHint 'choco install ripgrep'
        $d.Publisher | Should -Be 'BurntSushi'
        $d.Downloads | Should -Be 998877
        $d.Tags | Should -Be @('search', 'grep', 'cli')
        $d.Dependencies | Should -Be @('chocolatey-core.extension (1.3.3)', 'other (2.0)')
        $d.RepositoryUrl | Should -Be 'https://github.com/BurntSushi/ripgrep'
        $d.ReleaseNotes | Should -Be 'Fixed things.'
        $d.InstallHint | Should -Be 'choco install ripgrep'
    }
    It 'returns null for a null entry' {
        ConvertFrom-DFCatalogODataDetailEntry -Source choco -Entry $null -InstallHint 'x' | Should -BeNullOrEmpty
    }
}

Describe 'choco + psgallery detail hooks' {
    BeforeEach {
        $script:SavedXdgCache = $Env:XDG_CACHE_HOME
        $Env:XDG_CACHE_HOME = Join-Path $TestDrive 'cache'
    }
    AfterEach { $Env:XDG_CACHE_HOME = $script:SavedXdgCache }

    It 'choco: fetches FindPackagesById filtered to the latest version' {
        Mock Invoke-RestMethod { @(New-FakeODataEntry -Id ripgrep -Downloads 5) } -ParameterFilter {
            $Uri -like '*community.chocolatey.org*FindPackagesById*IsLatestVersion*'
        }
        $d = Get-DFCatalogChocoDetail -PackageId ripgrep -Fresh
        $d.Publisher | Should -Be 'BurntSushi'
        $d.InstallHint | Should -Be 'choco install ripgrep'
    }

    It 'psgallery: same shape, PSResource install hint' {
        Mock Invoke-RestMethod { @(New-FakeODataEntry -Id PSFzf -Downloads 7) } -ParameterFilter {
            $Uri -like '*powershellgallery.com*FindPackagesById*IsLatestVersion*'
        }
        $d = Get-DFCatalogPSGalleryDetail -PackageId PSFzf -Fresh
        $d.InstallHint | Should -Be 'Install-PSResource PSFzf'
    }

    It 'registers Detail hooks on both providers' {
        $script:DFCatalogProviders['choco'].Detail | Should -Not -BeNullOrEmpty
        $script:DFCatalogProviders['psgallery'].Detail | Should -Not -BeNullOrEmpty
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/DFCatalogDetailProviders.OData.Tests.ps1 -Output Detailed"`
Expected: FAIL — functions not defined.

- [ ] **Step 3: Implement the shared mapper + choco detail** (append to `Private/DFCatalog.Choco.ps1` before the registration block)

```powershell
function ConvertFrom-DFCatalogODataDetailEntry {
    <#
    .SYNOPSIS
        Maps one NuGet v2 OData entry (choco / PSGallery) to a
        DotForge.ToolSourceDetail. Shared by both OData providers.
    .PARAMETER Source
        Provider name to stamp on the result.
    .PARAMETER Entry
        One feed entry as returned by Invoke-RestMethod.
    .PARAMETER InstallHint
        The catalog's install one-liner for this package.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Source,

        [AllowNull()]
        [object]$Entry,

        [Parameter(Mandatory)]
        [string]$InstallHint
    )

    if (-not $Entry) { return $null }
    $props = $Entry.properties
    $id = [string]$props.Id
    if (-not $id) { return $null }

    # m:typed OData elements surface as XmlElement with '#text'.
    $text = { param($v) ($v -and $v -isnot [string]) ? [string]$v.'#text' : [string]$v }

    $downloads = $null
    $raw = & $text $props.DownloadCount
    if ($raw) { try { $downloads = [long]$raw } catch {} }

    $deps = @(foreach ($spec in ((& $text $props.Dependencies) -split '\|') -ne '') {
        $parts = $spec -split ':'
        $parts[1] ? "$($parts[0]) ($($parts[1]))" : $parts[0]
    })

    New-DFToolSourceDetail -Source $Source `
        -PackageId $id `
        -Publisher (& $text $props.Authors) `
        -Dependencies $deps `
        -Tags @(((& $text $props.Tags) -split '\s+') -ne '') `
        -Downloads $downloads `
        -ReleaseNotes (& $text $props.ReleaseNotes) `
        -RepositoryUrl ((& $text $props.ProjectSourceUrl) ? (& $text $props.ProjectSourceUrl) : (& $text $props.ProjectUrl)) `
        -DocsUrl (& $text $props.DocsUrl) `
        -InstallHint $InstallHint
}

function Invoke-DFCatalogChocoDetailFetch {
    <#
    .SYNOPSIS
        Live Chocolatey OData detail lookup (latest version of one id).
    .PARAMETER PackageId
        The choco package id.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$PackageId
    )

    $term = [uri]::EscapeDataString(($PackageId -replace "'", "''"))
    $uri = "https://community.chocolatey.org/api/v2/FindPackagesById()?id='$term'&`$filter=IsLatestVersion"
    $entry = @(Invoke-RestMethod -Uri $uri -TimeoutSec 15) | Select-Object -First 1
    ConvertFrom-DFCatalogODataDetailEntry -Source 'choco' -Entry $entry -InstallHint "choco install $PackageId"
}

function Get-DFCatalogChocoDetail {
    <#
    .SYNOPSIS
        Cache-first Chocolatey detail lookup (72h TTL — slow, rate-limited API).
    .PARAMETER PackageId
        The choco package id.
    .PARAMETER Fresh
        Force a live fetch.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$PackageId,

        [switch]$Fresh
    )

    Get-DFCatalogDetailCache -Provider 'choco' -PackageId $PackageId -Fresh:$Fresh `
        -Fetch { param($id) Invoke-DFCatalogChocoDetailFetch -PackageId $id }
}
```

Registration entry: `Detail = { param($PackageId, $Fresh) Get-DFCatalogChocoDetail -PackageId $PackageId -Fresh:$Fresh }`

- [ ] **Step 4: Implement psgallery detail** (append to `Private/DFCatalog.PSGallery.ps1` before the registration block)

Note: the spec table mentioned `Find-PSResource`; we use the same v2 OData endpoint the provider already uses instead — consistent with the CLAUDE.md guidance that OData is the source of truth, richer (ReleaseNotes/Dependencies), and it reuses the shared mapper.

```powershell
function Invoke-DFCatalogPSGalleryDetailFetch {
    <#
    .SYNOPSIS
        Live PSGallery OData detail lookup (latest version of one id).
    .PARAMETER PackageId
        The module name.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$PackageId
    )

    $term = [uri]::EscapeDataString(($PackageId -replace "'", "''"))
    $uri = "https://www.powershellgallery.com/api/v2/FindPackagesById()?id='$term'&`$filter=IsLatestVersion"
    $entry = @(Invoke-RestMethod -Uri $uri -TimeoutSec 15) | Select-Object -First 1
    ConvertFrom-DFCatalogODataDetailEntry -Source 'psgallery' -Entry $entry -InstallHint "Install-PSResource $PackageId"
}

function Get-DFCatalogPSGalleryDetail {
    <#
    .SYNOPSIS
        Cache-first PSGallery detail lookup.
    .PARAMETER PackageId
        The module name.
    .PARAMETER Fresh
        Force a live fetch.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$PackageId,

        [switch]$Fresh
    )

    Get-DFCatalogDetailCache -Provider 'psgallery' -PackageId $PackageId -Fresh:$Fresh `
        -Fetch { param($id) Invoke-DFCatalogPSGalleryDetailFetch -PackageId $id }
}
```

Registration entry: `Detail = { param($PackageId, $Fresh) Get-DFCatalogPSGalleryDetail -PackageId $PackageId -Fresh:$Fresh }`

- [ ] **Step 5: Run tests to verify they pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/DFCatalogDetailProviders.OData.Tests.ps1 -Output Detailed"`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Private/DFCatalog.Choco.ps1 Private/DFCatalog.PSGallery.ps1 tests/DFCatalogDetailProviders.OData.Tests.ps1
git commit -m "feat(trifle): choco and psgallery detail providers via shared OData mapper"
```

---

### Task 5: GitHub enrichment (`-GitInfo` backend)

**Files:**
- Create: `Private/Get-DFGitHubRepoInfo.ps1`
- Test: `tests/Get-DFGitHubRepoInfo.Tests.ps1` (new)

**Interfaces:**
- Consumes: `Get-DFCatalogDetailCache` (Task 1 — reused with `-Provider 'github'`).
- Produces:
  - `Resolve-DFGitHubRepoUrl -Info <ToolInfo>` → `[pscustomobject]@{ Owner; Repo }` or `$null` (checks `Details` values' `RepositoryUrl` in canonical source order, then `Info.Homepage`).
  - `Test-DFGitHubCli` → `[bool]` (memoized in `$script:DFGitHubCliOk`: gh on PATH AND `gh auth status` exit 0).
  - `Get-DFGitHubRepoInfo -Owner <string> -Repo <string> [-Fresh]` → `PSCustomObject` (PSTypeName `DotForge.RepoInfo`) with `Owner, Repo, Stars, OpenIssues, PushedAt, LatestRelease, LatestReleaseAt, Archived, DefaultBranch, Description, License` — or `$null` on failure.
  - `Invoke-DFGitHubApi -Path <string>` → parsed JSON object or throws — the mockable seam (gh vs anonymous).

- [ ] **Step 1: Write the failing tests**

Create `tests/Get-DFGitHubRepoInfo.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/DFCatalog.ps1"
    . "$PSScriptRoot/../Private/Start-DFCatalogRefreshJob.ps1"
    . "$PSScriptRoot/../Private/Get-DFGitHubRepoInfo.ps1"
}

Describe 'Resolve-DFGitHubRepoUrl' {
    It 'extracts owner/repo from a Details RepositoryUrl (git+ and .git stripped)' {
        $info = [pscustomobject]@{
            Details  = [ordered]@{ npm = [pscustomobject]@{ RepositoryUrl = 'git+https://github.com/left-pad/left-pad.git#readme' } }
            Homepage = ''
        }
        $r = Resolve-DFGitHubRepoUrl -Info $info
        $r.Owner | Should -Be 'left-pad'
        $r.Repo | Should -Be 'left-pad'
    }
    It 'falls back to Homepage' {
        $info = [pscustomobject]@{ Details = $null; Homepage = 'https://github.com/BurntSushi/ripgrep' }
        (Resolve-DFGitHubRepoUrl -Info $info).Repo | Should -Be 'ripgrep'
    }
    It 'returns null for non-GitHub urls' {
        $info = [pscustomobject]@{ Details = $null; Homepage = 'https://zed.dev' }
        Resolve-DFGitHubRepoUrl -Info $info | Should -BeNullOrEmpty
    }
}

Describe 'Get-DFGitHubRepoInfo' {
    BeforeEach {
        $script:SavedXdgCache = $Env:XDG_CACHE_HOME
        $Env:XDG_CACHE_HOME = Join-Path $TestDrive 'cache'
        $script:DFGitHubCliOk = $null
    }
    AfterEach { $Env:XDG_CACHE_HOME = $script:SavedXdgCache; $script:DFGitHubCliOk = $null }

    It 'maps repo + latest release into DotForge.RepoInfo' {
        Mock Invoke-DFGitHubApi {
            param($Path)
            if ($Path -like '*/releases/latest') {
                [pscustomobject]@{ tag_name = 'v14.1.1'; published_at = '2026-06-01T00:00:00Z' }
            } else {
                [pscustomobject]@{
                    stargazers_count = 55000; open_issues_count = 120
                    pushed_at = '2026-07-01T12:00:00Z'; archived = $false
                    default_branch = 'master'; description = 'recursively searches'
                    license = [pscustomobject]@{ spdx_id = 'MIT' }
                }
            }
        }
        $r = Get-DFGitHubRepoInfo -Owner BurntSushi -Repo ripgrep -Fresh
        $r.PSObject.TypeNames[0] | Should -Be 'DotForge.RepoInfo'
        $r.Stars | Should -Be 55000
        $r.LatestRelease | Should -Be 'v14.1.1'
        $r.License | Should -Be 'MIT'
    }

    It 'tolerates a missing latest release (404)' {
        Mock Invoke-DFGitHubApi {
            param($Path)
            if ($Path -like '*/releases/latest') { throw '404' }
            [pscustomobject]@{ stargazers_count = 1; open_issues_count = 0; pushed_at = '2026-01-01T00:00:00Z'
                archived = $true; default_branch = 'main'; description = 'x'; license = $null }
        }
        $r = Get-DFGitHubRepoInfo -Owner a -Repo b -Fresh
        $r.LatestRelease | Should -BeNullOrEmpty
        $r.Archived | Should -BeTrue
    }

    It 'returns null when the repo fetch fails' {
        Mock Invoke-DFGitHubApi { throw 'rate limited' }
        Get-DFGitHubRepoInfo -Owner a -Repo b -Fresh | Should -BeNullOrEmpty
    }

    It 'serves the second call from cache' {
        Mock Invoke-DFGitHubApi {
            param($Path)
            if ($Path -like '*/releases/latest') { throw '404' }
            [pscustomobject]@{ stargazers_count = 9; open_issues_count = 0; pushed_at = '2026-01-01T00:00:00Z'
                archived = $false; default_branch = 'main'; description = 'x'; license = $null }
        }
        $null = Get-DFGitHubRepoInfo -Owner a -Repo b
        $r = Get-DFGitHubRepoInfo -Owner a -Repo b
        $r.Stars | Should -Be 9
        Should -Invoke Invoke-DFGitHubApi -Times 2 -Exactly   # repo + release, once each
    }
}

Describe 'Invoke-DFGitHubApi transport selection' {
    AfterEach { $script:DFGitHubCliOk = $null }
    It 'uses anonymous REST when gh is unavailable' {
        $script:DFGitHubCliOk = $false
        Mock Invoke-RestMethod { [pscustomobject]@{ ok = 1 } }
        (Invoke-DFGitHubApi -Path 'repos/a/b').ok | Should -Be 1
        Should -Invoke Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.github.com/repos/a/b' }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Get-DFGitHubRepoInfo.Tests.ps1 -Output Detailed"`
Expected: FAIL — file/functions don't exist.

- [ ] **Step 3: Implement `Private/Get-DFGitHubRepoInfo.ps1`**

```powershell
#Requires -Version 7.0

# GitHub enrichment for trifle's -GitInfo: repo stats + latest release,
# fetched via gh (authenticated, 5000 req/hr) when available, anonymous REST
# (60 req/hr — fine for single lookups) otherwise. Cached through the catalog
# detail engine under catalogs/github/details/.

function Test-DFGitHubCli {
    <#
    .SYNOPSIS
        True when gh is on PATH and authenticated. Memoized per session in
        $script:DFGitHubCliOk.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if ($null -eq $script:DFGitHubCliOk) {
        $script:DFGitHubCliOk = $false
        if (Get-Command gh -ErrorAction Ignore) {
            $null = gh auth status 2>$null
            $script:DFGitHubCliOk = ($LASTEXITCODE -eq 0)
        }
    }
    $script:DFGitHubCliOk
}

function Invoke-DFGitHubApi {
    <#
    .SYNOPSIS
        Fetches one GitHub REST path ('repos/<o>/<r>', …) via gh or anonymous
        Invoke-RestMethod. Mockable seam; throws on failure.
    .PARAMETER Path
        API path relative to https://api.github.com/.
    .PARAMETER Accept
        Optional Accept header (e.g. 'application/vnd.github.raw' for readmes).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Path,

        [string]$Accept
    )

    if (Test-DFGitHubCli) {
        $ghArgs = @('api', $Path)
        if ($Accept) { $ghArgs += @('-H', "Accept: $Accept") }
        $raw = gh @ghArgs 2>$null
        if ($LASTEXITCODE -ne 0) { throw "gh api $Path failed" }
        $joined = $raw -join "`n"
        # Raw-media responses (readme) aren't JSON — return the text as-is.
        return ($Accept -like '*raw*') ? $joined : ($joined | ConvertFrom-Json)
    }

    $headers = @{ 'User-Agent' = 'DotForge PowerShell module (+https://github.com/simsrw73/DotForge)' }
    if ($Accept) { $headers['Accept'] = $Accept }
    Invoke-RestMethod -Uri "https://api.github.com/$Path" -Headers $headers -TimeoutSec 10
}

function Resolve-DFGitHubRepoUrl {
    <#
    .SYNOPSIS
        Resolves a merged ToolInfo to a GitHub owner/repo pair, checking each
        source detail's RepositoryUrl (canonical order) then the Homepage.
        Returns $null when nothing points at github.com.
    .PARAMETER Info
        A DotForge.ToolInfo (Details may be $null).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Info
    )

    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($Info.Details) {
        foreach ($detail in $Info.Details.Values) {
            if ($detail -and $detail.RepositoryUrl) { $candidates.Add([string]$detail.RepositoryUrl) }
        }
    }
    if ($Info.Homepage) { $candidates.Add([string]$Info.Homepage) }

    foreach ($url in $candidates) {
        if ($url -match 'github\.com[/:]([^/]+)/([^/#?\s]+)') {
            return [pscustomobject]@{
                Owner = $Matches[1]
                Repo  = ($Matches[2] -replace '\.git$', '')
            }
        }
    }
    $null
}

function Get-DFGitHubRepoInfo {
    <#
    .SYNOPSIS
        Fetches (cache-first) GitHub repo stats + latest release as a
        DotForge.RepoInfo, or $null when the repo is unreachable.
    .PARAMETER Owner
        Repository owner.
    .PARAMETER Repo
        Repository name.
    .PARAMETER Fresh
        Force a live fetch.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Owner,

        [Parameter(Mandatory)]
        [string]$Repo,

        [switch]$Fresh
    )

    Get-DFCatalogDetailCache -Provider 'github' -PackageId "$Owner/$Repo" -Fresh:$Fresh -Fetch {
        param($id)
        $repoDoc = Invoke-DFGitHubApi -Path "repos/$id"

        $release = $null
        try { $release = Invoke-DFGitHubApi -Path "repos/$id/releases/latest" } catch {
            Write-Verbose "DotForge: no latest release for $id"
        }

        $toDate = { param($v) if ($v) { try { [datetime]$v } catch { $null } } }

        [pscustomobject]@{
            PSTypeName      = 'DotForge.RepoInfo'
            Owner           = ($id -split '/')[0]
            Repo            = ($id -split '/')[1]
            Stars           = [long]$repoDoc.stargazers_count
            OpenIssues      = [long]$repoDoc.open_issues_count
            PushedAt        = & $toDate $repoDoc.pushed_at
            LatestRelease   = [string]$release.tag_name
            LatestReleaseAt = & $toDate $release.published_at
            Archived        = [bool]$repoDoc.archived
            DefaultBranch   = [string]$repoDoc.default_branch
            Description     = [string]$repoDoc.description
            License         = [string]$repoDoc.license.spdx_id
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Get-DFGitHubRepoInfo.Tests.ps1 -Output Detailed"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Private/Get-DFGitHubRepoInfo.ps1 tests/Get-DFGitHubRepoInfo.Tests.ps1
git commit -m "feat(trifle): GitHub repo enrichment via gh or anonymous REST"
```

---

### Task 6: Readme resolution (`-Readme` backend)

**Files:**
- Create: `Private/Get-DFPackageReadme.ps1`
- Test: `tests/Get-DFPackageReadme.Tests.ps1` (new)

**Interfaces:**
- Consumes: `Resolve-DFGitHubRepoUrl`, `Invoke-DFGitHubApi`, `Get-DFCatalogDetailCache` (Tasks 1, 5); npm detail `Readme` + pypi `Extra['description']` (Task 3).
- Produces: `Get-DFPackageReadme -Info <ToolInfo> [-Fresh]` → `string[]` lines or `$null`. Resolution order: npm detail readme → GitHub readme (raw media type, cached under `catalogs/github/readmes` — note the engine hardcodes `details/`, so the GitHub readme uses provider name `github-readme` giving `catalogs/github-readme/details/`) → PyPI description when `description_content_type` is markdown/plain.

- [ ] **Step 1: Write the failing tests**

Create `tests/Get-DFPackageReadme.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/DFCatalog.ps1"
    . "$PSScriptRoot/../Private/Start-DFCatalogRefreshJob.ps1"
    . "$PSScriptRoot/../Private/Get-DFGitHubRepoInfo.ps1"
    . "$PSScriptRoot/../Private/Get-DFPackageReadme.ps1"
}

Describe 'Get-DFPackageReadme' {
    BeforeEach {
        $script:SavedXdgCache = $Env:XDG_CACHE_HOME
        $Env:XDG_CACHE_HOME = Join-Path $TestDrive 'cache'
    }
    AfterEach { $Env:XDG_CACHE_HOME = $script:SavedXdgCache }

    It 'prefers the npm detail readme' {
        $info = [pscustomobject]@{
            Details  = [ordered]@{ npm = [pscustomobject]@{ RepositoryUrl = ''; Readme = "# Title`nBody" } }
            Homepage = ''
        }
        (Get-DFPackageReadme -Info $info) -join "`n" | Should -Be "# Title`nBody"
    }

    It 'falls back to the GitHub readme when npm has none' {
        Mock Invoke-DFGitHubApi { "# GH readme" } -ParameterFilter { $Accept -like '*raw*' }
        $info = [pscustomobject]@{
            Details  = $null
            Homepage = 'https://github.com/a/b'
        }
        (Get-DFPackageReadme -Info $info -Fresh) -join "`n" | Should -Be '# GH readme'
    }

    It 'falls back to the PyPI markdown description' {
        $extra = [ordered]@{ description = '# pypi desc'; description_content_type = 'text/markdown' }
        $info = [pscustomobject]@{
            Details  = [ordered]@{ pypi = [pscustomobject]@{ RepositoryUrl = ''; Readme = $null; Extra = $extra } }
            Homepage = 'https://example.org'
        }
        (Get-DFPackageReadme -Info $info) -join "`n" | Should -Be '# pypi desc'
    }

    It 'returns null when nothing resolves' {
        $info = [pscustomobject]@{ Details = $null; Homepage = 'https://example.org' }
        Get-DFPackageReadme -Info $info | Should -BeNullOrEmpty
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Get-DFPackageReadme.Tests.ps1 -Output Detailed"`
Expected: FAIL.

- [ ] **Step 3: Implement `Private/Get-DFPackageReadme.ps1`**

```powershell
#Requires -Version 7.0

function Get-DFPackageReadme {
    <#
    .SYNOPSIS
        Resolves a readme for a merged ToolInfo: npm registry readme, then the
        GitHub readme (raw media type, cache-first), then a PyPI markdown/plain
        long description. Returns the readme as lines, or $null.
    .PARAMETER Info
        A DotForge.ToolInfo whose Details have been populated.
    .PARAMETER Fresh
        Force a live GitHub fetch.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Info,

        [switch]$Fresh
    )

    if ($Info.Details) {
        $npm = $Info.Details['npm']
        if ($npm -and $npm.Readme) { return [string[]]($npm.Readme -split "\r?\n") }
    }

    $repo = Resolve-DFGitHubRepoUrl -Info $Info
    if ($repo) {
        # Engine path is catalogs/<provider>/details/ — a distinct provider
        # name keeps readmes out of the RepoInfo namespace.
        $wrapper = Get-DFCatalogDetailCache -Provider 'github-readme' -PackageId "$($repo.Owner)/$($repo.Repo)" -Fresh:$Fresh -Fetch {
            param($id)
            $content = Invoke-DFGitHubApi -Path "repos/$id/readme" -Accept 'application/vnd.github.raw'
            $content ? [pscustomobject]@{ Content = [string]$content } : $null
        }
        if ($wrapper -and $wrapper.Content) { return [string[]]($wrapper.Content -split "\r?\n") }
    }

    if ($Info.Details) {
        $pypi = $Info.Details['pypi']
        if ($pypi -and $pypi.Extra -and $pypi.Extra['description'] -and
            $pypi.Extra['description_content_type'] -match 'markdown|plain|^$') {
            return [string[]]($pypi.Extra['description'] -split "\r?\n")
        }
    }

    $null
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Get-DFPackageReadme.Tests.ps1 -Output Detailed"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Private/Get-DFPackageReadme.ps1 tests/Get-DFPackageReadme.Tests.ps1
git commit -m "feat(trifle): readme resolution (npm doc, GitHub raw, PyPI description)"
```

---

### Task 7: Renderers — detail card + table Id column

**Files:**
- Modify: `Private/Format-DFToolInfo.ps1` (add `Format-DFToolDetailCount`, `Format-DFToolDetailCard`; extend `Format-DFToolInfoTable` with an Id column)
- Test: `tests/Format-DFToolDetailCard.Tests.ps1` (new); existing `tests/*` that assert on the table may need the new column reflected — check `tests/Find-DFPackage.Tests.ps1` (it doesn't assert table columns today).

**Interfaces:**
- Consumes: `Format-DFToolInfoCard`, `Format-DFToolInfoAge` (existing); duck-typed `Details` dict values (Tasks 2–4), `GitHub` RepoInfo (Task 5).
- Produces:
  - `Format-DFToolDetailCount -Count <long>` → `'998'`, `'12.3k'`, `'1.2M'`.
  - `Format-DFToolDetailCard -Info <ToolInfo> -Color <bool> [-MoreMatches <int>] [-QueryText <string>]` → `string[]`. Sections after the base card: Publisher, Deps (one line per source), Tags (union, cap 10), Downloads, Install (one line per hint), Notes, GitHub (2 lines), faint `details unavailable: <sources>` for `Details` keys whose value is `$null`, faint footer `+ N more matches — trifle <query> -All` when `MoreMatches -gt 0`.
  - `Format-DFToolInfoTable` rows gain an `Id` column (first source's `source:packageId`), width-capped at 34, placed between `Sources` and `Latest`.

- [ ] **Step 1: Write the failing tests**

Create `tests/Format-DFToolDetailCard.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/../Private/DFCatalog.ps1"
    . "$PSScriptRoot/../Private/Format-DFToolInfo.ps1"

    function New-TestInfo {
        param($Details, $GitHub)
        $src = New-DFToolSourceInfo -Source scoop -PackageId 'extras/zed' -Name zed `
            -Description 'code editor' -LatestVersion '0.191.6' -MatchKind exact-name
        New-DFToolInfo -Name zed -Description 'code editor' -Sources @($src) `
            -Latest ([ordered]@{ scoop = '0.191.6' }) -Homepage 'https://zed.dev' `
            -License 'GPL-3.0' -MatchKind exact-name -Details $Details -GitHub $GitHub
    }
}

Describe 'Format-DFToolDetailCount' {
    It 'formats plain, k, and M counts' {
        Format-DFToolDetailCount -Count 998      | Should -Be '998'
        Format-DFToolDetailCount -Count 12345    | Should -Be '12.3k'
        Format-DFToolDetailCount -Count 1234567  | Should -Be '1.2M'
    }
}

Describe 'Format-DFToolDetailCard' {
    It 'renders detail sections from populated Details' {
        $details = [ordered]@{
            scoop = New-DFToolSourceDetail -Source scoop -PackageId 'extras/zed' `
                -Dependencies @('extras/vcredist2022') -InstallHint 'scoop install extras/zed' `
                -Notes 'Run zed once to install CLI.'
            crates = New-DFToolSourceDetail -Source crates -PackageId zed `
                -Publisher 'Zed Industries' -Tags @('editor', 'rust') -Downloads 1234567 `
                -InstallHint 'cargo install zed'
        }
        $out = (Format-DFToolDetailCard -Info (New-TestInfo -Details $details) -Color $false) -join "`n"
        $out | Should -Match 'Publisher\s+Zed Industries'
        $out | Should -Match 'Deps\s+scoop: extras/vcredist2022'
        $out | Should -Match 'Tags\s+editor . rust'
        $out | Should -Match 'Downloads\s+crates 1\.2M'
        $out | Should -Match 'Install\s+scoop install extras/zed'
        $out | Should -Match 'cargo install zed'
        $out | Should -Match 'Notes\s+Run zed once'
    }

    It 'marks sources whose detail fetch failed (null Details value)' {
        $details = [ordered]@{ choco = $null }
        $out = (Format-DFToolDetailCard -Info (New-TestInfo -Details $details) -Color $false) -join "`n"
        $out | Should -Match 'details unavailable: choco'
    }

    It 'renders the GitHub section' {
        $gh = [pscustomobject]@{
            PSTypeName = 'DotForge.RepoInfo'; Owner = 'zed-industries'; Repo = 'zed'
            Stars = 55123; OpenIssues = 1400; PushedAt = [datetime]'2026-07-01'
            LatestRelease = 'v0.192.0'; LatestReleaseAt = [datetime]'2026-06-28'
            Archived = $false; DefaultBranch = 'main'; Description = 'Code at the speed of thought'; License = 'GPL-3.0'
        }
        $out = (Format-DFToolDetailCard -Info (New-TestInfo -GitHub $gh) -Color $false) -join "`n"
        $out | Should -Match 'GitHub\s+. 55\.1k'
        $out | Should -Match 'release v0\.192\.0 \(2026-06-28\)'
        $out | Should -Match 'Code at the speed of thought'
    }

    It 'appends the more-matches footer' {
        $out = (Format-DFToolDetailCard -Info (New-TestInfo) -Color $false -MoreMatches 7 -QueryText zed) -join "`n"
        $out | Should -Match '\+ 7 more matches .* trifle zed -All'
    }

    It 'omits every detail section when Details and GitHub are empty' {
        $out = (Format-DFToolDetailCard -Info (New-TestInfo) -Color $false) -join "`n"
        $out | Should -Not -Match 'Publisher'
        $out | Should -Not -Match 'Install'
        $out | Should -Not -Match 'GitHub'
    }
}

Describe 'Format-DFToolInfoTable Id column' {
    It 'shows source:packageId per row' {
        $src = New-DFToolSourceInfo -Source winget -PackageId 'Zed.Zed' -Name Zed -MatchKind exact-id
        $info = New-DFToolInfo -Name Zed -Sources @($src) -MatchKind exact-id
        $rows = Format-DFToolInfoTable -Infos @($info) -Color $false -Width 200
        $rows[0] | Should -Match 'Id'
        $rows[1] | Should -Match 'winget:Zed\.Zed'
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Format-DFToolDetailCard.Tests.ps1 -Output Detailed"`
Expected: FAIL.

- [ ] **Step 3: Implement in `Private/Format-DFToolInfo.ps1`**

3a. Append the count formatter and detail card renderer:

```powershell
function Format-DFToolDetailCount {
    <#
    .SYNOPSIS
        Formats a count as a compact '998' / '12.3k' / '1.2M' string.
    .PARAMETER Count
        The raw count.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [long]$Count
    )

    if ($Count -lt 1000) { return [string]$Count }
    if ($Count -lt 1000000) { return "$([math]::Round($Count / 1000, 1))k" }
    "$([math]::Round($Count / 1000000, 1))M"
}

function Format-DFToolDetailCard {
    <#
    .SYNOPSIS
        Renders a DotForge.ToolInfo WITH populated Details/GitHub as the full
        detail card: the basic card followed by Publisher / Deps / Tags /
        Downloads / Install / Notes / GitHub sections and an optional
        more-matches footer. Sections without data are omitted.
    .PARAMETER Info
        The merged tool info (Details: ordered dict source → detail, values
        may be $null for failed fetches; GitHub: DotForge.RepoInfo or $null).
    .PARAMETER Color
        When false, plain text.
    .PARAMETER MoreMatches
        Count of suppressed keyword matches (renders the -All footer when > 0).
    .PARAMETER QueryText
        The original query, for the footer's suggested command.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        $Info,

        [Parameter(Mandatory)]
        [bool]$Color,

        [int]$MoreMatches = 0,

        [string]$QueryText = ''
    )

    $faint = $Color ? "`e[2m" : ''
    $reset = $Color ? "`e[0m" : ''
    $label = { param($text) ($Color ? "`e[2m" : '') + $text.PadRight(9) + ($Color ? "`e[0m" : '') + '  ' }
    $indent = ' ' * 11

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.AddRange([string[]](Format-DFToolInfoCard -Info $Info -Color $Color))

    $details = @()
    $failed = @()
    if ($Info.Details) {
        foreach ($key in $Info.Details.Keys) {
            if ($null -ne $Info.Details[$key]) { $details += $Info.Details[$key] }
            else { $failed += $key }
        }
    }

    $publisher = @($details | ForEach-Object { $_.Publisher } | Where-Object { $_ }) | Select-Object -First 1
    if (-not $publisher) {
        $publisher = @($details | ForEach-Object { @($_.Maintainers) -join ', ' } | Where-Object { $_ }) | Select-Object -First 1
    }
    if ($publisher) { $lines.Add((& $label 'Publisher') + $publisher) }

    $first = $true
    foreach ($d in $details) {
        $deps = @($d.Dependencies) -ne '' -ne $null
        if (-not $deps) { continue }
        $shown = @($deps | Select-Object -First 8)
        $suffix = $deps.Count -gt 8 ? " +$($deps.Count - 8) more" : ''
        $prefix = $first ? (& $label 'Deps') : $indent
        $lines.Add("$prefix$($d.Source): $($shown -join ', ')$suffix")
        $first = $false
    }

    $tags = @($details | ForEach-Object { @($_.Tags) } | Where-Object { $_ } | Select-Object -Unique -First 10)
    if ($tags) { $lines.Add((& $label 'Tags') + ($tags -join ' · ')) }

    $downloads = @($details | Where-Object { $_.Downloads } | ForEach-Object {
        "$($_.Source) $(Format-DFToolDetailCount -Count $_.Downloads)"
    })
    if ($downloads) { $lines.Add((& $label 'Downloads') + ($downloads -join ' · ')) }

    $hints = @($details | ForEach-Object { $_.InstallHint } | Where-Object { $_ })
    for ($i = 0; $i -lt $hints.Count; $i++) {
        $lines.Add(($i -eq 0 ? (& $label 'Install') : $indent) + $hints[$i])
    }

    $notes = @($details | ForEach-Object { $_.Notes } | Where-Object { $_ }) | Select-Object -First 1
    if ($notes) { $lines.Add((& $label 'Notes') + $notes) }

    if ($Info.GitHub) {
        $gh = $Info.GitHub
        $parts = [System.Collections.Generic.List[string]]::new()
        $parts.Add("★ $(Format-DFToolDetailCount -Count $gh.Stars)")
        if ($gh.PushedAt) { $parts.Add("updated $($gh.PushedAt.ToString('yyyy-MM-dd'))") }
        if ($gh.LatestRelease) {
            $when = $gh.LatestReleaseAt ? " ($($gh.LatestReleaseAt.ToString('yyyy-MM-dd')))" : ''
            $parts.Add("release $($gh.LatestRelease)$when")
        }
        $parts.Add("$(Format-DFToolDetailCount -Count $gh.OpenIssues) issues")
        if ($gh.Archived) { $parts.Add('ARCHIVED') }
        $lines.Add((& $label 'GitHub') + ($parts -join ' · '))
        if ($gh.Description) { $lines.Add($indent + "$faint$($gh.Description)$reset") }
    }

    if ($failed) {
        $lines.Add("$faint(details unavailable: $($failed -join ', '))$reset")
    }

    if ($MoreMatches -gt 0) {
        $lines.Add("$faint+ $MoreMatches more matches — trifle $QueryText -All$reset")
    }

    $lines
}
```

3b. Extend `Format-DFToolInfoTable` — replace its column-width block and row loop with:

```powershell
    $nameW = [math]::Min(25, [math]::Max(4, (@($Infos.Name) + 'Name' | Measure-Object Length -Maximum).Maximum))
    $idStrings = @($Infos | ForEach-Object {
        $s = @($_.Sources) | Select-Object -First 1
        $s ? "$($s.Source):$($s.PackageId)" : ''
    })
    $idW = [math]::Min(34, [math]::Max(2, (@($idStrings) + 'Id' | Measure-Object Length -Maximum).Maximum))
    $srcStrings = @($Infos | ForEach-Object { @($_.Sources.Source) -join ',' })
    $srcW = [math]::Min(30, [math]::Max(7, (@($srcStrings) + 'Sources' | Measure-Object Length -Maximum).Maximum))
    $verW = 12

    $rows = [System.Collections.Generic.List[string]]::new()
    $rows.Add("$faint$('Name'.PadRight($nameW))  In  $('Sources'.PadRight($srcW))  $('Id'.PadRight($idW))  $('Latest'.PadRight($verW))  Description$reset")

    for ($i = 0; $i -lt $Infos.Count; $i++) {
        $info = $Infos[$i]
        $name = $info.Name.Length -gt $nameW ? $info.Name.Substring(0, $nameW) : $info.Name.PadRight($nameW)
        $inst = $info.Installed ? "$green✓$reset " : '  '
        $src = $srcStrings[$i]
        $src = $src.Length -gt $srcW ? $src.Substring(0, $srcW) : $src.PadRight($srcW)
        $id = $idStrings[$i]
        $id = $id.Length -gt $idW ? $id.Substring(0, $idW) : $id.PadRight($idW)
        $latest = ''
        if ($info.Latest -and $info.Latest.Count -gt 0) {
            $latest = [string]@($info.Latest.Values)[0]
        }
        $latest = $latest.Length -gt $verW ? $latest.Substring(0, $verW) : $latest.PadRight($verW)

        $row = "$name  $inst  $src  $id  $latest  $($info.Description)"
        if ($row.Length -gt $Width) { $row = $row.Substring(0, $Width) }
        $rows.Add($row)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Format-DFToolDetailCard.Tests.ps1, tests/Find-DFPackage.Tests.ps1 -Output Detailed"`
Expected: PASS (both files).

- [ ] **Step 5: Commit**

```bash
git add Private/Format-DFToolInfo.ps1 tests/Format-DFToolDetailCard.Tests.ps1
git commit -m "feat(trifle): detail card renderer and table Id column"
```

---

### Task 8: Find-DFPackage integration — `-All`, exact-match rule, qualified ids, `-Readme`/`-GitInfo`

**Files:**
- Modify: `Public/Find-DFPackage.ps1`
- Modify: `Private/DFCatalog.ps1` (add `Get-DFToolInfoDetails` helper next to `Get-DFCatalogDetail`)
- Test: extend `tests/Find-DFPackage.Tests.ps1`

**Interfaces:**
- Consumes: `Get-DFCatalogDetail` (Task 1), `Format-DFToolDetailCard` (Task 7), `Resolve-DFGitHubRepoUrl` + `Get-DFGitHubRepoInfo` (Task 5), `Get-DFPackageReadme` (Task 6), `Invoke-DFWithPager` (existing public).
- Produces:
  - New `Find-DFPackage` switches: `-All`, `-Readme`, `-GitInfo`.
  - `Get-DFToolInfoDetails -Info <ToolInfo> [-Fresh]` → ordered dict `source → detail-or-$null` (`$null` marks a source whose provider HAS a Detail hook but the fetch failed; hookless sources are omitted).
  - Detail-path rule: qualified id, or (`-All` absent AND top merged result is exact). Enriched top result's `Details`/`GitHub` are set before objects are emitted or the card renders.

- [ ] **Step 1: Write the failing tests** (append to `tests/Find-DFPackage.Tests.ps1`, inside the existing `Describe`; the fake scoop provider gains a `Detail` hook in `BeforeEach` — add it to the existing hashtable literal)

Add to the `BeforeEach` provider table, in the `scoop` entry after `Refresh = { }`:

```powershell
                Detail = { param($Id, $Fresh)
                    New-DFToolSourceDetail -Source 'scoop' -PackageId $Id `
                        -InstallHint "scoop install $Id" -Notes 'test note' }
```

And dot-source the new dependencies in the file's `BeforeAll` (after the existing lines):

```powershell
    . "$PSScriptRoot/../Private/Start-DFCatalogRefreshJob.ps1"
    . "$PSScriptRoot/../Private/Get-DFGitHubRepoInfo.ps1"
    . "$PSScriptRoot/../Private/Get-DFPackageReadme.ps1"
    . "$PSScriptRoot/../Public/DFHelpers.Pager.ps1"
```

New `It` blocks:

```powershell
    It 'enriches the top exact match with Details' {
        $r = @(Find-DFPackage ripgrep)
        $r[0].Details | Should -Not -BeNullOrEmpty
        $r[0].Details['scoop'].InstallHint | Should -Be 'scoop install main/ripgrep'
    }

    It 'renders the DETAIL card interactively on an exact match even with other keyword hits' {
        Mock Test-DFOutputPiped { $false }
        $script:DFCatalogProviders['scoop'].Search = { param($Query, $Fresh)
            if ($Query -eq 'ripgrep') {
                New-DFToolSourceInfo -Source 'scoop' -PackageId 'main/ripgrep' -Name 'ripgrep' `
                    -Description 'search tool' -LatestVersion '14.1.1' -MatchKind 'exact-name'
                New-DFToolSourceInfo -Source 'scoop' -PackageId 'main/ripgrep-all' -Name 'ripgrep-all' `
                    -Description 'rga' -LatestVersion '1.0' -MatchKind 'keyword'
            }
        }
        $saved = $Env:NO_COLOR; $Env:NO_COLOR = '1'
        try {
            $out = (Find-DFPackage ripgrep) -join "`n"
            $out | Should -Match 'Install\s+scoop install main/ripgrep'
            $out | Should -Match '\+ 1 more matches — trifle ripgrep -All'
        } finally { $Env:NO_COLOR = $saved }
    }

    It '-All always renders the table, never the card' {
        Mock Test-DFOutputPiped { $false }
        $saved = $Env:NO_COLOR; $Env:NO_COLOR = '1'
        try {
            $out = (Find-DFPackage ripgrep -All) -join "`n"
            $out | Should -Match 'Name\s+'
            $out | Should -Not -Match 'Installed'
        } finally { $Env:NO_COLOR = $saved }
    }

    It 'resolves a qualified source:packageId query' {
        $r = @(Find-DFPackage scoop:main/ripgrep)
        $r.Count | Should -Be 1
        $r[0].Name | Should -Be 'ripgrep'
        $r[0].Details['scoop'] | Should -Not -BeNullOrEmpty
    }

    It 'falls back to keyword search for an unknown qualified prefix' {
        { Find-DFPackage foo:bar } | Should -Not -Throw
    }

    It 'warns and falls back when a qualified id does not exist' {
        $w = $null
        $null = Find-DFPackage scoop:main/nope -WarningVariable w -WarningAction SilentlyContinue
        "$w" | Should -Match "No package 'main/nope' found in scoop"
    }

    It '-GitInfo attaches GitHub repo info' {
        Mock Get-DFGitHubRepoInfo { [pscustomobject]@{ PSTypeName = 'DotForge.RepoInfo'; Stars = 5 } }
        Mock Resolve-DFGitHubRepoUrl { [pscustomobject]@{ Owner = 'a'; Repo = 'b' } }
        $r = @(Find-DFPackage ripgrep -GitInfo)
        $r[0].GitHub.Stars | Should -Be 5
    }

    It '-Readme pages the readme after the card' {
        Mock Test-DFOutputPiped { $false }
        Mock Get-DFPackageReadme { @('# readme line') }
        $saved = $Env:NO_COLOR; $Env:NO_COLOR = '1'
        try {
            $out = (Find-DFPackage ripgrep -Readme) -join "`n"
            $out | Should -Match '# readme line'
        } finally { $Env:NO_COLOR = $saved }
    }

    It 'marks a failed detail fetch as null in Details' {
        $script:DFCatalogProviders['choco'].Detail = { param($Id, $Fresh) throw 'api down' }
        $r = @(Find-DFPackage ripgrep)
        $r[0].Details.Contains('choco') | Should -BeTrue
        $r[0].Details['choco'] | Should -BeNullOrEmpty
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Find-DFPackage.Tests.ps1 -Output Detailed"`
Expected: new `It` blocks FAIL (no `-All` param, no Details enrichment); existing blocks still PASS.

- [ ] **Step 3: Add `Get-DFToolInfoDetails` to `Private/DFCatalog.ps1`** (after `Get-DFCatalogDetail`)

```powershell
function Get-DFToolInfoDetails {
    <#
    .SYNOPSIS
        Fetches per-source details for every source of a merged ToolInfo.
        Returns an ordered dict source → detail; a $null value marks a source
        whose Detail hook exists but failed (renders as 'details unavailable').
        Sources whose provider has no Detail hook are omitted entirely.
    .PARAMETER Info
        The merged DotForge.ToolInfo.
    .PARAMETER Fresh
        Force live fetches.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Info,

        [switch]$Fresh
    )

    $details = [ordered]@{}
    foreach ($source in @($Info.Sources)) {
        $provider = $script:DFCatalogProviders[$source.Source]
        if (-not $provider -or -not $provider.Detail) { continue }
        if ($details.Contains($source.Source)) { continue }
        $details[$source.Source] = Get-DFCatalogDetail -Source $source.Source -PackageId $source.PackageId -Fresh:$Fresh
    }
    $details
}
```

- [ ] **Step 4: Rework `Public/Find-DFPackage.ps1`**

4a. Param block — add after `[switch]$Fresh`:

```powershell
        [switch]$All,

        [switch]$Readme,

        [switch]$GitInfo,
```

Update comment-based help: `.PARAMETER All` (always show the full match table; adds the Id column values usable as `trifle <source>:<id>`), `.PARAMETER Readme` (fetch and page the package readme after the detail card), `.PARAMETER GitInfo` (add GitHub stars/release/activity to the detail card), and a `.EXAMPLE` for `trifle winget:Zed.Zed`.

4b. Qualified-id parsing — insert immediately after `$queryText = $Query -join ' '`:

```powershell
    # Qualified id (source:packageId, from the -All table) → zero in on one
    # package in one catalog. Unknown prefixes stay ordinary keyword queries.
    $qualified = $null
    if ($queryText -match '^(?<src>scoop|winget|choco|npm|pypi|crates|psgallery):(?<id>.+)$') {
        $qualified = @{ Source = $Matches.src.ToLowerInvariant(); Id = $Matches.id.Trim() }
        # Cross-catalog searches use the bare trailing segment (scoop ids are
        # bucket-qualified; other catalogs' ids ARE the name).
        $queryText = $qualified.Id.Contains('/') ? ($qualified.Id -split '/')[-1] : $qualified.Id
    }
```

4c. The provider fan-out loop is unchanged (it now runs with the bare name when qualified). After the merge + sort (right after the `$merged = @($merged | Sort-Object ...)` statement), insert:

```powershell
    if ($qualified) {
        # Keep only the group that actually contains the qualified package.
        $exact = @($merged | Where-Object {
            @($_.Sources | Where-Object { $_.Source -eq $qualified.Source -and $_.PackageId -ieq $qualified.Id }).Count -gt 0
        })
        if ($exact) {
            $merged = @($exact | Select-Object -First 1)
        } else {
            Write-Warning "DotForge: No package '$($qualified.Id)' found in $($qualified.Source) — showing matches for '$queryText'."
            $qualified = $null
        }
    }
```

4d. Detail enrichment — insert after the PATH-fallback block (before the piped/AsObject return):

```powershell
    # Detail path: a qualified id, or an exact top match without -All.
    $topExact = $merged.Count -gt 0 -and (
        $merged[0].MatchKind -in 'exact-id', 'exact-name' -or $merged[0].Name -ieq $normalized)
    $detailMode = [bool]$qualified -or (-not $All -and $topExact)

    if ($detailMode -and $merged.Count -gt 0) {
        $top = $merged[0]
        $top.Details = Get-DFToolInfoDetails -Info $top -Fresh:$Fresh
        if ($GitInfo) {
            $repo = Resolve-DFGitHubRepoUrl -Info $top
            if ($repo) {
                $top.GitHub = Get-DFGitHubRepoInfo -Owner $repo.Owner -Repo $repo.Repo -Fresh:$Fresh
            }
        }
    }
```

4e. Replace the interactive render tail (everything from `$confident = ...` through the final `Format-DFToolInfoTable` call) with:

```powershell
    if ($detailMode -and $merged.Count -gt 0) {
        $card = [System.Collections.Generic.List[string]](Format-DFToolDetailCard -Info $merged[0] -Color $color `
            -MoreMatches ($merged.Count - 1) -QueryText $queryText)
        if ($GitInfo -and -not $merged[0].GitHub) {
            $faintOn = $color ? "`e[2m" : ''
            $faintOff = $color ? "`e[0m" : ''
            $card.Add("${faintOn}GitHub — no repository resolved${faintOff}")
        }
        if ($Readme) {
            $readmeLines = Get-DFPackageReadme -Info $merged[0] -Fresh:$Fresh
            if ($readmeLines) {
                $card
                return ($readmeLines | Invoke-DFWithPager)
            }
            Write-Warning "DotForge: no readme found for '$($merged[0].Name)'."
        }
        return $card
    }

    if (($Readme -or $GitInfo) -and -not $detailMode) {
        Write-Warning 'DotForge: -Readme/-GitInfo need an exact match — showing the match table instead.'
    }

    $width = 120
    try { if ($Host.UI.RawUI.WindowSize.Width -gt 0) { $width = $Host.UI.RawUI.WindowSize.Width } } catch {}
    Format-DFToolInfoTable -Infos $merged -Color $color -Width $width
```

Note: when the query is qualified, `$merged` was already filtered to one entry, so `MoreMatches` is 0 there — correct, nothing was suppressed by ranking.

- [ ] **Step 5: Run tests to verify they pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Find-DFPackage.Tests.ps1 -Output Detailed"`
Expected: PASS — all pre-existing and new blocks. (The pre-existing "renders an info card for a confident single match" test now goes through the detail path and still matches `Installed`/`main/ripgrep` because the detail card embeds the basic card.)

- [ ] **Step 6: Verify help renders**

Run: `pwsh -NoProfile -Command "Import-Module ./DotForge.psd1 -Force; Get-Help Find-DFPackage -Full | Out-String"`
Expected: `.PARAMETER` sections for All / Readme / GitInfo present; new qualified-id EXAMPLE shown.

- [ ] **Step 7: Commit**

```bash
git add Public/Find-DFPackage.ps1 Private/DFCatalog.ps1 tests/Find-DFPackage.Tests.ps1
git commit -m "feat(trifle): detail card on exact match, qualified source:id queries, -All/-Readme/-GitInfo"
```

---

### Task 9: Select-DFPackage (`ftrifle`) query mode with preview

**Files:**
- Modify: `Public/Select-DFPackage.ps1`
- Test: extend `tests/Select-DFPackage.Tests.ps1`

**Interfaces:**
- Consumes: `Find-DFPackage -AsObject` (Task 8), `Format-DFToolInfoCard` (existing), `Invoke-DFPicker` (existing — `-Preview`, `-Delimiter`, `-WithNth`, `-Parse`, `-Action`).
- Produces: `Select-DFPackage [[-Query] <string[]>] [-Source <string[]>] [-Readme] [-GitInfo]`. Query mode line format: `<previewFile>\t<qualifiedId>\t<name>\t<sources>\t<description>` with `--with-nth 3..` (fields 1–2 hidden); preview command reads the pre-rendered card file (`type {1}` on Windows, `cat {1}` elsewhere — fzf quotes the placeholder itself, so the whole path must be field 1). Enter → `Find-DFPackage -Query <qualifiedId> -Readme: -GitInfo:`.

- [ ] **Step 1: Write the failing tests** (append to `tests/Select-DFPackage.Tests.ps1`; its `BeforeAll` must additionally dot-source `Public/New-DFDirectory.ps1`, `Private/Format-DFToolInfo.ps1`, `Private/DFCatalog.ps1`, and `Public/Find-DFPackage.ps1` if not already)

```powershell
    Context 'query mode' {
        BeforeEach {
            Mock Find-DFPackage {
                $src = New-DFToolSourceInfo -Source scoop -PackageId 'extras/zed' -Name zed `
                    -Description 'editor' -LatestVersion '1.0' -MatchKind exact-name
                New-DFToolInfo -Name zed -Description 'editor' -Sources @($src) -MatchKind exact-name
            } -ParameterFilter { $AsObject }
        }

        It 'searches, pre-renders preview files, and passes a preview command' {
            Mock Invoke-DFFzf {
                $script:CapturedArgs = $FzfArgs
                $script:CapturedItems = $InputItems
                $null
            }
            Select-DFPackage zed
            $script:CapturedArgs -join ' ' | Should -Match '--preview'
            $fields = $script:CapturedItems[0] -split "`t"
            Test-Path $fields[0] | Should -BeTrue      # pre-rendered card file
            $fields[1] | Should -Be 'scoop:extras/zed' # qualified id
            $fields[2] | Should -Be 'zed'
        }

        It 'cleans the preview temp dir after the picker exits' {
            $script:Dir = $null
            Mock Invoke-DFFzf {
                $script:Dir = Split-Path (($InputItems[0] -split "`t")[0]) -Parent
                $null
            }
            Select-DFPackage zed
            Test-Path $script:Dir | Should -BeFalse
        }

        It 'invokes Find-DFPackage with the qualified id and passthrough switches on selection' {
            Mock Invoke-DFFzf { $InputItems[0] }   # simulate picking the first row
            Mock Find-DFPackage { 'card' } -ParameterFilter { -not $AsObject }
            Select-DFPackage zed -Readme -GitInfo
            Should -Invoke Find-DFPackage -ParameterFilter {
                (-not $AsObject) -and ($Query -contains 'scoop:extras/zed') -and $Readme -and $GitInfo
            }
        }

        It 'warns when the query has no matches' {
            Mock Find-DFPackage { @() } -ParameterFilter { $AsObject }
            $w = $null
            Select-DFPackage zzz -WarningVariable w -WarningAction SilentlyContinue
            "$w" | Should -Match 'no matches'
        }
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Select-DFPackage.Tests.ps1 -Output Detailed"`
Expected: new Context FAILs (no `-Query` param); existing tests PASS.

- [ ] **Step 3: Implement — full new `Public/Select-DFPackage.ps1`**

```powershell
#Requires -Version 7.0

function Select-DFPackage {
    <#
    .SYNOPSIS
        Fuzzy-browse packages with fzf. With a query: searches every catalog
        (like trifle) and previews each result's info card; Enter renders the
        full detail card. Without a query: browses all locally cached packages.
    .DESCRIPTION
        Query mode pre-renders each result's basic info card to a temp file so
        the fzf preview is instant — no subprocess module loads, no network
        while scrolling. The selection re-enters Find-DFPackage via its
        qualified source:packageId, which fetches full per-catalog details.

        Browse mode (no query) reads only local caches (scoop/winget indexes,
        cached web queries, the installed snapshot) so the list opens
        instantly — run Update-DFPackageCache (or any first trifle query) to
        populate it.
    .PARAMETER Query
        Search terms. When present, the list is live search results with a
        detail-card pipeline; when absent, the local-cache browser.
    .PARAMETER Source
        Restrict to packages known to these catalogs.
    .PARAMETER Readme
        After selection, also fetch and page the package readme.
    .PARAMETER GitInfo
        After selection, include GitHub stars/release/activity on the card.
    .EXAMPLE
        ftrifle zed
        Search all catalogs for 'zed', preview cards while scrolling, Enter
        shows the full detail card.
    .EXAMPLE
        ftrifle
        Browse all locally known packages; Enter renders the info card.
    .OUTPUTS
        None — the selection is rendered via Find-DFPackage.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromRemainingArguments)]
        [string[]]$Query,

        [ValidateSet('scoop', 'winget', 'choco', 'npm', 'pypi', 'crates', 'psgallery')]
        [string[]]$Source,

        [switch]$Readme,

        [switch]$GitInfo
    )

    if ($Query) {
        $findArgs = @{ Query = $Query; AsObject = $true }
        if ($Source) { $findArgs.Source = $Source }
        $results = @(Find-DFPackage @findArgs)
        if (-not $results) {
            Write-Warning "DotForge: no matches for '$($Query -join ' ')'."
            return
        }

        # Pre-render each result's card for the fzf preview. The preview file
        # path is field 1 because fzf quotes {1} itself — a path assembled
        # around the placeholder would break on the inserted quotes.
        $previewDir = Join-Path ([System.IO.Path]::GetTempPath()) "dotforge-preview-$PID"
        New-DFDirectory $previewDir
        try {
            $lines = @(for ($i = 0; $i -lt $results.Count; $i++) {
                $info = $results[$i]
                $file = Join-Path $previewDir "$i.txt"
                (Format-DFToolInfoCard -Info $info -Color $true) -join "`n" | Set-Content -Path $file -Encoding UTF8
                $best = @($info.Sources) | Select-Object -First 1
                $qualifiedId = "$($best.Source):$($best.PackageId)"
                "$file`t$qualifiedId`t$($info.Name)`t$(@($info.Sources.Source) -join ',')`t$($info.Description)"
            })

            $previewCmd = $IsWindows ? 'type {1}' : 'cat {1}'

            Invoke-DFPicker -List { $lines }.GetNewClosure() `
                -Header 'Select package [Enter: full details]' `
                -Preview $previewCmd `
                -Delimiter "`t" -WithNth '3..' `
                -Parse { ($_ -split "`t")[1] } `
                -Action { param($qid) Find-DFPackage -Query $qid -Readme:$Readme -GitInfo:$GitInfo }.GetNewClosure()
        } finally {
            Remove-Item $previewDir -Recurse -Force -ErrorAction Ignore
        }
        return
    }

    $packages = @(Get-DFCatalogLocalPackages)
    if ($Source) {
        $packages = @($packages | Where-Object {
            @($_.Sources -split ',') | Where-Object { $_ -in $Source }
        })
    }
    if (-not $packages) {
        Write-Warning 'DotForge: no local catalog data yet — run Update-DFPackageCache or a first trifle query.'
        return
    }

    $browseLines = @($packages | ForEach-Object { "$($_.Name)`t$($_.Sources)`t$($_.Description)" })

    Invoke-DFPicker -List { $browseLines }.GetNewClosure() `
        -Header 'Select package [Enter: info card]' `
        -Delimiter "`t" -WithNth '1,3' `
        -Parse { ($_ -split "`t")[0] } `
        -Action { param($name) Find-DFPackage -Query $name }
}

Set-Alias -Name ftrifle -Value Select-DFPackage -Scope Global -Force
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Select-DFPackage.Tests.ps1 -Output Detailed"`
Expected: PASS.

- [ ] **Step 5: Verify help renders**

Run: `pwsh -NoProfile -Command "Import-Module ./DotForge.psd1 -Force; Get-Help Select-DFPackage -Full | Out-String"`
Expected: all four `.PARAMETER` sections and both examples render.

- [ ] **Step 6: Commit**

```bash
git add Public/Select-DFPackage.ps1 tests/Select-DFPackage.Tests.ps1
git commit -m "feat(trifle): ftrifle query mode with instant card preview and detail-card selection"
```

---

### Task 10: Update-DFPackageCache detail re-warm + docs

**Files:**
- Modify: `Public/Update-DFPackageCache.ps1`
- Modify: `README.md`, `examples/05-trifle-catalog.ps1`, `CHANGELOG.md`
- Test: extend `tests/Update-DFPackageCache.Tests.ps1`

**Interfaces:**
- Consumes: provider `Detail` hooks (Tasks 2–4); detail envelopes' `query` field carrying the raw PackageId (Task 1).
- Produces: cached detail entries re-warmed on every `Update-DFPackageCache` run (the files under `catalogs/<provider>/details/` ARE the re-warm list — no LRU).

- [ ] **Step 1: Write the failing test** (append inside the existing `Describe` in `tests/Update-DFPackageCache.Tests.ps1`, using its existing fake-provider harness — give one fake provider a `Detail` hook that records invocations. If that harness's fake providers use different names than `choco`, adapt the provider key; any `query-cache`-kind fake works.)

```powershell
    It 're-warms cached detail entries with the stored raw PackageId' {
        $script:DetailCalls = [System.Collections.Generic.List[string]]::new()
        $script:DFCatalogProviders['choco'].Detail = { param($Id, $Fresh)
            $script:DetailCalls.Add("$Id fresh=$Fresh") }

        $detailsDir = Join-Path $Env:XDG_CACHE_HOME 'dotforge/catalogs/choco/details'
        New-Item -ItemType Directory -Path $detailsDir -Force | Out-Null
        @{ timestamp = [datetime]::UtcNow.ToString('o'); query = 'RipGrep'; results = @(@{ PackageId = 'RipGrep' }) } |
            ConvertTo-Json -Depth 4 | Set-Content (Join-Path $detailsDir 'ripgrep-abcd1234.json')

        Update-DFPackageCache -Quiet
        $script:DetailCalls | Should -Contain 'RipGrep fresh=True'
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Update-DFPackageCache.Tests.ps1 -Output Detailed"`
Expected: new test FAILs; existing PASS.

- [ ] **Step 3: Implement** — in `Public/Update-DFPackageCache.ps1`, insert before the final `if (-not $Quiet)` summary block:

```powershell
    # Re-warm every cached detail entry (the files themselves are the list;
    # the envelope's query field holds the raw PackageId).
    $detailCount = 0
    if ($cacheRoot) {
        foreach ($provider in $providers) {
            if (-not $provider.Detail) { continue }
            $detailsDir = Join-Path $cacheRoot "$($provider.Name)/details"
            if (-not (Test-Path $detailsDir)) { continue }
            foreach ($file in Get-ChildItem $detailsDir -Filter '*.json' -File) {
                $cached = Read-DFCatalogCacheFile -Path $file.FullName -Ttl ([timespan]::MaxValue)
                if (-not $cached -or -not $cached.Query) { continue }
                try {
                    $null = & $provider.Detail $cached.Query $true
                    $detailCount++
                } catch {
                    Write-Warning "DotForge: $($provider.Name) detail re-warm of '$($cached.Query)' failed: $_"
                }
            }
        }
    }
```

And extend the summary line:

```powershell
    if (-not $Quiet) {
        Write-Host "Re-warmed $($queries.Count) queries across $($webProviders.Count) web catalogs and $detailCount detail entries."
    }
```

Also update the function's `.DESCRIPTION` to mention detail re-warm.

- [ ] **Step 4: Run tests to verify they pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Update-DFPackageCache.Tests.ps1 -Output Detailed"`
Expected: PASS.

- [ ] **Step 5: Full suite + smoke test**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/ -Output Detailed"`
Expected: ALL PASS.

Manual smoke (interactive shell): `Import-Module ./DotForge.psd1 -Force; trifle zed; trifle zed -All; trifle winget:Zed.Zed; ftrifle zed`
Expected: detail card / Id-column table / qualified detail card / fzf with preview.

- [ ] **Step 6: Documentation**

- `README.md` — in the trifle section: exact-match detail card behavior, `-All` + Id column, qualified `source:id` queries, `-Readme`, `-GitInfo`, `ftrifle <query>` preview flow.
- `examples/05-trifle-catalog.ps1` — add commented examples: `trifle zed`, `trifle zed -All`, `trifle winget:Zed.Zed -GitInfo`, `ftrifle zed -Readme`.
- `CHANGELOG.md` — under `[Unreleased]` → `### Added`: detail view bullets (detail providers for all 7 catalogs, qualified ids, `-All`/`-Readme`/`-GitInfo`, ftrifle preview, detail cache re-warm).

- [ ] **Step 7: Commit**

```bash
git add Public/Update-DFPackageCache.ps1 tests/Update-DFPackageCache.Tests.ps1 README.md examples/05-trifle-catalog.ps1 CHANGELOG.md
git commit -m "feat(trifle): detail cache re-warm in Update-DFPackageCache; docs for detail view"
```

---

## Verification (whole feature)

1. `pwsh -NoProfile -Command "Invoke-Pester tests/ -Output Detailed"` — all green.
2. `pwsh -NoProfile -Command "Test-ModuleManifest ./DotForge.psd1"` — clean (no manifest changes expected).
3. `Get-Help Find-DFPackage -Full` / `Get-Help Select-DFPackage -Full` — every param documented.
4. Live smoke: `trifle ripgrep` (detail card with scoop notes + install hints), `trifle ripgrep -GitInfo` (star count), `trifle npm:left-pad -Readme` (readme pages), `trifle zed -All` (Id column), `ftrifle zed` (instant preview, Enter → detail card).






