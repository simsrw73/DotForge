# Alias Ownership — Design

**Date:** 2026-07-26
**Status:** Approved design; ready for implementation planning.
**Parent standard:** `ToolAcquisitionSpec.md` §9 (Aliases); audit
`ToolAcquisitionSpec-Audit.md` platform gap #5.
**Governed by:** `docs/plugin-architecture.md` (core invariant), `docs/builtin-safety-policy.md`
(new — never silently claim a builtin name).

## Purpose

The audit found that `DotForge.psd1`'s `AliasesToExport` is decorative:
DotForge's helper aliases are created with `Set-Alias -Scope Global -Force`
at dot-source time, so the module never actually owns them —
`(Get-Module DotForge).ExportedAliases` is empty, and `Remove-Module DotForge`
leaves every alias behind. `Get-DFCommandConflict` reads the manifest's raw
`AliasesToExport` list purely as data, precisely because the real export
mechanism reports nothing.

This workstream fixes that for the category of aliases where it's actually
fixable, and formally documents why the other category (tool/picker aliases)
is not — and, prompted by an incident found while investigating this
(`copy` colliding with the builtin `copy`→`Copy-Item`), establishes a standing
policy against silently claiming builtin names, and renames `copy`→`yank`.

## Grounding facts (verified empirically, not assumed)

- **27 general-helper aliases** (`pg`, `hm`, `clh`, `clhp`, `fcmd`, `fverb`,
  `fmod`, `fh`, `up`, `mkcd`, `fcd`, `touch`, `which`, `open`, `fps`, `top`,
  `env`, `path`, `fenv`, `ep`, `reload`, `copy`, `paste`, `uuidgen`, `trifle`,
  `ftrifle`, `tcats`) are declared across 11 `Public/*.ps1` files, each via a
  top-level `Set-Alias -Name <n> -Value <Function> -Scope Global -Force`. Each
  is 1:1 with a specific public function — a closed, static, author-time-known
  set.
- **`DotForge.psm1` has no `Export-ModuleMember` call at all** — it relies
  purely on the manifest's `FunctionsToExport`/`AliasesToExport` declarations.
  `Public/*.ps1` files are dot-sourced from the module's own script scope.
- **Verified via a throwaway test module:** a bare `Set-Alias -Name X -Value Y`
  (no `-Scope Global`) inside a dot-sourced file, when `X` is already listed in
  the manifest's `AliasesToExport`, produces a *genuinely* module-owned alias —
  `(Get-Module).ExportedAliases` reports it, `(Get-Alias X).ModuleName` is the
  module's name, and `Remove-Module` cleans it up. **No other restructuring is
  needed** — no `[Alias()]` attributes, no explicit `Export-ModuleMember` call —
  because the manifest already lists the correct names.
- **Verified: real module exports do NOT change import-time clobbering
  behavior.** Tested both with and without `-Force` on `Import-Module`: a
  genuinely-exported alias silently overwrites a pre-existing same-named global
  alias, with **no warning either way** — identical observable behavior to
  today's `-Scope Global -Force`. The fix's actual, verified benefit is
  ownership/introspection (`ExportedAliases`, `Remove-Module` cleanup), **not**
  clobber-safety. (A prior design draft assumed otherwise; corrected after
  empirical testing — see "Explicitly out of scope" below.)
- **Only one of the 27 names collided with a PowerShell builtin: `copy`**
  (→ `Copy-Item`, `Options=AllScope`). Verified: an `AllScope` alias cannot be
  overridden outside global scope, with or without `-Force` — the override
  fails with `"The AllScope option cannot be removed from the alias 'copy'"`
  even when both `-Force` and module scope (no `-Scope Global`) are used
  together. The *existing* code's `-Scope Global -Force -Option AllScope` was a
  deliberate (if undocumented) choice to replicate the builtin's all-scopes
  visibility — but it made this one alias structurally unfixable within the
  ownership model, and was never surfaced to users as a considered trade-off.
- **Resolution: rename `copy` → `yank`.** Verified `yank` has no builtin
  collision. This removes the exception entirely — all 27 aliases now follow
  the identical, uniform fix.
- **Dynamic tool/picker aliases** (`ls`, `cat`, `ff`, …, created by
  `Register-DFTool` from `Tools/*.json`) are inherently session-created,
  data-driven per user/machine — they can never be a static manifest list.
  `Get-DFCommandConflict.ps1` already reads the tool DB directly for exactly
  this reason. This is a design fact, not a defect to fix.

## Scope

**In scope:**
1. Rename the `copy` alias to `yank` (4 real files: `Public/DFHelpers.Clipboard.ps1`,
   `DotForge.psd1`, `README.md`, `tests/DFHelpers.Clipboard.Tests.ps1`).
2. Make all 27 general-helper aliases genuinely module-owned by dropping
   `-Scope Global -Force` (and, for `yank`, the now-unnecessary `-Option AllScope`)
   from their `Set-Alias` call sites.
3. Document the dynamic tool/picker-alias category as intentionally
   registry-owned (not manifest-owned) — amending the audit's open question,
   not leaving it as "TBD."
4. A consistency test guarding against future drift between the two categories
   (a name in `AliasesToExport` must never also be declared as a tool/picker
   alias in any shipped `Tools/*.json`, and vice versa).
5. `docs/builtin-safety-policy.md` and the `TODO.md` future-idea entry are
   **already committed** (this session, ahead of the plan) — this workstream's
   plan only needs to apply the `copy`→`yank` rename and ownership fix; the
   policy/TODO documentation is done.

