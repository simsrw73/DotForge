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
[catppuccin/delta](https://github.com/catppuccin/delta)'s theme file.

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

## Scope

**In scope:** bundle the theme file, deploy it to a stable XDG path, manage
one `include.path` entry in the user's real global git config (add if
missing, visible marker comment, documented one-line removal, an opt-out
`$DFConfig` key), tests, docs.

**Out of scope:** a general "config-injection" primitive for other tools —
this is delta-specific plumbing; if another tool needs the same pattern later
it gets its own considered design, not a premature abstraction.

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

via `New-DFDirectory` + `Copy-Item`, from `Tools/delta.ps1`.

## Section 3 — Manage the `include.path` entry

```powershell
$deployedPath = ConvertTo-DFPath (Join-Path $Env:XDG_CONFIG_HOME 'delta' 'catppuccin.gitconfig')

$existing = git config --global --get-all include.path 2>$null
if ($existing -notcontains $deployedPath) {
    git config --global --add include.path $deployedPath
    Write-Host "DotForge: added catppuccin theme include to your global git config ($($env:XDG_CONFIG_HOME)\git\config or ~\.gitconfig, whichever git resolves) — remove with: git config --global --unset-all include.path `"$deployedPath`"" -ForegroundColor Green
}
```

- **Idempotent**: re-running `Register-DFTool` never adds a duplicate entry.
- **Visible on first add**: an explicit `Write-Host`, not silent — the user
  sees it happened and sees the exact removal command in the same message,
  not just a comment they'd have to go find in a file.
- **Uses `git config` itself**, never hand-parses or hand-edits the config
  file — correct regardless of which physical path git resolves the global
  config to (`~/.gitconfig` vs. `$XDG_CONFIG_HOME/git/config`), and avoids
  any risk of corrupting a file DotForge doesn't own the format of.
- **Opt-out**: `$DFConfig['DeltaSkipGitConfig'] = $true` skips this whole
  block — the one part of this feature that reaches outside DotForge's own
  XDG-scoped footprint, so it gets its own explicit escape hatch beyond "just
  don't register delta" (registering delta is still wanted for
  `DELTA_FEATURES`/`GIT_PAGER`; a user might want that without the
  git-config edit).
- **`DELTA_FEATURES` continues exactly as today** — `Tools/delta.ps1`'s
  existing `Get-DFConfiguredTheme`/`Resolve-DFThemeName` call is unchanged;
  this section only adds the `include.path` management alongside it.

## Section 4 — Testing

`git config --global` mutates real, shared state — **tests must never touch
the actual global config**. Use `GIT_CONFIG_GLOBAL=<TestDrive path>` (verified
working directly: it fully redirects `git config --global`'s target file) set
for the duration of each test, matching how other tests isolate `$Env:XDG_*`
via `$TestDrive`.

- Registering delta (fresh `GIT_CONFIG_GLOBAL`, no prior entry) adds exactly
  one `include.path` entry pointing at the deployed file.
- Registering delta twice does not duplicate the entry.
- The deployed file exists at the expected path and contains a
  `[delta "catppuccin-mocha"]` section.
- `$DFConfig['DeltaSkipGitConfig'] = $true` registers delta (still sets
  `DELTA_FEATURES`) without touching `include.path` at all.
- `DELTA_FEATURES` resolution behavior (existing tests in `tests/delta.Tests.ps1`)
  is unchanged and still passes.

## Section 5 — Documentation

- **README.md**'s delta subsection: explain the `include.path` addition, the
  visible confirmation message, the removal command, and the
  `DeltaSkipGitConfig` opt-out.
- **`docs/external-dependencies.md`**: new entry — delta's config-resolution
  rules (follows standard `git-config` file rules, not a delta-specific
  lookup) and the `--config <path>`-replaces-vs-`include.path`-layers
  distinction that drove this design, so a future contributor doesn't
  rediscover it the hard way.
- **`CHANGELOG.md`** `[Unreleased]`.
- **`TODO.md`**: close the delta line in the coverage-audit list.

## Acceptance criteria

- `Tools/delta/catppuccin.gitconfig` exists, matches upstream.
- Registering `delta` deploys it to `$XDG_CONFIG_HOME/delta/catppuccin.gitconfig`
  and ensures exactly one matching `include.path` entry in the user's real
  global git config (verified via `git config --global --get-all include.path`
  in a real, isolated test config — never the developer's actual config).
- A second registration does not duplicate the entry.
- `$DFConfig['DeltaSkipGitConfig'] = $true` skips the git-config edit
  entirely; `DELTA_FEATURES` still gets set.
- The first-time add prints a visible message naming the exact removal
  command.
- `git diff` piped through `delta` with `DELTA_FEATURES=catppuccin-mocha`
  renders real catppuccin-mocha colors (already confirmed manually; the test
  only needs to assert the config plumbing, not delta's rendering).
- No test ever mutates the real global git config.
- README, `docs/external-dependencies.md`, `CHANGELOG.md`, `TODO.md` updated.
