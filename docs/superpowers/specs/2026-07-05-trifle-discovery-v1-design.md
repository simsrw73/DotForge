# trifle Discovery v1 — Seed Category Database + Consumption — Design

**Date:** 2026-07-05
**Status:** Approved
**Depends on:** trifle detail view (`docs/superpowers/specs/2026-07-04-trifle-detail-view-design.md`), shipped on `feat/trifle`

## Problem

`trifle` can search and show detail on a package once you know roughly what
it's called, but it has no notion of *category*. There is no way to ask
"what search tools do I have" or "what's like ripgrep" — the only
discoverability signal today is free-text keyword matching against catalog
names/descriptions, plus the 32 hand-curated `Tools/*.json` records' `tags`
arrays, which are inconsistent in vocabulary and not searchable as a facet.

## Goals

- A curated, versioned taxonomy of CLI tool categories that ships with the
  module and works fully offline.
- `trifle` can be queried by category/facet, not just by name or keyword.
- A user can discover the valid category/facet vocabulary itself — the
  terms are worthless if you have to already know them to find them.
- The detail card surfaces related/alternative tools for the package being
  viewed — directly answering "recommend similar tools based on current
  search."
- `ftrifle` gains a category-browse mode.
- The database can be refreshed independently of a module release.

## Non-Goals (deferred to a phase-2 spec)

- The full multi-source gathering pipeline (debtags, crates.io/PyPI trove
  classifiers, Homebrew analytics, Repology identity resolution, GitHub
  topics, distro package-section mining) that would auto-populate and
  maintain the database from live external sources.