**Explicitly out of scope** (confirmed with the user after the empirical
correction):
- **Clobber-safety on import.** Real module ownership does not change
  collision behavior (verified above) — this is normal PowerShell module
  behavior for every module, not a DotForge-specific defect. Not addressed
  here.
- **The opt-in/opt-out whitelist/blacklist mechanism** — shelved, captured in
  `TODO.md` Priority 3, not implemented.
- **Refactoring `Register-DFTool`'s dynamic alias creation** — it already uses
  `-Scope Global -Force` deliberately (idempotent re-registration; the
  documented Alias-outranks-Function precedence fix for wrapper functions) and
  is unaffected by this workstream.

## Section 1 — The uniform fix (26 existing call sites + the `yank` rename)

For each of the 27 `Set-Alias` call sites across `Public/*.ps1`:

```powershell
# Before (all 27, e.g. Public/DFHelpers.Pager.ps1):
Set-Alias -Name pg -Value Invoke-DFWithPager -Scope Global -Force

# After:
Set-Alias -Name pg -Value Invoke-DFWithPager
```

For `copy` specifically, in `Public/DFHelpers.Clipboard.ps1`:

```powershell
# Before:
Set-Alias -Name copy -Value Copy-DFToClipboard -Scope Global -Force -Option AllScope

# After (renamed, no scope/force/option needed — no builtin collision):
Set-Alias -Name yank -Value Copy-DFToClipboard
```

Update the function's comment-based help (`.SYNOPSIS`/`.EXAMPLE` referencing
"copy equivalent" / "using the copy alias") to say `yank`.

`DotForge.psd1`'s `AliasesToExport` list is otherwise unchanged in *content*
(all 27 names, `copy` replaced by `yank`) — it already had the right names;
the mechanism now actually honors it.

## Section 2 — Formalize the dynamic tool/picker-alias category

No code change. Document (in `ToolAcquisitionSpec.md` §9 and
`docs/external-dependencies.md`) that tool/picker aliases are, by design,
never part of `AliasesToExport` — they are read directly from the tool DB by
`Get-DFCommandConflict` and created at `Register-DFTool` runtime, because their
existence is conditional on what's installed and what `$DFConfig.Defaults`
says. This closes the audit's "pick option 1 or 2" framing: both apply,
scoped to their respective category.

## Section 3 — Consistency guard

A test (new or appended to an existing schema/consistency test file) that:
- Loads `DotForge.psd1`'s `AliasesToExport`.
- Loads every `Tools/*.json` and collects every declared `aliases` key and
  `picker.alias` value.
- Fails if any name appears in **both** sets — a signal that a general-helper
  alias and a tool alias have collided, which the two-category model assumes
  never happens.

## Section 4 — Testing

- **Real-import test** against the actual `DotForge.psd1` (not a throwaway
  module): `Import-Module DotForge -Force`; assert `(Get-Module DotForge).ExportedAliases`
  contains all 26 non-`yank`-affected names correctly (in fact all 27 including
  `yank`, since it now has no collision either) plus `yank`; assert each
  resolves and its `.ModuleName` is `DotForge`; `Remove-Module DotForge` then
  removes all of them from the session.
- **`tests/DFHelpers.Clipboard.Tests.ps1`** updated: the alias is `yank`, not
  `copy`; behavior (pipeline join, clipboard write) is otherwise unchanged and
  its existing mocked-clipboard tests carry over unmodified apart from the name.
- **Consistency guard test** (Section 3) as new coverage.
- Full suite green under Pester 5.8.0 and 6.0.1.

## Section 5 — Documentation

- **`README.md`** — the `$DFConfig`/alias reference table: `copy` → `yank`.
  Any prose mentioning "the copy alias" updated.
- **`CHANGELOG.md`** `[Unreleased]` → `### Changed` — the alias rename
  (user-visible, arguably breaking for anyone's muscle memory) and the
  ownership fix (informational — `Remove-Module`/`ExportedAliases` now behave
  correctly; no action needed from users).
- **`ToolAcquisitionSpec.md`** §9 — add the two-category model (general-helper
  aliases are manifest-owned; tool/picker aliases are registry-owned by
  design) and a pointer to `docs/builtin-safety-policy.md` for the "check
  against a builtin before adding any alias" rule.
- **`docs/external-dependencies.md`** — update or remove the existing
  "`AliasesToExport` is decorative" note (it becomes true only for the
  dynamic tool/picker category now, not the general-helper one).
- **`TODO.md`** — mark both original tracked items ("`AliasesToExport` is
  decorative" and "stop force-creating global aliases at import time")
  resolved, with the corrected finding recorded (ownership fixed; clobber
  behavior is unchanged, by design, per the empirical correction above).

## Acceptance criteria

- All 27 general-helper aliases (including `yank`, formerly `copy`) are
  created via a bare `Set-Alias` (no `-Scope Global`, no `-Force`, no
  `-Option AllScope`) and are genuinely exported: `(Get-Module DotForge).ExportedAliases`
  lists all 27; each resolves with `.ModuleName -eq 'DotForge'`;
  `Remove-Module DotForge` removes all of them.
- No remaining reference to the `copy` alias in any current (non-historical)
  file; `yank` is documented everywhere `copy` was.
- The consistency guard test exists and passes against the shipped
  `Tools/*.json` set.
- `ToolAcquisitionSpec.md`, `docs/external-dependencies.md`, `CHANGELOG.md`,
  `README.md`, and `TODO.md` are updated.
- No regression in the full suite (both Pester versions).
