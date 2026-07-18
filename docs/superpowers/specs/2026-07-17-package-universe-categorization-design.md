# Package Universe — Phase D: Categorization & Discovery Enrichment — Design

**Date:** 2026-07-17
**Status:** Designed. Not yet implemented.

**Part of:** the cross-catalog package-index effort (identity linking → tool merge → **categorization**).
Phases A (acquisition), B (identity clustering), and C (tool merge) are complete and validated live.
This spec covers **Phase D: categorization & discovery enrichment** — assigning a curated, multi-axis
category taxonomy (plus related/alternative tools) to every tool in the merged universe, using an LLM
classifier over each tool's own documentation, cached durably so the expensive work runs once per tool
and survives re-runs.

**Why this phase matters most (user framing):** categorization is the project's biggest goal and its
primary differentiator. A cross-catalog package index that can answer "what search tools do I have,"
"what's like `ripgrep`," and "show me networking CLIs" — over the *whole* 25k-tool universe, not a
hand-curated seed — is the payoff the earlier phases were built to enable.

## Problem

Phase C produced a master `tools` table (≈25,000 real-world tools) with a **first-pass keyword category**
derived from a tiny committed rule file — coarse, sparse, and only as good as the hand-written keyword
map. Meanwhile DotForge already ships a **rich, CLI-tuned category taxonomy** (`data/tool-categories.json`,
the trifle discovery-v1 database) — a two-facet `function`/`worksWith` vocabulary with related/alternative
links — but only **~72 tools** are populated, all hand-authored. The gap: we have a good taxonomy applied
to 72 tools, and 25k tools with almost no real categories.

Hand-authoring categories for 25k tools is infeasible (v1 did ~72 by hand). Existing external taxonomies
are a poor fit as a base: **PyPI trove classifiers** are Python-library-shaped, 3–5 levels deep, and
collapse nearly every CLI tool into two nodes; **Gentoo categories** are a better fit (they literally shelve
command-line software) but are a single-axis "shelf location," not a rich facet model. So Phase D **extends
our own taxonomy** and **applies it at scale with an LLM classifier** reading each tool's real documentation.

## Goals

- Assign every tool a **multi-axis category record** — a coarse `domain`, plus the fine `function` and
  `worksWith` facets and `interface` — drawn from a **closed, curated, version-controlled vocabulary**.
- Add **related** and **alternative** tools (`relatedTo` via description embeddings; `alternativeTo` — the
  `bat`→`cat` classic-command mapping — via the LLM).
- **Widest possible coverage** — every tool classified, effort tiered to available signal.
- **Run once per tool, cached semi-permanently**, keyed on a **durable identity** that survives re-runs and
  re-clustering; only genuinely-new or identity-shifted tools ever cost a fresh LLM call.
- Be **resumable, incremental, budget-capped, and resilient** to partial runs — designed to grind over days,
  spaced out, stopped at a budget and resumed later exactly where it left off.
- Become the **source for the shipped trifle category database**, retiring the hand-authored ~72-tool seed.

## Non-Goals

- **A framework-based (LlamaIndex / OntoRAG) RAG stack.** Our task is per-tool *classification into a fixed
  vocabulary*, not retrieval-QA over a corpus, and DotForge's pipeline is PowerShell + SQLite. See Rejected
  Alternatives. OntoRAG's *bottom-up-induction idea* is borrowed (lightweight); its machinery is not.
- **An open-ended / model-invented taxonomy.** The vocabulary is closed at classification time; the model
  can only pick in-vocabulary values (schema-enforced) or flag "nothing fits."
- **Runtime AI in the shipped module.** All LLM work is build-side; the shipped module reads a static
  generated database offline (the trifle-v1 principle, unchanged).
- **External-ecosystem cross-refs** (npm/crates/pypi/psgallery/gem) — still Phase B-ext, independent.
- **Re-clustering or re-merging** — Phase D reads Phase C's `tools` verbatim; it does not re-link.

## Decisions locked during brainstorming (do not re-litigate)

- **Ontology source:** *hybrid* — extend the existing trifle `function`/`worksWith` closed vocabulary as the
  base, plus a new coarse **`domain`** axis (~10–15 values, the "limited set" Gentoo instinct), grown by a
  lightweight bottom-up discovery pass. External taxonomies (Gentoo, PyPI) are reference-only.
