# delta Catppuccin Theming — Design

**Date:** 2026-09-04
**Status:** Approved design; ready for implementation planning.
**Governed by:** `docs/plugin-architecture.md` (core invariant); the newly-recorded
`TODO.md` "silent-override risk" principle — the user must be able to see what
DotForge changed and easily undo it.

## Purpose

`Tools/delta.ps1` already sets `DELTA_FEATURES` from the resolved theme (default
`catppuccin-mocha`), but the matching `[delta "catppuccin-mocha"]` style block
has never existed anywhere delta looks — the feature name is a pointer to
nothing (`TODO.md`, tracked since 2026-07-15). This closes that gap using
[catppuccin/delta](https://github.com/catppuccin/delta)'s theme file — and,
along the way, fixes a second, already-shipped silent-override bug in how
`DELTA_FEATURES` itself is set (see Section 0).

## Timing (asked directly, worth stating explicitly)

This is **runtime, not install-time** — DotForge has no separate install
hook. Everything here runs inside `Tools/delta.ps1`, which executes every
time `Register-DFTool -Name delta` (or `-All`) runs, i.e. every new shell
via the user's profile, same as every other sidecar. The *check* of whether
work is still needed is cheap after the first run (Section 3's marker); the
*mutation* (deploying the theme file, adding the `include.path` entry)
happens at most once, ever, per machine.

## The core design decision (already made, not re-litigated here)

Two ways to hand delta the style block; the user explicitly chose the second
after weighing the tradeoff:

1. **`delta --config <path>`, via `GIT_PAGER`.** Self-contained (nothing
   outside DotForge's own footprint changes), but `--config <path>` *replaces*
   delta's entire config resolution rather than layering on it — any of the
   user's own `[delta ...]` settings would be silently shadowed the moment
   `GIT_PAGER` includes that flag, with no visible trace of why.
2. **`[include] path = ...` in the user's real global git config.** This is
   catppuccin/delta's own recommended install method. It's additive — the
   user's existing delta settings keep working — and it's visible: the line
   sits in a file the user already knows to check for git/delta behavior,
   with a comment explaining what it is and a one-line removal instruction.

**Decided: option 2.** The user's own words: *"I strongly want to avoid doing
anything that is not explicit that the user can easily see what is happening
and have an easy way to override the choices we make as default."*

## Verified facts

- **The user's actual global git config is not `~/.gitconfig`.** `git config
  --list --show-origin --global` resolves to `$XDG_CONFIG_HOME/git/config`
  here (confirmed: `C:\Users\simsr\.config\git\config`) — git supports the
  XDG convention for its own config file, and since DotForge already sets
  `$XDG_CONFIG_HOME` (`Initialize-DFEnvironment`), this is the expected
  resolution on any DotForge-managed machine, not a quirk of this one. **Never
  hardcode `~/.gitconfig`** — let `git config --global` resolve the path
  itself (it already respects XDG internally); don't compute or guess it.
- **`git config --global --add include.path <value>`** appends correctly
  (verified on a scratch config via `GIT_CONFIG_GLOBAL=<scratch> git config
  ...`) and **`git config --global --get-all include.path`** reads back the
  exact value for an idempotency check before adding again.
- **delta 0.19.2** (installed here) needs no `catppuccin/bat` prerequisite —
  that's only required before delta 0.19 per the catppuccin/delta README.
- **catppuccin/delta's theme file is a single file** (`catppuccin.gitconfig`
  at the repo root, not a `themes/` directory as the README's generic
  `PATH/TO/delta/themes/...` instruction implies) containing all four
  flavours as separate `[delta "catppuccin-<flavour>"]` sections — including
  `catppuccin-mocha`, matching what `DELTA_FEATURES` already resolves to.
  Fetched and inspected directly (not assumed).
- **End-to-end confirmed working**: piping a real `git diff` through
  `delta --config <bundled-file>` (with `DELTA_FEATURES=catppuccin-mocha`
  already set, exactly as `Tools/delta.ps1` sets it today) produced real
  24-bit ANSI codes matching catppuccin-mocha's documented hex values
  (`38;2;205;214;244` = `#cdd6f4`, the theme's `file-style`).
- Each theme section's `syntax-theme` key names bat's theme by the *same*
  string (`Catppuccin Mocha`) `Tools/bat.json` now sets `BAT_THEME` to (per
  this session's own `bat` theming work) — coincidental shared naming with
  bat's own bundled themes (delta bundles the same syntax-highlighting
  library bat uses), not a runtime dependency on `BAT_THEME`; no coupling to
  manage.
- **`DELTA_FEATURES` without a leading `+` doesn't just override overlapping
  style keys — it discards the user's entire git-config `features` list.**
  Verified directly (not from the help text alone): a scratch config with
  `[delta] features = my-custom-feature` and a `line-numbers = true` setting
  unique to that feature — `DELTA_FEATURES=catppuccin-mocha` (today's shipped
  form, no `+`) reverts `line-numbers` to its default `false`; the *only*
  difference `DELTA_FEATURES=+catppuccin-mocha` makes is that `my-custom-feature`
  stays active *alongside* catppuccin-mocha (catppuccin still wins on any key
  both define, since it's applied later in the combined list — the `+` only
  changes whether the user's non-overlapping settings survive at all). This is
  a live bug in the already-shipped `Tools/delta.ps1` (from the July
  theme-centralization work), not something this task introduces — fixed here
  (Section 0) since it's the direct analog, for `features`, of what
  `include.path`'s own `--add` semantics already get right (Section 3).

## Scope

**In scope:** fix `DELTA_FEATURES` to be additive (`+`-prefixed); bundle the
theme file; deploy it to a stable XDG path; manage one `include.path` entry
in the user's real global git config (add if missing, a persisted marker so
an explicit removal by the user stays removed, visible confirmation naming
the exact removal command, an opt-out `$DFConfig` key); tests; docs.

**Out of scope:** a general "config-injection" primitive for other tools —
this is delta-specific plumbing; if another tool needs the same pattern later
it gets its own considered design, not a premature abstraction.

## Section 0 — Fix `DELTA_FEATURES` to be additive

In `Tools/delta.ps1`, the existing line

```powershell
[System.Environment]::SetEnvironmentVariable('DELTA_FEATURES', $_native, 'Process')
```

becomes

```powershell
[System.Environment]::SetEnvironmentVariable('DELTA_FEATURES', "+$_native", 'Process')
```

That's the entire fix — one character, `+`, prepended to the already-resolved
theme name. No other logic in the file changes: `Get-DFConfiguredTheme`/
`Resolve-DFThemeName` resolution is unaffected, this only changes how the
resolved name is *handed to delta*. Confirmed this doesn't change behavior
for the common case (no pre-existing `features` in the user's git config):
an empty/absent `features` list plus `+catppuccin-mocha` still just activates
catppuccin-mocha.

## Section 1 — Bundle the theme file

`Tools/delta/catppuccin.gitconfig` — the upstream file verbatim (already
fetched and inspected; all four flavours, `catppuccin-mocha` matches
`DELTA_FEATURES`'s existing default exactly). Matches the existing
`Tools/psreadline/*.json` / `Tools/glow/*.json` bundled-theme-file
convention.

## Section 2 — Deploy to a stable path

Module-relative paths (`$PSScriptRoot/delta/catppuccin.gitconfig`) are
fragile across a PSGallery version upgrade, which can relocate the module's
install directory. Deploy (always-refresh, not seed-once — this is pure
DotForge-shipped content with no user-customization expectation, matching
`Tools/carapace/specs/*.yaml`'s redeploy-every-run pattern, not `mdv`'s
seed-only-when-absent one) to:

```
$XDG_CONFIG_HOME/delta/catppuccin.gitconfig
```

via `New-DFDirectory`, from `Tools/delta.ps1`, skipping the write when the
deployed copy is already byte-identical (a `Get-Content`/`Set-Content`
comparison, not a raw `Copy-Item` — the same comparison `Tools/carapace.ps1`
uses for its own bundled specs, referenced above).

## Section 3 — Manage the `include.path` entry, once, respecting removal

**Revision note (2026-09-05):** this section originally drafted a bespoke
`delta-gitconfig-include.done` marker file plus a delta-specific
`$DFConfig['DeltaSkipGitConfig']` opt-out. The general one-time-setup
primitive this design anticipated (`docs/superpowers/specs/2026-09-04-tool-setup-lifecycle-design.md`)
has since shipped — `Tools/<name>.setup.ps1` run via `Invoke-DFToolCompanion`,
gated on `Get-DFToolSetupState`, recorded via `Complete-DFToolSetup`, opted
out via the general `$DFConfig['SkipSetup']` array — so this section is
rewritten to use that instead of inventing delta-specific machinery. Delta is
that primitive's first real consumer, exactly as planned.

**Why not "check `git config` every session, add if missing"**: it spawns
`git.exe` on every single shell startup just to check, and worse, it's not
actually an override-respecting design — if the user removes the include
line themselves, the very next session would see "not present" and silently
re-add it. A real override has to *stay* overridden. The one-time-setup
primitive's state file (`$XDG_STATE_HOME/dotforge/setup-state.json`) is
exactly this "stays overridden" record, generalized across tools instead of
reinvented per tool.

**Design: `Tools/delta.setup.ps1`, run at most once ever per machine.**

```powershell
# Tools/delta.setup.ps1
$deployedPath = ConvertTo-DFPath (Join-Path $Env:XDG_CONFIG_HOME 'delta' 'catppuccin.gitconfig')

$existing = git config --global --get-all include.path 2>$null
if ($existing -notcontains $deployedPath) {
    git config --global --add include.path $deployedPath
    Write-Host "DotForge: added catppuccin theme include to your global git config — remove with: git config --global --unset-all include.path `"$deployedPath`"" -ForegroundColor Green
}

Complete-DFToolSetup -Name 'delta' -Actions @(
    @{ type = 'gitConfigInclude'; path = $deployedPath }
)
```

- **Runs the `git config` check/add at most once, ever, per machine.**
  `Invoke-DFToolCompanion` dot-sources `Tools/delta.setup.ps1` only when
  `Get-DFToolSetupState` has no `delta` entry yet; once
  `Complete-DFToolSetup -Name 'delta'` records that entry, every later
  `Register-DFTool` call — this session or any future one — skips the file
  entirely, no process spawn.
- **Respects an explicit user removal.** If you delete the `include.path`
  line yourself, the state entry still exists, so DotForge does not
  re-examine or re-add it next session — your removal sticks. If you want
  DotForge to re-sync (e.g. after deliberately editing your git config),
  delete delta's entry from `$XDG_STATE_HOME/dotforge/setup-state.json` (or
  the whole file) and the check-and-add-if-missing runs again on the next
  registration.
- **Visible on the one time it actually adds something**: an explicit
  `Write-Host` naming the exact removal command, not a silent mutation
  discoverable only by chance.
- **Uses `git config` itself**, never hand-parses or hand-edits the config
  file — correct regardless of which physical path git resolves the global
  config to (`~/.gitconfig` vs. `$XDG_CONFIG_HOME/git/config`), and avoids
  any risk of corrupting a file DotForge doesn't own the format of.
- **`include.path` is additive by construction** (`--add`, confirmed) — an
  unrelated pre-existing `include.path` entry pointing at the user's own
  theme file is never touched, only ever added alongside.
- **Idempotent on retry.** If the script throws before reaching
  `Complete-DFToolSetup` (e.g. `git.exe` transiently unavailable), no state
  entry is written, so the next `Register-DFTool` call retries the whole
  script from the top per the primitive's own contract — the
  `-notcontains`-gated `--add` above is what makes that retry safe rather
  than appending a duplicate line.
- **Opt-out**: `$DFConfig['SkipSetup'] = @('delta')` skips this whole
  file — the general mechanism, not a delta-specific flag. Registering
  delta is still wanted for `DELTA_FEATURES`/`GIT_PAGER` (set by
  `Tools/delta.ps1`, which is unaffected by `SkipSetup`); a user can opt out
  of the git-config edit without losing that.

## Section 4 — Testing

`git config --global` mutates real, shared state — **tests must never touch
the actual global config**. Use `GIT_CONFIG_GLOBAL=<TestDrive path>` (verified
working directly: it fully redirects `git config --global`'s target file) set
for the duration of each test, matching how other tests isolate `$Env:XDG_*`
via `$TestDrive`.

- `DELTA_FEATURES` is set with a leading `+` (e.g. `+catppuccin-mocha`), not
  bare — the actual regression test for Section 0. Existing `DELTA_FEATURES`
  resolution tests in `tests/delta.Tests.ps1` (theme chain, `Resolve-DFThemeName`)
  are otherwise unchanged and still pass; only the literal env var *value*
  assertion needs the `+` added.
- Registering delta with no setup-state entry present (fresh
  `$XDG_STATE_HOME`, fresh `GIT_CONFIG_GLOBAL`, no prior entry) adds exactly
  one `include.path` entry pointing at the deployed file, and records a
  `delta` entry in `$XDG_STATE_HOME/dotforge/setup-state.json` via
  `Complete-DFToolSetup`.
- Registering delta again (state entry now present) does **not** re-invoke
  `git config` at all — assert this by removing the `include.path` entry
  from the test's scratch config after the first registration, registering
  again, and confirming the entry is *not* re-added (proves the state check
  actually short-circuits `Tools/delta.setup.ps1`, not just that it happens
  not to duplicate).
- The deployed file exists at the expected path and contains a
  `[delta "catppuccin-mocha"]` section.
- `$DFConfig['SkipSetup'] = @('delta')` registers delta (still sets
  `DELTA_FEATURES`) without touching `include.path` and without writing a
  `delta` setup-state entry.

## Section 5 — Documentation

- **README.md**'s delta subsection: explain the `include.path` addition, the
  visible confirmation message, the removal command, and the
  `$DFConfig['SkipSetup']` opt-out.
- **`docs/external-dependencies.md`**: new entry — delta's config-resolution
  rules (follows standard `git-config` file rules, not a delta-specific
  lookup) and the `--config <path>`-replaces-vs-`include.path`-layers
  distinction that drove this design, so a future contributor doesn't
  rediscover it the hard way.
- **`CHANGELOG.md`** `[Unreleased]`.
- **`TODO.md`**: close the delta line in the coverage-audit list.

## Acceptance criteria

- `DELTA_FEATURES` is set as `+<resolved-theme>` (additive), not bare —
  confirmed a pre-existing `features` entry (or `line-numbers`-style setting
  unique to it) in the user's own git config survives alongside DotForge's
  theme, matching the verified `+`-prefix behavior in this spec.
- `Tools/delta/catppuccin.gitconfig` exists, matches upstream.
- Registering `delta` for the first time (no setup-state entry present)
  deploys the file to `$XDG_CONFIG_HOME/delta/catppuccin.gitconfig`, adds
  exactly one matching `include.path` entry in the user's real global git
  config (verified via `git config --global --get-all include.path` in a
  real, isolated test config — never the developer's actual config), and
  records the `delta` entry in the setup-state file.
- Once the setup-state entry exists, registering delta again does not
  invoke `Tools/delta.setup.ps1` (and therefore not `git config`) at all —
  proven by an explicit removal-then-re-register test, not merely "no
  duplicate."
- Manually deleting the `delta` entry from the setup-state file (simulating
  "I want DotForge to re-check") causes the next registration to re-run the
  check-and-add.
- `$DFConfig['SkipSetup'] = @('delta')` skips the git-config edit and the
  state write entirely; `DELTA_FEATURES` still gets set (with the `+`
  prefix), since that's set by `Tools/delta.ps1`, not `Tools/delta.setup.ps1`.
- The first-time add prints a visible message naming the exact removal
  command.
- `git diff` piped through `delta` with `DELTA_FEATURES=+catppuccin-mocha`
  renders real catppuccin-mocha colors (already confirmed manually; the test
  only needs to assert the config plumbing, not delta's rendering).
- No test ever mutates the real global git config.
- README, `docs/external-dependencies.md`, `CHANGELOG.md`, `TODO.md` updated.
