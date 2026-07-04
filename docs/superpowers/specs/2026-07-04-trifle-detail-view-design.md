# trifle Detail View — Design

**Date:** 2026-07-04
**Status:** Approved
**Depends on:** multi-catalog package info (`Find-DFPackage` / `Select-DFPackage` / `Update-DFPackageCache`, shipped on `feat/trifle`)

## Problem

`trifle zed` returns a long match table with no way to zero in on one entry.
The rich info card only renders when the search produces exactly one confident
match, and even then it shows only search-level data (id, version, description,
homepage, license). Every catalog knows far more about a package than its
search endpoint returns — full manifests, dependencies, maintainers, release
notes — and none of it is reachable today.

## Goals

- Zero in on a single package from an ambiguous result list, both
  non-interactively (unique id) and interactively (fzf).
- Show as much detail as each catalog can provide, merged into one card.
- Opt-in enrichment: GitHub repo info and readme.
- Stay cache-first and non-blocking, matching the existing catalog engine.

## Non-Goals

- Installing packages (that remains Phase 3 `Install-DFTool` territory).
- Live detail fetches inside the fzf preview window (decided against: sluggish
  scrolling, API hammering). Preview uses pre-rendered search-level cards.
- Readme rendering beyond plain paging (no markdown-to-ANSI rendering).

## Command Surface

### `trifle <query>` (Find-DFPackage)

| Invocation | Behavior |
|---|---|
| `trifle zed` | Exact match on name → **detailed card** (see below). No exact match → full match table (same as `-All`). |
| `trifle zed -All` | Always the full match table, never the card. Table gains an **Id** column (`source:packageId`, e.g. `winget:Zed.Zed`) so a unique id can be copied. |
| `trifle winget:Zed.Zed` | Qualified-id query. Skips keyword search for the id itself: fetches detail for exactly that package from that source, and additionally searches the bare name across the other catalogs so the card still shows cross-catalog availability. |
| `trifle zed -Readme` | Detailed card, then the readme paged through `Invoke-DFWithPager`. |
| `trifle zed -GitInfo` | Detailed card including a GitHub section (stars, latest release, last push, open issues, archived). |
| `trifle zed -Fresh` | As today: block on live fetches (applies to detail fetches too). |

New parameters on `Find-DFPackage`: `-All`, `-Readme`, `-GitInfo`.
`-Readme` / `-GitInfo` imply the detail path; when the query has no exact
match they emit a warning and fall back to the table.

**Exact-match rule (replaces the current "confident" rule):** the detailed
card renders when the top-ranked merged result has `MatchKind` of `exact-id`
or `exact-name`, or its `Name` equals the normalized query case-insensitively
— even when other keyword matches exist. When other matches were suppressed,
the card ends with a faint footer: `+ N more matches — trifle <query> -All`.

Pipeline behavior is unchanged: piped/redirected output (or `-AsObject`)
emits objects, never rendered strings. The detail path enriches the emitted
`DotForge.ToolInfo` with a `Details` property (per-source detail objects) and
optional `GitHub` property.

### `ftrifle [query]` (Select-DFPackage)

- Gains an optional positional `-Query` plus `-Readme` / `-GitInfo`
  passthrough switches.
- With a query: runs the same search as `Find-DFPackage`, lists the merged
  results in fzf.
- Without a query: current behavior (browse all locally cached packages).
- **Preview window:** shows the basic info card for the highlighted row,
  pre-rendered from data already in memory. Before launching fzf, each row's
  card is written to `<temp>/dotforge-preview-<pid>/<index>.txt`; the fzf
  preview command reads the file by index field (first tab-delimited field,
  hidden from display via `--with-nth`). No subprocess module loads, no
  network in preview. Temp dir is removed in a `finally` after the picker
  exits.
- **On Enter:** renders the full detailed card in the terminal (same path as
  `trifle <exact>`), honoring `-Readme` / `-GitInfo`.

## Architecture

### Provider `Detail` hook (Approach A — approved)

Each provider registration in `Private/DFCatalog.<Provider>.ps1` gains one
entry:

```powershell
Detail = { param($PackageId, $Fresh) Get-DFCatalog<Provider>Detail -PackageId $PackageId -Fresh:$Fresh }
```

