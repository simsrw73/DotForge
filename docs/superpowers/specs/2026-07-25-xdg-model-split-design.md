# XDG Model Split — Design

**Date:** 2026-07-25
**Status:** Approved design; ready for implementation planning.
**Parent standard:** `ToolAcquisitionSpec.md` §3 (the XDG ladder); audit
`ToolAcquisitionSpec-Audit.md` platform gap #2 and decision #4.

## Purpose

The tool JSON `xdg` object is overloaded. It is meant to declare **XDG
conformance** — where a tool's config/data/state/cache land and the mechanism
that makes the tool honor those locations. In practice four tools also stuff
**non-XDG session settings** into `xdg.vars`:

| Tool | Non-XDG values currently in `xdg.vars` | Real XDG paths present? |
|---|---|---|
| **fzf** | `FZF_DEFAULT_COMMAND`, `FZF_DEFAULT_OPTS`, `FZF_ALT_C_COMMAND`, `FZF_ALT_C_OPTS`, `FZF_CTRL_T_COMMAND`, `FZF_CTRL_T_OPTS` | No |
| **delta** | `GIT_PAGER`, `DELTA_FEATURES` | No |
| **less** | `LESS` (flag string) | **Yes** (`LESSHISTFILE`, `LESSKEY`) |
| **mdcat** | `MDCAT_THEME` | No |

This conflates "XDG path placement" with "arbitrary environment settings" and
forced a special case into `Private/Expand-DFXdgPath.ps1` (flag strings passing
through un-normalized). This workstream introduces a dedicated channel for
non-XDG environment variables and reduces `xdg.vars` to a single, honest
purpose.

**Target invariant:** after this workstream, **`xdg.vars` contains only
`${XDG_*}` path templates.** Every non-path environment variable lives in a new
top-level `env` block. The invariant has no exceptions — including the two
theme vars (`DELTA_FEATURES`, `MDCAT_THEME`), which move now even though
workstream C (theme centralization) will later change how their *values* are
computed.

## Scope

**In scope:** introduce the `env` block; teach `Register-DFTool` to apply it;
migrate fzf, delta, less, and mdcat; amend the standard and docs; add tests.

**Out of scope:**
- Theme *value resolution* (routing `DELTA_FEATURES`/`MDCAT_THEME` through the
  theme resolver / a sidecar) — workstream C. B only relocates the vars.
- The broader `compliance`/`method` (`none` vs `default`) reconciliation across
  all 36 tools — workstream A/F retrofit. B touches only the four tools above.
- Any change to `PAGER`/`EDITOR`/`VISUAL` only-when-unset policy (§5).

## The `env` block

A new **top-level** object in the tool JSON, sibling to `xdg` (path placement)
and `settings` (sidecar-consumed data). A flat `env-var → value` map:

```jsonc
"env": {
  "GIT_PAGER": "delta",
  "DELTA_FEATURES": "catppuccin-mocha"
}
```

- **Applied unconditionally** by `Register-DFTool`, independent of any
  `xdg.method` — environment variables are not tied to XDG placement.
- **Behavior-preserving semantics:** each value is set via
  `[System.Environment]::SetEnvironmentVariable($name, (Expand-DFXdgPath $value), 'Process')`
  — the exact mechanism the `xdg.method: env` branch uses today, so migrated
  vars are set identically (clobber semantics unchanged; this is a pure
  structural refactor, not a policy change).
- **`Expand-DFXdgPath` is reused unchanged.** A token-less flag string (e.g.
  `FZF_DEFAULT_OPTS`, `LESS`) passes through byte-for-byte; a value that
  references `${XDG_*}` still expands. The helper's dual-use now serves the
  `env` channel instead of `xdg.vars`.

## Per-tool migration

| Tool | `xdg.method` | `xdg.vars` after | `xdg.compliance` | new `env` block |
|---|---|---|---|---|
| **fzf** | `env` → `default` | *(removed)* | `none` (unchanged) | all 6 fzf vars |
| **delta** | `env` → `default` | *(removed)* | `none` (unchanged) | `GIT_PAGER`, `DELTA_FEATURES` |
| **less** | `env` (unchanged) | `LESSHISTFILE`, `LESSKEY` (+ `dirs` unchanged) | `partial` (unchanged) | `LESS` |
| **mdcat** | `env` → `default` | *(removed)* | `full` (unchanged) | `MDCAT_THEME` |

