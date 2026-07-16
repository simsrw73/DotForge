# Package Universe — Phase B: Identity Clustering — Design

**Date:** 2026-07-16
**Status:** Implemented and validated against live data 2026-07-16. Stage 0 re-acquired
30,251 rows with 100% `extra` population and zero errors; Stage 1 clustering over the enriched
corpus produced 3,847 clusters (max size 10) covering 9,200 members, 3,241 review candidates, and
235 monorepo/vendor families flagged for review. Ground truth (`bat`/`fd`/`ripgrep`) clusters
correctly. The **monorepo/vendor-family guard** below was added during implementation after a live
run exposed repo/homepage over-merging (nerd-fonts: 280 fonts, one repo; `dot.net/core`: 108 distinct
packages, one URL) — see that section and Rejected Alternatives.

**Part of:** the cross-catalog package-index effort (identity linking + metadata merge + categorization).
Phase A (catalog acquisition) is complete and validated live. This spec covers **Phase B: identity
clustering** — linking the same real-world application across scoop/winget/choco. It is split into two
stages: **Stage 0**, a full-fidelity capture amendment to Phase A acquisition (a prerequisite that turned
out to be acquisition work), and **Stage 1**, the clustering itself.

**Scope note (locked with the user, 2026-07-16):** this spec covers **offline clustering of
scoop+winget+choco only**. The search-and-validate cross-references into npm/crates/pypi/psgallery/gem
that the Phase A spec listed under "Phase B" are **deferred to their own later spec** (Phase B-ext) —
they are live, rate-limited crawls of five more ecosystems, a different beast from offline linking.

## Problem

Phase A produced `raw_packages` — 30,251 packages across scoop (5,286), winget (13,763), choco (11,202) —
but every catalog names the same tool differently (`bat` is scoop `bat`, winget `sharkdp.bat`, choco
`bat`). Nothing links them. DotForge already links catalog identities for **28 curated tools** (the
`Tools/*.json` `packages` blocks → `data/tool-identities.json`), but the universe has ~30k packages. Phase
B generalizes that linking to the whole universe, with a **confidence score per link**, a **human-review
loop**, and a **durable curation layer** so verified judgments accumulate and harden the clusters over
successive runs.

The generalization must not repeat a known failure. The curated layer's `trifle zed` bug merged winget's
`Zed.Zed` (the editor) with choco's unrelated `zed` (a SpiceDB tool) on a **bare name match**
(`CHANGELOG.md`, "trifle cross-catalog identity fix"). **Bare name matching across catalogs is known-broken
and is not a cluster-forming signal in this design.**

## Goals

- Link packages that are the same real-world tool across scoop/winget/choco, each link carrying a
  `method` and a numeric `confidence`, stored as a pairwise evidence graph.
- Compute clusters as a **reproducible view** (union-find) over that graph — never hand-edit clusters.
- Provide a **durable, version-controlled curation layer** for human verdicts (confirmed-same *and*
  confirmed-different), applied on every run, that survives the regenerable database.
- Surface ambiguous/low-confidence candidates to a review queue without ever auto-merging them.
- Capture **every** field every catalog supplies (Stage 0), for manual review and unknown future use.

## Non-Goals

- **External-ecosystem cross-refs** (npm/crates/pypi/psgallery/gem) — deferred to Phase B-ext.
- **Metadata merge** across a cluster (Phase C) and **categorization** (Phase D).
- **Official-vs-third-party derivation** — the *inputs* are captured in Stage 0, but the derivation is a
  Phase C computation (see Officialness, deferred).
- **Fuzzy/edit-distance name matching** — only exact normalized-key equality is used; fuzzy matching is a
  precision hazard not justified by the measured reach.
- **README/repo mining for install commands** — rejected (see Rejected Alternatives).

## Pipeline Context

Phase B writes into the same shared `universe.db` (Phase A convention), adds its own tables, uses
`stage='link'` in the shared `pipeline_log` (value already reserved), and is independently runnable and
testable via a new `build/Build-DFPackageUniverseLinks.ps1`, mirroring the Phase A script.

## Measured evidence (gathered 2026-07-16 against the live `universe.db`; justifies every design choice)

