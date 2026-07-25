# Theme Centralization — Design

**Date:** 2026-07-25
**Status:** Approved design; ready for implementation planning.
**Parent standard:** `ToolAcquisitionSpec.md` §6 (Theme); audit
`ToolAcquisitionSpec-Audit.md` platform gap #4.

## Purpose

DotForge aims for **one system-wide default theme, set once, applied to every
themed tool** (`ToolAcquisitionSpec.md` §6.1). The fallback *chain* is already
centralized (`Private/Get-DFConfiguredTheme.ps1`: per-tool key → shared `Theme`
→ default). But the **family→dialect mapping** — translating a canonical family
name to what each tool natively calls it — is duplicated and hardcoded across
four sidecars:

| Sidecar | Hardcoded rule | Tool's native name |
|---|---|---|
| `Tools/glow.ps1:37` | `catppuccin → catppuccin-mocha` | `catppuccin-mocha` |
| `Tools/psreadline.ps1:66` | `catppuccin → catppuccin-mocha` | `catppuccin-mocha` |
| `Tools/mdcat.ps1:14` | `catppuccin → catppuccin-mocha` | `catppuccin-mocha` |
| `Tools/mdv.ps1:14` | `catppuccin-* → catppuccin` (reverse) | `catppuccin` |

This workstream moves the mapping into a single data file
(`data/theme-aliases.json`) consumed by a resolver, refactors the four sidecars
to call it, and — realizing §6.1 for the name-based case — makes `delta` respond
to `$DFConfig.Theme` too.

## Configuration rules (collision-free vocabulary)

- **`$DFConfig.Theme` (shared)** accepts the **canonical family name only**
  (e.g. `catppuccin-mocha`).
