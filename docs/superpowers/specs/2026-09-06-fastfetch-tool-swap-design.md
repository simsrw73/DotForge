# winfetch → fastfetch Tool Swap — Design

**Date:** 2026-09-06
**Status:** Approved design; ready for implementation planning.
**Governed by:** `docs/plugin-architecture.md` (core invariant — this is a
pure plugin swap, no core code changes); `TODO.md`'s existing coverage-audit
line (already called for this exact swap: winfetch is abandoned upstream,
fastfetch is its actively maintained successor).

## Purpose

`Tools/winfetch.json` configures an abandoned tool via an XDG workaround
(`WINFETCH_CONFIG_PATH` env var, `xdg.compliance: "partial"`). `fastfetch` is
the actively maintained successor, is natively XDG-aware, and can be shipped
with a real catppuccin-mocha themed default config instead of leaving the
user to write one from scratch. This also adds an optional, purely
documentation-level pattern for running it as a startup banner.

## Verified facts

- **`fastfetch` is installed locally (scoop, v2.68.1)** and its winget ID is
  confirmed via a live `winget search fastfetch` on this machine:
  `Fastfetch-cli.Fastfetch`. Scoop package name confirmed by the existing
  local install: `fastfetch`.
- **Timing measurements** (this machine, `Measure-Command` around real
  `fastfetch --config <file>` invocations, `*>​ $null` to discard output):
  - A minimal local-only module set (`os`, `host`, `kernel`, `uptime`,
    `shell`, `terminal`, `cpu`, `memory`, `disk`) runs in ~45-60ms steady
    state.
  - The full draft config (adds `packages`, `gpu`, `display`, `localip`,
    `publicip`, `physicaldisk`) runs ~100-125ms steady state, **but hit a
    2,871ms outlier on the very first invocation of the session** — isolating
    `publicip` alone (an HTTP/geoip lookup) reproduced the same ~100ms warm
    cost with no other module present, consistent with the spike being a
    cold DNS/TLS cost on that module's network call. `gpu` and
    `physicaldisk` showed no equivalent spike in repeated runs.
  - **Decision (user, after seeing this data): drop only `publicip`** from
    the shipped config; keep every other module from the original draft
    (`packages`, `gpu`, `display`, `localip`, `disk`, `physicaldisk`).
- **`Set-DFToolXdgConfig`'s `'config'` method already does everything this
  needs**: seeds `xdg.config_path` from `xdg.config_content` only when the
  target file is absent (`Private/Set-DFToolXdgConfig.ps1`), never
  overwriting a user's edits. No tool in the repo currently uses this method
  (`grep` for `config_content`/`config_path` across `Tools/*.json` returns
  nothing) — fastfetch is its first real consumer, and no core change is
  needed to support it.
- **`data/tool-categories.json` and `data/tool-identities.json` are
  build-generated**, not hand-edited (confirmed by reading
  `build/Build-DFCategoryDb.ps1` and `build/Build-DFToolIdentities.ps1`).
  `Build-DFCategoryDb.ps1` merges `build/categories/*.jsonc` fragments and
  throws on a duplicate tool key across fragments — so `fastfetch`'s existing
  entry in `build/categories/extras.jsonc` must move out before
  `dotforge-curated.jsonc` gains its own `fastfetch` key, not be added
  alongside it.
- **`fastfetch` already has a category entry** (in `extras.jsonc`, since it
  was previously cataloged as a known-but-not-shipped alternative to
  winfetch): `function: ["system-info"]`, `worksWith: ["filesystem"]`,
  `interface: "cli"`, `alternativeTo: ["neofetch"]`,
  `relatedTo: ["winfetch"]`, `popularity: 1`. This moves to
  `dotforge-curated.jsonc` with an added `ids` block; content otherwise
  unchanged.
- **The user's own scratch file `fastfetch.config.jsonc`** (untracked, repo
  root) is the source for the shipped config content, provided as a
  reference via `@`-mention in this conversation — it is folded into
  `Tools/fastfetch.json` as the single source of truth and then deleted
  standalone, so the config doesn't exist in two places that can drift.