| Signal | Multi-source groups | Notes |
|---|---|---|
| GitHub `owner/repo` agreement (≥2 sources) | 909 | 196 tri-catalog, 679 dual |
| `publisher`+`name` agree **and** share a repo | 345 | independently corroborated |
| `publisher`+`name` agree, no repo to check | 756 | recall gain — **winget↔choco only** |
| `publisher`+`name` agree, repos differ | 9 | ~0.1% — mostly repo-moves/forks |
| `name-only` new linkage beyond the above | 2,817 | **2,778 bridge scoop↔other** |
| ‣ repo-corroborated / conflict / unverifiable | 643 / 94 / 2,080 | conflicts = true collisions + forks |

Row coverage: repo-only **2,514**; union (repo + publisher+name) **4,339 (14.3%)**. Key facts these
numbers establish:

- **Full-path `owner/repo` is safe; bare host is not.** `www.nirsoft.net` is the homepage of **636
  distinct tools**; bare-host matching would fuse them — the `trifle zed` failure at scale. Path-preserving
  keys (github `owner/repo`, normalized full-URL homepage) do not have this problem.
- **`publisher`+`name` cannot reach scoop.** Scoop's `publisher` column is always NULL, so a
  `(publisher, name)` key structurally links only winget↔choco (measured: of 1,110 such groups, exactly
  **3** touch scoop). Reaching scoop by name requires a **name-only** key — hence the name-only tier.
- **Name-only is high-reach but the noisiest signal**, so it is **review-only** (below). Its 94 repo-conflict
  cases are exactly the collisions worth catching: `air` (`air-verse/air` Go reloader vs `posit-dev/air`
  R formatter), `cemu` (calculator emulator vs Wii-U emulator), `chatgpt` (three unrelated apps).
- **Version must never key identity.** Repo-corroborated same-tool pairs carry different versions and even
  formats across catalogs: `zoxide` 0.10.0/0.9.2, `Servy` 8.6/8.6.0, `WinPaletter` 1.0.9.8/1.0.98.

---

## Stage 0 — Full-fidelity capture (Phase A acquisition amendment)

Phase A hard-codes `extra = $null` in all three mappers, discarding most source fields — including the
repo signals that most improve linking. Stage 0 serializes each package's **complete source-native field
set** into `extra` (JSON object). Typed columns are unchanged. All offline **except a choco re-walk**
(user-authorized; ~281 requests, ~21 min).

- **choco** (`build/Private/DFPackageUniverse.Choco.ps1`): the walk feed and the detail feed project the
  **same `<m:properties>` element** — the detail mapper (`Private/DFCatalog.Choco.ps1:156`) reads `$props`
  exactly as the walk mapper (`:38`) does — so the rich fields ride the walk we already do. Capture the
  full property bag plus the four feed-customized fields remapped onto Atom elements
  (`Id`→`<title>`, `Authors`→`<author><name>`, `LastUpdated`→`<updated>`, `Summary`). Newly captured, of
  which `ProjectSourceUrl` is the load-bearing repo URL: `ProjectSourceUrl`, `PackageSourceUrl`, `DocsUrl`,
  `BugTrackerUrl`, `MailingListUrl`, `IconUrl`, `ReleaseNotes`, `Copyright`, `DownloadCount`,
  `Dependencies`, `Published`. **Verify against one live walk page before the full run** — the code carries
  a standing "verify against live" note near the detail mapper.
- **winget** (`build/Private/DFPackageUniverse.Winget.ps1`): capture the whole default-locale + version
  manifest — `PublisherUrl`, `PublisherSupportUrl`, `ReleaseNotesUrl`, `ReleaseNotes`, `Documentations`,
  `Moniker`, `Author`, `Copyright`/`CopyrightUrl`, `LicenseUrl`, `PrivacyUrl`, `PurchaseUrl`. **Fully
  offline** from the on-disk snapshot. Winget manifests carry **no** repo-URL field — an expected asymmetry.
