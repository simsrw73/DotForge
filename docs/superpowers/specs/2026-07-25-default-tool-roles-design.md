# Default-Tool Roles — Design

**Date:** 2026-07-25
**Status:** Approved design; ready for implementation planning.
**Parent standard:** `ToolAcquisitionSpec.md` §10 (Default Tool Selection); audit
`ToolAcquisitionSpec-Audit.md` platform gap #3.
**Governed by:** `docs/plugin-architecture.md` (core invariant — adding a tool
never modifies core, no central per-tool registry).

## Purpose

When several tools do the same job (a modern `ls` replacement; a markdown
viewer), the user should pick one **winner**, and only the winner should claim
the contested aliases for that role (`ls`, `ll`, `la`, `tree`). Today there is
no mechanism for this at all: `$DFConfig.Defaults` is documented in
`ToolAcquisitionSpec.md` §10.1 but never implemented, and the audit correctly
warns against deriving "which tools compete for the same role" from
`data/tool-categories.json`'s `function` field — that field is deliberately
broad and multi-valued (verified: `eza`, `broot`, and `fd` all carry
`file-management`, even though only `eza` is a genuine `ls` replacement; using
it directly would wrongly treat `fd`/`broot` as `eza`'s rivals).

**Grounding fact:** among the 38 shipped tools, **zero aliases currently
collide** — every declared alias key maps to exactly one tool. `eza` alone owns
`ls`/`ll`/`la`/`tree`. This workstream builds the mechanism and proves it with a
genuine second occupant: `lsd`, a real, verified `ls`/`eza` alternative, onboarded
as part of this work.

## Configuration model

- **`role`** (optional, top-level string, per tool JSON): a free-form name a
  tool declares to say "I compete in this equivalence group" (e.g.
  `"role": "listing"`). No central role registry or enum — a role name is just
  a string the user also uses as a key in `$DFConfig.Defaults`. Per the plugin
  invariant, a new tool joins an existing role by declaring this one field in
  its own JSON; nothing else changes.
- **`$DFConfig.Defaults`** (already documented in §10.1, now implemented): a
  role → winning-tool-name map, e.g. `@{ listing = 'eza' }`. Declarative only —
  no startup prompt.
- **Contested aliases are computed, not declared.** "Contested" simply means
  "an alias key the role's winner also declares." This is derived at
  registration time from each participating tool's own existing `aliases`
  block — no new per-role alias-list data file. A tool that shares a role but
  has an alias the winner does **not** also have keeps that alias.

## Section 1 — Winner resolution & suppression algorithm (in `Register-DFTool`)

A pre-pass runs before the main per-tool registration loop (both `-All` and
`-Name` — the mechanism only depends on `$DFConfig.Defaults` + the loaded tool
DB + the current call's tool set, never cross-call state):

1. For each role key in `$DFConfig.Defaults`, resolve the named tool from the
   full DB (`Import-DFToolDb`'s result, not just the tools being registered).
2. **Validate role match.** If the named tool doesn't exist in the DB, or its
   own `role` property doesn't equal this role key, `Write-Warning` and treat
   this role's `Defaults` entry as absent (no suppression for anyone sharing
   that role, this run). Never throws — degrade silently.
3. **Validate the winner is actually active this call.** Check the same
   availability the main loop uses (`Get-Command`/module presence) AND that the
   winner isn't itself in the effective `SkipTools` set AND that the winner is
   part of the tool set actually being registered in this invocation (present
   in `$Name`, or included under `-All`). If the winner won't actually
   register, treat the role as absent (no suppression) — a `Defaults` entry
   naming an unavailable tool must never strand its peers without any alias.
4. If valid and active, record `role → Set(winner's own declared alias keys)`
   (e.g. `listing → {ls, ll, la, tree}`).

Then, inside the existing per-tool alias-registration step: if the tool being
processed declares a role present in the active-winners map from step 4, **and
this tool is not the winner**, skip creating any alias whose key is in that
role's winner-alias-set. Every other alias the tool declares, its XDG config,
its picker, and its companion `.ps1` are unaffected. The winner itself always
gets every alias it declares — the algorithm only ever filters losers.

A role with no `Defaults` entry at all is completely untouched — today's
collision behavior (whatever it is, e.g. last-registered-wins) is unchanged,
matching "no startup prompt, purely declarative" (§10.1).

## Section 2 — Onboarding `lsd` (the real pilot)

`lsd` (https://github.com/lsd-rs/lsd) is a genuine `ls`/`eza` alternative,
already installed on this dev machine via scoop (`lsd 1.2.0`), giving a real
tool to prove the mechanism against instead of only synthetic fixtures.

**Verified facts** (empirical, per the Tool Acquisition Standard's "don't trust
the docs" principle):

- Packages confirmed present in each catalog: `scoop: lsd`, `winget: lsd-rs.lsd`
  (confirmed via `winget search lsd`), `choco: lsd` (confirmed via
  `choco search lsd --limit-output`).
- **`lsd --config-file <path>` PANICS on a nonexistent path** — `thread 'main'
  panicked at src\main.rs:116:33: Provided file path is invalid`, not a clean
  error exit. This is a sharper failure mode than glow's exit-1-on-bad-style. A
  malformed-but-existing YAML file is handled more gracefully (a field-name
  error is printed), but the panic on a missing path means DotForge must never
  pass `--config-file` without first guaranteeing the path exists.
- **Decision: do not wire lsd's config in this workstream.** `xdg.method:
  "manual"`, `compliance: "none"`. Safely wiring `--config-file` needs strong
  path-existence guarantees that are real, separate scope — deferred to a
  future retrofit. This workstream's job is the role mechanism, not lsd's full
  XDG conformance.
- `lsd --help` (1.2.0) confirms direct flag equivalents for every eza alias
  DotForge needs to mirror: `--color`, `--icon`, `--group-directories-first`,
  `--hyperlink`, `-a/--all`, `-l/--long`, `--header`, `--tree`.

**`Tools/lsd.json`** (new):

```jsonc
{
  "name": "lsd",
  "description": "Modern ls replacement with colors, icons, and tree view",
  "tags": ["file", "directory", "ls"],
  "executable": "lsd.exe",
  "packages": { "scoop": "lsd", "winget": "lsd-rs.lsd", "choco": "lsd" },
  "xdg": {
    "compliance": "none",
    "method": "manual",
    "instructions": "lsd's --config-file panics on a nonexistent path; DotForge does not manage its config. Point --config-file yourself if you want a custom lsd config."
  },
  "role": "listing",
  "aliases": {
    "ls":   { "command": "lsd", "args": ["--color=auto", "--icon=auto", "--group-directories-first", "--hyperlink=auto"] },
    "ll":   { "command": "lsd", "args": ["--all", "--long", "--header", "--hyperlink=auto"] },
    "la":   { "command": "lsd", "args": ["--all", "--hyperlink=auto"] },
    "tree": { "command": "lsd", "args": ["--tree"] }
  },
  "picker": null
}
```

`picker: null` — `eza`'s existing file picker (`ff`) is not duplicated; not a
contested alias, no justification to add a second one for this workstream.

**`Tools/eza.json`** gains one line: `"role": "listing"`. Zero behavior change
by itself (no `Defaults` entry is required for `eza` to keep exactly its
current registration; the field only matters once a peer + a `Defaults` entry
exist).

## Section 3 — Testing

- **Synthetic-fixture unit tests** (mirroring the existing `testtool` pattern
  in `tests/Register-DFTool.Tests.ps1`) for the resolution mechanism itself:
  - winner + loser sharing a role, `Defaults` set → loser's contested aliases
    suppressed, non-contested alias kept, loser's XDG/picker/companion still run.
  - `Defaults` names a tool that doesn't declare that role → warns, no
    suppression for the whole role.
  - `Defaults` names a tool that isn't available/registering this call →
    degrades to no-op (no suppression) — the "stranded role" guard.
  - a tool with no `role` property is never touched by any of this.
  - no `Defaults` entry for a role at all → both tools register their aliases
    exactly as they do today.
- **Real end-to-end test** using the actual shipped `eza`/`lsd` records:
  `$DFConfig.Defaults = @{ listing = 'eza' }` → registering both tools leaves
  `lsd`'s `ls`/`ll`/`la`/`tree` absent, `eza`'s present. Flip
  `Defaults.listing = 'lsd'` → the reverse. Neither set → both register their
  full alias sets (today's behavior, unchanged).
- `Tools/lsd.json` passes `Test-DFToolSchema` (add to the seed-file list).

## Section 4 — Documentation

- **`ToolAcquisitionSpec.md` §10** — replace the "auto-added to the skip set"
  framing (§10.1's third bullet) with the alias-intersection mechanism
  actually implemented: contested aliases are computed as the intersection
  between a role's declared winner's aliases and a loser's aliases; losers keep
  everything else. Document the `role` field (§10, new subsection or folded
  into 10.1) as a per-tool declaration, not a central registry — cross-reference
  `docs/plugin-architecture.md`.
- **CLAUDE.md "Tool JSON Schema"** — document the optional `role` field.
- **CHANGELOG.md `[Unreleased]`** — Added: `$DFConfig.Defaults`-driven
  default-tool role resolution (contested-alias suppression for role losers);
  onboarded `lsd` as a real second `listing`-role tool alongside `eza`.
- **README.md** — add a `Defaults` example now that a real one exists
  (`Defaults = @{ listing = 'eza' }`), and an `lsd` mention alongside `eza` in
  the tool table if one exists there.
- **`docs/external-dependencies.md`** — new entry: lsd's `--config-file` panics
  on a nonexistent path; DotForge never passes it a path it hasn't verified
  exists (currently: never passes it at all, since config is `manual`).
- **examples/** — if any profile example lists `SkipTools = @('lsd')`-style
  guidance for listing tools, note `Defaults` as the preferred mechanism now
  that it exists; otherwise no change needed.

## Out of scope

- Full XDG/conformance-ledger work for `lsd` (workstream A/retrofit territory).
- Any other role beyond `listing` (pagers, markdown viewers) — no shipped tool
  contests an alias in those groups today; a future retrofit adds `role` to a
  tool only once a genuine second occupant exists, per the plugin invariant.
- Alias ownership / manifest-export questions (`AliasesToExport`) — workstream E.

## Acceptance criteria

- `Register-DFTool` implements the winner-resolution + contested-alias-only
  suppression algorithm above; degrades silently on every invalid/absent case.
- `Tools/lsd.json` exists, passes schema validation, and both `eza`/`lsd`
  declare `"role": "listing"`.
- Registering both `eza` and `lsd` with `Defaults.listing` set to either one
  leaves only the winner holding `ls`/`ll`/`la`/`tree`; the loser keeps
  everything else it declares.
- With no `Defaults` entry, behavior for any role-sharing tools is unchanged
  from today.
- The standard, CLAUDE.md, CHANGELOG, README, and external-dependencies are
  updated.
- Full suite green under Pester 5.8.0 and 6.0.1.
