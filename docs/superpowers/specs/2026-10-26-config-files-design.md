# Config files over variables (T-79)

Piece 8 of the restore work (`2026-10-24-restore-install-locations-notes.md`, Environment size).

## Why

Your policy (2026-10-25): when a setting can go in a tool's config file or a variable, it goes in
the config file, and variables only point at config files and folders. A DotForge session's
environment was about 30,000 characters, 17,889 of them `LS_COLORS`. Every child process carries the
whole block, and cmd.exe ignores any inherited variable over 8,191 characters, so cmd and batch files
never see `LS_COLORS` today.

## The audit (2026-10-26)

| Variables | Decision |
|---|---|
| vivid's `LS_COLORS` | Stays a variable (it's the shared format eza, lsd and fd read) but shrinks: a curated extension list |
| fzf's `FZF_DEFAULT_OPTS` base options (layout, height, border, info) | Move to a seeded `fzfrc` (`FZF_DEFAULT_OPTS_FILE`) |
| less's `LESS` | Moves to the seeded `lesskey` that `LESSKEYIN` already points at (`#env` section) |
| fzf's `*_COMMAND` / `*_OPTS` for Ctrl+T and Alt+C, skim's `SKIM_DEFAULT_*` | Stay: neither tool reads them from a file |
| Theme variables: `BAT_THEME`, `DELTA_FEATURES`, `MDCAT_THEME`, `MOOR`, gum's, fzf's theme colors | Stay: `Set-DFToolTheme` switches them live without rewriting your files |
| Role and convention variables: `PAGER`, `BAT_PAGER`, `GIT_PAGER`, `EDITOR`, `VISUAL`, `Picker`, `CARAPACE_BRIDGES`, `POSH_GIT_ENABLED` | Stay: the variable is the interface other programs read |

## Goals

- `LS_COLORS` under 8,191 characters with the default theme, so cmd children see it too.
- fzf's and less's editable defaults live in files you can change; DotForge keeps in variables only
  what it manages live.
- The policy and its exceptions are written down where tool authors read them.

## Non-goals

- skim, the theme variables and the role variables (above).
- `Path` (the winget links work in the restore notes).
- Changing what any tool looks like or does: same flags, same colors for the extensions kept.

## Anti-goals

- Overwriting a config file the user already has (seeds copy only when absent).
- A file DotForge rewrites on every load or theme switch.
- Losing a user's own `FZF_DEFAULT_OPTS` or `LESS` set outside DotForge (`Set-DFEnv` keeps them today;
  that stays true).

## Decided (yours)

1. **LS_COLORS:** a curated extension list, 24-bit colors kept.
2. **fzf:** a seeded `fzfrc` for the base options; the variable keeps only DotForge's live values.
3. **less:** a seeded `lesskey` with an `#env` section; `LESS` goes away.
4. **Exceptions** (themes, roles) stay variables, documented with the reason.

## Design

### vivid

- Seed `$XDG_CONFIG_HOME\vivid\filetypes.yml`: vivid's own database format, trimmed to the common
  extensions in each category vivid has (code, markup and docs, images, audio and video, archives,
  office, executables, build and config files). Builder's call which ones; the bar is "a file a
  developer meets weekly". Target: the generated value for the default theme (catppuccin-mocha) under
  8,191 characters, with room for the user to add some.
- The companion runs `vivid -d <that file> generate <theme>` (explicit, not vivid's own config
  lookup). If the file is missing (the user deleted it), vivid's built-in database is used, as today.
- The cache fingerprint becomes theme + the database file's last-write time, so editing the file
  regenerates `LS_COLORS` on the next load.
- `xdg.native` covers the new file (vivid's own config folder).

### fzf

- `xdg.vars`: `FZF_DEFAULT_OPTS_FILE = ${XDG_CONFIG_HOME}/fzf/fzfrc` (a location: policy-compliant),
  `xdg.method` becomes `env`, with `xdg.native` `[]` (fzf has no default file).
- Seed `fzfrc` with today's base options (`--layout=reverse`, `--inline-info`, `--height=40%`,
  `--border`), one per line, with a comment saying fzf reads it before `FZF_DEFAULT_OPTS`.
- `FZF_DEFAULT_OPTS` leaves `env`. The theme function sets it to DotForge's color option alone and
  replaces its own earlier one on a theme switch (today it appends, so the variable grows with every
  switch). A value set outside DotForge is still kept, with the colors appended, as today. PSFzf's
  `--ansi` stays as it is.
- The `*_COMMAND` and Ctrl+T / Alt+C `*_OPTS` entries stay in `env`.

### less

- Seed `$XDG_CONFIG_HOME\less\lesskey` (the path `LESSKEYIN` already names) with:

  ```
  #env
  LESS = --RAW-CONTROL-CHARS --quit-if-one-screen --no-init
  ```

- `LESS` leaves `env`. A user's existing `lesskey` is never overwritten; the changelog says to add the
  `#env` lines to it to keep the flags.
- Verified with the real less at build time (the conformance harness or a probe): the flags take
  effect from the file.

### The policy, written down

- `docs/guide/writing-a-tool.md` (the `env` row): settings go in a seeded config file when the tool
  reads one; `env` is for settings a tool takes only from a variable, live theme values and role
  variables.
- CLAUDE.md's `env` schema bullet says the same in one line.

## Left to the builder

- Which extensions make the list, within the target.
- Comment wording in the seeded files.
- Tests: the seeded files exist with the right content; the records no longer set `LESS` or the base
  `FZF_DEFAULT_OPTS`; the fzf theme switch replaces rather than appends; vivid's cache key includes the
  database file; a test that runs real vivid (skipped when it isn't installed) checks the length
  target.
- Docs: `tools.md` (fzf, less, vivid notes), CHANGELOG, restore notes, TODO (close T-79).
