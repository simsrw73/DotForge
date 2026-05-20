# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Project Is

DotForge is a PowerShell 7+ module that configures CLI tools (XDG paths, fzf pickers, aliases) from a JSON tool database.

PowerShell 7+ module that configures CLI tools (XDG paths, fzf pickers,
aliases) from a JSON tool database. Extracted and generalized from a real-world
PowerShell profile.

## Structure

```
DotForge/
├── Public/          # Exported cmdlets and helpers
├── Private/         # Internal functions
├── Tools/           # Per-tool JSON + optional .ps1
├── docs/            # Specs and implementation plans
├── examples/        # Profile usage examples
└── tests/           # Pester 5 tests
```

## Conventions

- **All public functions** use the `DF` prefix: `Add-DFToPath`, `Invoke-DFPicker`, etc.
- **Private helpers** also use `DF` prefix but live in `Private/` and are not exported.
- **Tool JSON files** are named `<toolname>.json` (lowercase, no spaces).
- **Optional `.ps1` companions** share the same basename as the JSON file.
- **No `$ErrorActionPreference = 'Stop'`** in any module file — inherited from caller.
- **All directory creation** goes through `New-DFDirectory`, never raw `New-Item`.
- **All PATH additions** go through `Add-DFToPath`, never raw `$Env:Path +=`.
- **PowerShell regex on help output**: use `-creplace` (not `-replace`) for case-sensitive matching; use `\r?$` instead of `$` since `Get-Help | Out-String` produces CRLF on Windows.
- **`$XDG_CACHE_HOME` must be set** for General Helpers cache (help topics) to work. Set it in your profile: `$Env:XDG_CACHE_HOME = "$Env:USERPROFILE\.cache"`.
- **New public functions and aliases** must be added to both `FunctionsToExport` and `AliasesToExport` in `DotForge.psd1` — the psm1 auto-loads them but the manifest controls `Get-Command -Module DotForge` visibility and PSGallery accuracy.

## Architecture (3 layers)

Layer 1 — Core Primitives (Phase 1)
Add-DFToPath, New-DFDirectory, Invoke-DFPicker, Invoke-DFWithPager

Layer 2 — Tool Registry (Phase 2)
Import-DFToolDb, Get-DFTool, Find-DFTool, Register-DFTool

Layer 3 — Tool Operations (Phase 3)
Install-DFTool, Initialize-DFEnvironment

General Helpers (Phase 5+)
DFHelpers.\*.ps1 — pager, help/discovery, navigation, filesystem, process, environment, clipboard

## Testing

Load module for development:

```powershell
Import-Module ./DotForge.psd1 -Force
```

Pester 5. Run all tests:

```powershell
Invoke-Pester tests/ -Output Detailed  # run from pwsh -NoProfile to avoid profile interference
```

Run a single file:

```powershell
Invoke-Pester tests/Add-DFToPath.Tests.ps1 -Output Detailed
```

## Tool JSON Schema

Each `Tools/*.json` must have at minimum:

- `name` (string, required)
- `executable` (string, required)
- `xdg.method`: one of `default | env | config | wrapper | manual`
- `xdg.vars`: env vars to set when applying XDG config — values may be XDG path templates (expanded via `Expand-DFXdgPath`) OR plain strings (e.g., `LESS` flag strings). Phase 3 tooling must not assume all `vars` values are filesystem paths.

## Key Design Decisions

- `Invoke-DFPicker` uses a private `Invoke-DFFzf` wrapper so tests can mock fzf
  without spawning a real process.
- The `Parse` scriptblock in `Invoke-DFPicker` receives `$_` via `ForEach-Object`,
  not as a positional argument.
- Scriptblocks passed to `Invoke-DFPicker -List` that capture local variables must use
  `.GetNewClosure()` (e.g., `{ $topics }.GetNewClosure()`). Without it, `& $List` inside
  `Invoke-DFPicker` silently sees nothing — the variable lookup happens in the wrong scope.
- **oh-my-posh + zoxide prompt hook ordering**: zoxide's `--hook pwd` wraps
  `function:prompt` (not `LocationChangedAction` — both hook modes use prompt wrapping;
  `pwd` mode just skips `zoxide add` when the directory hasn't changed). oh-my-posh must
  initialize *before* zoxide so zoxide correctly wraps OMP's prompt. `Register-DFTool -All`
  handles this automatically via alphabetical processing (`oh-my-posh` < `zoxide`). Selective
  registration must explicitly register oh-my-posh before zoxide. After a theme switch via
  `fpot`/`Select-PoshTheme`, OMP re-inits and replaces `function:prompt`; zoxide's
  `$global:__zoxide_hooked = 1` guard prevents re-hooking, so directory tracking stops
  until the next shell session. This is a known limitation with no clean workaround.
