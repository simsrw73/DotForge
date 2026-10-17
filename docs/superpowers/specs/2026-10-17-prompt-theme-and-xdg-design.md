# Prompt themes and runtime XDG paths

Status: draft, 2026-10-17. Closes the gaps `TODO-Tools.md` lists for the `prompt`, `js-runtime`,
`js-package-manager`, `python-runtime` and `python-package-manager` roles.

## Goal

Two small batches, done together:

1. **Prompt themes.** starship and oh-my-posh follow `Theme`, so the `prompt` role can close.
2. **XDG paths.** bun, pnpm, python, pip and pipx keep their files under the XDG folders, so the
   runtime and package-manager roles can close.

A role closes when every member has the whole tool contract and the role is filled (the rule in
`TODO-Tools.md`).

## What the user said

- **starship:** "session copy, palette swapped". The user's `starship.toml` (their own catppuccin
  "p9cat" layout, `palette = "catppuccin_mocha"`) stays the source and is never edited.
- **oh-my-posh:** yes, use its catppuccin themes in this batch.
- **Python:** move only the REPL history. No `PYTHONPYCACHEPREFIX`.
- **pnpm and bun pickers:** npm's `Select-NpmScript` already runs a script with the project's own
  package manager, and that is enough. Record it; no new picker.

## starship (`Tools/starship.json`, `Tools/starship.ps1`)

- **Theme block:** key `StarshipTheme`, default `catppuccin-mocha`, following `Theme`. The `map` is
  the four catppuccin flavors → the palette names starship configs use: `catppuccin-mocha` →
  `catppuccin_mocha`, and the same for latte, frappe and macchiato.
- **Source:** whatever `STARSHIP_CONFIG` points at before DotForge's theme step. Usually that's the
  XDG path DotForge set; a path the user set themselves is kept (`Set-DFEnv` rule).
- **Applying a theme:** a companion function named in the theme block's new `apply` field (see
  "Live switching" below):
  - **Copy:** if the source file defines `[palettes.<native>]` and its top-level `palette = "..."`
    names a different one, DotForge writes a copy to `$XDG_CACHE_HOME\dotforge\starship\starship.toml`
    with only that `palette` line changed, and points `STARSHIP_CONFIG` at the copy.
  - **Use the source as is** (my call), so edits to it show at once, as starship normally does,
    when its palette already matches, or when it has no `palette` line.
  - **Missing palette** (my call): if the source sets `palette` but doesn't define
    `[palettes.<native>]`, the copy gets that table appended from DotForge's catppuccin palette
    (`build/catppuccin-palette.psd1`, generated into `Tools/starship/catppuccin-palettes.toml` by
    `build/New-DFCatppuccinThemes.ps1`), mapping catppuccin's 26 color names to the palette's own
    names. The user's file defines all four flavors already, so it never needs this.
  - The copy is rewritten when the theme changes, and at each shell start when the source is newer
    than the copy. So with a copy in use, an edit to the source shows from the next shell or the
    next `Set-DFToolTheme starship …`. This limit goes in the guide.
- **No seeding:** a new user's `starship.toml` is not created. Seeding a layout is out of scope.
  With no config, starship's defaults show and nothing is written. Without a `palette` line, Theme
  does nothing, and a one-time setup note says so.
- The copy step names starship only in its own companion; core is unchanged.

## oh-my-posh (`Tools/oh-my-posh.json`, `Tools/oh-my-posh.ps1`)