- **Classifier:** a **small OpenAI model** (the user has unused OpenAI credit; structured-output/JSON-schema
  mode) for the 25k bulk grind — *not* a meaningful quality drop for constrained classification. A **stronger
  model (Claude)** is reserved for the two low-volume, high-leverage spots: the bottom-up vocab discovery,
  and escalation of low-confidence / "nothing fits" tools.
- **Coverage:** *tiered but widest* — every tool gets a record; effort scales to signal.
- **Any repo host**, not just GitHub. Follow metadata doc pointers (`Documentations`/`DocsUrl`/homepage).
- **Cache = resume state**, keyed on durable identity (not the volatile `tool_id`).
- **Include related/alternatives** in this phase (embeddings + LLM), not a separate phase.
- **Phase D becomes the source** for the shipped trifle category-db, gated by an offline quality bar.
- **Budget-capped, days-long, spaced, resumable, resilient** to partial runs and re-runs.

## Pipeline Context

Phase D reads Phase C's `tools`/`tool_packages` from the shared `universe.db`, adds its own tables, uses a
new `stage='categorize'` in `pipeline_log`, and is independently runnable via a new build script
(`build/Build-DFPackageUniverseCategories.ps1`) mirroring the Phase A–C scripts. The OpenAI API key is read
from the gitignored `.env` (`OPENAI_API_KEY=...`, the same pattern as `PSGALLERY_API_KEY`) — never hardcoded
or committed. All LLM/HTTP work is outward-facing and user-triggered.

---

## §1 — Durable identity & the classification cache

The cache is the backbone of resumability, so its *key* must be stable across re-runs and re-clusterings.
Three granularities, each at the level that fits it:

- **Fetch** (README/docs — the slow, rate-limited part) is deduped **per distinct repo**: a monorepo's
  README is pulled once, not once per member.
- **Classification** is per **tool** (a category describes a tool).
- **Cache key** is the tool's **durable identity signal**, resolved by this ladder:
  1. **Normalized repo URL (any host)** — plus the tool's **normalized name** when a single repo is shared
     by a *split family* (so OpenDsc's four distinct tools, or a monorepo of genuinely different CLIs, do
     not collapse to one classification).
  2. **Normalized homepage** (with a path) — for repo-less tools sharing a vendor page.
  3. The tool's **anchor `(source, package_id)`** — a deterministic member pick (winget > choco > scoop,
     then lexical) — for repo-less singletons.

**Why this survives everything:** `(source, package_id)` is immutable (Phase A); repo URLs rarely change;
none of these depend on the volatile `tool_id` (reassigned every Phase C run by insertion order). Re-running
B→C (the 7zip fold, the choco normalization) recomputes each tool's durable key; an unchanged key is an
instant cache hit. Only genuinely-new or identity-shifted tools cost a fresh LLM call.

**The cache doubles as resume state and provenance.** A run is: *select tools whose durable key has no
classification row → gather input → classify → persist → repeat until the budget is hit or nothing is
unprocessed.* Stop anytime; resume is the same query. Every row records `signal_source`, `confidence`,
`model`, and `classified_at`, so web-derived / low-confidence rows are distinguishable and reviewable.

---

## §2 — Ontology construction (the hybrid)

**Base = our existing closed vocabulary, extended.** Phase D keeps trifle's two facets — `function` (*what
it does*) and `worksWith` (*what it operates on*) — as the authoritative, version-controlled vocabulary
(living where the current one does: `build/categories/*.jsonc` → the generated taxonomy), and **adds a coarse
`domain` axis** (~10–15 fixed values: `dev`, `system`, `network`, `text`, `media`, `security`, `data`,
`productivity`, …). The coarse axis gives discovery a stable high-level browse ("show me networking tools")
above the finer facets, and is the easiest axis for the small model to get right (coarse = reliable). The
classifier only ever picks values that exist in the vocabulary.

**Bottom-up discovery grows the vocabulary — in two human-gated moments:**
- **Bootstrap (one-time, stronger model):** run an OntoRAG-*inspired* but lightweight pass over a *sample*
  (a few hundred diverse tools) — the model extracts candidate category terms from readmes/docs, the terms
  are embedded and clustered, and the human curates the clusters into vocabulary additions. This closes the
  biggest gaps *before* the big grind, so the small model has a good vocabulary on day one.
