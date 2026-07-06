# trifle Tool Identity Guide — Design

**Date:** 2026-07-06
**Status:** Approved
**Depends on:** trifle detail view (`docs/superpowers/specs/2026-07-04-trifle-detail-view-design.md`) — reuses `Resolve-DFGitHubRepoUrl` and per-catalog `RepositoryUrl` detail fields. Sits alongside (does not modify) trifle discovery v1 (`docs/superpowers/specs/2026-07-05-trifle-discovery-v1-design.md`) — a separate artifact, same architectural pattern.

## Problem

`trifle`'s cross-catalog merge groups search hits into one row via `Tools/*.json`'s curated `packages` blocks (32 tools only) or, failing that, by **exact case-insensitive name string** across catalogs. This second path is unsound in both directions:

- **Same name, different tool:** `trifle zed` merges winget's `Zed.Zed` (the Zed code editor) with choco's unrelated `zed` package (a SpiceDB-adjacent schema tool) into one Frankenstein row — different versions, different publishers, different everything, presented as if they were one package.
- **Different name, same tool:** a tool published as `fd-find` on one catalog and `fd` on another never unifies today, even though they are the same project — the merge logic never even considers them as candidates, since nothing puts differently-named hits side by side for comparison.

Fixing only the first direction (disambiguating name collisions) doesn't fix the second. Both share a root cause: the merge key is a display name, which is neither a reliable positive signal (coincidental collisions) nor a complete one (legitimate renames/aliases across catalogs).

## Goals

