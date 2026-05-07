# Changelog

All notable changes to DotForge are documented here.

## [Unreleased]

## [0.1.0] — 2026-05-07

### Added

- **Core primitives:** `Add-DFToPath` (normalized PATH dedup), `Ensure-DFDir` (idempotent
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
