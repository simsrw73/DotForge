# Theme Centralization — Design

**Date:** 2026-07-25
**Status:** Approved design; ready for implementation planning.
**Parent standard:** `ToolAcquisitionSpec.md` §6 (Theme); audit
`ToolAcquisitionSpec-Audit.md` platform gap #4.
**Governed by:** `docs/plugin-architecture.md` (core invariant — adding a tool
never modifies core; per-tool declaration over central registries).

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

This workstream removes those hardcoded rules. Per the plugin invariant, the
mapping is **not** moved to a central registry keyed by tool (that would make
adding a themed tool require editing core data). Instead **each tool declares its
own family→native map in its own JSON**, and a tiny resolver translates using the
*target tool's* declaration. It also — realizing §6.1 for the name-based case —
makes `delta` respond to `$DFConfig.Theme`.

## Configuration rules (collision-free vocabulary)

- **`$DFConfig.Theme` (shared)** accepts the **canonical family name only**
  (e.g. `catppuccin-mocha`).
- **`$DFConfig.<Tool>Theme` (per-tool override)** accepts the **canonical name
  OR a name that tool alone natively understands** (its own built-ins, e.g.
  glow's `dracula`).
- **The canonical name is the only value that triggers translation.** A per-tool
  override that isn't a canonical key in that tool's map passes through and is
  validated by the tool's own built-in list (falling back to `auto` if
  unrecognized). Nothing else cross-resolves — no aliases, no other tool's native
  value. This prevents a name like `catppuccin` (mdv's dialect) written for glow
  from wrongly resolving to glow's `catppuccin-mocha`.

This supersedes the `aliases` array shown in the current `ToolAcquisitionSpec.md`
§6.2 example — there are no aliases; canonical is the single shared vocabulary.

## Scope

**In scope:** an optional per-tool `themeMap` block in the tool JSON; a
`Resolve-DFThemeName` resolver that reads the target tool's map; refactor
glow/psreadline/mdcat/mdv to use it; a new minimal `delta.ps1` sidecar so
`DELTA_FEATURES` tracks `$DFConfig.Theme`; amend the standard; tests + docs.

**Out of scope:**
- **Provisioning delta's config feature.** C makes `DELTA_FEATURES` *track* the
  theme; for delta to actually *render* catppuccin its config must define a
  `catppuccin-mocha` feature. Shipping that definition is a conformance/retrofit
  concern, not C.
- Extending theming to other static tools (fzf colors, bat, lazygit, micro,
  procs, winfetch) — per-tool retrofit.
- A warning when a shared `Theme` isn't canonical — documented as a rule, not
  enforced (enforcing it would couple the fallback chain to per-tool maps; YAGNI).

## Section 1 — The per-tool `themeMap` block

A tool declares, in its own JSON, how it names each canonical family it supports:

```jsonc
// Tools/mdv.json  — mdv's native name for the family differs from the canonical
"themeMap": { "catppuccin-mocha": "catppuccin" }
```

- **Optional, and only needed when a tool's native name differs from the
  canonical.** glow/psreadline/mdcat/delta natively call the family
  `catppuccin-mocha` (identity), so they need **no** `themeMap` — the canonical
  passes straight through their existing built-in/file resolution. **mdv is the
  only current tool that needs one** (its native is `catppuccin`).
- Keys are canonical family names; values are that tool's dialect. A map that
  generalizes to future flavours (a second `catppuccin-latte` key, etc.).
- The block rides in the already-loaded tool record (`$DFCurrentTool`), so there
  is **no central file and no extra startup file-read** — consistent with the
  plugin invariant's startup-cost rule.

## Section 2 — `Resolve-DFThemeName` (new private function)

`Private/Resolve-DFThemeName.ps1` — a pure translator, distinct from
`Get-DFConfiguredTheme` (which keeps its one job, the fallback chain).

```
Resolve-DFThemeName -Name <string> -ThemeMap <pscustomobject>  ->  [string]
```

**Algorithm:**

```
if $ThemeMap is non-null AND has a key equal to $Name (case-insensitive):
    return $ThemeMap[$Name]      # canonical -> this tool's dialect
else:
    return $Name unchanged       # pass-through
```

- No file I/O, no cache, no module state — the map is passed in by the caller
  (the sidecar reads its own `$DFCurrentTool.themeMap`). A `$null`/absent map
  yields pass-through, so a tool without a `themeMap` is unaffected.
- StrictMode-safe property reads (`$ThemeMap.PSObject.Properties[$Name]?.Value`).
- Purely a translator: it never validates a name or falls back — that stays in
  the sidecars (§6.2).

**Resulting sidecar flow:** `Get-DFConfiguredTheme` (chain) →
`Resolve-DFThemeName -ThemeMap $DFCurrentTool.themeMap` (canonical → this tool's
dialect, or pass-through) → the sidecar's existing built-in validation + fallback
→ apply.

## Section 3 — Sidecar refactors (glow, psreadline, mdcat, mdv)

Each sidecar: delete the hardcoded family line, insert a uniform
`Resolve-DFThemeName` call reading the tool's own `themeMap`, set the tool's
default theme to the **canonical** `catppuccin-mocha`. Built-in lists, fallbacks,
and application are unchanged. The call is uniform even for tools without a
`themeMap` (a `$null` map passes through):

```powershell
$_configured = Get-DFConfiguredTheme -ToolKey '<Tool>Theme' -Default 'catppuccin-mocha'
$_native     = Resolve-DFThemeName -Name $_configured `
                    -ThemeMap ($DFCurrentTool.PSObject.Properties['themeMap']?.Value)
# ... existing built-in validation + fallback + apply on $_native ...
```

- **glow** (`Tools/glow.ps1`): remove the `if ($Name -eq 'catppuccin')` line in
  `Resolve-DFGlowStyle`; resolve in the body before handing to
  `Resolve-DFGlowStyle`. No `themeMap` (native == canonical). Default stays
  `catppuccin-mocha`.
- **psreadline** (`Tools/psreadline.ps1`): remove the `if ($Name -eq 'catppuccin')`
  line in `Invoke-DFApplyPSReadLineTheme`; resolve in the body. No `themeMap`.
  Default `dark` passes through.
- **mdcat** (`Tools/mdcat.ps1`): remove the `if ($_name -eq 'catppuccin')` line;
  resolve via the uniform call. No `themeMap`. Keep the "override only when
  `$DFConfig` specifies a theme" behavior and the env-block static default (B).
- **mdv** (`Tools/mdv.ps1`): replace the reverse rule `if ($_name -like
  'catppuccin-*')` with the uniform call; **add `"themeMap": { "catppuccin-mocha":
  "catppuccin" }` to `Tools/mdv.json`**; default becomes canonical
  `catppuccin-mocha` (resolver returns `catppuccin`).

**Behavior change:** the bare alias `catppuccin` is no longer special-cased. All
*defaults* are canonical, so out-of-the-box rendering is unchanged; a user who
explicitly set `<Tool>Theme = 'catppuccin'` must switch to `catppuccin-mocha`.
Existing tests exercising the `catppuccin` alias are updated to the canonical.

## Section 4 — New `delta.ps1` sidecar + `delta.json` change

`Tools/delta.ps1` (new, minimal — theming is its only job):

```powershell
$_theme  = Get-DFConfiguredTheme -ToolKey 'DeltaTheme' -Default 'catppuccin-mocha'
$_native = Resolve-DFThemeName -Name $_theme `
                -ThemeMap ($DFCurrentTool.PSObject.Properties['themeMap']?.Value)
[System.Environment]::SetEnvironmentVariable('DELTA_FEATURES', $_native, 'Process')
```

`Tools/delta.json`: remove `DELTA_FEATURES` from the `env` block (the sidecar
owns it now); keep `GIT_PAGER` in `env`. No `themeMap` (native == canonical), no
built-in validation — delta features are user-defined names, and delta silently
ignores an unknown feature.

## Section 5 — Testing

- **`Resolve-DFThemeName` unit tests:** a `themeMap` with the canonical key
  returns the dialect (mdv's `catppuccin`); a `$null`/absent map passes through;
  a name not in the map passes through; case-insensitive key match.
- **Per-tool `themeMap` shape:** `Tools/mdv.json` has `themeMap` mapping
  `catppuccin-mocha` → `catppuccin`; if `Test-DFToolSchema` grows a `themeMap`
  check, values are non-empty strings.
- **Sidecar tests:** glow/psreadline/mdcat/mdv land on the correct native name;
  setting `$DFConfig.Theme = 'catppuccin-mocha'` yields `catppuccin` for mdv and
  `catppuccin-mocha` for glow/psreadline/mdcat; **existing `catppuccin`-alias
  assertions updated to `catppuccin-mocha`** (notably `tests/mdcat.Tests.ps1`'s
  "maps the shared catppuccin family" test; plus mdv/glow/psreadline theme tests).
- **New `tests/delta.Tests.ps1`:** registering delta sets `DELTA_FEATURES` from
  the resolved theme (default `catppuccin-mocha`; `DeltaTheme`/`Theme` override);
  a non-canonical `DeltaTheme` passes through verbatim.
- **Update `tests/XdgSplit.Tests.ps1`** (from workstream B): its "delta env
  carries GIT_PAGER and DELTA_FEATURES" test asserts `env.DELTA_FEATURES` — since
  `DELTA_FEATURES` moves out of the `env` block into `delta.ps1`, drop that
  assertion (keep `GIT_PAGER`) and optionally assert `delta.json` no longer
  carries `DELTA_FEATURES` in `env`.
- Full suite green under Pester 5.8.0 and 6.0.1.

## Section 6 — Documentation

- **`ToolAcquisitionSpec.md` §6.2** — replace the central-aliases-file model with
  the per-tool model: each themed tool optionally declares a `themeMap`
  (canonical → its dialect) in its own JSON; `Resolve-DFThemeName` translates
  using the target tool's map; shared `Theme` is canonical-only; per-tool
  overrides accept canonical or that tool's own native; the canonical is the only
  translation trigger. Note the alignment with `docs/plugin-architecture.md`.
- **CLAUDE.md** — a short note on theme resolution under "Tool JSON Schema":
  optional `themeMap` (canonical → dialect); `Get-DFConfiguredTheme` (chain) +
  `Resolve-DFThemeName` (translate via the tool's own `themeMap`); sidecars
  validate against their own built-in lists; shared `Theme` must be canonical.
- **`docs/external-dependencies.md`** — add/adjust the delta entry: DotForge sets
  `DELTA_FEATURES` from the resolved theme; rendering requires a delta config
  defining that feature (out of DotForge's scope) — degrade silently if absent.
- **CHANGELOG.md** `[Unreleased]` — Changed: theme family→dialect mapping moved
  from hardcoded sidecar rules into an optional per-tool `themeMap` resolved by
  `Resolve-DFThemeName`; the bare `catppuccin` alias is retired in favor of the
  canonical `catppuccin-mocha`; delta's `DELTA_FEATURES` now tracks `$DFConfig.Theme`.
- **README.md** — if it documents `$DFConfig` theme keys, note the canonical-only
  shared `Theme` rule and the per-tool override rule.

## Acceptance criteria

- No central theme file exists; the family→dialect mapping lives in each tool's
  own optional `themeMap` block. mdv declares `{ "catppuccin-mocha": "catppuccin" }`;
  glow/psreadline/mdcat/delta need none (native == canonical).
- `Resolve-DFThemeName -Name <canonical> -ThemeMap <map>` returns the dialect;
  a `$null`/absent map or a non-canonical name passes through; no file I/O.
- glow/psreadline/mdcat/mdv contain no hardcoded family→dialect mapping; they
  resolve via `Resolve-DFThemeName` reading their own `themeMap`; defaults are
  canonical.
- delta responds to `$DFConfig.Theme`/`DeltaTheme` via `Tools/delta.ps1`;
  `DELTA_FEATURES` leaves `delta.json`'s `env` block.
- Setting `$DFConfig.Theme = 'catppuccin-mocha'` yields `catppuccin` for mdv and
  `catppuccin-mocha` for glow/psreadline/mdcat/delta — proven by tests.
- Adding a hypothetical new themed tool requires only its own files (a `themeMap`
  if its dialect differs) — no core edit. (Plugin-invariant check.)
- The standard, CLAUDE.md, external-dependencies, and CHANGELOG are updated.
- No regression in the full suite (both Pester versions).