- A precomputed, offline-built artifact linking canonical tools to their package IDs across catalogs, independent of display-name string matching in either direction.
- `trifle` never merges two catalog hits into one row unless a genuine identity link (curated `Tools/*.json` mapping or a guide entry) says they're the same tool.
- The expensive part of establishing a link (resolving each candidate's real-world identity) happens once, offline, not on every ambiguous search.
- Coverage grows over time through the same seed-corpus-plus-content-authoring model already used for the category database — never by loosening the safety bar at query time.

## Non-Goals

- Install-status verification (binary-name-vs-package-name mismatches, Sysinternals-style collections) — a separate, sequenced spec.
- Full catalog-universe coverage — anchored to the same CLI-tool-union seed-corpus scope as the category database (currently 72 tools there; this guide seeds from the same universe, starting with the 32 `Tools/*.json` entries).
- Any live, per-query heuristic disambiguation (description similarity, version-scheme plausibility as a merge trigger) — rejected in favor of a precomputed guide plus a safe default. Version-scheme divergence remains useful only as a **build-time reviewer's aid**, never a runtime signal.
- Non-GitHub repository resolution (GitLab, Bitbucket, sourcehut, …) — the existing `Resolve-DFGitHubRepoUrl` machinery is GitHub-only; extending repo resolution to other forges is future work.
- Any change to `data/tool-categories.json` or its build pipeline — a separate artifact, unaffected by this spec.
- Runtime AI / automatic guide-entry creation — the guide is a build-time, human-reviewed artifact, exactly like the category taxonomy's authoring model.

## Architecture

A new shipped artifact, `data/tool-identities.json`, maps canonical tool keys to their known package IDs across catalogs. It is built offline by `build/Build-DFToolIdentities.ps1` from `build/identities/*.jsonc` fragments (mirroring `build/categories/*.jsonc` and `Build-DFCategoryDb.ps1` exactly), loaded lazily at query time by a `Get-DFToolIdentityGuide` singleton loader (mirroring `Get-DFCategoryDb`'s shipped/refreshed precedence and two-tier fallback), and refreshed independently of module releases via a new opt-in `Update-DFToolIdentityGuide` command (mirroring `Update-DFCategoryDb` — never implicit, never triggered by any `trifle`/`ftrifle` call).

**Two identity sources remain active at query time, unioned, not one replacing the other:**

1. **`Tools/*.json` `packages` blocks** — the existing, always-live mechanism (`Import-DFToolDb` reads these fresh on every call via `Get-DFCatalogInstalled`'s `IdentityMap` construction). Authoritative for the 32 curated tools. Editing a `Tools/*.json` file takes effect immediately, with no build/refresh step, so it stays the fast path for anyone actively maintaining a curated tool entry.
2. **The new tool-identity guide** — broader coverage, precomputed, refreshed on its own cadence. Extends coverage without requiring every addition to go through a `Tools/*.json` edit.

Both sources feed the same lookup: "does this `(source, packageId)` pair belong to a known canonical tool?" A hit resolves to a canonical tool if *either* source says so; the two are checked in the same call, not as a fallback chain with different semantics.

The 32 existing `Tools/*.json` entries are also imported as seed data into the guide's initial `build/identities/*.jsonc` fragments (Task-level detail in the implementation plan) — not because the live `Tools/*.json` path stops being consulted, but so the guide's own coverage numbers and future automated re-verification passes include them.

## Data Model

### `data/tool-identities.json`

```jsonc
{
  "schemaVersion": 1,
  "updated": "2026-07-06",
  "tools": {
    "zed": {
      "repo": "https://github.com/zed-industries/zed",
      "packages": { "winget": "Zed.Zed", "scoop": "extras/zed" },
      "linkedVia": "repo"
    },
    "ripgrep": {
      "repo": "https://github.com/BurntSushi/ripgrep",
      "packages": {
        "scoop": "ripgrep", "winget": "BurntSushi.ripgrep.MSVC", "choco": "ripgrep",
        "npm": "ripgrep", "pypi": "ripgrep", "crates": "ripgrep"
      },
      "linkedVia": "curated"
    },
    "some-homepage-only-tool": {
      "packages": { "scoop": "foo", "choco": "foo-cli" },
      "linkedVia": "homepage"
    }
  }
}
```

- `packages`: required, non-empty object of catalog-name → package ID (same catalog-name vocabulary as the live provider engine: `scoop`, `winget`, `choco`, `npm`, `pypi`, `crates`, `psgallery`).
- `repo`: optional — the resolved GitHub URL that established the link, when `linkedVia` is `repo`. Omitted for `homepage`- or `curated`-linked entries that have no resolvable repo.
- `linkedVia`: required, one of `repo` | `homepage` | `curated` — records how the link was established. Used by the build script to decide what's safe to auto-regenerate (`repo`/`homepage` entries can be re-derived by re-running resolution) versus what must be preserved verbatim across rebuilds (`curated` entries are hand-authored and never silently overwritten by an automated pass).
- **Uniqueness constraint:** no `(source, packageId)` pair may appear under more than one tool key. The build script must reject this as a build-time error (analogous to `Build-DFCategoryDb.ps1`'s duplicate-tool-key check).
- Tool keys follow the same lowercase-project-name convention as `data/tool-categories.json`'s tool keys, for readability and eventual cross-referencing — the two artifacts are not required to share entries or validate against each other, this is a soft naming convention only.

## Build-Time Linking Strategy

**Seed scope, and why it's bounded to 32 for v1:** linking requires at least two *already-known* `(source, packageId)` candidates to compare in the first place. The 32 curated `Tools/*.json` entries are the only tools where DotForge already knows multiple catalog IDs for the same intended tool — the category database's 40 "extras" tools deliberately carry no `ids` (per that spec's no-fabrication rule), so there is nothing yet to resolve a repo *from* for them. Growing this guide past 32 requires first discovering candidate `(source, packageId)` pairs to compare — e.g. via a future crawl, or by mining co-occurrences from live search results over time — which is exactly the kind of expansion deferred to Out of Scope / Future, not a v1 concern. v1's job is to prove the linking mechanism and pipeline on the known-good 32, not to grow coverage yet.

For each seed-corpus tool, resolve every catalog's candidate package to a canonical identity, in this priority order — all offline, all reusing detail-view machinery already shipped:

1. **Resolved GitHub repo match.** Run `Resolve-DFGitHubRepoUrl`-equivalent resolution (via each catalog's detail-level `RepositoryUrl`, or homepage when it's already a `github.com` URL) for every candidate. Two candidates resolving to the same normalized `owner/repo` are linked automatically, `linkedVia: "repo"`.
2. **Exact homepage URL match.** For candidates with no resolvable repo, compare homepage URLs after normalization (strip scheme, trailing slash, `www.` prefix, lowercase host) — two catalogs listing the same normalized homepage link automatically, `linkedVia: "homepage"`.
3. **Manual curation.** Anything neither automated pass resolves is either hand-linked (`linkedVia: "curated"`, same author-drafts/human-reviews workflow as the category taxonomy) or left unlinked — an unlinked candidate is not an error, it's simply not yet part of the guide.

Version-scheme plausibility (the original tell that surfaced this whole problem) has no runtime role. It's a note for whoever is authoring/reviewing `curated` links: wildly divergent version numbers across "the same" name is a hint to check more carefully before manually linking, not something the build script computes or enforces.

## Query-Time Integration

`Resolve-DFCatalogQueryMerge`'s grouping key changes:

- A cross-catalog pair merges into one row when **either** identity source (live `Tools/*.json` IdentityMap, or the loaded tool-identity guide) links them, **or** they are the literal same `(source, packageId)`.
- **Bare name-string matching across different sources is removed entirely as a grouping key.** This is the one explicit trade-off signed off on during design: today's naive behavior gives a free unified row to the common case (two catalogs legitimately sharing an exact name — most collisions are legitimate). Under this design, any tool not yet covered by either identity source shows as separate rows until it's added. This is intentional: correctness over convenience, with coverage improving over time via the same content-authoring model as the category database, never by loosening the query-time safety bar.
- Hits from the **same single source** with the same name are unaffected (grouping same-source duplicates was never an identity question).

## Refresh

`Update-DFToolIdentityGuide` (new public command) mirrors `Update-DFCategoryDb` exactly: downloads the latest published `data/tool-identities.json` release asset, validates it against the schema, writes atomically to `$XDG_DATA_HOME/dotforge/tool-identities.json`, never runs implicitly, standard `-WhatIf`/`ShouldProcess` support.

## Build Tooling

`build/Build-DFToolIdentities.ps1` (author-side, not shipped) mirrors `Build-DFCategoryDb.ps1`: merges `build/identities/*.jsonc` fragments, enforces the uniqueness constraint, validates the merged document against the schema, emits `data/tool-identities.json` sorted and pretty-printed. A companion resolution helper (reusable, not a new dependency) drives the automated repo/homepage matching passes described above, consuming the same per-catalog detail fetchers the trifle detail-view feature already ships.

## Error Handling

- Missing/corrupt shipped or refreshed guide degrades to "guide has zero entries" — `Tools/*.json`'s live IdentityMap still functions independently, so curated-tool merging is never affected by a guide failure. Warns once per session, never throws.
- A `(source, packageId)` pair appearing in both `Tools/*.json` and the guide with **conflicting** tool keys is a data inconsistency — the live `Tools/*.json` mapping wins (it's the more authoritative, actively-maintained source), and this should be flagged via `Write-Verbose` for anyone debugging, not surfaced as a user-facing warning.

## Testing (Pester 5)

- Schema validator: required fields, `linkedVia` enum, uniqueness-constraint violations.
- Loader: shipped/refreshed precedence and two-tier fallback (identical pattern to `Get-DFCategoryDb`'s already-tested behavior).
- Build script: repo-match linking (mocked detail fetchers), homepage-match linking with URL normalization edge cases (scheme, trailing slash, `www.`), duplicate `(source, packageId)` detection, `curated` entries preserved verbatim across a rebuild that also runs the automated passes.
- Query-time integration: a guide-linked pair merges into one row; an unlinked same-name pair splits into separate rows; a `Tools/*.json`-curated pair still merges via the live path independent of guide state; a `(source, packageId)` conflict between the two sources resolves in `Tools/*.json`'s favor.

## Out of Scope / Future

- Install-status verification (Spec B, sequenced next).
- Automated gathering pipeline scaling the guide toward full CLI-tool-union coverage (parallels the category database's own deferred phase-2 pipeline).
- Non-GitHub repository resolution.
- Periodic drift re-verification of `repo`/`homepage`-linked entries (packages can change their declared repo/homepage over time; today's design links once at authoring time and doesn't re-check).