## Scope

**In scope:** `Tools/fastfetch.json` (new); `Tools/winfetch.json` (deleted);
`build/categories/{extras,dotforge-curated}.jsonc` source edits + regenerated
`data/tool-categories.json` (local, no network) and `data/tool-identities.json`
(network-verified against live catalogs); README's Included Tools table;
`tests/Test-DFToolSchema.Tests.ps1` seed list; `TODO.md` line closed;
`examples/01-minimal.ps1` and `examples/02-standard.ps1` gain a commented-out
optional startup-banner line; root-level scratch `fastfetch.config.jsonc`
removed.

**Out of scope:** any new `$DFConfig` flag or core hook to auto-run fastfetch
at startup (user explicitly chose the docs-only approach); a bundled
companion `.ps1` (not needed — no runtime theme-switching like `fzf`'s, this
is a static seeded file); extending `Set-DFToolXdgConfig`'s `'config'` method
to support a separate bundled file instead of an inline string (no current
need, and no other consumer to justify the added surface — YAGNI per
`docs/plugin-architecture.md`).

## Section 1 — `Tools/fastfetch.json`

```json
{
  "name": "fastfetch",
  "description": "Fast, actively-maintained neofetch-like system information tool",
  "tags": ["system", "info"],
  "executable": "fastfetch.exe",
  "packages": {
    "scoop": "fastfetch",
    "winget": "Fastfetch-cli.Fastfetch"
  },
  "xdg": {
    "compliance": "full",
    "method": "config",
    "config_path": "${XDG_CONFIG_HOME}/fastfetch/config.jsonc",
    "config_content": "<jsonc below, embedded as a JSON string>"
  },
  "aliases": {},
  "picker": null
}
```

`compliance: "full"` because fastfetch reads `$XDG_CONFIG_HOME` natively —
unlike winfetch's `"partial"`/env-var redirection, DotForge isn't working
around any tool limitation here, it's choosing to *also* seed a themed
default via the already-generic `'config'` method.

Seeded config content (unescaped, for readability — the real file stores
this as one JSON string value per `config_content`'s existing contract):

```jsonc
{
  "$schema": "https://github.com/fastfetch-cli/fastfetch/raw/2.68.1/doc/json_schema.json",
  "logo": { "type": "none" },
  "display": { "separator": "  ", "color": { "keys": "#cba6f7", "output": "#cdd6f4" } },
  "modules": [
    "os", "host", "kernel", "uptime", "packages", "shell", "terminal",
    "cpu", "gpu", { "type": "memory", "format": "{used} / {total} ({percentage})" },
    "display", { "type": "localip", "format": "{ipv4} ({ifname})" },
    { "type": "disk", "format": "{mountpoint} ({filesystem}): {size-used} / {size-total} ({size-percentage})" },
    { "type": "physicaldisk", "hideVirtual": true, "hideUnused": true, "format": "{name} ({physical-type}, {interconnect}): {size}" }
  ]
}
```

`#cba6f7` (mauve) / `#cdd6f4` (text) are catppuccin mocha's own palette —
same colors already used by `bat.json`'s theming, kept literal here rather
than resolved through `Resolve-DFThemeName`/`Get-DFConfiguredTheme` since
fastfetch's config is a static seeded file, not a per-session runtime
resolution like `fzf`'s or `psreadline`'s companions. If per-session theme
switching for fastfetch is wanted later, that's a new design (a `.ps1`
companion rewriting the seeded file), not something this task should grow
into.

`logo: { type: "none" }` is deliberate for the "lightweight startup banner"
use case: rendering ASCII art costs cycles and vertical space that a
one-line-per-shell banner doesn't want.

## Section 2 — Category/identity data