- **scoop** (`Private/DFCatalog.Scoop.ps1` `Build-DFCatalogScoopIndexData`, the upstream discard point, +
  `build/Private/DFPackageUniverse.Scoop.ps1`): capture the whole manifest — high-value **`checkver` /
  `autoupdate`** (frequently name the GitHub repo when `homepage` is a vanity domain), plus `bin`,
  `architecture`/`url`, `depends`, `suggest`, `notes`. **Fully offline** from local buckets.

Align the `extra` JSON key vocabulary to the existing `New-DFToolSourceDetail` record
(`Private/DFCatalog.ps1:337`), which already models `RepositoryUrl`/`DocsUrl`/`ReleaseNotes`/`Downloads`/
`Dependencies`/`Extra`.

Re-run: `./build/Build-DFPackageUniverseRaw.ps1 -WingetPkgsSnapshot ./build/.package-universe/winget-pkgs`.

---

## Stage 1 — Identity clustering (`Build-DFPackageUniverseLinks.ps1`)

### Data Model
```sql
CREATE TABLE identity_links (           -- pairwise evidence graph; rebuilt each run
  id INTEGER PRIMARY KEY,
  source_a TEXT NOT NULL, package_id_a TEXT NOT NULL,
  source_b TEXT NOT NULL, package_id_b TEXT NOT NULL,
  method TEXT NOT NULL,      -- 'curated' | 'repo' | 'homepage' | 'publisher-name' | 'name-only' | 'conflict'
  confidence REAL NOT NULL,  -- 0.0..1.0
  evidence TEXT,             -- JSON: the matched key
  linked_at TEXT NOT NULL,
  UNIQUE(source_a, package_id_a, source_b, package_id_b, method)
);
CREATE TABLE identity_clusters (
  cluster_id INTEGER PRIMARY KEY,
  size INTEGER NOT NULL,
  methods TEXT NOT NULL,        -- JSON array of methods present
  min_confidence REAL NOT NULL, -- weakest edge holding the cluster together
  has_curated INTEGER NOT NULL,
  needs_review INTEGER NOT NULL,
  created_at TEXT NOT NULL
);
CREATE TABLE cluster_members (
  cluster_id INTEGER NOT NULL,
  source TEXT NOT NULL, package_id TEXT NOT NULL,
  join_method TEXT NOT NULL, join_confidence REAL NOT NULL,
  PRIMARY KEY(source, package_id)   -- each package in at most one cluster
);
CREATE TABLE curated_links (            -- runtime MIRROR of the curation file (file is source of truth)
  kind TEXT NOT NULL,          -- 'same' | 'different'
  group_id TEXT,               -- for 'same': the curated cluster label
  source TEXT NOT NULL, package_id TEXT NOT NULL,
  note TEXT
);
```
Truncation follows Phase A discipline: each run clears its own four tables + `pipeline_log WHERE
stage='link'`, then rebuilds. Clusters are a reproducible view over the edge graph.

### Signal derivation (reuse existing helpers; read `homepage` **and** enriched `extra`)
- **repo** — GitHub `owner/repo` via `Resolve-DFGitHubRepoUrl`'s regex
  `github\.com[/:]([^/]+)/([^/#?\s]+)` + strip `.git` + lowercase (`Private/Get-DFGitHubRepoInfo.ps1:61`).
  Priority: choco `ProjectSourceUrl` → scoop `checkver`/`autoupdate` github ref → any github `homepage`.
- **homepage** — normalized non-github homepage via `ConvertTo-DFNormalizedHomepage`
  (`Private/Resolve-DFToolIdentityCandidateRepo.ps1:3`; strips scheme/`www.`/trailing slash, lowercases,
  **preserves path**). A bare-domain-only homepage (no path) is too weak → **review**, not an edge.
- **publisher-name** — `(NormPub(publisher), Norm(name))`. `Norm` = lowercase + strip non-alphanumeric;
  `NormPub` additionally strips corporate suffixes (`inc|ltd|llc|gmbh|corp|co|software|…`). Reaches
  winget↔choco only.
- **name-only** — `Norm(name)`, **gated to length ≥ 4** to drop the `ado`/`air`-class short-name collisions.