Each `Get-DFCatalog<Provider>Detail` returns a single
`DotForge.ToolSourceDetail` (or `$null` on failure). Providers without a
meaningful detail source may omit the hook; the engine skips them.

### Engine: `Get-DFCatalogDetail` (new, `Private/DFCatalog.ps1`)

Mirrors `Search-DFCatalogQueryCache`:

- Cache path: `catalogs/<provider>/details/<key>.json` where `key` is
  `(ConvertTo-DFCatalogQueryKey -Query $PackageId).Key` (reuses the existing
  sanitize+hash scheme — package ids like `extras/zed` and `Zed.Zed` are made
  filename-safe the same way queries are).
- Fresh hit → served instantly. Stale hit → served instantly + background
  `Start-DFCatalogRefreshJob` re-warm. Miss or `-Fresh` → inline fetch,
  falling back to stale cache on failure.
- TTLs reuse `$script:DFCatalogTtl` (choco 72h, default 24h). Scoop's detail
  read is local-disk and free, so its provider bypasses the cache entirely
  and always reads the manifest.
- `Update-DFPackageCache` re-warms cached detail entries the same way it
  re-warms seen queries (details directory enumeration; no new LRU needed —
  the files themselves are the record).

### Per-provider detail sources

| Provider | Fetch | Notable fields |
|---|---|---|
| scoop | Read full manifest JSON from the bucket clone (local, no cache needed) | `notes`, `depends`, `suggest`, `bin` (shims), `checkver` presence, license, description |
| winget | `winget show --id <id> --exact --disable-interactivity`, parse `Key: value` lines | Publisher, Author, Moniker, Tags, Release Notes (+ URL), Installer type, Homepage |
| choco | OData package entry `Packages(Id='<id>',Version='<latest>')` | Authors, ProjectUrl, Tags, ReleaseNotes, DownloadCount, Docs/Source links |
| npm | `https://registry.npmjs.org/<name>` full doc | dist-tags, dependencies, maintainers, repository, keywords, readme (reused by `-Readme`), per-version times |
| pypi | `https://pypi.org/pypi/<name>/json` | author, requires_python, classifiers, project_urls, keywords, summary vs description |
| crates | `https://crates.io/api/v1/crates/<name>` | downloads, recent_downloads, keywords, categories, repository, documentation |
| psgallery | `Find-PSResource -Name <id>` (PSResourceGet, already a module dep path) | Author, CompanyName, Tags, Dependencies, ProjectUri, ReleaseNotes |

### `DotForge.ToolSourceDetail` (new constructor in `Private/DFCatalog.ps1`)

Normalized shape; every field optional except `Source`/`PackageId`:

```
Source, PackageId, Publisher, Maintainers[], Dependencies[], Tags[],
Downloads, ReleaseNotes, ReleaseNotesUrl, RepositoryUrl, DocsUrl,
InstallHint, Notes, Extra (ordered dict for source-specific leftovers)
```

`InstallHint` is the copy-pasteable install command for that catalog
(`scoop install extras/zed`, `winget install --id Zed.Zed`, `npm i -g zed`, …)
built by the provider.

### Merged output

`Find-DFPackage`'s detail path attaches to the existing `DotForge.ToolInfo`:

- `Details` — ordered dict `source → ToolSourceDetail` (canonical order).
- `GitHub` — `DotForge.RepoInfo` or `$null` (only populated with `-GitInfo`).

No new top-level type: `ToolInfo` remains the single pipeline currency.

### GitHub enrichment (`-GitInfo`)

New private `Get-DFGitHubRepoInfo -RepoUrl <url>`:

1. Resolve the repo URL: first `RepositoryUrl` from details, then `Homepage`
   — accept only `github.com/<owner>/<repo>` shapes (strip `.git`, `#readme`,
   tree paths).
2. If `gh` is on PATH and `gh auth status` succeeds (memoized per session):
   `gh api repos/<owner>/<repo>` — authenticated, 5000 req/hr.
3. Else anonymous `Invoke-RestMethod https://api.github.com/repos/<owner>/<repo>`
   (60 req/hr — fine for single lookups). Rate-limit response → warning +
   skip section.