1. Delete the `winfetch` key from `build/categories/dotforge-curated.jsonc`.
2. Move the `fastfetch` key from `build/categories/extras.jsonc` into
   `build/categories/dotforge-curated.jsonc`, adding:
   ```json
   "ids": { "scoop": "fastfetch", "winget": "Fastfetch-cli.Fastfetch" }
   ```
   keeping its existing `function`/`worksWith`/`interface`/`alternativeTo`/
   `relatedTo`/`popularity` values as-is.
3. Regenerate `data/tool-categories.json`:
   ```
   ./build/Build-DFCategoryDb.ps1
   ```
4. Regenerate `data/tool-identities.json`:
   ```
   ./build/Build-DFToolIdentities.ps1
   ```
   This independently re-verifies the `scoop`/`winget` package IDs against
   live catalogs — a second confirmation beyond the manual `winget search`
   already done, using cached results (no `-Fresh`) since this is a routine
   regen, not a release-time refresh.

## Section 3 — Housekeeping

- Delete `Tools/winfetch.json`.
- `README.md`: Included Tools table, System row: `procs, winfetch, gsudo` →
  `procs, fastfetch, gsudo`.
- `tests/Test-DFToolSchema.Tests.ps1`: seed-file list, `'winfetch'` →
  `'fastfetch'`.
- `TODO.md`: remove/check off the winfetch→fastfetch coverage-audit line
  (the task it described is now done).
- Delete the root-level scratch `fastfetch.config.jsonc` (its content now
  lives solely in `Tools/fastfetch.json`).

## Section 4 — Optional startup banner (documentation only)

`examples/02-standard.ps1`, near the top (alongside the file's other
optional, commented-out toggles):

```powershell
# ── Optional: lightweight system-info banner ──────────────────────────────────
# Uncomment to show a one-shot system summary at the top of every new shell.
# The bundled fastfetch config has no logo and skips network-dependent
# modules, so this stays fast even on a cold shell.
# if (Get-Command fastfetch.exe -ErrorAction Ignore) { fastfetch }
```

`examples/01-minimal.ps1` gets a one-line comment pointing at the same
pattern rather than duplicating the explanation, consistent with that file's
existing terse style.

No new `$DFConfig` key, no core hook — `Register-DFTool` never runs a tool's
executable as a side effect of registration, and this doesn't change that.

## Section 5 — Testing

This is a data/config swap, not new core logic, so no new core test suite is
needed. Verify by running the existing suites, which already assert every
seed file parses and passes schema validation:

- `Invoke-Pester tests/Test-DFToolSchema.Tests.ps1 -Output Detailed` — passes
  with `fastfetch` in the seed list and no `winfetch` reference remaining.
- `Invoke-Pester tests/ -Output Detailed` — full suite still green (nothing
  else references `winfetch` by name in module code, per the earlier repo
  search; only docs/data/build fragments do, all covered above).
- Manual: `Import-Module ./DotForge.psd1 -Force; Initialize-DFEnvironment;
  Register-DFTool -Name fastfetch` on a machine with fastfetch installed
  seeds `$XDG_CONFIG_HOME/fastfetch/config.jsonc` with the expected content
  on first run, and does not overwrite it on a second run after a manual
  edit.

## Acceptance criteria

- `Tools/fastfetch.json` exists, passes `Test-DFToolSchema`, and seeds the
  catppuccin-mocha config (minus `publicip`) at
  `$XDG_CONFIG_HOME/fastfetch/config.jsonc` only when absent.
- `Tools/winfetch.json` is gone; no remaining reference to `winfetch` in
  README's tool table, the test seed list, or `build/categories/*.jsonc`.
- `data/tool-categories.json` and `data/tool-identities.json` regenerated
  and reflect `fastfetch` as a curated (shipped) tool with verified
  `scoop`/`winget` IDs.
- `examples/01-minimal.ps1` / `02-standard.ps1` document the optional
  startup banner as a commented-out line; no automatic invocation anywhere
  in module code.
- Full Pester suite passes.
- `TODO.md`'s winfetch→fastfetch line is closed.
