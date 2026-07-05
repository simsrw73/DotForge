# Changelog

All notable changes to DotForge are documented here.

## [Unreleased]

### Added

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