**The `method: default` call for fzf/delta/mdcat.** With no XDG paths left,
their `xdg` block does nothing, so `method` becomes `default` — the existing
no-op branch ("take no XDG action"). This treats the two `xdg` fields as
distinct concerns: **`method` = dispatch key** (what `Register-DFTool` does),
**`compliance` = documentation** (how XDG-native the tool is). Thus
`method: default` + `compliance: none` (fzf/delta) reads consistently as "not
XDG-compliant, and DotForge takes no XDG action — the `env` channel does the
work"; mdcat becomes *correctly* `method: default` + `compliance: full` (it is
XDG-native; it was only mislabeled `env` to carry the theme var). No new
`method` value is introduced and the `Register-DFTool` switch is unchanged.

## `Register-DFTool` change

One addition, immediately after the existing `xdg` switch (`Public/Register-DFTool.ps1`,
after the block ending ~line 135):

```powershell
# ── Non-XDG environment settings ───────────────────────────────────
$envBlock = $tool.PSObject.Properties['env']?.Value
if ($envBlock) {
    $envBlock.PSObject.Properties | ForEach-Object {
        [System.Environment]::SetEnvironmentVariable(
            $_.Name,
            (Expand-DFXdgPath $_.Value),
            'Process'
        )
    }
}
```

No other production code changes. `Import-DFToolDb`/`Get-DFTool` load the JSON
as-is; the `env` property rides along and is read only here.

## Testing

- **`Register-DFTool` env-block application:** a tool JSON with an `env` block
  sets each variable through the test-mockable environment boundary; a value
  containing `${XDG_*}` expands; a tool with no `env` block is unaffected. Use
  the same env-boundary mocking the existing `xdg.method: env` tests use.
- **Behavior preservation (the key guard):** after registering each of fzf,
  delta, less, mdcat, assert the exact environment variables they set today are
  still set to the same values — `FZF_DEFAULT_OPTS` preserved byte-for-byte
  (multiline, colors intact), `LESS` flag string intact, `GIT_PAGER=delta`,
  `DELTA_FEATURES`/`MDCAT_THEME` present. This proves the migration is a pure
  relocation. Save/restore each touched env var in `BeforeEach`/`AfterEach`.
- **`xdg` no-op:** for fzf/delta/mdcat, registering no longer creates or sets
  anything via the `xdg` path (method `default` is a no-op); `less` still sets
  its two XDG path vars and creates its dirs.
- **Shipped-data schema:** if a schema/consistency test over `Tools/*.json`
  exists, extend it to allow the optional `env` block and to assert
  `xdg.vars` values are all `${XDG_*}` templates (the new invariant) for the
  migrated tools.

## Documentation / normative updates

- **`ToolAcquisitionSpec.md` §3** — amend the path-templating paragraph: non-path
  environment values belong in the top-level `env` block, not `xdg.vars`;
  `xdg.vars` values are `${XDG_*}` path templates only. Remove the "`xdg.vars`
  values MAY also be plain strings (e.g. `LESS`)" allowance and point to `env`.
- **CLAUDE.md "Tool JSON Schema"** — document the optional top-level `env` block
  (`env-var → value`, applied unconditionally, values expanded via
  `Expand-DFXdgPath`).
- **`docs/external-dependencies.md`** — the `Expand-DFXdgPath` flag-string
  note re-points from "LESS in `xdg.vars`" to "the `env` channel."
- **CHANGELOG.md** `[Unreleased]` — Changed: non-XDG environment variables moved
  from `xdg.vars` to a dedicated top-level `env` block (fzf, delta, less,
  mdcat); `xdg.vars` is now path-templates-only.
- **README.md / examples/** — grep for references to the migrated vars or to
  `xdg.vars` holding flag strings; update any that exist. (No runtime surface
  changes for users; the vars are still set.)

## Acceptance criteria

- A top-level `env` block is defined, documented in the standard and CLAUDE.md,
  and applied by `Register-DFTool` unconditionally via `Expand-DFXdgPath`.
- fzf, delta, less, and mdcat are migrated per the table; `xdg.vars` for every
  one contains only `${XDG_*}` templates (empty for fzf/delta/mdcat).
- Behavior-preservation tests prove each tool sets the same environment
  variables to the same values after migration as before.
- The standard (`ToolAcquisitionSpec.md` §3), CLAUDE.md, external-dependencies,
  and CHANGELOG are updated.
- No regression in the full suite.
