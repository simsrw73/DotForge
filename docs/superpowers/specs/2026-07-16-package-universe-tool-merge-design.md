# Package Universe — Phase C: Tool Merge (Cluster Flattening) — Design

**Date:** 2026-07-16
**Status:** Designed. Not yet implemented.

**Part of:** the cross-catalog package-index effort (identity linking → **tool merge** → officialness →
categorization). Phase A (catalog acquisition) and Phase B (identity clustering) are complete and
validated live. This spec covers **Phase C: tool merge** — flattening each Phase B cluster (and every
unclustered singleton) into one row in a master `tools` table, losslessly, so the universe becomes a
queryable list of real-world tools rather than a graph over catalog packages.

**Scope note (locked with the user, 2026-07-16):** this phase is a **structural flattening plus a
first-pass category derivation**. It explicitly does **not** derive officialness / the true code author,
and it does **not** build a category ontology — both are deferred to Phase D. The one concession beyond
pure flattening is a basic keyword→category derivation from metadata already captured, because the
category signals are already sitting in the merged children and trifle discovery needs *something* now.

## Problem

Phase B produced an **identity graph**: `identity_clusters` + `cluster_members` say "these N catalog
packages are the same real-world tool." But there is no single row you can read to answer "what *is* this
tool, and where can I get it?" Every field still lives in its per-catalog `raw_packages` row. The two known
consumers both need a flattened record:

1. The **trifle detail card** — show the tool, which package managers offer it, under what install id, and
   its install status.
2. **trifle discovery** — filter tools by category (and, later, by "alternatives"), where categories are
   read from or derived from the metadata already captured.

Phase C flattens the universe into a master **`tools`** table: **exactly one row per real-world tool,
covering the entire corpus** — not just the multi-source clusters but every unclustered singleton too — so
that every one of Phase A's 30,251 packages is accounted for, none appearing in more than one tool row, and
**no source data is lost**.

## Goals

- Produce a master `tools` table with **one row per real-world tool**, spanning clusters *and* singletons,
  such that every package appears in exactly one tool.
- **Lose no data.** Every source field (typed columns *and* the full Stage-0 `extra` bag) is preserved on a
  one-to-many child table; the flattening relocates data, it never discards it.
- Make the parent row **directly renderable** by the trifle card (canonical display scalars) and its
  provenance visible (which package managers, which install ids).
- Make discovery a **first-class relational query** — tags and categories broken into indexed child tables,
  never substring-scanned out of a JSON blob.
- **Resolve or flag single-answer conflicts.** A field that should have exactly one true value (license)
  and doesn't, after normalization, is flagged for human review rather than silently picked.
- Derive a **first-pass category** per tool from already-captured metadata via a committed, growable rule file.

## Non-Goals

- **Officialness / preferred-installer / true code-author derivation** — Phase D. The *inputs* are captured
  (choco `Authors`, winget `Publisher`/`PackageIdentifier`, repo owner via `repo_url`), but reconciling
  "who wrote the code" and "which package is the official one" is intertwined with officialness and is
  deferred. See Rejected Alternatives (publisher on the parent).
- **Category ontology / reconciliation with the curated trifle category-db** — Phase D. Phase C ships only a
  coarse keyword→category rule file.
- **Metadata *enrichment*** — Phase C merges what Phase A/B already captured; it fetches nothing.
- **External-ecosystem sources** (npm/crates/pypi/psgallery/gem) — Phase B-ext, unchanged by this phase.
- **Fuzzy matching / re-clustering** — Phase C trusts `cluster_members` verbatim; it does not re-link.

## Pipeline Context

Phase C writes into the same shared `universe.db` (Phase A/B convention), adds its own tables, uses a new
`stage='merge'` value in the shared `pipeline_log`, and is independently runnable and testable via a new
`build/Build-DFPackageUniverseTools.ps1`, mirroring the Phase A and Phase B scripts. It reads
`raw_packages` and `cluster_members` and the new category rule file; it re-reads nothing over the network.

## Key facts this design rests on (established in Phase A/B, verified in the code)

- **Winget's `name` column already holds the friendly display name.** `DFPackageUniverse.Winget.ps1:172`
  sets `name = PackageName` (`bat`), while `package_id` is the `PackageIdentifier` (`sharkdp.bat`, winget's
  disambiguation key). So "prefer the winget name" reads straight off the typed column; the dotted id is an
  install id that belongs on the child row, not the display name. (`winget show sharkdp.bat` →
  `Found bat [sharkdp.bat]` confirms the split.)