- **`$DFConfig.<Tool>Theme` (per-tool override)** accepts the **canonical name
  OR a name that tool alone natively understands** (its own built-ins, e.g.
  glow's `dracula`).
- **The canonical name is the only value that triggers cross-tool translation.**
  Nothing else — no aliases, no other tool's native value — cross-resolves. A
  per-tool override that isn't canonical passes through and is validated by that
  tool's own built-in list (falling back to `auto` if unrecognized). This is
  what prevents a name like `catppuccin` (mdv's dialect) written for glow from
  wrongly resolving to glow's `catppuccin-mocha`.

This supersedes the `aliases` array shown in the current `ToolAcquisitionSpec.md`
§6.2 example — there are no aliases; canonical is the single shared vocabulary.

## Scope

**In scope:** `data/theme-aliases.json`; a `Resolve-DFThemeName` resolver;
refactor glow/psreadline/mdcat/mdv to use it; a new minimal `delta.ps1` sidecar
so `DELTA_FEATURES` tracks `$DFConfig.Theme`; amend the standard; tests + docs.

**Out of scope:**
- **Provisioning delta's config feature.** C makes `DELTA_FEATURES` *track* the
  theme; for delta to actually *render* catppuccin its config must define a
  `catppuccin-mocha` feature. Shipping that definition is a conformance/retrofit
  concern, not C.
- Extending theming to other static tools (fzf colors, bat, lazygit, micro,
  procs, winfetch) — per-tool retrofit.
- A warning when a shared `Theme` isn't canonical — documented as a rule, not
  enforced (enforcing it would couple the fallback chain to the mapping table;
  YAGNI). May be added later.

## Section 1 — `data/theme-aliases.json`

Canonical family → per-tool native name. Runtime-loaded by the module (NOT
author-time — unlike the conformance ledger). Initial content:

```jsonc
{
  "catppuccin-mocha": {
    "glow": "catppuccin-mocha",
    "psreadline": "catppuccin-mocha",
    "mdcat": "catppuccin-mocha",
    "mdv": "catppuccin",
    "delta": "catppuccin-mocha"
  }
}
```

Each top-level key is a canonical family; its value maps tool → that tool's
dialect. A tool absent from a family's map receives the canonical name verbatim.

## Section 2 — `Resolve-DFThemeName` (new private function)

`Private/Resolve-DFThemeName.ps1`, distinct from `Get-DFConfiguredTheme` (which
keeps its single job — the fallback chain).

```
Resolve-DFThemeName -Name <string> -Tool <string>  ->  [string]
```

**Algorithm:**

```
if $Name equals a canonical family key (case-insensitive):
    return family[$Tool]   (or $Name — the canonical — if $Tool isn't in the map)
else:
    return $Name unchanged   (pass-through)
```

- **Loading:** read `data/theme-aliases.json` once and cache in a module-scoped
  variable. Path resolves relative to the module root (`$PSScriptRoot/..`).
- **Degradation (house rule):** if the file is missing or malformed, the
  resolver returns `$Name` unchanged (no throw, no warning-storm). The sidecars'
  own built-in validation still applies.
- **StrictMode-safe** reads of the parsed JSON (`$obj.PSObject.Properties['x']?.Value`).
- Purely a translator: it never validates a name or falls back — that stays in
  the sidecars (§6.2).

**Resulting sidecar flow:** `Get-DFConfiguredTheme` (chain) →
`Resolve-DFThemeName` (family → this tool's dialect) → the sidecar's existing
built-in validation + fallback → apply.

## Section 3 — Sidecar refactors (glow, psreadline, mdcat, mdv)

Each sidecar: delete the hardcoded family line, insert a `Resolve-DFThemeName`
call, set the tool's JSON/`-Default` theme to the **canonical** `catppuccin-mocha`
(the resolver translates). Built-in lists, fallbacks, and application are
unchanged.

- **glow** (`Tools/glow.ps1`): remove the `if ($Name -eq 'catppuccin')` line
  inside `Resolve-DFGlowStyle`; the sidecar body resolves the configured theme
  via `Resolve-DFThemeName … -Tool 'glow'` before handing it to
  `Resolve-DFGlowStyle` for file/built-in lookup. Default stays `catppuccin-mocha`.
- **psreadline** (`Tools/psreadline.ps1`): remove the `if ($Name -eq 'catppuccin')`
  line in `Invoke-DFApplyPSReadLineTheme`; resolve via `Resolve-DFThemeName …
  -Tool 'psreadline'` in the body. Default `dark` passes through unchanged.
- **mdcat** (`Tools/mdcat.ps1`): remove the `if ($_name -eq 'catppuccin')` line;
  resolve via `Resolve-DFThemeName … -Tool 'mdcat'`. Keep the "override only when
  `$DFConfig` specifies a theme" behavior and the env-block static default (from
  workstream B).
- **mdv** (`Tools/mdv.ps1`): replace the reverse rule `if ($_name -like
  'catppuccin-*') { 'catppuccin' }` with `Resolve-DFThemeName … -Tool 'mdv'`;
  set the default to canonical `catppuccin-mocha` (resolver returns `catppuccin`).

**Behavior change:** the bare alias `catppuccin` is no longer special-cased. All
*defaults* are canonical, so out-of-the-box rendering is unchanged; a user who
explicitly set `<Tool>Theme = 'catppuccin'` must switch to `catppuccin-mocha`.
Existing tests exercising the `catppuccin` alias are updated to the canonical.

## Section 4 — New `delta.ps1` sidecar + `delta.json` change

`Tools/delta.ps1` (new, minimal — theming is its only job):

```powershell
$_theme  = Get-DFConfiguredTheme -ToolKey 'DeltaTheme' -Default 'catppuccin-mocha'
$_native = Resolve-DFThemeName -Name $_theme -Tool 'delta'
[System.Environment]::SetEnvironmentVariable('DELTA_FEATURES', $_native, 'Process')
```

`Tools/delta.json`: remove `DELTA_FEATURES` from the `env` block (the sidecar
owns it now); keep `GIT_PAGER` in `env`. No built-in validation — delta features
are user-defined names, and delta silently ignores an unknown feature.

## Section 5 — Testing

- **`Resolve-DFThemeName` unit tests:** canonical → each tool's native
  (including mdv's `catppuccin` and a tool-absent-from-map returning the
  canonical); a non-canonical name passes through unchanged; a missing/malformed
  data file degrades to pass-through (no throw).
- **`theme-aliases.json` data-shape test:** parses; every tool value is a
  non-empty string; the canonical key is present.
- **Sidecar tests:** glow/psreadline/mdcat/mdv land on the correct native name
  via the central table; **existing `catppuccin`-alias assertions updated to
  `catppuccin-mocha`** (notably `tests/mdcat.Tests.ps1`'s "maps the shared
  catppuccin family" test); `mdv`/`glow`/`psreadline` theme tests likewise.
- **New `tests/delta.Tests.ps1`:** registering delta sets `DELTA_FEATURES` from
  the resolved theme (default `catppuccin-mocha`; `DeltaTheme`/`Theme` override);
  a non-canonical `DeltaTheme` passes through verbatim.
- **Update `tests/XdgSplit.Tests.ps1`** (from workstream B): its "delta env
  carries GIT_PAGER and DELTA_FEATURES" test asserts `env.DELTA_FEATURES` — since
  `DELTA_FEATURES` moves out of the `env` block into `delta.ps1`, drop that
  assertion (keep the `GIT_PAGER` one) and, if desired, assert `delta.json` no
  longer carries `DELTA_FEATURES` in `env`.
- Full suite green under Pester 5.8.0 and 6.0.1.

## Section 6 — Documentation

- **`ToolAcquisitionSpec.md` §6.2** — replace the aliases-based example and the
  "accept alias or native" resolver text with the canonical-only model: one
  `data/theme-aliases.json` mapping canonical → per-tool native; shared `Theme`
  is canonical-only; per-tool overrides accept canonical or that tool's own
  native; the canonical is the only cross-tool translation trigger.
- **CLAUDE.md** — a short note on theme resolution: `Get-DFConfiguredTheme`
  (chain) + `Resolve-DFThemeName` (family→dialect via `data/theme-aliases.json`);
  sidecars validate against their own built-in lists; shared `Theme` must be
  canonical.
- **`docs/external-dependencies.md`** — add/adjust the delta entry: DotForge sets
  `DELTA_FEATURES` from the resolved theme; rendering requires a delta config
  defining that feature (out of DotForge's scope) — degrade silently if absent.
- **CHANGELOG.md** `[Unreleased]` — Changed: theme family→dialect mapping
  centralized in `data/theme-aliases.json` via `Resolve-DFThemeName`; the bare
  `catppuccin` alias is retired in favor of the canonical `catppuccin-mocha`;
  delta's `DELTA_FEATURES` now tracks `$DFConfig.Theme`.
- **README.md** — if it documents `$DFConfig` theme keys, note the canonical-only
  shared `Theme` rule and the per-tool override rule.

## Acceptance criteria

- `data/theme-aliases.json` exists (canonical → per-tool native, no aliases) and
  is validated by a data-shape test.
- `Resolve-DFThemeName` translates canonical → native, passes non-canonical
  through, and degrades to pass-through on a missing/malformed file.
- glow/psreadline/mdcat/mdv contain no hardcoded family→dialect mapping; they
  resolve via the central table; their defaults are canonical.
- delta responds to `$DFConfig.Theme`/`DeltaTheme` via `Tools/delta.ps1`;
  `DELTA_FEATURES` leaves `delta.json`'s `env` block.
- Setting `$DFConfig.Theme = 'catppuccin-mocha'` yields `catppuccin` for mdv and
  `catppuccin-mocha` for glow/psreadline/mdcat/delta — proven by tests.
- The standard, CLAUDE.md, external-dependencies, and CHANGELOG are updated.
- No regression in the full suite (both Pester versions).