- **Accretion (ongoing):** every classifier "nothing fits well" result logs the tool + its suggested term as
  a **vocab-gap proposal**. These accumulate; the human periodically promotes good ones into the vocabulary,
  and the affected tools are re-classified. The taxonomy *converges* where the corpus proved it thin.

So the vocabulary is **closed at classification time** (no invented categories) but **growable between
rounds** — the discipline of a curated ontology with the coverage of bottom-up discovery. The "nothing fits"
flag does double duty: a low-confidence marker on the tool *and* the raw material for the next vocab round.

---

## §3 — Classifier & input gathering

**Per-tool input, best-signal-first** (every fetch cached; fetches deduped per repo; polite per-host
rate-limiting; long documents truncated to a bounded context — intro + headings — before the model sees them):
1. **Repo README — any host.** New work: our `repo_url` is GitHub-only, so Phase D needs an **any-host repo
   resolver** (GitHub/GitLab/Bitbucket/Codeberg raw-README endpoints + a generic fallback) mining the repo
   signal from `extra`/homepage across hosts. (This also back-fills Phase C's GitHub-only `repo_url` gap —
   GitLab-hosted tools currently resolve to `NULL` — improving the tool records, not just categories.)
2. **Documentation page** — `Documentations` (winget) / `DocsUrl` (choco) / homepage → fetch HTML → text.
3. **Metadata** — description, tags, moniker, publisher (always present; the floor).
4. **Gated web-search summary** — *last resort only*, for thin-signal tools. Accepted **only if it
   corroborates** something already known (mentions the same publisher/repo/homepage), guarding against the
   wrong-tool-retrieval failure (search "air" → Go reloader vs R formatter vs Adobe AIR). Always recorded as
   `signal_source='websearch'`, low-trust, routed to review — never trusted blindly.

**The classification call** (small OpenAI, structured JSON-schema output) takes
`{name, publisher, description, tags, moniker, doc excerpt}` + the current closed vocabulary, and returns:
```
{ domain: <one vocab value>, function: [<vocab values>], worksWith: [<vocab values>],
  interface: cli|tui|gui, alternativeTo: [<command names>],
  confidence: 0.0..1.0, nothing_fits: bool, suggested_terms: [..],
  signal_source: readme|docs|metadata|websearch }
```
Schema enumeration means the model **cannot emit an out-of-vocabulary value** — its only escape hatch is
`nothing_fits`, which is exactly the discovery signal. **Escalation:** `confidence < threshold` or
`nothing_fits` → re-run that tool on the stronger model (Claude). Everything else stays on the cheap grind.

**Related / alternative tools:**
- **`relatedTo`** — a **description embedding** per tool (small embedding model), stored in a
  `tool_embeddings` table; `relatedTo` = nearest neighbours (cosine), filtered to same-`domain`/`function`,
  capped. Also usable to retrieve already-classified neighbours as few-shot anchors for classifier
  consistency.
- **`alternativeTo`** — the LLM's `alternativeTo` output (classic-command mapping), verbatim.

Rate-limit + retry + per-call cost accounting feed the budget cap (§4).

---

## §4 — Run mechanics: resumable, budget-capped, resilient

The run loop is deliberately dumb, which is what makes it robust:

```
while (budget remaining AND unprocessed tools exist):
    take next batch of tools whose durable key has no classification row
    for each tool:
        gather input (cached fetches) -> classify (small model)
            -> escalate if low-confidence / nothing-fits (strong model)
            -> PERSIST immediately (classification + embedding + provenance)
    accumulate spend; stop when spend >= cap
```

- **Per-tool persistence:** a crash or kill loses at most the one in-flight tool; everything prior is durable.
  Resume is re-running the same "unprocessed durable keys" query.
- **Per-tool failures are non-fatal:** a dead repo link, a 404 doc, a rate-limit → log it, mark the tool
  *deferred* (not *done*), continue; the next run retries it. One bad tool never stalls the batch (Phase A/B
  item-isolation discipline).
- **Budget** is a configurable cap — dollars (via per-call token accounting), call count, or wall-clock —
  checked each tool. Nothing to unwind on stop.