- **Clusters are inherently multi-source.** Phase B emits only cross-source edges, so every cluster has ≥2
  sources. Therefore a package is either in `cluster_members` (→ merge its cluster) or it is not (→ it is a
  one-package tool). The set difference **is** the singleton set — singletons need no separate detection.
- **Every source field is already captured.** Stage 0 of Phase B serialized each package's complete
  source-native field set into `raw_packages.extra`, so "no data lost" is satisfiable by *copying* the child
  rows verbatim; the merge only has to pick a handful of display scalars on the parent.
- **The repo authority already exists.** `Get-DFPackageUniverseRepoKey` (Phase B) resolves the canonical
  GitHub `owner/repo` with the priority choco `ProjectSourceUrl` → scoop `checkver`/`autoupdate` → github
  homepage. Phase C reuses it verbatim so the merged `repo_url` cannot diverge from the clustering authority.
- **Publisher is packager-identity, not authorship.** choco `Authors` is frequently the *packager*; winget
  `Publisher` is the author only for official packages; scoop has no publisher. Cross-catalog publisher
  disagreement is therefore common and benign — it is the official-vs-third-party signal Phase D resolves —
  so publisher is **not** reconciled onto the parent here (it stays per-catalog on the child).

## Data Model

```sql
CREATE TABLE tools (                    -- the master table: exactly one row per real-world tool
  tool_id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,                   -- canonical display name (winget PackageName > choco title > scoop name)
  name_source TEXT,                     -- provenance of the picked name: 'winget'|'choco'|'scoop'
  description TEXT,                     -- richest description (winget > choco > scoop, first non-null)
  description_source TEXT,
  homepage TEXT,                        -- canonical homepage (winget > choco > scoop, first non-null)
  repo_url TEXT,                        -- canonical repo via Get-DFPackageUniverseRepoKey (choco ProjectSourceUrl > scoop checkver/autoupdate > github homepage)
  license TEXT,                         -- priority-picked display license (winget > choco > scoop)
  source_count INTEGER NOT NULL,        -- distinct package managers offering it (1 = singleton)
  cluster_id INTEGER,                   -- Phase B cluster this came from; NULL for singletons
  needs_review INTEGER NOT NULL,        -- 1 if a single-answer field conflicted (currently: license)
  review_reasons TEXT,                  -- JSON array of reasons, e.g. ["license-conflict: MIT | Apache-2.0"]
  created_at TEXT NOT NULL
);
CREATE TABLE tool_packages (            -- one-to-many: every catalog appearance of the tool. LOSSLESS store.
  tool_id INTEGER NOT NULL,
  source TEXT NOT NULL,                 -- 'scoop'|'winget'|'choco'
  package_id TEXT NOT NULL,             -- per-catalog install id (winget PackageIdentifier, scoop bucket/name, choco id)
  name TEXT, version TEXT, description TEXT, homepage TEXT, license TEXT, publisher TEXT,
  extra TEXT,                           -- verbatim source-native field bag from Stage 0 — nothing dropped
  PRIMARY KEY(source, package_id)       -- each package belongs to exactly one tool
);
CREATE TABLE tool_tags (                -- normalized tag union across the tool's packages (indexed for discovery)
  tool_id INTEGER NOT NULL,
  tag TEXT NOT NULL,                    -- normalized: lowercased, trimmed
  PRIMARY KEY(tool_id, tag)
);
CREATE TABLE tool_categories (          -- first-pass derived categories (keyword->category rule file)
  tool_id INTEGER NOT NULL,
  category TEXT NOT NULL,
  PRIMARY KEY(tool_id, category)
);
```

- **`tool_packages` is the lossless backing store.** Every member row's typed fields *and* its full `extra`
  land here, so the no-data-lost contract is enforced by copying, not merging-away. Publisher lives here (it
  is per-catalog packager identity), never on the parent.
- **`tools` is a view convenience.** Each display scalar is a documented pick with a `_source` provenance
  column where the field is contested (name, description), so nothing is silently chosen.
