# Package Universe — Phase A: Catalog Acquisition — Design

**Date:** 2026-07-13
**Status:** Approved
**Part of:** a larger admin-tooling effort to build a cross-catalog package index (identity linking + metadata merge + categorization). This spec covers only the first phase, acquisition. Later phases (identity clustering, metadata merge, categorization, and optional AI-assisted categorization / additional ecosystems) are each sequenced as their own future spec.

## Problem

DotForge's `trifle` today searches scoop/winget/choco/npm/crates/psgallery/pypi on demand, one query at a time, with per-query caching. There is no artifact anywhere that says "here is every package these catalogs contain" — that's a prerequisite for the larger goal (an index linking the same real-world application across every package manager it's distributed through, with merged metadata and categories). This spec builds that prerequisite for the three catalogs that anchor the effort: scoop, winget, and choco.

## Goals

- Produce a complete, offline snapshot of every package in scoop (locally-added buckets), winget, and choco, with whatever metadata (name, version, description, homepage, license, publisher, tags) each catalog can supply cheaply.
- Store the result in a form later phases (identity clustering, metadata merge, categorization) can query and build on directly.
- Never let one catalog's failure (rate-limited API, unreachable download, corrupt file) block the other two, or abort a partial run.
- Log anything ambiguous or broken for later human review, without treating it as fatal.

## Non-Goals

- Cross-catalog identity linking, metadata merging, or categorization — later phases, each with their own spec.
- npm/crates/pypi/psgallery/gem acquisition — those are cross-reference targets for a later phase (search-and-validate against the scoop/winget/choco-derived universe), not full-catalog crawls themselves.
- Every scoop bucket that exists in the world — scoop has no central registry; scope is whatever buckets are already added on the machine running the build.
- Incremental/diff-based updates — this is a rebuild-from-scratch tool, rerun manually/occasionally. Incremental acquisition is deferred until (if) this becomes a scheduled job.
- rpm/deb/homebrew or any non-Windows ecosystem — future work, unscoped here.
- Shipping this data as part of the installed DotForge module — this is author-side admin tooling under `build/`, exactly like `Build-DFCategoryDb.ps1` / `Build-DFToolIdentities.ps1`, never loaded by the module itself.

## Pipeline Context (for later phases)

This is Phase A of a multi-phase pipeline. All phases share one SQLite working database (`universe.db`) rather than each inventing its own storage:

- **Phase A (this spec):** `raw_packages` — per-catalog raw acquisition.
- **Phase B (future):** `identity_clusters` / `cluster_members` — cross-catalog identity linking, plus search-and-validate cross-references into npm/crates/pypi/psgallery/gem.
- **Phase C (future):** `merged_metadata` — normalized, merged per-cluster metadata.
- **Phase D (future):** `categories` — derived ontology/tags.
- **Phase E/F (future, optional):** AI-assisted categorization; additional ecosystems (rpm/deb/homebrew).

Every phase writes into one shared log table, `pipeline_log`, tagged by `stage`. This is the "log for later manual review" mechanism spanning the whole pipeline, not just this phase.

## Data Model

```sql
CREATE TABLE raw_packages (
  id          INTEGER PRIMARY KEY,
  source      TEXT NOT NULL,   -- 'scoop' | 'winget' | 'choco'
  package_id  TEXT NOT NULL,   -- catalog-native id ('bucket/name' for scoop, winget PackageIdentifier, choco id)
  name        TEXT,
  version     TEXT,
  description TEXT,
  homepage    TEXT,
  license     TEXT,
  publisher   TEXT,
  tags        TEXT,            -- JSON array, serialized
  extra       TEXT,             -- JSON object, source-specific leftover fields
  fetched_at  TEXT NOT NULL,    -- ISO 8601 UTC
  UNIQUE(source, package_id)
);

CREATE TABLE pipeline_log (
  id         INTEGER PRIMARY KEY,
  stage      TEXT NOT NULL,   -- 'acquire' | 'link' | 'merge' | 'categorize'
  source     TEXT,            -- nullable: which catalog, if applicable
  package_id TEXT,            -- nullable: which package, if applicable
  level      TEXT NOT NULL,   -- 'warning' | 'error' | 'review'
  message    TEXT NOT NULL,
  logged_at  TEXT NOT NULL    -- ISO 8601 UTC
);
```

- `level = 'error'`: something failed outright (a catalog fetch failed, a page/file was unreadable after retries).
- `level = 'warning'`: a single item was skipped (unparseable manifest, missing required field).
- `level = 'review'`: parsed fine, but worth a human glance later (e.g. no default-locale winget manifest found, a homepage URL that fails basic format validation, an empty scoop `bin` array).
- Each run truncates both `raw_packages` and this run's rows before starting (full rebuild, no reconciliation against prior runs, per the "occasional manual re-run" cadence this is scoped for).

## Acquisition Strategy Per Catalog

### Scoop

Thin wrapper around the existing `Build-DFCatalogScoopIndexData` (`Private/DFCatalog.Scoop.ps1`) — it already reads every manifest from every locally-cloned bucket (name, bucket, version, description, homepage, license), entirely from local disk, no network. Map each result into `raw_packages` with `source = 'scoop'`, `package_id = "$bucket/$name"`. Scope is exactly whatever buckets are added on the machine running the build — there is no broader "every scoop bucket" universe to reach for.

### Winget

The local SQLite index (`Private/DFCatalog.Winget.ps1`'s `index.db`) has `id`/`name`/`moniker`/`latest_version` only — no description/homepage/publisher/tags by design. Rather than pay for tens of thousands of slow `winget show` CLI spawns, acquire directly from the public source of truth:

1. Download a zip snapshot of `microsoft/winget-pkgs`'s default branch (GitHub's zipball/tarball endpoint — no `git` dependency, no history, just the current tree). This mirrors the existing in-process zip-extraction approach `Get-DFCatalogWingetIndex` already uses for the msix. No incremental logic — full re-download and replace each run.
2. This is the single most expensive step in Phase A: the repo holds every published version of every package under `manifests/<letter>/<publisher>/<package>/<version>/`, so expect a sizeable download (plausibly several hundred MB+) and a non-trivial extraction/parse pass. Budget real wall-clock time for this step; it is not expected to be fast.
3. For each package, resolve only its **latest version folder** — version folder names are compared using `[version]` parsing where they parse cleanly, falling back to ordinal string comparison for the minority that don't (winget versions aren't strictly required to be semver) — then parse the default-locale manifest (`<PackageIdentifier>.locale.yaml` — the unsuffixed default, not a specific `<PackageIdentifier>.locale.xx-XX.yaml`) for `PackageName`, `Publisher`, `ShortDescription`/`Description`, `Homepage`, `License`, `Tags`. The installer manifest is not needed and is skipped entirely.
4. YAML parsing uses the `powershell-yaml` module (a new build-time-only dependency — never required by the shipped DotForge module or its end users, exactly analogous to how some existing build tooling already assumes `gh` is available).
5. A package with no default-locale manifest logs a `review` row and is skipped (some winget-pkgs entries are genuinely incomplete).