- **Processing order (budget matters):** signal-rich / discoverable tools first (has-repo, then
  popularity / multi-source), so an early budget stop leaves the *most useful* tools classified. The obscure
  long tail fills in on later runs — widest coverage *eventually*, best coverage *first*.

---

## §5 — Output, persistence, integration

### Data model (new tables in `universe.db`)
```sql
CREATE TABLE tool_classifications (      -- the durable cache; one row per durable identity key
  cache_key TEXT PRIMARY KEY,            -- normalized repo(+name) | homepage | anchor source|package_id
  domain TEXT,
  function_json TEXT,                    -- JSON array of vocab values
  works_with_json TEXT,                  -- JSON array
  interface TEXT,                        -- cli | tui | gui
  alternative_to_json TEXT,              -- JSON array of command names
  confidence REAL,
  nothing_fits INTEGER NOT NULL DEFAULT 0,
  suggested_terms_json TEXT,             -- vocab-gap proposals
  signal_source TEXT,                    -- readme | docs | metadata | websearch
  model TEXT,                            -- which model produced it (small | escalated)
  status TEXT NOT NULL,                  -- done | deferred
  classified_at TEXT NOT NULL
);
CREATE TABLE fetch_cache (               -- deduped, polite document fetches
  url TEXT PRIMARY KEY,
  content TEXT, content_type TEXT, fetched_at TEXT NOT NULL, status TEXT
);
CREATE TABLE tool_embeddings (           -- description embeddings for relatedTo
  cache_key TEXT PRIMARY KEY,
  embedding BLOB NOT NULL, model TEXT NOT NULL, embedded_at TEXT NOT NULL
);
CREATE TABLE tool_relatedto (            -- computed nearest neighbours (rebuilt from embeddings)
  cache_key TEXT NOT NULL, related_key TEXT NOT NULL, score REAL,
  PRIMARY KEY(cache_key, related_key)
);
```

### Durable export (non-negotiable)
The classification store exports to a **version-controlled artifact**,
`data/package-universe-classifications.jsonc` (mirroring `data/package-universe-curation.jsonc`), re-imported
on rebuild — so a DB regeneration never destroys days of paid LLM work. **The JSONC file is the source of
truth; the DB table is the working mirror.** The curated **vocabulary** likewise lives version-controlled in
`build/categories/*.jsonc`.

### Aggregation
A tool's final categories = its durable key's `tool_classifications` row, written onto the tool record
(`domain`/`function`/`worksWith`/`interface`) plus `relatedTo`/`alternativeTo`, **superseding** Phase C's
first-pass keyword `tool_categories`.

### Review queue
Low-confidence + web-sourced + `nothing_fits` rows → a review view (`pipeline_log` `stage='categorize'`,
`level='review'`). Human verdicts and promoted vocab terms feed the next round.

### Integration — Phase D becomes the shipped-db source
A build step exports the universe's classifications into the **shipped trifle category-db format**
(`data/tool-categories.json`, which `trifle -Category` reads), **retiring the hand-authored ~72-tool seed**
in favour of the generated set. The export is **gated by the offline quality bar** (§6): the generated db
ships only once precision on the ground-truth set clears the threshold. Filtering (the "CLI-tool union"
subset vs the whole universe) is an export-time policy knob.

---

## §6 — Testing & verification