- **`tool_tags` / `tool_categories` are broken out for safe set queries.** Discovery filters ("every tool
  in category `editor`") are indexed joins, not `LIKE '%editor%'` substring scans — the same false-match
  hazard (`www.nirsoft.net` = 636 tools) that shaped Phase B's key design.
- **Truncation** follows Phase A/B discipline: each run clears its own four tables + `pipeline_log WHERE
  stage='merge'`, then rebuilds. The whole table set is a reproducible function of `raw_packages` +
  `cluster_members` + the category rule file.

## Merge Algorithm

The phase is a **deterministic reduction** over three inputs (`raw_packages`, `cluster_members`, the
category rule file) with no network and no ordering hazard: same inputs → identical `tools` table.

### Grouping (covers all packages, each exactly once)
1. Load `cluster_members` into a map `(source, package_id) → cluster_id`.
2. Stream `raw_packages`. Route each row by whether its key is in that map: clustered rows accumulate under
   their `cluster_id`; unclustered rows each form their own singleton group. The two partitions are disjoint
   by construction and their union is the whole corpus.
3. **Reconciliation assert:** `Σ (members over all groups) == COUNT(raw_packages)`. A mismatch is a run-level
   failure (a leak), not a silent drop.

### Per-group reduction → one `tools` row + N `tool_packages` rows
- **Copy first, merge second.** Write every member verbatim to `tool_packages` (typed fields + full `extra`)
  *before* picking any parent scalar, so the lossless store exists independent of every merge decision.
- **Scalar picks (per-field priority `winget > choco > scoop`, first non-null):**
  - `name` ← member `name` in priority order (winget's is the friendly `PackageName`); record `name_source`.
  - `description` ← priority order, first non-null; record `description_source`. (Order matches richness:
    winget/choco descriptions are fuller; scoop is terse.)
  - `homepage`, `license` ← priority order, first non-null.
  - `repo_url` ← `Get-DFPackageUniverseRepoKey` over the members (Phase B authority), reconstructed to a
    canonical `https://github.com/<owner>/<repo>`.
- **License conflict flag (single-answer resolution):** collect the *distinct normalized* license values
  across members (normalization folds `MIT` / `MIT License` / SPDX-ish spelling). If more than one distinct
  value survives, set `needs_review = 1` and append `license-conflict: <a> | <b>` to `review_reasons`. The
  displayed `license` still takes the priority pick. Publisher is deliberately **not** conflict-checked
  (benign divergence; Phase D signal).
- **`source_count`** = distinct sources among members; **`cluster_id`** = the Phase B cluster, or NULL.

### Curation carry-through
Phase B already applied `data/package-universe-curation.jsonc` (confirmed-same forced a merge;
confirmed-different blocked one) when it built `cluster_members`. Phase C consumes `cluster_members`
verbatim, so curated verdicts arrive pre-merged and Phase C needs no separate curation logic. Family-guard
members that Phase B left unmerged simply arrive as singletons until a human curates them — correct and safe
(errs toward under-merging, per the Phase B principle).

### Tags
Union across the tool's members: winget `tags` (JSON array column) + choco `Tags` (delimited string in
`extra`) + any scoop tags. Normalize (lowercase, trim), dedup, write to `tool_tags`. Tags are the category
seed *and* the future "alternatives" signal (e.g. `bat`'s tags carry `cat` and `less`), so they are unioned,
never reduced to one source's set.

### Categories (first-pass derivation)
- **Rule file `data/package-universe-categories.jsonc`** (version-controlled, human-growable, mirrors the
  curation-file pattern): a small map of keyword → coarse category (e.g. `grep|search|find → search`,
  `editor|ide → editor`). Loaded and comment-stripped like `Import-DFPackageUniverseCuration`.
- `ConvertTo-DFPackageUniverseCategories` applies the rules to each tool's tag union (and winget `Moniker`
  where present), writing matched categories to `tool_categories`. Unmatched tags yield no category — a tool
  may legitimately have none until Phase D. This is explicitly first-pass; the full ontology and
  reconciliation with the curated trifle category-db are Phase D.

## Error Handling (Phase A/B conventions)
- **Reconciliation:** every run logs population-vs-emitted counts — raw rows in, clusters, singletons, tools
  out, `tool_packages` out, tags, categories, review count — plus the `Σ tool_packages == COUNT(raw_packages)`
  equality, so a silent collapse is visible. A systematic pattern of item-level failures is a run-level failure.
- **Item isolation:** one unparseable `extra`/row logs a `warning` and is skipped; it never aborts the run.
- `review`-level entries (license conflicts) are not failures.

## Testing (Pester 5)
- The build script and every function call `Set-StrictMode -Version Latest`; **never `-Off`**. The tests
  call it too — Pester does not (the Phase A lesson: a mapper can pass every test and still throw in
  production; that gap cost 4,734 winget rows). Merge reads many optional/absent fields — use `$hash['Key']`
  index access, wrap whole pipelines `@(x | Where-Object {...})`, filter empty collections.
- **No-data-lost invariant, asserted as a hard test:** `Σ tool_packages == COUNT(raw_packages)`, and every
  input `(source, package_id)` appears in `tool_packages` exactly once. This is the phase's core contract.
- **Ground truth (`bat`):** one `tools` row; `name='bat'`, `name_source='winget'` (not `sharkdp.bat`); three
  `tool_packages` children (scoop `bat`, winget `sharkdp.bat`, choco `bat`); `description_source='winget'`
  (richest beats scoop's terse line); `repo_url='https://github.com/sharkdp/bat'`; `tool_tags` union includes
  `cat`/`less`; categories per the rule file. Extend to `fd`/`ripgrep` as further guards.
- **Singleton:** a package in no cluster → its own tool row, `source_count=1`, `cluster_id=NULL`, its full
  data intact on the single child.
- **Field resolution + license flag:** winget description wins over scoop's; genuinely conflicting licenses
  ⇒ `needs_review` + reason; `MIT` vs `MIT License` (formatting only) does **not** fire (proves the flag is
  precise, not spelling-noise).
- **Tags:** union across sources, normalized and deduped.
- **Category rules:** a known tag maps to its category; unmapped tags yield no category row.
- **Idempotency:** two consecutive runs produce identical tables (truncate-rebuild).
- Injectable seams: all inputs are DB rows / a fixture rule file — no test touches the network.
- One end-to-end test over an all-three-catalog fixture asserting the four tables' shapes + review queue.

## Verification (end-to-end, evidence before assertions)
1. Full Pester suite from `pwsh -NoProfile`.
2. After a merge run: `SELECT COUNT(*) FROM tools`; singleton count (`SUM(source_count = 1)`); the
   `Σ tool_packages == COUNT(raw_packages)` equality; spot-check `bat`/`fd`/`ripgrep` tool rows and their
   children; sanity-check the license-conflict review-queue size (should be small).

## Files
- **Create:** `build/Build-DFPackageUniverseTools.ps1` (thin orchestrator),
  `build/Private/DFPackageUniverse.Merge.ps1` (grouping / reduction / tags / categories / persistence),
  `data/package-universe-categories.jsonc` (seed keyword→category rules),
  `tests/DFPackageUniverse.Merge.Tests.ps1`.
- **Update:** `CHANGELOG.md` `[Unreleased]`. Build-only — no public module surface, so no README/examples change.

## Out of Scope / Future
- **Phase D:** officialness / preferred-installer / true code-author derivation; category ontology and
  reconciliation with the curated trifle category-db; the "alternatives" feature over the tag union.
- **Phase B-ext:** external-ecosystem cross-refs (npm/crates/pypi/psgallery/gem).

## Rejected Alternatives
- **Publisher/author reconciled onto the parent `tools` row** — rejected: catalog publisher is packager
  identity, not authorship, and cross-catalog disagreement is common and benign (the official-vs-third-party
  signal). Forcing agreement would flood the review queue with non-problems; deriving the true author is
  intertwined with officialness and belongs to Phase D. Publisher stays per-catalog on `tool_packages`; the
  authoritative code-author proxy (repo owner) is already implicit in `repo_url` for Phase D to split out.
- **Tags/categories as JSON columns on the parent** — rejected: discovery would filter by substring scan
  (`LIKE '%search%'`), reintroducing the false-match hazard the whole effort avoids. Broken-out indexed
  child tables make set queries first-class.
- **Categories = normalized tag union verbatim** — rejected: `tool_categories` would duplicate `tool_tags`
  and be as noisy as raw tags. A small controlled keyword→category rule file gives discovery real categories
  now while staying human-growable.
- **Reconciling all ~3,800 tools onto the curated trifle category-db** — deferred: matching the universe onto
  a curated ontology is Phase D ontology work, heavier than the "basic" first-pass this phase commits to.
- **A generic attribute (EAV) table** — rejected as speculative generality: nothing here needs it, and it
  turns every read into a pivot.
- **Re-clustering or fuzzy-matching during the merge** — rejected: Phase C trusts `cluster_members` verbatim;
  re-linking here would fork the identity authority and defeat the reproducibility contract.