4. Cached at `catalogs/github/details/<key>.json`, default TTL.

Fields: `Stars, OpenIssues, PushedAt, LatestRelease, LatestReleaseAt,
Archived, DefaultBranch, Description, License`. Latest release comes from
`releases/latest` (second call, same auth path; 404 → omit).

Card section is modeled on `gh repo view` output.

### Readme (`-Readme`)

Resolution order:

1. npm registry doc `readme` field (already fetched for npm details).
2. crates.io `/api/v1/crates/<name>/readme` (HTML → skipped; use raw GitHub instead when repo known).
3. GitHub readme API (`gh api repos/<o>/<r>/readme --jq .content` base64 or
   anonymous with `Accept: application/vnd.github.raw`) when a repo URL
   resolved.
4. PyPI long `description` when `description_content_type` is markdown/text.

First hit wins. Output is paged via `Invoke-DFWithPager` after the card.
Not cached separately beyond the detail cache that carries it (npm) — the
GitHub readme fetch is cached alongside RepoInfo under `catalogs/github/`.

## Rendering

New `Format-DFToolDetailCard` in `Private/Format-DFToolInfo.ps1`, same pure
`(object, [bool]$Color) → string[]` pattern. Layout: the existing card
sections first (title, Installed, Sources table, Homepage, License, Updated,
Cache), then per availability:

```
Publisher  <publisher / authors>            (first non-empty across sources)
Deps       <source>: dep1, dep2 …           (one line per source that has any)
Tags       tag1 · tag2 · tag3               (union, capped ~10)
Downloads  crates 1.2M · psgallery 30k
Install    scoop install extras/zed
           winget install --id Zed.Zed
Notes      <scoop notes, wrapped>
GitHub     ★ 12.3k · updated 2026-07-01 · release v0.192 (2026-06-28) · 1.4k issues
           <repo description>
+ 7 more matches — trifle zed -All        (faint footer, when applicable)
```

Long values wrap at the card width; missing sections are omitted entirely.
`Format-DFToolInfoTable` gains the Id column (`source:packageId` of the
best-ranked source per row), width-budgeted like existing columns.

## Error Handling

- Any single catalog's detail fetch failing (timeout, rate limit, parse
  error) degrades that source to its search-level data; the card marks it
  with a faint `(details unavailable)` on that source's row. Never blocks or
  throws.
- `-GitInfo` with no resolvable GitHub URL → faint `GitHub — no repository
  resolved` line.
- `-Readme` with no readme found → warning, card still renders.
- Qualified id with unknown source prefix (`foo:bar`) → treated as a plain
  keyword query (colons appear in real searches; only the seven known source
  names activate the qualified path).
- Qualified id whose package doesn't exist → `No package '<id>' found in
  <source>.` plus a normal keyword search of the bare name as fallback.

## Testing (Pester 5)

- **Engine:** `Get-DFCatalogDetail` cache hit / stale-refresh / miss / fetch
  failure fallback — mock provider `Detail` scriptblocks, temp
  `XDG_CACHE_HOME` (same harness as `Find-DFPackage.Tests.ps1`).
- **Qualified id parsing:** each known prefix routes; unknown prefixes fall
  through to keyword search.
- **Exact-match rule:** exact + keyword mix → card; keyword-only → table;
  `-All` forces table.
- **Providers:** per-provider detail normalization from canned API/manifest
  fixtures (mock `Invoke-RestMethod` / filesystem, as existing provider tests
  do). winget `Key: value` parser gets CRLF-safe tests (`-creplace`, `\r?$`
  per CLAUDE.md).
- **Renderer:** pure string assertions on `Format-DFToolDetailCard` with and
  without color, missing-section omission, footer.
- **GitHub:** gh-present vs anonymous fallback (mock `Get-Command` and both
  fetch paths), rate-limit degradation.
- **ftrifle:** preview temp files written/cleaned, query mode vs browse mode
  (mock `Invoke-DFFzf`).

## Out of Scope / Future

- Markdown rendering of readmes (glow integration).
- GitLab/Codeberg enrichment.
- `trifle -Pick` style index selection on the table.
