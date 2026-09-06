# Changelog

All notable changes to DotForge are documented here.

## [Unreleased]

## [0.6.0-preview] - 2026-09-06

### Fixed

- **`eza`'s `ll`/`la` aliases and `fzf`'s match mode/previews had drifted from the reference zsh
  config they were meant to mirror.** Found during a 2026-09-06 zsh-parity comparison against the
  user's `~/.zshrc`. `ll` (`Tools/eza.json`) showed hidden files and had no `--git`/icons/dirs-first
  — now `--long --group-directories-first --icons=auto --color=auto --git` (plus DotForge's own
  `--hyperlink=auto` addition). `la` wasn't even a long listing and used a stray `--group` (group/
  owner column) instead of `--group-directories-first` — now matches `ll` with `--all` added.
  `fzf`'s `FZF_DEFAULT_OPTS` (`Tools/fzf.json`) had `--exact --no-sort` — genuinely non-fuzzy
  substring matching for a *fuzzy* finder — replaced with `--inline-info` to match zsh; also
  dropped `--cycle` and matched the height (`40%`, was `50%`). `fd` calls across
  `FZF_DEFAULT_COMMAND`/`ALT_C_COMMAND`/`CTRL_T_COMMAND` gained `--strip-cwd-prefix` to match zsh,
  and `CTRL_T_COMMAND` is now identical to `FZF_DEFAULT_COMMAND` (zsh sets it that way explicitly).
  Previews: Alt+C now shows an `eza --tree --level=2` tree (was a flat listing); Ctrl+T's `bat`
  preview lost its 500-line cap and gained zsh's `ctrl-/` preview-window toggle bind.
- **`Get-DFCategoryDb.Tests.ps1`/`Get-DFCategoryList.Tests.ps1` silently tested against a real,
  ambient `$Env:XDG_DATA_HOME/dotforge/tool-categories.json` instead of their own small fixture.**
  `Get-DFCategoryDb`'s refreshed-vs-shipped comparison runs unconditionally even when `-Path`
  overrides the "shipped" side (by design, so tests exercise the full resolution algorithm) — a
  real, newer `tool-categories.json` from actual DotForge usage on the dev machine silently
  outranked the fixture in every test that didn't isolate `$Env:XDG_DATA_HOME` itself. Isolated
  it in all three `Get-DFCategoryDb.Tests.ps1` `Describe` blocks and in
  `Get-DFCategoryList.Tests.ps1`'s `BeforeEach`, matching the pattern the file's own
  "refreshed copy" tests already used correctly. No production code changed — test-only.
- **`mdv`'s seeded `config.yaml` was silently reasserted after a deliberate deletion.**
  `Tools/mdv.ps1` checked `Test-Path config.yaml` every session and wrote the file
  whenever absent — indistinguishable from "DotForge has never run here," so a user who
  deleted the seeded file to opt out got it silently rewritten on the very next
  `Register-DFTool` call. Migrated to the new tool-setup-lifecycle primitive: theme
  resolution and seeding now live in `Tools/mdv.setup.ps1`, which runs at most once ever
  (tracked in `$XDG_STATE_HOME/dotforge/setup-state.json`), so a later deletion sticks
  permanently. `Tools/mdv.ps1` retired entirely — directory creation was already handled
  declaratively by `xdg.dirs`, and seeding was its only other job.
- **`Invoke-DFSqliteQuery` built queries by string concatenation, with manual escaping at its one
  call site that embeds free text.** `DFCatalog.Winget.ps1`'s search doubled embedded single
  quotes itself before building the SQL string — correct today, but a discipline that has to be
  re-applied at every future call site forever. Added real `sqlite3_bind_text` parameter binding
  (a new `-Parameters` argument, bound to `?` placeholders); the winget search now binds its search
  term instead of concatenating it, so this class of bug is structurally impossible there going
  forward rather than dependent on remembering to escape.
- **`fzf`'s color theme was hardcoded to catppuccin-mocha, ignoring `$DFConfig['Theme']`/`$DFConfig['FzfTheme']`.**
  `Tools/fzf.json`'s `FZF_DEFAULT_OPTS` embedded a literal `--color=…` string, unlike every
  other themed tool in this codebase, which resolves through `Get-DFConfiguredTheme`/
  `Resolve-DFThemeName`. The color values move to a bundled `Tools/fzf/catppuccin-mocha.json`
  (same shape as `Tools/psreadline/*.json`), resolved by a new `Tools/fzf.ps1` companion and
  appended to `FZF_DEFAULT_OPTS` after `Register-DFTool` sets the non-color flags from
  `fzf.json`'s `env` block — same default appearance as before, now theme-configurable and
  overridable from `$XDG_CONFIG_HOME/fzf/themes/`.
- **`Get-Help Register-DFTool -Full` never rendered its synopsis, description, or examples.**
  A `[Diagnostics.CodeAnalysis.SuppressMessageAttribute(...)]` sat before the comment-based
  help block, and PowerShell only recognizes comment-based help as the very first token in a
  function body. Moved the attribute after the help block — the same fix already applied to
  `Invoke-DFToolCompanion` when the same issue was introduced there during the
  `Register-DFTool` split. This predated that split entirely.
- **`New-DFShim` changed directory before invoking the target.** The generated `.cmd` did
  `cd /d` into the target executable's own install directory before running it, so any
  relative-path argument the user passed resolved against that directory instead of the
  caller's actual working directory. The `cd` is removed — nothing needed it (Windows
  already resolves an executable's own DLL dependencies relative to its own directory
  regardless of `cwd`).
- **`Import-DFToolDb` and `Resolve-DFPackageManager` could return a stale or
  cross-contaminated result.** Both cached their result in a single unkeyed variable
  regardless of whether the caller passed an explicit `-ToolsPath`/`-Priority`, so a
  one-off call with a custom value could read another caller's cached answer, or silently
  overwrite the shared cache for every later default-argument caller in the session. An
  explicit override now always does a fresh, uncached read/write, mirroring the guard
  `Get-DFCategoryDb` already used correctly for its own `-Path` override.