### Choco

Reuses `ConvertFrom-DFCatalogODataEntry` (`Private/DFCatalog.Choco.ps1`), which already maps OData entries to id/name/description/version/homepage. Paginate the same `Packages()` OData collection (no search term) with `$filter=IsLatestVersion&$top=<ChocoPageSize>&$skip=N`, advancing until an empty page, with a deliberate delay between pages given the API is already documented in-repo as slow and aggressively rate-limited. Defaults: `-ChocoPageSize 100`, `-ChocoDelayMs 500`. A page is retried up to 3 times with exponential backoff (1s/2s/4s) before it's given up on; a page that still fails after retries logs an `error` row and the crawl continues from the next page (`$skip` advances by `ChocoPageSize` regardless) rather than aborting the whole run.

## Error Handling

- **Catalog-level isolation**: a total failure in one catalog (winget-pkgs download fails, choco API unreachable, no scoop buckets found) logs an `error` row and the other catalogs' acquisition still proceeds and is still written to `raw_packages`.
- **Item-level isolation**: one unparseable manifest/entry logs a `warning` row and is skipped; it never aborts the catalog's crawl.
- **`review`-level entries**: logged for anything that parsed successfully but merits a later human look (see Data Model above for examples). These are not failures.

## Testing (Pester 5)

