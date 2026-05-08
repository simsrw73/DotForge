# DotForge

PowerShell 7+ module that configures CLI tools (XDG paths, completions, fzf pickers,
aliases) from a JSON tool database. Extracted and generalized from a real-world
PowerShell profile.

## Structure

```
DotForge/
├── Public/          # Exported cmdlets and helpers
├── Private/         # Internal functions
├── Tools/           # Per-tool JSON + optional .ps1
└── tests/           # Pester 5 tests
```

## Conventions

- **All public functions** use the `DF` prefix: `Add-DFToPath`, `Invoke-DFPicker`, etc.
- **Private helpers** also use `DF` prefix but live in `Private/` and are not exported.
- **Tool JSON files** are named `<toolname>.json` (lowercase, no spaces).
- **Optional `.ps1` companions** share the same basename as the JSON file.
- **No `$ErrorActionPreference = 'Stop'`** in any module file — inherited from caller.
- **All directory creation** goes through `Ensure-DFDir`, never raw `New-Item`.
- **All PATH additions** go through `Add-DFToPath`, never raw `$Env:Path +=`.
- **PowerShell regex on help output**: use `-creplace` (not `-replace`) for case-sensitive matching; use `\r?$` instead of `$` since `Get-Help | Out-String` produces CRLF on Windows.

## Architecture (3 layers)

Layer 1 — Core Primitives (Phase 1)
  Add-DFToPath, Ensure-DFDir, Invoke-DFPicker, Get-DFCachedCompletion, Invoke-DFWithPager

Layer 2 — Tool Registry (Phase 2)
  Import-DFToolDb, Get-DFTool, Find-DFTool, Register-DFTool

Layer 3 — Tool Operations (Phase 3)
  Install-DFTool, Initialize-DFEnvironment, Update-DFCompletions

General Helpers (Phase 5+)
  DFHelpers.*.ps1 — pager, help/discovery, navigation, filesystem, process, environment, clipboard

## Testing

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
- `completions.type`: one of `static | dynamic`
- dynamic completions require `completions.command`
- `xdg.vars`: env vars to set when applying XDG config — values may be XDG path templates (expanded via `Expand-DFXdgPath`) OR plain strings (e.g., `LESS` flag strings). Phase 3 tooling must not assume all `vars` values are filesystem paths.

## Key Design Decisions

- `Invoke-DFPicker` uses a private `Invoke-DFFzf` wrapper so tests can mock fzf
  without spawning a real process.
- `Get-DFCachedCompletion` caches to `$XDG_CACHE_HOME/dotforge/completions/<key>.ps1`
  and only regenerates when the tool binary is newer than the cache file.
- The `Parse` scriptblock in `Invoke-DFPicker` receives `$_` via `ForEach-Object`,
  not as a positional argument.
- Scriptblocks passed to `Invoke-DFPicker -List` that capture local variables must use
  `.GetNewClosure()` (e.g., `{ $topics }.GetNewClosure()`). Without it, `& $List` inside
  `Invoke-DFPicker` silently sees nothing — the variable lookup happens in the wrong scope.