### Added

- **`vcpkg` (`Tools/vcpkg.json`/`.ps1`).** New tool, closing one of the four remaining
  zsh-parity gaps tracked from the 2026-09-06 comparison. `VCPKG_ROOT` relocates under
  `$XDG_DATA_HOME/vcpkg` and `VCPKG_DOWNLOADS` under `$XDG_CACHE_HOME/vcpkg/downloads`
  (matching zsh's `.zshenv` exactly); the sidecar adds `$VCPKG_ROOT` itself to PATH since
  `vcpkg.exe` has no `bin/` subfolder.
- **`direnv` (`Tools/direnv.json`/`.ps1`).** New tool, closing the last of the four
  zsh-parity gaps. direnv is natively XDG-compliant (config at
  `$XDG_CONFIG_HOME/direnv/direnv.toml`, allow-list at `$XDG_DATA_HOME/direnv/allow`) so
  no `xdg.vars` were needed — `xdg.method: "default"`. The sidecar installs direnv's own
  `hook pwsh` output (cached via `Get-DFCachedCommandOutput`, same pattern as
  `Tools/zoxide.ps1`), which attaches to
  `$ExecutionContext.SessionState.InvokeCommand.LocationChangedAction` rather than wrapping
  `function:prompt` — so, unlike zoxide/oh-my-posh, it has no registration-order dependency
  on either. The hook requires PowerShell 7.2+ and throws below that; the sidecar guards
  this and degrades to a warning instead.

### Changed

- **`psreadline`'s default `EditMode` is now `Emacs`, not `Windows`.** Override with
  `$DFConfig['PSReadLineEditMode'] = 'Windows'` to keep the old default. Also folded in three
  settings that previously lived in a personal `profile.ps1` (marked there as a
  `### TODO: Move this to DotForge`): `HistorySearchCursorMovesToEnd` (new `settings` key in
  `Tools/psreadline.json`), and `Ctrl+p`/`Ctrl+n` bound to `HistorySearchBackward`/`-Forward`
  (`Tools/psreadline.ps1`) — history search filtered by what's already typed, cursor landing at
  the end of the recalled line.
- **`psreadline`'s history is now relocated and sized to match zsh** — another of the
  2026-09-06 zsh-parity gaps. `HistorySavePath` moves to `$XDG_STATE_HOME/psreadline/history`
  (was PowerShell's AppData default; the directory is created via a new `xdg.dirs` entry) and
  `MaximumHistoryCount` is raised to `10000` (new `settings` key), matching zsh's explicit
  `HISTSIZE=10000` instead of PSReadLine's own default of 4096.
- **`rustup`'s `RUSTUP_HOME`/`CARGO_HOME` are now relocated under `$XDG_DATA_HOME`** — the
  last of the four zsh-parity gaps (`Tools/rustup.json` gained `xdg.method: "env"`; a new
  `Tools/rustup.ps1` adds `$CARGO_HOME/bin` to PATH, since core's env-var application never
  touches PATH itself). Previously `rustup`/`cargo` used their un-relocated Windows defaults.
- **`Register-DFTool -All` no longer re-probes the same tool's availability more than
  once per session.** A new `Test-DFToolAvailable` (`Private/Test-DFToolAvailable.ps1`)
  memoizes `Get-Command`/`Get-Module` results per `(type, executable)` — previously a
  `$DFConfig.Defaults` role winner was probed twice per `Register-DFTool` call (once
  during role resolution, once in the main loop), and every tool was re-probed from
  scratch on any later `Register-DFTool` call in the same session. Measured ~44%
  reduction in `Register-DFTool -All` wall-clock cost on a representative machine
  (`build/Measure-DFStartup.ps1`). `Install-DFTool` refreshes a tool's cached entry
  immediately after a successful install, so a `Register-DFTool` call right after
  installing a tool picks it up, provided the install landed on the current session's
  PATH already (true for scoop; not guaranteed for winget/choco installs that land
  somewhere the running shell won't see until it restarts).
- **`carapace`, `zoxide`, `mdcat`, and `scoop-search`'s init/completion scripts no longer spawn
  their process every single session.** A startup-perf audit
  (`docs/superpowers/specs/2026-09-05-startup-perf-audit.md`) found these four companions spawn
  a real process every `Register-DFTool` call to produce output that is a pure, byte-identical
  function of the tool's own build — a caching candidate exactly like `vivid`'s existing
  `LS_COLORS` cache, just with no session-input theme name to key on. New
  `Get-DFCachedCommandOutput` (`Private/Get-DFCachedCommandOutput.ps1`) fingerprints the resolved
  executable's own file identity (path + `LastWriteTimeUtc`) instead — a file stat, not a process
  spawn — so a tool upgrade correctly invalidates the cache with no version-check cost on the
  common (cache-hit) path. Falls back to always regenerating, uncached, whenever the resolved
  command has no real file behind it (a function/alias stand-in) so a stubbed or shadowed command
  degrades to "slower but correct," never broken. Measured ~200ms mean reduction in
  `Register-DFTool -All` on a representative machine (`build/Measure-DFStartup.ps1`).
- **`type: module` tools now warm their `Import-Module` cost in the background before
  `Register-DFTool`'s per-tool loop reaches them.** A new `Start-DFModulePrewarm`
  (`Private/Start-DFModulePrewarm.ps1`) fires one background job that pre-imports every
  prewarm-eligible `type: module` tool actually being registered this call (`Terminal-Icons`,
  `PSFzf`, `posh-git`) into a throwaway runspace, purely to warm OS/CLR-level caches
  before the loop reaches that tool's own existing, unchanged `Import-Module` call — the
  later, real import is then measured ~77% faster (282ms → 65ms on a representative
  module, reproduced 3/3, per `docs/superpowers/specs/2026-09-05-startup-perf-audit.md`
  Part 2). Automatic for every prewarm-eligible `type: module` tool actually being
  registered — see `Start-DFModulePrewarm`'s own doc comment for the one assumption this
  relies on (no import-time side effects beyond session-local state). A tool opts out via a
  new `Tools/<name>.json` `"prewarm": false` field; `psreadline` deliberately sets it and is
  excluded — its sidecar (`Tools/psreadline.ps1`) never calls `Import-Module` (PSReadLine is
  always pre-loaded by the PS7 host before any profile runs), so prewarming it has no
  benefit, and it is the module most exposed to the shared-process CLR statics
  `Start-ThreadJob` implies (PSReadLine keeps its key-handler dispatch table on a
  process-global static singleton that PSFzf's import touches).
  Deliberately excludes `oh-my-posh`/`fnm` (neither is a `type: module` tool, and the audit
  found deferring `oh-my-posh`'s init reproduces a documented prompt-hook bug) and
  `inshellisense`'s session check (a separately-tracked, differently-shaped follow-up —
  see `TODO.md`).

### Added

- **Tool setup lifecycle.** A new optional `Tools/<name>.setup.ps1` companion
  runs at most once ever per tool — for setup that makes a persistent,
  user-visible change (e.g. adding an `[include]` line to the user's real git
  config) that must never be silently reasserted after the user edits or
  removes it. Tracked in `$XDG_STATE_HOME/dotforge/setup-state.json`
  (`Private/Get-DFToolSetupState.ps1`); a tool's setup script records its own
  success by calling the new `Complete-DFToolSetup -Name <tool> [-Actions
  <object[]>]`, so a script that throws before reaching that call is retried
  on the next `Register-DFTool` call rather than silently marked done. New
  `$DFConfig['SkipSetup']` opts a tool out, mirroring `SkipTools`. First
  consumer: `delta` (below); `mdv`'s migration closes an already-shipped bug
  (see Fixed).

- **`delta` now actually renders catppuccin instead of silently no-opping.**
  `DELTA_FEATURES=catppuccin-mocha` pointed at a feature that never existed in
  any git config, anywhere — a confirmed no-op. Fixed two ways: `Tools/delta.ps1`
  now bundles and deploys [catppuccin/delta](https://github.com/catppuccin/delta)'s
  `catppuccin.gitconfig` (all four flavours) to
  `$XDG_CONFIG_HOME/delta/catppuccin.gitconfig` every registration, and a new
  `Tools/delta.setup.ps1` — the tool-setup-lifecycle primitive's first
  consumer — adds one `include.path` entry pointing at it to the user's real
  global git config, exactly once ever, printing the exact removal command and
  never re-adding it after an explicit removal. Also fixed a related
  already-shipped bug found along the way: `DELTA_FEATURES` was set bare,
  which *replaces* the user's entire git-config `features` list rather than
  layering on top of it (verified directly) — now prefixed with `+`, additive
  like every other feature DotForge doesn't own. Opt out of the git-config
  edit alone (keeping `DELTA_FEATURES`/`GIT_PAGER`) with
  `$DFConfig['SkipSetup'] = @('delta')`.

- **`vivid` LS_COLORS theming.** New `Tools/vivid.json`/`.ps1` plugin resolves
  the shared theme (default `catppuccin-mocha`) via the existing
  `Get-DFConfiguredTheme`/`Resolve-DFThemeName` chain and applies it as
  `LS_COLORS`, cached under `$XDG_CACHE_HOME/dotforge` and regenerated only on
  a theme change (`vivid generate` costs ~40ms). `eza` (this repo's
  `listing`-role default, per `man eza_colors`) and `lsd` (per its README FAQ)
  both read `LS_COLORS` directly for filetype-extension coloring — confirmed
  documented behavior for both, not an assumption — so their output changes
  once `vivid` is installed; it's a suggested, not required, tool. Ships a
  live picker, `Select-LSColorsTheme` / `fls`, mirroring psreadline's `fprl`,
  with a `vivid preview {}` swatch per theme in the fzf preview pane.
- **`bat` theming via `BAT_THEME`.** `Tools/bat.json` now ships bat's native
  `Catppuccin Mocha` theme as the default (bat already had this theme built
  in — no external config needed, unlike `delta`). A new `Tools/bat.ps1`
  overrides it from `$DFConfig['BatTheme']`/`$DFConfig['Theme']` via the
  standard `Get-DFConfiguredTheme`/`Resolve-DFThemeName` chain, same pattern
  as `mdcat`. bat validates the theme name itself and degrades gracefully on
  an unrecognized one, so no DotForge-side whitelist is needed.
- **`$DFConfig.Defaults`-driven default-tool role resolution.** A tool optionally declares a
  `role` (e.g. `"listing"`); `$DFConfig.Defaults = @{ listing = 'eza' }` names the winner, and
  `Register-DFTool` suppresses only the alias keys a role LOSER shares with the winner — every
  other alias, XDG config, and picker the loser declares still applies. Onboarded `lsd` as a real
  second `listing`-role tool alongside `eza` to prove the mechanism.
- **Author-time tool-conformance harness.** `build/Test-DFToolConformance.ps1`
  probes whether a tool actually honors its configuration (env vars, config
  files, flags) rather than trusting the docs, recording per-claim
  `pass`/`fail`/`manual`/`unknown` verdicts in a versioned ledger
  (`data/tool-conformance.json`) and generating an upstream-ready issue report
  (`reports/tool-conformance-issues.md`). Probe descriptors live in
  `build/conformance/*.jsonc`; sidecar adapters cite the claim they work around
  (`# adapter for <claim-id>`), and the harness flags orphaned or upstream-fixed
  adapters. Piloted on `bat` and `glow`. Author-time only — never loaded or run
  by the module.

### Changed

- **`psreadline` now defaults to `catppuccin-mocha`**, matching `mdcat`/`mdv`/`glow`.
  Previously its built-in default was `dark` — the only themed tool in this
  codebase that didn't ship catppuccin out of the box. `Tools/psreadline/catppuccin-mocha.json`
  already existed; this was a one-line default-value change
  (`Tools/psreadline.ps1`'s `Get-DFConfiguredTheme -Default` argument).
- **The `copy` alias is renamed to `yank`.** It collided with PowerShell's builtin `copy` alias
  (`Copy-Item`, `AllScope`) — the only general-helper alias that did. Anyone using `copy` for
  `Copy-DFToClipboard` needs to switch to `yank`.
- **All 27 general-helper aliases (`pg`, `hm`, `touch`, `yank`, …) are now genuinely module-owned.**
  `(Get-Module DotForge).ExportedAliases` reports them and `Remove-Module DotForge` cleans them up
  correctly — previously the manifest's `AliasesToExport` was decorative. No change to how or when
  they're created relative to a session's existing aliases (import-time collision behavior is
  unchanged; see `docs/superpowers/specs/2026-07-26-alias-ownership-design.md` for why).

### Fixed

- **`$DFConfig = $null` in a profile crashed five code paths.** `Register-DFTool`,
  `Install-DFTool`, `New-DFShim`, and both `$DFConfig` reads in `Tools/psreadline.ps1`
  guarded on the *variable's existence* (`Get-Variable -Name DFConfig`) before indexing
  into it. Assigning `$null` leaves the variable defined, so the index threw
  `Cannot index into a null array`. All five now test the value (`$null -ne $Global:DFConfig`),
  matching the already-safe short-circuit in `Get-DFCommandConflict`. Regression tests
  added for each.

- **glow ignored its DotForge configuration entirely.** `Tools/glow.json` set
  `GLOW_CONFIG_DIR` and created `$XDG_CONFIG_HOME/glow`, but glow honors no XDG
  environment variable: its config path comes from a Win32 known-folder lookup
  (it does not move even when `APPDATA`/`LOCALAPPDATA` are redirected),
  `GLAMOUR_STYLE` is never read at all, and `GLOW_STYLE` is parsed but loses to
  glow's non-TTY downgrade. The result was an empty config directory and a theme
  that never rendered. A new companion `Tools/glow.ps1` now wraps the executable
  and passes `--config` and `-s` as flags — the only knobs that work — so
  `xdg.method` moves from `env` to `wrapper` and the dead `xdg.vars` are gone.

### Added

- **Canonical path handling (`ConvertTo-DFPath`).** All paths DotForge stores, compares, emits, or
  accepts are now absolute, native-separator, free of `.`/`..`, and without a trailing separator, with
  a leading `~` expanded to `$HOME`. This fixes the mixed `\`/`/` separators that XDG-derived env vars
  (`BAT_CONFIG_PATH`, `MDV_CONFIG_PATH`, …) previously carried on Windows, and collapses `..` in
  internal path defaults. Non-path flag strings (`LESS`, `FZF_DEFAULT_OPTS`) are unaffected.
- **Two markdown viewers — `mdcat` and `mdv`:** both catppuccin by default. `mdcat`
  is themed via `MDCAT_THEME` with native `--completions`; `mdv` is themed by a seeded
  `config.yaml` (written only when absent) plus a bundled carapace spec. A shared
  `$DFConfig['Theme']` key now drives `glow`, `mdcat`, `mdv`, and `psreadline`, with
  per-tool keys (`GlowTheme`, `MdcatTheme`, `MdvTheme`, `PSReadLineTheme`) overriding it.
  `Install-DFTool` gained a `cargo` arm (last-resort) so cargo-only tools install.
- **Bundled glow theme + `$DFConfig['GlowTheme']`:** `Tools/glow/catppuccin-mocha.json`
  ships with the module, and `Resolve-DFGlowStyle` resolves a theme name the same
  way PSReadLine themes resolve — rooted path, then
  `$XDG_CONFIG_HOME/glow/themes/<name>.json`, then the bundled copy, then glow's
  own built-in style names (`auto`, `dark`, `light`, `dracula`, `pink`, `notty`,
  `ascii`, `tokyo-night`). An unresolved name warns and falls back to `auto`,
  because a `-s` path glow cannot load makes it exit 1 rather than degrade. The
  resolved value lives in `$global:DFGlowStyle` and is read at call time, so
  assigning to it switches theme for the rest of the session.

### Changed

- **Non-XDG environment variables moved out of `xdg.vars` into a dedicated top-level `env`
  block.** `xdg.vars` is now `${XDG_*}` path-templates only. Affects `fzf`, `delta`, `less`,
  and `mdcat` (fzf/delta/mdcat move to `xdg.method: default`). Behavior is unchanged — the same
  variables are set to the same values, just declared in `env`.

- **Theme family→dialect mapping moved from hardcoded sidecar rules into an optional per-tool
  `themeMap`**, resolved by the new `Private/Resolve-DFThemeName.ps1` from each tool's own
  declaration (no central registry — governed by `docs/plugin-architecture.md`). The bare
  `catppuccin` alias is retired in favor of the canonical `catppuccin-mocha`; the shared
  `$DFConfig.Theme` is now canonical-name-only, while a per-tool `<Tool>Theme` still accepts a
  tool's own native names. All tool defaults remain canonical, so out-of-the-box rendering is
  unchanged. `delta` gains a new companion (`Tools/delta.ps1`) so `DELTA_FEATURES` tracks
  `$DFConfig.Theme`/`DeltaTheme` instead of being a static value.

## [0.5.0-preview] - 2026-07-23

### Added

- **Debounced picker previews:** the winget/scoop/choco preview panes are
  prefixed with a ~1s cmd sleep (`ping -n 2 127.0.0.1 >nul &`). fzf kills the
  running preview when the cursor moves, so scrolling quickly through a list no
  longer spawns `winget show` / `scoop info` / `choco info` for every skipped
  item — the preview only fetches once the cursor rests on an item.
- **Command-line prefill chords for the search pickers:** when PSReadLine is
  available, each companion binds a `Ctrl+G` chord — `Ctrl+G W` (winget),
  `Ctrl+G S` (scoop), `Ctrl+G C` (choco) — that reads the current line as the
  search query, opens the fuzzy picker, and drops the resulting install command
  onto the command line (editable; press Enter to run). Guarded, so it is a no-op
  when PSReadLine is not loaded.
- **scoop fuzzy pickers (`Tools/scoop.ps1`):** `Select-ScoopPackage` / `sins`,
  `Remove-ScoopPackage` / `srm`, `Invoke-ScoopUpdate` / `sup` — same picker set
  and keybindings as winget, with a `scoop info` preview. Search uses
  `scoop-search` when present (fast, matches names and binaries) and falls back
  to the [`Scoop`](https://www.powershellgallery.com/packages/Scoop) module's
  `Find-ScoopApp`; the installed list and install/uninstall/update actions use the
  Scoop module (object output — no `scoop list` table scraping). `scoop.json`
  `picker` is now `"custom"`.
- **choco tool + fuzzy pickers (`Tools/choco.json` + `Tools/choco.ps1`):**
  `Select-ChocoPackage` / `cins`, `Remove-ChocoPackage` / `crm`,
  `Invoke-ChocoUpdate` / `cup`, driven by choco's machine-readable `-r` output
  (pipe-delimited, not table-scraped). Install/uninstall/upgrade run through
  `gsudo` when it is available (elevation); otherwise the search picker's `Enter`
  returns the command to run elevated.
- **winget fuzzy pickers (`Tools/winget.ps1`):** rebuilt on the
  `Microsoft.WinGet.Client` module (object output — no CLI table scraping) with a
  live `winget show` preview pane.
  - `Select-WingetPackage` / `wins [query]` — search → install. `Enter` returns
    the `winget install …` command; `Alt-R` installs now; `Alt-I` installs the
    highlighted package in place while you keep browsing.
  - `Remove-WingetPackage` / `wrm` — browse installed → uninstall (`Alt-C`
    returns the command, `Alt-X` uninstalls in place). `-Source <src>` (e.g.
    `wrm -Source winget`) filters the list to one source, hiding ARP/registry-only
    entries.
  - `Invoke-WingetUpdate` / `wup` — browse upgradable packages, multi-select to
    update (`Tab` marks, `Alt-A` runs `winget upgrade --all`). New picker.
  - The pickers warn and no-op if `Microsoft.WinGet.Client` is not installed.
- **`Invoke-DFPicker` keybinding support:** new `-Expect` (fzf `--expect`
  multi-key mode; returns a `{ Key; Selected }` object so callers branch on the
  pressed key), `-Bind` (one `--bind` per spec, for act-in-place `execute(...)`
  bindings), and `-FzfArgs` (verbatim passthrough). All backward-compatible —
  existing callers and the declarative picker generator are unaffected.

## [0.4.0-preview] - 2026-07-20

### Added

- **fnm tool (`Tools/fnm.json` + `Tools/fnm.ps1`):** configures the Fast Node Manager,
  including its `--use-on-cd` per-directory version switching. fnm's generated hook
  rebinds `cd` to a wrapper that calls plain `Set-Location`, which would clobber
  zoxide's smart `cd`. The companion captures whatever owns `cd` before fnm loads
  (`$global:cdBeforeFnm`) and re-points fnm's `Set-LocationWithFnm` back through it, so
  a single `cd` performs zoxide's jump **and** fnm's Node switch; it forwards `@args`
  (not fnm's single `$path`) so zoxide's multi-keyword queries survive. `fnm.json`
  declares `"dependsOn": ["zoxide"]` so `Register-DFTool` topo-sorts zoxide first; with
  zoxide absent it falls back to `Set-Location` and fnm still works standalone. XDG:
  `FNM_DIR` points at `${XDG_DATA_HOME}/fnm`. The dependency on fnm's and zoxide's
  internals is catalogued in `docs/external-dependencies.md`.
- **`Get-DFCommandConflict`:** reports DotForge commands that Coreutils for Windows
  shadows before PowerShell can resolve them. Coreutils installs a
  `PSConsoleHostReadLine` hook that rewrites matching command names to `<name>.cmd`
  above command resolution, so affected aliases (`cat`, `touch`, `env`, `paste`) never
  run — while `Get-Command` still reports DotForge's version, making the failure
  invisible to normal probing. `Register-DFTool` now emits one consolidated warning
  listing the affected commands and the exact `coreutils-manager disable` line.
  Resolving the conflict needs elevation and is a policy choice, so DotForge only ever
  prints the command; it never elevates or writes to the registry. Suppress per-command
  with `$DFConfig.IgnoreConflicts`, or entirely with `$DFConfig.SkipConflictCheck`.
  The check reads the same set the hook itself consults, so it costs nothing when
  coreutils is absent and correctly reports no conflict in hosts where the hook never
  loads (it is injected into the ConsoleHost profile only, so the VS Code terminal is
  unaffected).
- **`docs/external-dependencies.md`:** catalogues every undocumented internal DotForge
  relies on in the tools it configures — coreutils' `$__COREUTILS__` variable, its
  section-marker GUID and generated code shape, its profile load order and per-host
  injection, its synthesized `la`; PSReadLine's suppression of `Colors` in non-VT
  terminals; zoxide's prompt hooking and re-hook guard — plus documented-but-load-bearing
  assumptions. Each entry records what breaks if it changes and how DotForge degrades.
  Undocumented dependencies degrade silently; they never fail.
- **Coreutils collision tripwire (`tests/Coreutils.Conflicts.Tests.ps1`):** fails the suite
  when a new DotForge alias collides with a coreutils utility, so contributors without
  coreutils installed find out at dev time rather than shipping a command that silently
  cannot run. Accepted collisions are listed with reasons; the fixture records the
  coreutils version it was captured from.
- **`carapace` tool record:** registers native argument completers for ~519 commands,
  including `eza`, `bat`, `fd`, `rg`, `npm`, `gh`, `glow`, `procs`, `rustup`, `chezmoi`,
  and `winget`. Composes with PSFzf, which owns the Tab key and routes through
  `TabExpansion2`.
- **Bundled carapace spec for `scoop`.** Carapace ships no scoop completer, so
  `scoop <TAB>` fell through to filesystem completion (offering `.\` and directory
  names). `Tools/carapace/specs/scoop.yaml` supplies static subcommand and flag
  completion; `Tools/carapace.ps1` deploys bundled specs into
  `$XDG_CONFIG_HOME/carapace/specs/`, which carapace auto-loads. Deployed copies are
  refreshed only when the bundled content changes.
- **Package-universe Phase C (tool merge)** — `build/Build-DFPackageUniverseTools.ps1` flattens Phase B clusters and singletons into a master `tools` table (one row per real-world tool across the whole corpus, lossless via a `tool_packages` child), with per-field priority picks (winget > choco > scoop) and provenance, a license single-answer conflict flag, a `tool_tags` union, and first-pass `tool_categories` from a committed `data/package-universe-categories.jsonc` rule file. Build-only; no public module surface change.

### Fixed

- **`docker <TAB>` emitted raw ANSI escape sequences through the PSFzf picker.**
  Carapace styles completion `ListItemText` with colour escapes whenever it is
  attached to a console (invisible when stdout is redirected, so headless tests never
  saw it). PSFzf ran `fzf` without `--ansi`, so the escapes rendered literally. The
  completion-stack resolver now adds `--ansi` to `FZF_DEFAULT_OPTS` — a documented fzf
  environment variable, not a PSFzf internal — whenever PSFzf and Carapace are both
  registered. The inserted text stays clean because it comes from `CompletionText`,
  which Carapace never styles. The merge is idempotent and preserves existing options.
- **A fuzzy-picked Carapace completion was inserted quoted (`docker "build "`).**
  Carapace appends a trailing space to each `CompletionText`, and PSFzf quotes any
  completion containing a space. When PSFzf owns Tab (Native mode + PSFzf available),
  `Tools/carapace.ps1` now trims that trailing space from Carapace's generated
  completer, so the picked value lands unquoted (`docker build `); PSFzf re-adds the
  single trailing space. The space is preserved when PSFzf is not in play, where
  `MenuComplete` needs it for subcommand chaining. Catalogued in
  `docs/external-dependencies.md`.
- **The inshellisense Carapace bridge never activated.** `Tools/carapace.ps1` checks
  for the `is` executable before merging it into `CARAPACE_BRIDGES`, but Carapace
  sorted ahead of fnm, so `is` was not yet on PATH and the check always failed.
  `Tools/carapace.json` now declares `"dependsOn": ["fnm"]`, so `Register-DFTool`
  configures fnm (which puts the Node-hosted `is` on PATH) before Carapace runs. With
  fnm absent the dependency is skipped and Carapace still registers normally.
- **Eleven tools advertised fzf pickers that did not exist.** `Register-DFTool` only
  builds a picker from a declarative object, so `"picker": "custom"` without a sidecar
  that actually builds one did nothing at all — no error, no warning, no picker.
  `gh`, `jq`, `glow`, `docker`, `rustup`, `npm`, `uv`, `chezmoi`, `bitwarden`, `scoop`
  and `gsudo` were affected; `scoop` had a sidecar holding only the scoop-search hook.
  The field also under-reported: `psreadline` declared `null` while its sidecar builds
  the `fprl` picker. Records now match reality, and
  `tests/Tools.PickerDeclaration.Tests.ps1` fails the suite in both directions. The
  unported pickers are tracked in the fold-in spec.
- **`eza` aliases dropped their path argument.** `--icons` and `--hyperlink` take an
  optional value, and a trailing bare `--hyperlink` consumed the caller's path, so
  `ll .` failed with `invalid value '.' for '--hyperlink [<WHEN>]'`. All four aliases
  now bind values explicitly (`--icons=auto`, `--hyperlink=auto`).
- **`fzf` and `delta` configuration restored** to `Tools/fzf.json` and
  `Tools/delta.json` (`FZF_DEFAULT_OPTS` and friends; `GIT_PAGER`, `DELTA_FEATURES`).

- **`Find-DFPackage` (`trifle`):** fast multi-catalog tool lookup. Given a command
  name or keywords, searches scoop, winget, choco, npm, PyPI, crates.io, and
  PSGallery and renders a merged info card (single confident match) or match
  table (keyword search): description, installed status + owning catalog(s),
  per-catalog availability and latest versions, homepage, license, last-updated,
  and per-source cache age. Piped/redirected output (or `-AsObject`) emits raw
  `DotForge.ToolInfo` objects with no ANSI. Cross-catalog identities unify via
  the `packages` blocks in `Tools/*.json` (e.g. scoop `ripgrep` and winget
  `BurntSushi.ripgrep.MSVC` render as one row), and commands found on PATH but
  unclaimed by any catalog report `InstalledVia PATH`. Results order by match
  quality (exact id → exact name/moniker → keyword; installed tools win ties),
  and long first-run work (index builds, live fetches) reports status via the
  progress stream — never polluting piped output.
- **Speed architecture:** cache-first under `$XDG_CACHE_HOME/dotforge/catalogs/`.
  Scoop buckets are parsed directly from disk into a fingerprinted index (bucket
  git HEADs); the winget catalog is queried directly from the CLI's own SQLite
  `index.db` via a zero-dependency `winsqlite3.dll` P/Invoke (extracted from
  `source.msix`, keyed on its mtime+size, with a cached `winget search` CLI-parse
  fallback when the schema is unreadable); web catalogs use per-query TTL caches
  (24h; 72h for choco). Stale entries are served instantly while a background
  ThreadJob re-warms them. A warm query answers in ~200 ms across all seven
  catalogs.
- **`Update-DFPackageCache`:** refresh-only entry point designed for Task
  Scheduler — rebuilds snapshot indexes, refreshes the unified installed-package
  snapshot, and re-warms recently seen queries plus installed tool names.
  All cache writes are atomic renames, so a scheduled refresh is safe alongside
  an interactive session. Note: winget only refreshes its own `source.msix`
  when winget runs, so the recommended scheduled action prepends
  `winget source update` (documented in README, the example profile, and the
  cmdlet help) — otherwise the winget index ages silently on machines that
  rarely invoke winget.
- **`Select-DFPackage` (`ftrifle`):** fzf browser over every locally cached
  package (scoop + winget indexes, cached web queries, installed snapshot);
  Enter renders the trifle info card.
- **`trifle` detail view:** a confident single match (exact id or exact
  name/moniker) now renders a richer detail card instead of
  the summary card — every catalog (scoop, winget, choco, npm, PyPI,
  crates.io, PSGallery) contributes a `Detail` hook (manifest notes, dist-tags,
  resolved GitHub metadata, etc.). Qualified `source:id` queries (e.g. `trifle
  winget:Zed.Zed`) bypass keyword ranking and always resolve to that one
  package's detail card. `-All` forces the full match table even on an exact
  hit, and its table gains an `Id` column with values usable directly as a
  qualified query. `-Readme` fetches and pages the package's readme (npm
  registry, GitHub, or PyPI long description); `-GitInfo` resolves the GitHub
  repo and adds stars/latest release/activity, using `gh` when installed and
  authenticated and falling back to the anonymous GitHub REST API otherwise.
  `ftrifle <query>` live-searches and pre-renders instant preview cards for
  fzf's preview pane, with Enter re-entering `trifle` via the qualified id for
  the full detail card. `Update-DFPackageCache` now also re-warms every cached
  detail entry (the files under each provider's `details/` cache ARE the
  re-warm list) so detail lookups stay warm alongside search results.
- **trifle discovery (`-Category`/`-WorksWith`):** a curated, offline taxonomy
  (~70 well-known CLI tools, function + works-with facets) ships with the
  module in `data/tool-categories.json`. `trifle -Category <c> [-WorksWith <w>]`
  facet-searches the seed database and resolves every match through the same
  live catalog search-and-merge path as an ordinary query — installed state
  and versions are never a stale snapshot. `Get-DFCategoryList` (`tcats`)
  lists the valid vocabulary with live tool counts. The detail card gains
  `Category`/`Related`/`Alt to` lines for any package in the seed database.
  `ftrifle -Categories` browses the vocabulary interactively. `Update-DFCategoryDb`
  refreshes the database independently of module releases (opt-in only,
  never run implicitly). Built and regenerated via `build/Build-DFCategoryDb.ps1`
  from hand-authored `build/categories/*.jsonc` fragments.

### Fixed

- **trifle cross-catalog identity fix:** `Find-DFPackage`/`ftrifle` no longer
  merge two different catalogs' packages into one row on a bare name match.
  A new shipped, offline-verified tool-identity guide
  (`data/tool-identities.json`, built from `Tools/*.json`'s existing curated
  mappings via automated GitHub-repo and homepage-match verification, see
  `build/Build-DFToolIdentities.ps1`) supplements the existing live
  `Tools/*.json` identity mapping. Two catalog hits merge only when a
  genuine identity link says they're the same tool; anything else renders
  as separate rows — this fixes `trifle zed` wrongly combining the winget
  Zed editor with choco's unrelated `zed` package. `Update-DFToolIdentityGuide`
  refreshes the guide independently of module releases (opt-in only, never
  run implicitly).

## [0.3.0-preview] - 2026-06-20

### Added

- **`New-DFUuid` (`uuidgen`):** generates a version-4 UUID. Default output is lowercase,
  hyphenated, and unbraced (Unix-style, matching the Windows SDK `uuidgen` default). The
  `-UpperCase`, `-NoHyphens`, and `-Braces` switches are independent and combine freely —
  reaching all eight format variants, including the registry/COM form via `-UpperCase
  -Braces` (`{F47AC10B-...}`). `-Sdk` is a named preset (in its own parameter set, so it
  cannot be combined with the formatting switches) for the Windows SDK `uuidgen` default
  format. The `uuidgen` alias is unconditional and deliberately shadows any native
  `uuidgen` so output is identical on every platform.

### Changed

- **`Get-DFEnv` (`env`) colorized output:** KEY=VALUE lines now render with a bold-cyan
  variable name, a bold-yellow `=` divider, and a faint (theme-adaptive) value, gated on
  `$Env:NO_COLOR` / VT support. Color is suppressed automatically when output is piped or
  redirected (`env | Where-Object`, `env > out.txt`) so downstream string matching and
  captured files stay free of ANSI escapes. Backed by new private `Test-DFOutputPiped`
  (a mockable pipe/redirect detection seam using `PipelinePosition`/`PipelineLength` and
  `[Console]::IsOutputRedirected`).

## [0.2.0-preview] - 2026-06-12

### Added

- **`Show-DFCliHelp` (`clh`) + `Show-DFCliHelpPaged` (`clhp`):** colorized help for external
  CLI tools (git, eza, docker, ...). Auto-detects the help flag — tries `--help`, `-help`,
  `-?`, `help`, `-h` (in that order; `-h` last because it collides with real flags), accepts
  the first whose output looks like help and is not an unknown-option error, and caches the
  winner per command in `$XDG_CACHE_HOME/dotforge/cli-help-flags.json` (`-Force` re-detects).
  Colorizes like `hm` — bold-yellow section headers, faint tint on option flags — gated on
  `$Env:NO_COLOR` / VT support. `clhp` routes the result through `Invoke-DFWithPager`. Backed
  by private `Format-DFCliHelpText` (pure colorizer), `Resolve-DFCliHelpFlag` (detection +
  cache), and `Invoke-DFCommandCapture` (mockable command-execution seam).
- `New-DFShim [[-Target] <path>] [-Name] [-ShimsPath] [-Force]` — creates a `.cmd` shim in `$HOME\.local\bin` (or `$DFConfig['ShimsPath']`) that forwards invocations to a target executable, first `cd`-ing to the executable's own directory. `-Target` is positional (`New-DFShim C:\tools\grep\grep.exe`); shim name derived from target basename when `-Name` is omitted. Accepts a DotForge tool name via `-Name` for DB lookup when `-Target` is not given. Warns if the shims directory is not on `$PATH`.
- **General Helpers layer (Phase 5):** 19 functions across 7 helper files
  - **Pager:** `Invoke-DFWithPager` (`pg`) — pipes output through `$Env:Pager`
  - **Help & Discovery:** `Invoke-DFHelp` (`hm`), `Select-DFCommand` (`fcmd`), `Select-DFVerb` (`fverb`), `Select-DFModule` (`fmod`), `Select-DFHelpTopic` (`fh`) — fzf-powered help browsing with ANSI header colorization
  - **Navigation:** `Set-DFLocationUp` (`up`), `New-DFDirectoryAndSet` (`mkcd`), `Select-DFLocation` (`fcd`)
  - **File System:** `New-DFFile` (`touch`), `Get-DFWhich` (`which`), `Open-DFItem` (`open`)
  - **Process:** `Select-DFProcess` (`fps`), `Get-DFTopProcess` (`top`)
  - **Environment & Profile:** `Get-DFPath` (`path`), `Select-DFEnvVar` (`fenv`), `Edit-DFProfile` (`ep`), `Invoke-DFProfileReload` (`reload`)
  - **Clipboard:** `Copy-DFToClipboard` (`copy`), `Get-DFFromClipboard` (`paste`)
- **gsudo tool record:** `sudo` alias (direct gsudo alias) and `please` function — re-runs the last
  history entry in an elevated context via `gsudo ([scriptblock]::Create(...))`, preserving pipes,
  semicolons, and compound expressions
- **psreadline tool record with bundled themes:** Default settings record plus 3 bundled PSReadLine
  themes (dark, light, catppuccin-mocha) for syntax highlighting configuration
- **psreadline companion (`psreadline.ps1`):** Applies settings from tool JSON, registers
  `Invoke-DFApplyPSReadLineTheme` (XDG user dir → bundled theme lookup with VT true-color output),
  `Select-PSReadLineTheme` (`fprl`) fuzzy theme picker, and sets initial theme from
  `$DFConfig['PSReadLineTheme']` (defaults to `dark`). Theme colors stored in
  `$global:DFPSReadLineColors` for testability in non-VT environments.
- **oh-my-posh companion: OMP init moved into `oh-my-posh.ps1`** — conditionally imports posh-git
  and sets `POSH_GIT_ENABLED` before OMP starts; resolves theme config via `$Env:POSH_THEME` then
  XDG auto-discovery of `*.omp.*` in `$XDG_CONFIG_HOME/oh-my-posh/` (warns when multiple found,
  uses first alphabetically; warns and skips when none found). Removes the need for a manual OMP
  init block in `$profile`.

### Fixed

- **zoxide companion:** removed duplicate `zoxide init` call that defaulted to `--hook prompt` and
  conflicted with oh-my-posh's prompt wrapper (the actual conflict source); uses `--hook pwd`
  (calls `zoxide add` only on actual directory changes, not every prompt render). Keeps `--cmd cd`,
  so `cd`/`cdi` route through zoxide — zoxide emits `Set-Alias -Name cd -Option AllScope -Force`,
  replacing the built-in `cd` alias in place (alias-replaces-alias; no function-shadowing). The
  underlying `Set-Location` is untouched, so scripts calling it directly are unaffected.
- **arg-bearing aliases shadowed by built-in aliases:** `Register-DFTool` now removes any colliding
  global alias before defining a wrapper function (e.g. `ls` -> `eza --icons ...`). PowerShell
  resolves `Alias > Function`, so the built-in `ls`/`cd`/`cp`/... aliases previously shadowed the
  generated wrapper. `Remove-Item Alias:\<name> -Force` clears ReadOnly built-ins too.

### Changed

- `Register-DFTool`: respects `dependsOn` in tool JSON — tools are topologically sorted before
  registration so declared dependencies are always configured first (e.g. psreadline before PSFzf)
- `Register-DFTool`: sets `$DFCurrentTool` to the tool's parsed JSON object in the local scope
  before dot-sourcing its companion `.ps1`; cleared with `Remove-Variable` immediately after.
  Companions can read `$DFCurrentTool` directly to access their tool's metadata.
- `Ensure-DFDir` renamed to `New-DFDirectory` — approved PowerShell verb (`Ensure` is not in `Get-Verb`)
- `zoxide` picker alias renamed from `fcd` to `fzo` — `fcd` now cleanly belongs to `Select-DFLocation`
- `Register-DFTool`: `-Name` and `-All` are now mutually exclusive parameter sets
- **Selective registration ordering:** `oh-my-posh` must be registered before `zoxide` — zoxide's
  `--hook pwd` wraps `function:prompt`, so OMP must own the prompt first. `Register-DFTool -All`
  handles this automatically (alphabetical order); selective profiles must register oh-my-posh
  explicitly before zoxide. Example `03-selective.ps1` updated to reflect this.

### Removed

- `Get-DFCachedCompletion` — internal caching absorbed into `Get-DFHelpTopicList`
- `Update-DFCompletions` — removed

## [0.1.0] — 2026-05-07

### Added

- **Core primitives:** `Add-DFToPath` (normalized PATH dedup), `New-DFDirectory` (idempotent
  directory creation), `Invoke-DFPicker` (generalized fzf picker), `Get-DFCachedCompletion`
  (mtime-based completion caching)
- **Tool registry:** `Import-DFToolDb` (JSON DB loader), `Get-DFTool`, `Find-DFTool`
- **Configuration:** `Register-DFTool` — applies XDG env vars, static/dynamic completions,
  aliases, declarative fzf pickers, companion .ps1 dot-sourcing; supports `type = "module"`
- **Installation:** `Install-DFTool` (scoop / winget / choco / psresource),
  `Initialize-DFEnvironment`
- **Completions:** `Update-DFCompletions` — on-demand completion cache refresh
- **Tool records:** 30 JSON records covering file tools, dev tools, pagers, package managers,
  Python, Rust, Node, dotfiles, security, and PowerShell module tools
  (posh-git, PSFzf, Terminal-Icons, oh-my-posh)
- **`$DFConfig`** user configuration hashtable (`SkipTools`, `PackageManagerOrder`)
- **PS module tool type:** `type = "module"` in tool JSON