- Unit tests for each catalog's mapping/parsing logic (scoop manifest → row, winget locale YAML → row, choco OData entry → row) against small fixture files — pure functions, tested in isolation exactly like the existing `ConvertFrom-DFCatalogODataEntry`/`ConvertFrom-DFCatalogWingetShow` tests.
- No test hits real network, a real scoop install, or a real winget-pkgs download — the choco pager, the winget-pkgs zip fetch, and the scoop bucket scan each need an injectable seam (mirroring the `-FetchItems`/`-ResolveLinkage` pattern already used elsewhere in this repo) so tests supply canned data.
- One end-to-end test running the full Phase A script against fixtures for all three catalogs, asserting the resulting `raw_packages` table shape and row counts.
- A test confirming catalog-level failure isolation: one catalog's fetch seam throws, and the other two still populate `raw_packages` while an `error` row appears in `pipeline_log`.

## Location & Invocation

- `build/Build-DFPackageUniverseRaw.ps1` — Phase A's entry point, matching the existing `build/Build-DFCategoryDb.ps1` / `build/Build-DFToolIdentities.ps1` convention: `#Requires -Version 7.0`, full comment-based help, injectable fetch seams per catalog for testing, dot-sources `Private/*.ps1` only for what it reuses (scoop's index builder, choco's OData mapper).
- **SQLite read/write access is a second build-time-only dependency**, the `PSSQLite` module. The existing `Invoke-DFSqliteQuery` (used by the shipped module's winget provider) is read-only by construction and has no parameter binding — safe for its existing trusted, pre-escaped callers, but wrong for writing thousands of rows of untrusted scraped text (descriptions/tags routinely contain quotes/apostrophes). `PSSQLite` provides parameterized `Invoke-SqliteQuery -SqlParameters` for safe writes. Like `powershell-yaml`, this is never a dependency of the shipped DotForge module or its end users.
- Params: `-DatabasePath` (default alongside the script), `-ScoopRoot` (reuses existing default resolution), `-WingetPkgsSnapshot` (path to an already-downloaded/extracted snapshot; triggers a fresh download when omitted), `-ChocoPageSize` / `-ChocoDelayMs` (tunable pacing).
- The working database and the downloaded winget-pkgs snapshot are **not committed** — both regenerable, and the winget-pkgs snapshot is too large for git. Default location: a new gitignored `build/.package-universe/` working directory (`universe.db`, `winget-pkgs/`).
- Later phase scripts (`Build-DFPackageUniverseLinks.ps1`, etc.) will open the same `universe.db` and add their own tables, each independently runnable and independently testable.

## Out of Scope / Future

- Phase B: cross-catalog identity clustering (repo/homepage URL matching within scoop+winget+choco, then search-and-validate cross-references into npm/crates/pypi/psgallery/gem).
- Phase C: metadata merge across linked clusters.
- Phase D: categorization/ontology, most likely extending the existing `data/tool-categories.json` taxonomy.
- Phase E (optional): AI-assisted categorization for anything Phase D's rule-based pass can't confidently classify.
- Phase F (optional): rpm/deb/homebrew or other non-Windows ecosystems.
- Incremental/diff-based re-acquisition, if this ever becomes a scheduled recurring job instead of an occasional manual run.