- Runtime AI categorization (the AI-assisted pass for this v1 happens during
  development — the author drafts entries, the human reviews the diff —
  never at trifle's runtime).
- PSReadLine personal-usage mining, `-New` (recently-added-to-buckets),
  `-Provides` (reverse command lookup), description-embedding similarity.
- Catalog-native tag/category queries (npm keywords, PyPI classifiers,
  crates.io categories) as a *search* input — v1's db supersedes them for
  search; they remain visible as raw `Tags` on the detail card as already
  shipped.
- Any change to the existing `Tools/*.json` schema or its `tags` field.

## Data Model

### `data/tool-categories.json`

Ships inside the module (`data/` is a new top-level directory alongside
`Public/`, `Private/`, `Tools/`). Single JSON document:

```jsonc
{
  "schemaVersion": 1,
  "updated": "2026-07-05",
  "taxonomy": {
    // Illustrative subset — the shipped v1 vocabulary has ~35 function
    // values and ~25 worksWith values; the authoritative list lives in
    // build/categories/ and the generated data/tool-categories.json.
    "function": ["search", "file-viewing", "file-management", "vcs-client",
      "editor", "network-transfer", "process-monitor", "system-info",
      "shell-enhancement", "prompt", "archive", "diff-merge", "text-processing",
      "json-processing", "container-tooling", "package-manager", "secrets",
      "clipboard", "navigation", "benchmarking", "documentation",
      "terminal-multiplexer"],
    "worksWith": ["text", "json", "yaml", "git", "http", "images", "pdf",
      "containers", "processes", "filesystem", "clipboard", "environment-vars",
      "credentials", "markdown", "csv", "logs", "archives"]
  },
  "tools": {
    "ripgrep": {
      "function": ["search"],
      "worksWith": ["text", "filesystem"],
      "interface": "cli",
      "aliases": ["rg"],
      "alternativeTo": ["grep"],
      "relatedTo": ["fd", "fzf", "rga"],
      "repo": "https://github.com/BurntSushi/ripgrep",
      "ids": { "scoop": "main/ripgrep", "winget": "BurntSushi.ripgrep.MSVC",
               "npm": "ripgrep", "pypi": "ripgrep", "crates": "ripgrep" },
      "popularity": 3
    }
  }
}
```

- `taxonomy.function` / `taxonomy.worksWith`: the closed vocabularies. Every
  tool entry's `function`/`worksWith` values must appear here — enforced by
  the validator (Testing section).
- `interface`: one of `cli | tui | gui`.
- `aliases`: alternate names/monikers a query might use (e.g. `rg`).
- `alternativeTo`: classic-Unix-command mapping, modern-unix-list style
  (`bat` → `["cat"]`).
- `relatedTo`: curated, hand-picked list of tool keys — the strongest
  discovery signal, used verbatim before any computed overlap.
- `repo`, `ids`: identity data, same shape/spirit as `Tools/*.json`'s
  `packages` block — lets the db resolve to real catalog hits without a
  live search.
- `popularity`: integer 0–3, baked in at build time (author's editorial
  judgment for v1, informed by GitHub stars / download rank where known —
  no live fetching). Used only as a tie-breaker/cap in Related/Alt lists,
  never to reorder primary search results.

### Seed corpus scope

~300–500 tools: the 32 existing `Tools/*.json` entries (their `tags`
imported and re-mapped to the closed vocabulary), the modern-unix README
table, and the top tools per catalog (scoop main+extras highlights, winget
popular CLI tools, top crates.io/PyPI CLI-tagged packages by the author's
judgment). Anchored to the "CLI-tool union" scope agreed in brainstorming —
tools a DotForge user would plausibly search for, not an exhaustive package
index.

## Loader & Matching

### `Private/Get-DFCategoryDb.ps1`

```powershell
Get-DFCategoryDb [-Force]   # -> the parsed db object, cached in $script:DFCategoryDb
```

- Lazy singleton per session; `-Force` reloads.
- Resolution order: `$XDG_DATA_HOME/dotforge/tool-categories.json` (refreshed
  copy, see Refresh section) if its `updated` date is newer than the shipped
  copy's; otherwise the shipped `data/tool-categories.json` next to the
  module root (`$PSScriptRoot/../data/...` from `Private/`).
- On any read/parse failure of the refreshed copy, fall back to shipped and
  `Write-Verbose` — never throw, discovery is additive, not load-bearing.
- Builds three in-memory indexes once per load:
  - **by name/alias** (lowercased) → tool key
  - **by `source:packageId`** (lowercased, from each entry's `ids`) → tool key
  - **inverted facet index**: `function:<value>` and `worksWith:<value>` →
    `[tool key]`, for O(1) facet search

### Resolving a merged `ToolInfo` to a db entry

New `Get-DFCategoryDbEntry -Info <ToolInfo>` (same file): tries, in order,
(1) `$Info.DFTool` name, (2) each `source:packageId` in `$Info.Sources`,
(3) `$Info.Name` lowercased. Returns the db entry or `$null` — absence is
normal (most of the package universe isn't in the seed db) and never an
error.

## Command Surface

### `Get-DFCategoryList [-Facet function|worksWith] [-Counts]` (new public function, alias `tcats`)

Discoverability backstop for the two facet vocabularies — answers "what
terms can I even search by" without needing fzf or already knowing a value.

- No `-Facet`: prints both vocabularies as two labeled sections (`Function`
  then `WorksWith`), one value per line, sorted alphabetically.
- `-Facet function` / `-Facet worksWith`: prints only that section.
- `-Counts` (default: on): appends the live count of seed-db tools carrying
  that value, e.g. `search (14)` — computed from the same inverted facet
  index the search path uses, so counts never drift from what a matching
  `-Category`/`-WorksWith` call would actually return. `-Counts:$false` for
  a bare term list (e.g. for shell completion or scripting).
- Output is plain rendered `string[]` (pipeline-friendly, no ANSI unless
  interactive+color, matching every other trifle renderer's convention) —
  never emits typed objects, since there's nothing to act on beyond the term
  itself.
- Also the reference point named in the `-Category`/`-WorksWith` unknown-
  value error and in `ftrifle -Category`'s empty state.

### `trifle -Category <c...> [-WorksWith <w...>]` / `trifle -WorksWith <w...>`

New parameter set on `Find-DFPackage`, mutually exclusive with `Query`
(positional). Pure facet search, no text query:

- Multiple `-Category` values OR together; multiple `-WorksWith` values OR
  together; when both are given, the two facets AND together.
- All supplied facet values are validated against the taxonomy before any
  search executes; if any value is unknown, the call fails fast with a
  terminating error naming the invalid value(s) and pointing at
  `Get-DFCategoryList` to discover the valid vocabulary — no partial results
  from the valid values in the same invocation.
- Result rows: for each matching db tool key, resolve to a live `ToolInfo`
  via the existing search-and-merge path (search catalogs by the db entry's
  `ids`/name) so installed-state and versions stay accurate — the db is an
  index into real data, not a cached snapshot of it. A db entry whose `ids`
  no longer resolve against any live catalog (renamed/removed upstream) is
  silently skipped, not shown as an error — the same "stale seed data" case
  the phase-2 pipeline is meant to catch.
- Renders as the existing `Format-DFToolInfoTable` (Id column included);
  `-All` is meaningless here (no ranking to suppress) and is rejected with a
  usage error when combined with `-Category`/`-WorksWith`.

### Detail card additions (`Format-DFToolDetailCard`)

When `Get-DFCategoryDbEntry` resolves for the card's tool, two new
optional lines (own section, after Notes/before GitHub, same
omit-when-empty rule as every other section):

```
Category   search · works with: text, filesystem
Related    fd · fzf · rga                (curated relatedTo, then same-
                                           function tools by popularity,
                                           capped at 6, excluding self)
Alt to     grep
```

`Related` resolution: `relatedTo` entries first (in listed order), then —
only if fewer than 6 — same-`function` db tools sorted by `popularity`
descending, excluding the card's own tool and anything already listed.
Each related name is just a name (not a re-fetched detail); rendering a
name requires no network/cache call, keeping the card fast. `Alt to` shows
`alternativeTo` verbatim when present.

### `ftrifle -Category [<value>]`

- No value: fzf lists every taxonomy `function` (plus a synthetic "— browse
  by works-with —" divider entry leading into the `worksWith` list), each
  row annotated with its tool count. Selecting one re-invokes with that
  value.
- With a value: lists the matching tools (reusing the `-Category` search
  above) with the same pre-rendered basic-card preview pattern as query
  mode; Enter renders the full detail card.

## Refresh

### `Update-DFCategoryDb` (new public function)

```powershell
Update-DFCategoryDb [-WhatIf]
```

- Downloads the latest `tool-categories.json` published as a GitHub release
  asset on the DotForge repo (URL pattern:
  `https://github.com/simsrw73/DotForge/releases/latest/download/tool-categories.json`),
  validates it against the schema (reject and warn on failure, no partial
  write), and writes it atomically (tmp + rename, matching the catalog cache
  pattern) to `$XDG_DATA_HOME/dotforge/tool-categories.json`.
- Never runs implicitly — not part of `Update-DFPackageCache`, not
  triggered by any `trifle` call. Purely opt-in, so discovery stays usable
  fully offline by default.
- Standard `-WhatIf`/`ShouldProcess` support (this writes to disk).
- The next `trifle` invocation (or `Get-DFCategoryDb -Force`) picks up the
  refreshed copy per the loader's precedence rule.

## Build Tooling (author-side, not shipped to users)

### `build/Build-DFCategoryDb.ps1`

Development-time script, not part of the module's public surface:

- Reads hand-maintained fragments from `build/categories/*.jsonc` (one file
  per logical group, e.g. `search-and-files.jsonc`, `vcs.jsonc`,
  `modern-unix.jsonc` — comments allowed, stripped before parsing).
- Cross-references `Tools/*.json` to pull in the 32 existing curated tools'
  names/aliases automatically (their `tags` are read as a starting point for
  `function`/`worksWith` assignment during authoring, not auto-mapped
  blindly — the taxonomy is a closed, curated vocabulary).
- Validates every entry against the taxonomy vocab (same validator the
  runtime loader could reuse) and fails the build on any unknown facet
  value, duplicate tool key, or missing required field (`function`,
  `interface`).
- Emits the merged, sorted, pretty-printed `data/tool-categories.json` with
  `updated` stamped to the current date.
- The actual category assignment work for the ~300–500 seed tools happens
  as authored content in the `build/categories/*.jsonc` fragments — drafted
  with AI assistance during this development effort, reviewed by the human
  before commit. No AI runs as part of `Build-DFCategoryDb.ps1` itself.

## Error Handling

- Missing/corrupt shipped `data/tool-categories.json` would be a packaging
  bug — the loader still shouldn't crash the whole module: catch, warn once
  per session, and every discovery feature becomes a no-op / "category data
  unavailable" message while the rest of `trifle` continues working
  unaffected.
- A corrupt *refreshed* copy always falls back to the shipped copy (never
  fails the load) per the Loader section.
- `-Category`/`-WorksWith` with no matches → the existing "No packages
  found" message, reworded to name the searched facet(s).

## Testing (Pester 5)

- **Schema validator**: valid fixture passes; unknown function/worksWith
  value, missing required field, duplicate key each rejected with a clear
  message.
- **Loader**: shipped-only load; refreshed-newer-than-shipped wins;
  refreshed-older-than-shipped is ignored; corrupt refreshed copy falls back
  to shipped without throwing; `-Force` reload picks up a changed file.
- **Indexes**: name index, alias index, `source:packageId` index, inverted
  facet index — each resolves correctly and misses return `$null`/empty
  rather than throwing.
- **`Get-DFCategoryDbEntry`**: resolves via DFTool name, via `source:id`, via
  plain name, in that priority order; returns `$null` for an unmapped tool.
- **Facet search**: OR-within-facet, AND-across-facets, unknown-value error
  names the bad value(s) and points at `Get-DFCategoryList`,
  `-Category`/`-WorksWith` + `-All` rejected.
- **`Get-DFCategoryList`**: no-`-Facet` prints both sections; `-Facet`
  narrows to one; counts match the inverted facet index (cross-checked
  against an actual `-Category` search for the same value); `-Counts:$false`
  omits counts; output is plain strings.
- **Card sections**: Category line present/absent, Related resolution order
  (curated first, popularity-sorted fill, self-exclusion, cap at 6, dedupe),
  Alt-to present/absent — all pure string assertions, `-Color $false`.
- **`ftrifle -Category`**: no-value function-list flow, with-value tool-list
  flow (mocked `Invoke-DFFzf`), tool-count annotation.
- **`Update-DFCategoryDb`**: mocked download + validation success writes
  atomically; validation failure leaves the existing file untouched and
  warns; `-WhatIf` performs no write.
- **Build script**: at minimum, one test asserting the shipped
  `data/tool-categories.json` in the repo actually validates against the
  schema (a regression guard against a bad hand-edit slipping through).

## Out of Scope / Future (phase-2 spec)

- Automated multi-source gathering pipeline (debtags import, crates.io/PyPI
  trove classifiers, Homebrew analytics API, Repology cross-catalog identity
  resolution, GitHub topics, distro package-section mining) feeding this
  exact schema.
- Popularity as a live, periodically-refreshed metric rather than a
  build-time editorial tier.
- PSReadLine personal-usage-informed suggestions, `-New`, `-Provides`,
  computed description-similarity recommendations.