- **Theme block:** key `OhMyPoshTheme`, default `catppuccin-mocha`. `map`: `catppuccin-mocha` →
  `catppuccin_mocha`, and so on (oh-my-posh's own theme names).
- **Config choice**, first match wins:
  1. `$Env:POSH_THEME`, the user's. A value pointing into DotForge's own files (the bundled themes)
     is not the user's, so a nested shell still follows `Theme` (my call).
  2. A user config: exactly one `*.omp.*` in `$XDG_CONFIG_HOME\oh-my-posh`. That's today's
     discovery, which stays. With several, today's warning and pick also stay.
  3. **New:** the theme's file, bundled with DotForge (my call): this machine's oh-my-posh install
     has no local theme files, and `POSH_THEMES_PATH` is empty.
     - DotForge ships oh-my-posh's four catppuccin themes as `Tools/oh-my-posh/<native>.omp.json`,
       copied from oh-my-posh's repository (MIT), with its license file.
     - A same-named file in `POSH_THEMES_PATH`, when one exists, is used first.
  4. Otherwise, today's warning.
- **Live switching:** `Set-DFToolTheme oh-my-posh catppuccin-latte` re-inits with that theme file,
  the way `fpot` already does. It has the same known zoxide limitation (CLAUDE.md). An explicit
  `Set-DFToolTheme` beats a user config for the rest of the session (my call): the user asked for it.

## Live switching: the theme `apply` field (core change)

`Set-DFToolTheme` refuses a tool whose theme has a `command` (`Public/Set-DFToolTheme.ps1`). Five
tools have one (fzf, gum, psreadline, skim, vivid), and some of those commands are interactive
pickers. My call:

- **New optional field:** a theme block may name an `apply` function. It's defined by the
  companion as a global function taking `-Name <native>`, and applies one theme for the session.
- **`Set-DFToolTheme`:** resolves the theme as today, then calls `apply` when the block has one.
  Otherwise it keeps today's path: env through `Set-DFToolThemeEnv`, and refusing `command` tools.
- **The five existing tools are unchanged** in this batch. Giving them `apply` is a follow-up.
- **Plumbing:** the schema accepts `apply`, and the docs (writing-a-tool, CLAUDE.md's theme bullet)
  describe it. No tool name enters core.

## XDG paths

Each tool gets an `xdg` block (`method: env`, `vars`, `native`, `dirs`). Values the user set
outside DotForge are kept, as always.

| Tool | Variables | Native locations (`xdg.native`) |
|---|---|---|
| bun | `BUN_INSTALL = ${XDG_DATA_HOME}/bun` (global installs, its `bin`); `BUN_INSTALL_CACHE_DIR = ${XDG_CACHE_HOME}/bun/install/cache` | `${HOME}/.bun` |
| pnpm | `PNPM_HOME = ${XDG_DATA_HOME}/pnpm` (global bin, added to PATH with `Add-DFToPath`). pnpm reads `XDG_*` itself for config, cache, state and store (probe). | `${LOCALAPPDATA}/pnpm` |
| python | `PYTHON_HISTORY = ${XDG_STATE_HOME}/python/history` (Python 3.13+) | `${HOME}/.python_history` |
| pip | `PIP_CONFIG_FILE = ${XDG_CONFIG_HOME}/pip/pip.ini`; `PIP_CACHE_DIR = ${XDG_CACHE_HOME}/pip` | `${APPDATA}/pip/pip.ini`, `${HOME}/pip/pip.ini`; `${LOCALAPPDATA}/pip/cache` |
| pipx | `PIPX_HOME = ${XDG_DATA_HOME}/pipx`; `PIPX_BIN_DIR = ${XDG_BIN_HOME}` (probe the default) | `${HOME}/pipx`, `${LOCALAPPDATA}/pipx` (probe) |

- **bun's `bin`:** it goes on PATH with `Add-DFToPath`, so `bun add -g` tools work.
- **Homes that hold binaries or installed globals never block a tool** (my call):
  - The old homes are declared `{ paths, move: false, guide }`, never as a normal conflict:
    `${HOME}/.bun`, `${LOCALAPPDATA}/pnpm`, `${HOME}/pipx`, `${LOCALAPPDATA}/pipx`.
  - The same goes for `${HOME}/.python_history`, since a normal conflict there would make python
    Conflict and pip, which requires python, Blocked.
  - The guide says what lives there and how to move it: reinstall the globals, or copy the history
    file.
  - DotForge sets the new variables only where they aren't set already. A user who keeps the old
    home sets the variable to it, and that value is kept (`Set-DFEnv`).
- **Caches** (pip's, bun's) are only caches. Native cache folders are declared with
  `{ paths, move: false, guide }`, so an existing cache never blocks the tool. The guide says the
  old cache can be deleted. My call: a full cache should not hold a tool back as a conflict.
- **pip's config:** `PIP_CONFIG_FILE` only matters once that file exists. A user's existing
  `%APPDATA%\pip\pip.ini` makes pip a conflict, as with any relocated config, until
  `Resolve-DFToolConflict -Move | -Adopt`.
- **pipx venvs:** moving `PIPX_HOME` orphans existing venvs, which is why its old home is a
  `move: false` native with a guide (above), not a conflict.
- **Pickers:** the `TODO-Tools.md` gaps for pnpm and bun pickers are recorded as covered by
  `Select-NpmScript`. No new code.

## Testing

- **starship:**
  - copy written with only the `palette` line changed;
  - no copy when the palette matches, or when there's no `palette` line;
  - a missing `[palettes.<native>]` table appended to the copy;
  - a `STARSHIP_CONFIG` pointing at DotForge's own copy is not taken for the user's;
  - a source newer than the copy refreshes it;
  - `Set-DFToolTheme starship catppuccin-latte` switches `STARSHIP_CONFIG`;
  - a `STARSHIP_CONFIG` the user set is used as the source;
  - the one-time note when there's no `palette` line.
- **oh-my-posh:** the config order above, with fake files; a `POSH_THEME` inherited from DotForge's
  bundled theme isn't the user's; `Set-DFToolTheme` beats a user config.
- **`apply`:** `Set-DFToolTheme` calls it with the native name; tools with only `command` are still
  refused; the schema checks `apply`.
- **XDG:** each record's variables and native entries (`tests/ToolNative.Coverage.Tests.ps1` already
  enforces native coverage). `Add-DFToPath` for bun's and pnpm's bin folders. Cache natives don't
  block activation.
- **By hand:** a real starship prompt with `Theme = 'catppuccin-latte'`, and the real oh-my-posh theme.

## Probes (the plan's first task)

1. Does pnpm honor `XDG_*` on Windows for config, cache, state and store? Answer from its docs or
   source: pnpm isn't installed here, and the tests mustn't need it.
2. bun 1.3: do `BUN_INSTALL` and `BUN_INSTALL_CACHE_DIR` move the global installs and the cache,
   and where does `bun add -g` put binaries?
3. pipx 1.18 on Windows: the defaults for `PIPX_HOME` and `PIPX_BIN_DIR`.
4. Python 3.14 on Windows: is `PYTHON_HISTORY` honored by the new REPL and the basic one?
5. oh-my-posh: the exact catppuccin theme file names in its repository, and whether
   `oh-my-posh init pwsh --config <file>` accepts the bundled copies unchanged.
6. starship 1.26: is `STARSHIP_CONFIG` read on every prompt render, so a changed variable takes
   effect at the next prompt?

## Out of scope

- Seeding a starship layout for new users.
- `PYTHONPYCACHEPREFIX`.
- New pickers for pnpm and bun.
- carapace colors, and the other roles' gaps.
