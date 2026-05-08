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

### Changed

- `Ensure-DFDir` renamed to `New-DFDirectory` — approved PowerShell verb (`Ensure` is not in `Get-Verb`)
- `zoxide` picker alias renamed from `fcd` to `fzo` — `fcd` now cleanly belongs to `Select-DFLocation`
- `Register-DFTool`: `-Name` and `-All` are now mutually exclusive parameter sets

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