### Confidence tiers
| method | when | confidence | cluster-forming? |
|---|---|---|---|
| `curated` (same) | in the curation file's confirmed-same group | 1.0 | **yes (seeded first)** |
| `repo` | share github `owner/repo` | 1.0 | yes |
| `homepage` | share normalized homepage **with a path** | 0.75 | yes |
| `publisher-name` | share pub+name, no repo conflict | 0.60 | yes (≥ threshold) |
| `conflict` | share pub+name or name-only but resolve to **different** repos | 0.30 | no → review |
| `name-only` | share name (len ≥ 4), not otherwise linked | 0.20 | **no → review** |

### Clustering (constrained union-find)
1. **Seed** with curation confirmed-same groups (force-union, `method='curated'`).
2. Apply automatic edges in **descending confidence**; union components — but **skip any union that would
   violate a curation confirmed-different (cannot-link) pair**; a skipped edge logs a `review` row.
3. Only edges with `confidence ≥ THRESHOLD` (default **0.60**, parameterized) union. `name-only` (0.20)
   and `conflict` (0.30) never union — they persist in `identity_links` as review candidates.
4. Materialize `identity_clusters` + `cluster_members`; set `has_curated`/`needs_review` accordingly.

### Monorepo / vendor-family guard (added after live validation)
Repo-identity and homepage-identity are **not** tool-identity when one repo or host publishes many
distinct packages. A live run over the real corpus over-merged badly: `ryanoasis/nerd-fonts` fused
280 different fonts into one cluster, and `https://dot.net/core` fused 108 distinct .NET packages —
the O(n²) pairwise blow-up also drove edges from ~10k to ~82k. The `bat`/`air` unit fixtures could
not catch this (one package per repo); only the monorepo shape in production does.

**Policy (user decision, "cap + route to review"):** a repo or homepage group is a *family* when it
has **≥ `FamilySizeThreshold` members (default 5) carrying ≥ 2 distinct normalized names**. Families
are **not auto-merged** — `Get-DFPackageUniverseFamilyGroups` surfaces each one as a
`pipeline_log` (`stage='link'`, `level='review'`) row naming the shared key and size, for a human to
curate (split into per-tool families, or mark as a category). This applies only to the repo and
homepage tiers; publisher-name and name-only groups share one name by construction and are never
families. Small variant groups (e.g. ripgrep's GNU/MSVC winget builds, size < threshold) still
cluster. The guard makes the pipeline err toward **under**-merging (safe, reviewable) over
**over**-merging (silent, wrong) — the same principle as name-only being review-only.

### Curation & review loop (the durable human layer)
- **Source of truth: `data/package-universe-curation.jsonc`** — version-controlled, so it **survives the
  regenerable `universe.db`** (a full rebuild ~54 min recreates the DB; human verdicts are the one artifact
  that cannot be regenerated). Mirrors the existing `data/tool-identities.json` / `build/identities/*.jsonc`
  prior art. Holds `same` groups (verified identical → force-merge) and `different` pairs (verified
  distinct → cannot-link), keyed by durable `(source, package_id)` (verified unique: 30,251 rows, 0 empty).
- Each run loads it, applies it, and **mirrors** it into the `curated_links` table for querying.
- **Review candidates** (`name-only`, `conflict`, curation-skipped edges) → `pipeline_log`
  (`stage='link'`, `level='review'`), conflict-flagged first. A human works the queue and records verdicts
  back into the curation file; the next run applies them and the queue shrinks to only-new. This is the
  review→verify→re-run loop the whole design serves.

### Officialness (deferred to Phase C; inputs captured now)
"Official vs third-party / preferred installer" is derivable offline by comparing a member's
publisher/id-owner to its cluster's canonical repo owner (winget `ajeetdsouza.zoxide` = official; a
community-maintained choco `zoxide` = third-party). Stage 0's full capture already preserves every input
(choco `Authors`, winget `Publisher`/`PackageIdentifier`, repo owner), so this is a cheap Phase C
annotation, not a lost opportunity — it is out of scope for Phase B.

## Error Handling (Phase A conventions)
- **Reconciliation:** every run logs population-vs-emitted counts — rows read, edges by method, clusters
  formed, members clustered, review-queue size — so a silent collapse is visible. A systematic pattern of
  item-level failures is a run-level failure, not N independent skips.
