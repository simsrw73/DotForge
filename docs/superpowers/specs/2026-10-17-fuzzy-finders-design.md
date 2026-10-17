# Fuzzy finders and fuzzy keys (T-35 batch)

Status: approved design, 2026-10-17. Part of T-35 (complete the roles).

## Goal

Add skim, television, peco and gum as full DotForge tools (XDG paths, theme, useful default
config, completions), and give PowerShell's two fuzzy keys, Ctrl+R (history) and Ctrl+T (insert a
path), each a role, so any capable tool can own either key. Also add a small generic extension:
setup notes, for steps only the user can take.

## What the user said

- Is this one role or two? Answer agreed: split by contract, not by name. `picker` stays the
  engine every DotForge picker runs (must speak fzf's options); the others are a category.
- Follow the whole tool contract for each tool: XDG, aliases, pickers, themes, useful default
  config.
- There must be a role for PSReadLine's Ctrl+R / Ctrl+T. fzf, tv and skim belong in it. Tools such
  as atuin and mcfly fill only Ctrl+R (history navigators), so they must fit later. Alt+C belongs
  to a different future role (file managers, broot).
- television: seed config only when absent; one-time setup runs `tv update-channels` once and
  suggests the `ui.theme` change. General rule: use the one-time setup to tell the user about
  manual steps whenever that is possible.

## Roles

### `picker` (existing, single)

skim joins at priority 5 (fzf stays at 10). Verified against sk 5.7.4: it accepts every fzf option
DotForge's pickers use (`--preview`, `--preview-window`, `--bind`, `--expect`, `--disabled`,
`--delimiter`, `--with-nth`, `--multi`, `--header`, `--query`, `--exact`, `--ansi`, `--color`).
Its block sets `Picker = sk`. The reload action inside `--bind` is checked by the conformance probe
(below); if skim spells it differently, the picker that uses it is listed in the probe's ledger and
skim stays a member (the rest work).

### `history-search` (new, single): Ctrl+R

| Member | Priority | How it binds |
|---|---|---|
| PSFzf | 30 | `Set-PsFzfOption -PSReadlineChordReverseHistory 'Ctrl+r'` |
| television | 20 | tv's own `Invoke-TvShellHistory` (see television below) |
| fzf | 10 | shared handler, engine `fzf` |
| skim | 5 | shared handler, engine `sk` |

atuin and mcfly join later (TODO). Nothing in this design may assume a member also fills
`path-insert`.

### `path-insert` (new, single): Ctrl+T

Same members and priorities. PSFzf: `-PSReadlineChordProvider 'Ctrl+t'`; television:
`Invoke-TvSmartAutocomplete`; fzf and skim: the shared handler.