The pipeline splits into **deterministic machinery (unit-tested)** and **the LLM call (mocked in tests,
eval'd offline)** — the Phase A/B seam discipline (an injected classifier scriptblock, like `FetchItems`/`Log`).

**Unit-tested (Pester 5, `Set-StrictMode -Version Latest`, no network):**
- **Durable-key derivation** (the crux): same tool across membership changes → same key; a family-split
  shared repo → distinct keys; repo-less singleton → its anchor `(source,package_id)`.
- **Any-host repo resolver**: GitHub/GitLab/Bitbucket/Codeberg/generic fixtures → correct raw-README URL;
  non-repo → null.
- **Run loop (mock classifier):** resume selects only unprocessed durable keys; budget cap stops mid-run
  leaving valid state; a re-run against a full cache makes **zero** classifier calls (idempotency); a failing
  tool logs + is marked `deferred` (not `done`) and does not abort the batch; escalation fires on
  low-confidence / `nothing_fits`.
- **Structured-output contract:** an out-of-vocabulary facet value is rejected; `nothing_fits` routes to the
  vocab-gap queue.
- **Export/import round-trip:** `tool_classifications` ↔ `data/package-universe-classifications.jsonc` is
  lossless (the durable-work-survives-rebuild guarantee).
- **Aggregation + shipped-db export:** a tool inherits its durable key's facets; the trifle-format export
  validates against the existing `data/tool-categories.json` schema (the gate before it can ship).

**Offline eval (manual harness, real LLM — not CI):**
- A **ground-truth set** (~50 known tools: `bat`→domain `text`/function `file-viewing`, `ripgrep`→`search`,
  `docker`→`containers`…) scored for precision/recall on `domain`/`function`/`worksWith`. This is the
  quality bar that gates promoting the generated categories into the *shipped* db.
- **Reconciliation** each run: tools processed / classified / escalated / deferred / nothing-fits, cumulative
  spend — so a silent stall or budget blowout is visible.

Because classification is **cached, not recomputed**, tests never assert *what* the LLM said
(non-deterministic) — they assert the **cache contract** (classified once, reused forever, survives
rebuild). Content quality is judged by the offline eval harness, not CI. That split is what makes an
LLM-in-the-loop pipeline testable at all.

---

## Error Handling (Phase A–C conventions)
- **Item isolation:** one tool's fetch/API/parse failure logs a `warning`, marks the tool `deferred`, and is
  retried next run — never aborts the batch.
- **Reconciliation:** population-vs-processed counts + spend logged every run; a systematic failure pattern
  is a run-level failure, not N silent skips.
- **`review`-level entries** (low-confidence, web-sourced, nothing-fits) are not failures.
- **Budget stop** is a clean, expected terminal state, not an error.

## Rejected Alternatives
- **A RAG framework (LlamaIndex) or auto-ontology-induction stack (OntoRAG) as the backbone** — rejected on
  two grounds: *task mismatch* (our job is per-tool classification into a fixed vocabulary, not retrieval-QA
  over a corpus — the relevant context is the tool's own docs, so RAG's retrieval apparatus adds weight we
  never use) and *stack mismatch* (a Python subsystem bolted onto a PowerShell + SQLite pipeline). OntoRAG's
  bottom-up-induction *idea* is borrowed as the lightweight sample-bootstrap discovery pass; its machinery is
  not adopted.
- **PyPI trove classifiers as the taxonomy** — Python-library-shaped, too deep where we don't care, and
  nearly every CLI tool collapses into `Software Development`/`System`.
- **Gentoo categories as the taxonomy** — a better fit (it shelves CLI software) and kept as *reference* and
  the inspiration for the coarse `domain` axis, but a single-axis "shelf location," not a rich facet model.
- **A model-invented / open taxonomy** — LLMs produce drifting, overlapping, inconsistent categories at
  scale. The vocabulary is closed (schema-enumerated) and grown only through human-gated discovery.
- **Keying the cache on `tool_id`** — reassigned every Phase C run and shifts with cluster membership; would
  silently rot. Keyed on the durable identity signal instead.
- **Storing categories only in `universe.db`** — the DB is gitignored and regenerable; days of paid,
  human-reviewed LLM work would be destroyed on rebuild. The version-controlled JSONC export is the source of
  truth; the table is a mirror (the curation-file pattern).
- **A local small model for the bulk** — considered (unlimited/free/private), but the user has unused OpenAI
  credit and a small cloud model is a better quality/effort trade for constrained classification; a stronger
  model is reserved for discovery + escalation, where reasoning pays.

## Out of Scope / Future
- **Wiring the shipped module's `trifle` UI** to any new axes (e.g. `-Domain` browse) beyond regenerating the
  existing `data/tool-categories.json` — a trifle-side follow-on once the generated db clears the quality bar.
- **Phase B-ext** — external-ecosystem cross-refs (npm/crates/pypi/psgallery/gem).
- **Officialness / preferred-installer / true code-author derivation** — still deferred (was earmarked
  alongside categorization; this phase is categorization + related/alt only).
- **Popularity as a live metric**, PSReadLine personal-usage mining, and other trifle discovery-v2 ideas.
