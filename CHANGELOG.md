# Changelog

All notable changes to DotForge are documented here.

## [Unreleased]

### Added

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
- **oh-my-posh companion: OMP init moved into `oh-my-posh.ps1`** — conditionally imports posh-git
  and sets `POSH_GIT_ENABLED` before OMP starts; resolves theme config via `$Env:POSH_THEME` then
  XDG auto-discovery of `*.omp.*` in `$XDG_CONFIG_HOME/oh-my-posh/` (warns when multiple found,
  uses first alphabetically; warns and skips when none found). Removes the need for a manual OMP
  init block in `$profile`.

### Fixed

- **zoxide companion:** removed duplicate `zoxide init` call that defaulted to `--hook prompt` and
  conflicted with oh-my-posh's prompt wrapper; changed `--cmd cd` to `--cmd z` (restores `cd` to
  `Set-Location`, avoids alias conflicts); uses `--hook pwd` (calls `zoxide add` only on actual
  directory changes, not every prompt render)

### Changed

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