Both roles: the winner binds only its own key, from its hook (`Initialize-DFRoleHistorySearch`,
`Initialize-DFRolePathInsert` in the member's sidecar). The binding code for each key is the role's
reserved code, so `tests/Roles.Contract.Tests.ps1` rejects it anywhere else. A key the user bound
themselves before DotForge loads is kept: the hook checks `Get-PSReadLineKeyHandler -Chord` and
skips binding when the handler is not PSReadLine's default, noting it in the tool's status (same
rule as `Set-DFEnv`: a value set outside DotForge is kept). An explicit `Defaults` entry for the role
overrides it, with a warning.

PSFzf's companion keeps everything else it does today (fd, Alt+C, Tab expansion, scoop aliases); only
the two chord options move into the hooks. Alt+C stays in PSFzf's companion until the future
`directory-jump` role exists (TODO).

### Shared handler

`Private/Register-DFFuzzyKeyHandler.ps1`: `Register-DFFuzzyKeyHandler -Engine <exe> -Key History|Path`.
It binds the key with `Set-PSReadLineKeyHandler` to a scriptblock that:

- **History**: reads PSReadLine's history file (`(Get-PSReadLineOption).HistorySavePath`), newest
  first, de-duplicated, pipes it to `<engine> --no-sort --query <current line>` (the engine's default
  options from `FZF_DEFAULT_OPTS` / `SKIM_DEFAULT_OPTIONS` still apply), and replaces the line with the
  pick.
- **Path**: runs the engine with `--multi` over its default command (`FZF_DEFAULT_COMMAND` /
  `SKIM_DEFAULT_COMMAND`, which DotForge sets to `fd`) and inserts the picks at the cursor, each quoted
  when it contains a space.

Cancel (Esc) leaves the line unchanged. The helper names no tool; each sidecar passes its own
executable. It is in `Private/`: only the core's role hooks call it, and it reads the session's role
winners. Every binding, native or shared, goes through `Set-DFRoleKeyHandler` (`Private/`), which
keeps a user's own binding and is the roles' reserved code.

### `fuzzy-finder` (new, category)

Members: fzf, skim, television, peco, gum. No winner. `data/groups.json` gains `fuzzy` with the same
five, so `Tools = @('+fuzzy')` requests them.

## Tools

None of the four gets aliases: none replaces a common command, and inventing short names conflicts
with builtin safety. None gets a `picker`: there is no data source a DotForge picker would add over
what each tool already does. All four follow `Theme` (catppuccin, four flavors) through their own
theme key: `SkimTheme`, `TelevisionTheme`, `PecoTheme`, `GumTheme` (new config keys).

### skim (`Tools/skim.json`, `Tools/skim.ps1`)

- Executable `sk`; packages scoop `skim`, winget, crates `skim`.
- XDG: `default` (skim keeps no files). `xdg.native`: `[]`.
- Env: `SKIM_DEFAULT_OPTIONS` = fzf's `FZF_DEFAULT_OPTS` values (reverse layout, inline info, 40%
  height, border); `SKIM_DEFAULT_COMMAND` = fzf's `fd` command.
- Theme: `theme.command` builds `--color=...` from the catppuccin palette using skim's color keys and
  appends it to `SKIM_DEFAULT_OPTIONS`, the way `Invoke-DFApplyFzfTheme` does for fzf.