- **Item isolation:** one unparseable `extra`/row logs a `warning` and is skipped; never aborts the run.
- `review`-level entries are not failures.

## Testing (Pester 5)
- Both build scripts call `Set-StrictMode -Version Latest`; **never `-Off`**. Enrichment reads many
  optional/absent fields — use `Get-DFXmlMember`/`Get-DFXmlText` for XML, `$hash['Key']` for dictionaries,
  wrap whole pipelines `@(x | Where-Object {...})`, avoid `.GetNewClosure()` where script-scope functions
  are needed, and filter empty feeds `@(... | Where-Object { $_ })`. (These four traps each caused live
  data loss in Phase A.)
- **Tests must call `Set-StrictMode -Version Latest` themselves** — Pester does not; a mapper can pass
  every test and still throw in production (this gap cost 4,734 winget rows in Phase A).
- **Fixtures must include the sparse/minimal shape**, not just the rich one. No `<angle brackets>` in test
  names (Pester 5 treats them as `-ForEach` placeholders).
- **Ground-truth eval:** assert precision/recall against the **28 curated `Tools/*.json` `packages`
  blocks** (e.g. `bat` = scoop `bat` + winget `sharkdp.bat` + choco `bat` → one cluster). This is the
  regression guard against a future `trifle zed`.
- **Curation tests:** a confirmed-same forces a merge; a confirmed-different blocks an otherwise-valid
  auto-edge (`air`); the file round-trips into `curated_links`.
- **Signal tests:** repo/homepage/publisher-name/name-only derivation against fixtures incl. github
  homepages, vanity-domain-with-checkver, NULL scoop publisher, and a bare-domain homepage (→ review).
- Injectable seams (offline scoop/winget inputs; choco fixture) — no test touches the network.
- One end-to-end test over all-three-catalog fixtures asserting cluster tables + review-queue shape.

## Out of Scope / Future
- Phase B-ext: external-ecosystem cross-refs (npm/crates/pypi/psgallery/gem) — live search-and-validate.
- Phase C: metadata merge, and the officialness/preferred-installer derivation.
- Phase D: categorization/ontology.
- Fuzzy name matching, and any auto-promotion of `name-only` candidates without human review.

## Rejected Alternatives
- **Bare cross-catalog name matching as a cluster-forming signal** — the `trifle zed` bug; over-merges at
  scale (name-only is retained *only* as a review-only, non-clustering candidate tier, gated to len ≥ 4).
- **Bare-host homepage matching** — `www.nirsoft.net` = 636 distinct tools. Only path-preserving homepage
  keys are used, and bare-domain-only matches are demoted to review.
- **Version as part of the identity key** — same tool legitimately differs in version and format across
  catalogs (measured).
- **Curation stored only in a `universe.db` table** — the DB is gitignored and regenerable, so a table-only
  curation store would be destroyed on rebuild, losing irreplaceable human verdicts. The file is the source
  of truth; the table is a runtime mirror.
- **Re-crawling choco *detail* pages (~11k requests) to recover repo URLs** — unnecessary: `ProjectSourceUrl`
  rides the walk feed's `<m:properties>` (verify once live), so a free re-walk suffices.
- **README/repo mining for install commands** — chicken-and-egg (you can only read a README for a repo you
  already have, which is already linked by the repo tier) plus unstructured parsing; rejected.
- **Auto-merging monorepos/vendor families** — repo/homepage over-merges when one repo/host publishes many
  packages (nerd-fonts, dot.net/core). Rejected in favor of the cap-to-review guard above.
- **Name-compatibility gate on repo/homepage edges** (only merge same-repo packages whose names also agree)
  — considered as the family fix and rejected: catalogs name the same tool very differently (nerd-fonts is
  `Hack-NF` on scoop vs `nerd-fonts-Hack` on choco), so a name gate would *under*-cluster genuine matches
  while still needing a size cap. The heterogeneity-size cap is simpler and loses no real links.
- **Accept large clusters and flag them** (keep the over-merges, mark heterogeneous ones `needs_review`) —
  rejected: leaves ~6,800 members mis-clustered until hand-curated; the cap prevents the bad merge up front.
