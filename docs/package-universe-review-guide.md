# Package-Universe Review Guide

**Audience:** whoever is periodically working through the human-review backlog
the package-universe pipeline (Phases A–D) generates. Snapshot numbers below
are from `build/.package-universe/universe.db` as of 2026-08-02; re-run the
queries to get current counts.

## Scope

The package-universe pipeline (`docs/superpowers/specs/2026-07-1[3-7]-package-universe-*-design.md`)
builds a merged, categorized index of ~25,460 real-world CLI/GUI tools across
winget/choco/scoop. Three of its four phases produce a **review queue** —
machine output the pipeline isn't confident enough to trust unsupervised —
and each queue has a different resolution mechanism. This doc is the
"where do I look, what do I decide, where does the decision go" reference
across all of them. It does **not** cover `Tools/*.json` (the ~38 curated,
shipped tools) or their generated companions (`data/tool-identities.json`,
`data/tool-categories.json`) except to explain how they relate — see
[Downstream shipped artifacts](#downstream-shipped-artifacts).

## The shared pattern

Every review queue in this pipeline works the same way:

1. A build script logs a `review`-level row to `pipeline_log` (or, for Phase C,
   a flag on the `tools` row itself) when it can't resolve something
   confidently.
2. A human works the queue and records a **verdict** in a **version-controlled
   file** (never only in `universe.db` — that database is gitignored and gets
   rebuilt from scratch; a verdict that isn't in a committed file is destroyed
   on the next rebuild).
3. Re-running the phase's build script loads that file, applies the verdicts,
   and the queue shrinks to only genuinely-new candidates.

Everything below is a variation on that loop.

---

## Phase B — Identity clustering review

**Queue:** `pipeline_log` where `stage='link'` and `level='review'`. **4,983
rows currently unworked** — this queue has never been touched.

**What it's asking:** Phase B links matching packages across winget/choco/scoop
into one "tool" by similarity signals (shared repo, name proximity). A
`review` row is a *conflict candidate* — two packages the signals think might
be the same tool, but not confidently enough to auto-merge.

**Look at the queue:**
```powershell
Import-Module PSSQLite
Invoke-SqliteQuery -DataSource build/.package-universe/universe.db -Query @'
SELECT source, package_id, message FROM pipeline_log
WHERE stage='link' AND level='review'
ORDER BY logged_at LIMIT 50
'@
```
Each row looks like: `choco cerebro conflict candidate vs winget:AlexandrSubbotin.Cerebro (alexandrsubbotin|cerebro)`.

**Record your verdict** in `data/package-universe-curation.jsonc` (currently
empty — this is the *entire* file's job). The file's own header comment has
the exact shape; summary:
```jsonc
"same": [
  { "id": "cerebro", "members": [
    { "source": "choco",  "package_id": "cerebro" },
    { "source": "winget", "package_id": "AlexandrSubbotin.Cerebro" }
  ] }
],
"different": [
  { "note": "why they're actually different", "members": [
    { "source": "...", "package_id": "..." },
    { "source": "...", "package_id": "..." }
  ] }
]
```
`"same"` force-merges into one cluster. `"different"` is a permanent
cannot-link that overrides a signal that would otherwise merge them.

**Apply it:** `./build/Build-DFPackageUniverseLinks.ps1` (re-run Phase B; it
reloads `-CurationPath` every time). Downstream Phase C/D re-runs pick up the
new clustering automatically.

---

## Phase C — Tool merge review

**Queue:** the `tools` table's own `needs_review`/`review_reasons` columns
(no `pipeline_log` queue, no curation file). **283 tools currently flagged.**

**What it's asking:** when Phase C merges catalog entries into one canonical
tool row, some fields need a single answer (currently: `license`). If members
disagree after normalization, Phase C sets `needs_review=1` and records why —
e.g. `license-conflict: BSD-3-Clause | Apache-2.0`. This is **informational
only, not a durable-verdict workflow**: there is no curation file, and the
flag is recomputed fresh on every Phase C run. Treat it as "double-check the
displayed license before trusting it downstream," not a backlog to clear.

```powershell
Invoke-SqliteQuery -DataSource build/.package-universe/universe.db -Query @'
SELECT tool_id, name, review_reasons FROM tools WHERE needs_review=1 LIMIT 50
'@
```
If a genuine identity error is causing the conflict (two actually-different
tools got merged), that's a **Phase B** problem — fix it in
`package-universe-curation.jsonc` instead, not here.

---

## Phase D — Categorization review

**Queue:** `pipeline_log` where `stage='categorize'` and `level='review'`.
**3,045 rows** — 3,017 `nothing_fits` (the classifier couldn't find a good
category, tagged with `suggested_terms`) plus low-confidence/web-sourced rows.

This phase has **two distinct kinds of review**, and they go to different
places. Do the vocab-gap pass first — it's the higher-leverage one and
directly reduces the individual-row backlog.

### 1. Vocab-gap promotion (do this first)

`suggested_terms` recur — the same missing category gets suggested by dozens
of unrelated tools. Reviewing 3,045 rows one at a time is the wrong shape.

**Use the helper:** `./build/Invoke-DFPackageUniverseVocabReview.ps1` —
aggregates `suggested_terms` by frequency (excluding anything already
decided), walks you through the list one term at a time, and on promote:
inserts the value into the right vocab file (comment-preserving — see
`Add-DFPackageUniverseVocabValue` in
`build/Private/DFPackageUniverse.VocabReview.ps1`), clears every affected
tool's cached classification so it's picked up on the next Phase D run, and
records the decision in `data/package-universe-vocab-decisions.jsonc` so the
term never resurfaces. On reject, it just records that and moves on. Run it,
answer its prompts, then:
```powershell
git add data/package-universe-vocab-decisions.jsonc build/categories/*.jsonc
./build/Build-DFPackageUniverseCategories.ps1   # re-classifies the cleared tools
```

Real snapshot of the top candidates you'd see (as of 2026-08-02, before any
were promoted): `browser-extension` (42), `chrome-extension` (19),
`font-manager` (16), `game-launcher` (13), `game-client` (9), `daw-plugin` (9),
`audio-plugin` (8), `game-mod-manager` (7), `antivirus` (7). These read as
genuine, well-formed gaps (extensions, fonts, gaming, audio production,
security) — a `gaming`/`security` `domain` split already exists in
`build/categories/domains.jsonc`, but the fine-grained `function` values
(`browser-extension`, `font-manager`, `daw-plugin`, …) don't exist yet.

If you want to inspect the raw aggregation yourself without the interactive
flow (e.g. to plan a session before running it), the same query the tool runs:
```powershell
Invoke-SqliteQuery -DataSource build/.package-universe/universe.db -Query @'
SELECT suggested_terms_json FROM tool_classifications
WHERE nothing_fits=1 AND status='done' AND suggested_terms_json != '[]'
'@ | ForEach-Object { $_.suggested_terms_json | ConvertFrom-Json } |
  Group-Object | Sort-Object Count -Descending | Select-Object -First 30 Name, Count
```

### 2. Individual low-confidence / web-sourced rows

For the remainder — genuinely thin-signal tools, not a recurring vocab gap —
spot-check and correct directly:
```powershell
Invoke-SqliteQuery -DataSource build/.package-universe/universe.db -Query @'
SELECT cache_key, domain, function_json, confidence, signal_source
FROM tool_classifications WHERE nothing_fits=1 OR confidence < 0.5
LIMIT 50
'@
```
To fix one row by hand, `UPDATE tool_classifications SET domain=..., function_json=... WHERE cache_key=...`
(match the JSON-array-string shape already in the column), then re-export so
the fix survives a rebuild:
```powershell
Get-ChildItem build/Private -Filter '*.ps1' | ForEach-Object { . $_.FullName }
Export-DFPackageUniverseClassifications -DatabasePath build/.package-universe/universe.db -Path data/package-universe-classifications.jsonc
```
**Always commit `data/package-universe-classifications.jsonc` after any manual
DB edit** — it's the source of truth; the table is a mirror. An edit that
never gets exported is lost on rebuild.

---

## Downstream shipped artifacts

Two files look related but are **generated from different, smaller,
hand-curated inputs** — not from the package-universe pipeline above (yet):

- **`data/tool-identities.json`** — cross-catalog identity links for the ~38
  curated `Tools/*.json` tools, built by `./build/Build-DFToolIdentities.ps1`
  from `Tools/*.json` + optional `build/identities/*.jsonc` fragments,
  auto-verified against live catalogs/GitHub. No review queue; check by
  running the build script and reading its output.
- **`data/tool-categories.json`** — the *shipped* trifle category database
  (~72 hand-curated tools) that `trifle -Category` actually reads at runtime,
  built by `./build/Build-DFCategoryDb.ps1` from `build/categories/*.jsonc`
  fragments. This is the file the Phase D design spec says will **eventually
  be generated from the package-universe classifications** instead of hand-curated
  (retiring the 72-tool seed) — but that export/promotion step is explicitly
  **Plan 2, not built yet**. Today, editing `build/categories/dotforge-curated.jsonc`
  or `extras.jsonc` directly (then re-running `Build-DFCategoryDb.ps1`) is
  still how this file grows.

## Browsing the live data through trifle (preview, not shipped)

You don't have to wait for Plan 2's shipped-db promotion to actually *see*
the classifications in the real `trifle` UI. `Get-DFCategoryDb` already has a
built-in override: if `$Env:XDG_DATA_HOME/dotforge/tool-categories.json`
exists and is newer than the shipped copy, it wins automatically (with
fallback to shipped on any schema failure) — the same slot
`Update-DFCategoryDb` writes a real published release into.
`./build/Export-DFPackageUniversePreviewCategoryDb.ps1` writes the *live*
package-universe classifications into that exact slot:
```powershell
./build/Export-DFPackageUniversePreviewCategoryDb.ps1
# then, in a fresh shell (or Get-DFCategoryDb -Force):
Get-DFCategoryList
trifle -WorksWith uuid
```
This never touches the real shipped `data/tool-categories.json` — to go back
to the small hand-curated seed, delete the written file. Only classifiable
tools are included (valid `interface`, non-empty `function` — ~99% of the
universe); colliding tool names (~1,500 distinct names shared by genuinely
different real-world tools, e.g. "signal", "git") are disambiguated with a
`(tool_id)` suffix rather than silently overwriting each other.

**Known scale caveat:** `Find-DFPackage -Category`/`-WorksWith` resolves
*every* matching tool through a real, sequential catalog query (per-tool, no
batching) — fine for the shipped ~78-tool seed, but a category like
`game-client` (293 tools in the full universe) can take minutes. Prefer
`Get-DFCategoryList` for browsing counts/shape, and reach for `-Category`
mostly on facets with a smaller live count until this gets a fast path (or a
`-Limit`) for large result sets — a real Plan-2-adjacent follow-up, not
something to work around per-query.

---

## Should you build a helper tool?

My read, based on the actual queue shapes above:

**Worth building — a vocab-gap promotion helper. Built:
`./build/Invoke-DFPackageUniverseVocabReview.ps1`.** The categorize queue
*looks* like 3,045 rows but is really ~30–50 distinct recurring terms once
aggregated — reviewing it row-by-row is the wrong shape entirely. Rather than
pull in `Invoke-DFPicker` (fzf), it uses a plain numbered `Read-Host` menu —
the list is short enough (~30-50 items) that fzf's fuzzy-search value doesn't
pay for the extra dependency, and it keeps this build script self-contained
the way the rest of `build/*.ps1` already is (no dependency on the shipped
module). On promote, it inserts the value into the vocab file
(comment-preserving, `Add-DFPackageUniverseVocabValue`), clears every
affected tool's cached classification, and records the decision durably so
the term never resurfaces — turning a tedious, error-prone manual process
into a five-minute one.

**Plausibly worth it — a same/different picker for Phase B.** 4,983 candidates
is a lot to hand-edit `curation.jsonc` for, and each entry risks a JSON syntax
slip at that volume. A picker that shows each conflict candidate's info side
by side and appends the verdict on keypress would meaningfully de-risk this,
though it's more work than the vocab helper since each decision is genuinely
case-by-case (not aggregable).

**Not worth it — everything else.** Phase C's queue is informational-only by
design (no verdict to record). Individual Phase D corrections are rare,
one-off judgment calls where a raw `UPDATE` + re-export is simpler than any
UI you'd build around it. And the identity/category-db builds already have no
queue at all — reviewing their output is "run the script, read the diff."

I'd start with the vocab-gap helper alone, use it for a round or two, and only
build the Phase B picker if 4,983 manual entries actually turns out to be as
painful in practice as the row-count suggests — it might not be, if most
candidates get worked in short focused sessions rather than all at once.

---

## Quick reference

| Phase | Queue location | Verdict file | Apply |
|---|---|---|---|
| B (identity) | `pipeline_log` `stage='link' level='review'` | `data/package-universe-curation.jsonc` | `./build/Build-DFPackageUniverseLinks.ps1` |
| C (merge) | `tools.needs_review`/`review_reasons` | *(none — informational)* | *(recomputed every run)* |
| D (categorize) | `pipeline_log` `stage='categorize' level='review'` | `build/categories/{domains,taxonomy}.jsonc` + `data/package-universe-vocab-decisions.jsonc` (vocab) or direct `UPDATE` + export (individual) | `./build/Invoke-DFPackageUniverseVocabReview.ps1` (vocab), then `./build/Build-DFPackageUniverseCategories.ps1` |