- Completions: `sk --shell power-shell`, cached with `Get-DFCachedCommandOutput` (mdcat's pattern).
- Roles: `picker` 5, `history-search` 5, `path-insert` 5, `fuzzy-finder`.

### television (`Tools/television.json`, `Tools/television.ps1`, `Tools/television.setup.ps1`)

- Executable `tv`; packages scoop `television`, winget, crates `television`.
- XDG: `env`, `TELEVISION_CONFIG` = `${XDG_CONFIG_HOME}/television`. `xdg.native`:
  `%LOCALAPPDATA%\television\config` (tv's Windows default). tv already honors `XDG_CONFIG_HOME`;
  setting `TELEVISION_CONFIG` makes it explicit and testable.
- Theme: ship `Tools/television/themes/catppuccin-{mocha,macchiato,frappe,latte}.toml`; the seed
  copies them into `<config>/themes/`. tv has no theme flag or variable, so the theme applies through
  `ui.theme` in `config.toml`; the docs say so (`Set-DFToolTheme television` changes nothing tv reads).
- Setup (`setup.seed` plus `television.setup.ps1`, once ever):
  1. Seed the four theme files, and `config.toml` only when absent, holding only `ui.theme =
     "catppuccin-<flavor>"` from the theme block (verified: tv 0.15.9 merges a partial config over its
     defaults, so its shell-integration triggers and everything else keep their defaults).
  2. Run `tv update-channels` once, announced with one line. If it fails, setup still completes and
     adds a note to run it by hand (no retry on every startup).
  3. Note, only when `config.toml` existed before setup: "Your television config.toml predates
     DotForge; set `ui.theme = "catppuccin-mocha"` (or another flavor) to use the DotForge theme."
- Key bindings: `tv init power-shell` defines `Invoke-TvShellHistory` and `Invoke-TvSmartAutocomplete`
  and then binds Ctrl+R and Ctrl+T. The companion runs that script with its
  `Set-PSReadLineKeyHandler` lines removed (cached, like completions); each role hook then binds its
  key to tv's function. These names are an undocumented dependency: listed in
  `docs/external-dependencies.md`; if a function is missing, the key is left unbound and the status
  says so.
- Completions: `tv init power-shell` already registers tv's completer, so the cached init script
  covers them.
- Roles: `history-search` 20, `path-insert` 20, `fuzzy-finder`.

### peco (`Tools/peco.json`, `Tools/carapace/specs/peco.yaml`)

- Executable `peco`; packages scoop `peco`, winget, choco where they exist.
- XDG: `default`: peco reads `$XDG_CONFIG_HOME/peco/config.json` itself (verified on Windows,
  peco 0.6.0). `xdg.native`: `~/.config/peco/config.json`, `~/.peco/config.json`.
- Theme and default config: seeded `config.json` per flavor (`Tools/peco/catppuccin-<flavor>.json`):
  a `Style` block (basic, selected, saved selection, query, matched, prompt) in `#RRGGBB` (peco
  documents truecolor), and `"Layout": "top-down"`, matching the reverse layout DotForge gives fzf.
- Completions: a new carapace spec (peco ships none).
- Roles: `fuzzy-finder`.

### gum (`Tools/gum.json`, `Tools/gum.ps1`)

- Executable `gum`; packages scoop `gum`, winget `charmbracelet.gum`.
- XDG: `default` (gum keeps no files).
- Theme: `GUM_*` color variables per flavor from `Tools/gum/catppuccin-<flavor>.json` (choose cursor
  and selected, filter match/indicator/prompt, input prompt/cursor, confirm selected, spin spinner,
  headers), set through `Set-DFEnv` by the companion's `theme.command`.
- No behavior defaults: gum is a scripting toolkit, and scripts expect its stock behavior.
- Completions: carapace already ships gum's.
- Roles: `fuzzy-finder`.

## Setup notes (new generic extension)

- A tool's `setup.notes` is a list of `{ text, ifFile, unlessFile }` (conditions optional, same
  tokens as flag groups). A setup script adds notes with `Add-DFToolSetupNote -Name -Text`.
- Notes are collected when a tool's one-time setup runs and printed once, in the end-of-load
  summary (next to missing tools), not mid-startup.
- They are stored in `setup-state.json` with the setup record, and `Get-DFToolStatus <tool>` shows them
  (T-65's status command can list them all later).
- `SkipSetup` skips them with the rest of setup. Notes never block a load.
- Only television uses notes in this batch.

## Testing

- Role contract: the two new roles' reserved code appears only in hooks.
- Each winner binds only the key it won; a user's own binding is kept; `Defaults` overrides with a
  warning. PSReadLine is mocked.
- Shared handler: the engine command line for History and Path, cancel leaves the line alone,
  quoting of paths with spaces.
- television: the stripped init script from a canned `tv init power-shell` output; the degraded
  case where a function is missing; setup with and without an existing `config.toml`; failed
  `update-channels` adds the note and still completes. `Invoke-DFManagerCommand`-style seam: no test
  runs a real `tv`.
- Themes: skim's color string, tv's theme files, peco's styles and gum's variables for all four
  flavors.
- Setup notes: shown once, kept in status, conditions respected, `SkipSetup` honored.
- All XDG folders sandboxed; no test runs a real sk, tv, peco or gum.

## Probe results (2026-10-17, settled before planning)

1. skim 5.7.4 supports the `--bind` actions DotForge's pickers use (`execute`, `execute-silent`,
   `print-query`, `reload`), reads `SKIM_DEFAULT_OPTIONS` (newline-separated too) and takes hex in
   `--color` with its own element names (`matched`, `current`, `current_bg`, ...).
2. tv 0.15.9 honors `TELEVISION_CONFIG`, writes a full default `config.toml` on any first run when
   none exists, and accepts a partial one without rewriting it.
3. peco 0.6.0 reads `$XDG_CONFIG_HOME/peco/config.json` on Windows; its README documents `#RRGGBB`
   colors.
4. winget ids: `skim-rs.skim`, `alexpasmantier.television`, `peco.peco`, `charmbracelet.gum`; scoop:
   skim, peco, gum in main, television in extras.

## New TODOs

- atuin and mcfly join `history-search`.
- A `directory-jump` role for Alt+C (broot, file managers, fzf's Alt+C).
- Review existing tools for manual steps that should become setup notes.

## Out of scope

- gum and peco as key-binding members (possible later through the shared handler).
- Rewriting the user's existing tv `config.toml`.
- Live theme switching for television.
