# Finishing the pager role (T-35, first batch)

**Status:** design approved in chat 2026-10-16; this spec is for review.
Builds on role behaviors (`2026-10-16-role-behaviors-design.md`).

## Goal

The pager role should page the same way whichever pager wins, and paging should
work even with no pager tool installed:

- moor, ov and less (in that priority order, as today) each page with the same
  behavior: quit when the output fits one screen, keep colors, leave the output on
  screen when quitting, scroll with the mouse wheel.
- With no pager requested or installed, `more` (built into Windows) pages.
- ov follows the session theme like moor does.
- Tools that page through their own variable page the same way; for this batch
  that is bat (`BAT_PAGER`).

## Design

### 1. A role can name a fallback

A single role in `data/roles.json` may define `fallback`: what to apply when no
requested member wins. Today only `env` is supported:

```json
"pager": { ..., "fallback": { "env": { "PAGER": "more", "BAT_PAGER": "more" } } }
```

- Applied once per activation, after every member has registered, only when
  `Get-DFRoleWinners` found no winner for the role.
- Written through `Set-DFEnv` like any role env, so a value the user set outside
  DotForge is kept. Variables must be the role's reserved env (validated by
  `ConvertTo-DFRoleRecord`; an invalid fallback makes the role invalid with a
  warning).
- `Get-DFRole` shows the role's winner as `(fallback)` with the values set.
- A category role cannot declare a fallback.

### 2. Role behaviors can build environment variables

`behaviors` (from the role behaviors design) gains `env`: variable → words. The
winner's command line is its executable followed by each word's flags:

```json
"behaviors": {
  "words": {
    "quit-if-one-screen": "don't page output that fits one screen",
    "raw-color": "pass color codes through",
    "keep-screen": "leave the output on screen when quitting",
    "mouse": "scroll with the mouse wheel",
    "theme": "the session theme, where the pager takes it as an argument"
  },
  "env": {
    "PAGER":     ["quit-if-one-screen", "raw-color", "keep-screen", "mouse", "theme"],
    "BAT_PAGER": ["quit-if-one-screen", "raw-color", "keep-screen", "mouse", "theme"]
  }
}
```

- The command is the winner's executable path as `${DF_TOOL_EXE}` gives it (the
  native build, quoted when it has a space, `executableExclude` honored), so less
  keeps using the Windows build rather than Git's.
- A role with `behaviors.env` reserves those variables (they join
  `reserved.env`); members may not set them in their role block's `env`.
- Written through `Set-DFEnv` with the role's usual explicit reason
  (`Defaults`), as role env is today.
- Built at registration (startup), as role env is. A flag group (below) is
  therefore decided at startup; a later file change takes effect in a new shell.

### 3. A flag can be a conditional group

A member's flag value is an array whose items are strings or groups:

```json
"theme": [ { "ifFile": "{theme}/config.yaml", "unlessFile": "${XDG_CONFIG_HOME}/ov/config.yaml",
             "args": ["--config", "{file}"] } ]
```

- `ifFile`: the group applies only when this file exists; `{file}` in `args` is
  it. `unlessFile`: the group applies only when this file does not exist.
- Paths expand `${XDG_*}`, `{settings.<name>}` and `{theme}` (the tool's resolved
  theme value), and are canonical. A path naming a theme with no value is a
  missing file.
- Used for behavior aliases, pickers and env alike (one resolver,
  `Resolve-DFRoleWords`).

### 4. The members

| word | less | ov | moor |
|---|---|---|---|
| quit-if-one-screen | `-F` | `-F` | `-quit-if-one-screen` |
| raw-color | `-R` | `[]` | `[]` |
| keep-screen | `-X` | `-X` | `-no-clear-on-exit` |
| mouse | `--mouse` | `[]` (default) | `-mousemode`, `scroll` |
| theme | `[]` | the group above | `[]` (moor's theme stays in `MOOR`) |

- less: its top-level `env.LESS` keeps its options for programs that start less
  directly; the role block's `env.PAGER` is removed.
- moor: `MOOR` keeps only `-style {theme}`; `-quit-if-one-screen` moves to the
  word. The role block's `env.PAGER` is removed.
- ov: gains a `theme` block (`OvTheme` → `Theme` → `catppuccin-mocha`,
  `files: "ov"`, no `valid`), so a theme without a bundled folder is unset.
  Bundled: `Tools/ov/catppuccin-<flavor>/config.yaml` for mocha, macchiato, frappe
  and latte — ov's default config (`ov --generate-config=default`) with its colors
  replaced by the flavor's palette. A user config at
  `$XDG_CONFIG_HOME\ov\config.yaml` (ov reads it itself) is never overridden.

### 5. Out of scope

- `DELTA_PAGER` (delta falls back to `BAT_PAGER`), `GIT_PAGER` (the diff role's),
  `MANPAGER` (no `man` on Windows).
- `more`'s own options: `more` takes none worth setting.

## When something is missing

- A member lacks a word: the command is built without it and the tool's status
  notes it, as for aliases.
- A group's file is missing: the group is left out, silently.
- The user set `PAGER` or `BAT_PAGER`: kept and noted (`Set-DFEnv`); an explicit
  `Defaults.pager` overrides it with the existing one-time warning.
- A legacy member or one without `flags`: keeps its own role-block `env`.

## Tests

- `ConvertTo-DFRoleRecord`: `fallback` read and validated (reserved env only;
  rejected on a category role); `behaviors.env` read, its variables reserved, its
  words validated.
- `Resolve-DFRoleWords`: groups with `ifFile`, `unlessFile`, `{theme}`, `{file}`.
- Registration: each pager winning in turn sets `PAGER` and `BAT_PAGER` to its
  exact command; no pager requested sets both to `more`; a user `PAGER` is kept;
  ov with a user config passes no `--config`.
- A test spelling out each pager's exact `PAGER` string.
- The bundled ov configs parse as YAML and set the palette's colors; ov accepts
  each (`ov --config <file> --help` exits 0) when installed.
- Role contract: a behaviors role's members map its env words; no member sets a
  `behaviors.env` variable in its role block.

## Docs

`docs/guide/configuration.md` (pager role, fallback), `docs/guide/writing-a-tool.md`
(env behaviors, flag groups), `docs/guide/tools.md` (pagers), `CLAUDE.md` (roles
bullet), `docs/external-dependencies.md` (ov's config file and styles; bat's
`BAT_PAGER`), `CHANGELOG.md`, and T-35 in `TODO.md` updated (pagers done).
