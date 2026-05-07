# DotForge — Design Spec

**Date:** 2026-05-07
**Status:** Approved
**Scope:** v0.1 — Windows 11, PowerShell 7+

---

## Problem

Setting up a PowerShell profile for CLI tools is repetitive, error-prone, and per-person.
Every user who installs `bat`, `eza`, `fzf`, or `ripgrep` manually writes the same env vars,
the same XDG directory creation, the same argument completers, and the same fzf pickers.
DotForge encodes that knowledge once and applies it on demand.

---

## Goals

- One cmdlet to configure any known tool in the current session: `Register-DFTool`
- One cmdlet to install any known tool via the user's preferred package manager: `Install-DFTool`
- JSON tool database as the single source of truth for declarative metadata
- Generalized fzf picker helper that eliminates boilerplate across all pickers
- XDG Base Directory compliance for all tool config/data/cache paths
- Pester test coverage for all public cmdlets and core helpers

**Out of scope for v0.1:**
- macOS / Linux support
- Auto-discovery of tool arguments (scraping docs/man pages)
- "Recommended community config" beyond XDG + completions + aliases
- PSGallery publishing

---

## Architecture

Three layers, cleanly separated:

```
Layer 1 — Core Primitives
  Standalone helpers with no tool knowledge.
  Add-DFToPath, Ensure-DFDir, Invoke-DFPicker, Get-DFCachedCompletion

Layer 2 — Tool Registry
  Loads, validates, and queries the JSON tool database.
  Import-DFToolDb, Get-DFTool, Find-DFTool

Layer 3 — Tool Operations
  Uses Layers 1 + 2 to act on tools.
  Register-DFTool    — profile-time: configure one or all known tools
  Install-DFTool     — one-time: install via package manager
  Initialize-DFEnvironment — one-time: bootstrap XDG dirs, detect pkg managers
  Update-DFCompletions     — on-demand: refresh completion cache
```

**Key principle:** `Register-DFTool` runs on every shell start. It must be fast.
`Install-DFTool` and `Initialize-DFEnvironment` are one-time operations — performance
is not a concern.

---

## File Layout

```
DotForge/
├── DotForge.psd1               # Module manifest
├── DotForge.psm1               # Root: dot-sources Public/ and Private/
├── Public/
│   ├── Register-DFTool.ps1
│   ├── Install-DFTool.ps1
│   ├── Initialize-DFEnvironment.ps1
│   ├── Update-DFCompletions.ps1
│   ├── Get-DFTool.ps1
│   └── Find-DFTool.ps1
├── Private/
│   ├── Add-DFToPath.ps1
│   ├── Ensure-DFDir.ps1
│   ├── Invoke-DFPicker.ps1
│   ├── Get-DFCachedCompletion.ps1
│   ├── Import-DFToolDb.ps1
│   └── Resolve-DFPackageManager.ps1
├── Tools/                      # One entry per known tool
│   ├── bat.json
│   ├── bat.ps1                 # Optional: pickers/functions too complex for JSON
│   ├── eza.json
│   ├── eza.ps1
│   ├── fzf.json
│   ├── ripgrep.json
│   └── ...
├── docs/
│   └── superpowers/specs/
└── tests/
    ├── Add-DFToPath.Tests.ps1
    ├── Ensure-DFDir.Tests.ps1
    ├── Invoke-DFPicker.Tests.ps1
    ├── Get-DFCachedCompletion.Tests.ps1
    ├── Register-DFTool.Tests.ps1
    └── Install-DFTool.Tests.ps1
```

---

## Tool JSON Schema

Each file in `Tools/` is named `<toolname>.json`. All fields except `name` and
`executable` are optional.

```json
{
  "name": "bat",
  "description": "Modern cat replacement with syntax highlighting",
  "tags": ["viewer", "pager", "file"],
  "executable": "bat.exe",

  "packages": {
    "scoop":  "bat",
    "winget": "sharkdp.bat",
    "choco":  "bat"
  },

  "xdg": {
    "compliance": "partial",
    "method": "env",
    "vars": {
      "BAT_CONFIG_PATH": "${XDG_CONFIG_HOME}/bat/bat.conf"
    },
    "dirs": []
  },

  "completions": {
    "type": "static",
    "flags": [
      "--language", "--theme", "--style", "--paging", "--color",
      "--line-range", "--highlight-line", "--diff", "--show-all",
      "--plain", "--number", "--decorations", "--list-languages", "--list-themes"
    ]
  },

  "aliases": {
    "cat": { "command": "bat", "args": ["-pp"] }
  },

  "picker": null
}
```

**`xdg.compliance`:** `"full"` | `"partial"` | `"none"`

**`xdg.method`:** Controls how DotForge achieves XDG compliance:
- `"default"` — tool already follows XDG; do nothing
- `"env"` — set environment variables listed in `xdg.vars`
- `"config"` — write a config file; content defined in `xdg.config_content`
- `"wrapper"` — tool needs a function wrapper; implemented in companion `.ps1`
- `"manual"` — DotForge cannot automate this; emit instructions to user

**`completions.type`:** `"static"` | `"dynamic"`

For `"dynamic"`, add `"command"` (the generation command) and `"cache": true`:
```json
"completions": {
  "type": "dynamic",
  "command": "rg --generate complete-powershell",
  "cache": true
}
```

**`picker`:** For simple cases (declarative):
```json
"picker": {
  "alias": "fcd",
  "function": "Select-Directory",
  "list": "zoxide query --list",
  "preview": "eza --icons --color=always {}",
  "preview_window": "right:60%",
  "ansi": false,
  "header": "Select directory  [Enter to cd]",
  "action": "Set-Location {}"
}
```

`{}` in `preview` and `action` is substituted with the selected (and optionally parsed) value.
`parse` (optional string) is a PowerShell expression where `$_` is the raw fzf line.
`Register-DFTool` converts this string to a `[scriptblock]` at load time before
passing it to `Invoke-DFPicker`.

For pickers too complex to express declaratively, set `"picker": "custom"` and implement
the function in the companion `.ps1`.

---

## Core Primitives

### `Add-DFToPath`

Adds a directory to `$Env:Path` with normalization and dedup. Identical to the
`Add-ToPath` implementation proven in the PowerShell profile, with the `DF` prefix.

```powershell
Add-DFToPath 'C:\some\dir'
Add-DFToPath 'C:\python\scripts' -Prepend
```

Guards: empty string, non-rooted path (warns and skips), malformed existing PATH entries.

### `Ensure-DFDir`

Creates a directory idempotently. Wraps `New-Item -ItemType Directory -Force`.

```powershell
Ensure-DFDir (Join-Path $Env:XDG_CONFIG_HOME 'bat')
```

### `Invoke-DFPicker`

Generalized fzf picker. Handles the list → fzf → parse → action skeleton.

```powershell
function global:Invoke-DFPicker {
    param(
        [Parameter(Mandatory)][scriptblock]$List,
        [string]$Header        = '',
        [string]$Preview       = '',
        [string]$PreviewWindow = 'right:60%',
        [switch]$Ansi,
        [switch]$Multi,
        [string]$Delimiter     = '',
        [string]$WithNth       = '',
        [scriptblock]$Parse,    # transforms raw fzf line → usable value; $_ = raw line
        [scriptblock]$Action    # receives parsed value; if absent, outputs it
    )
    ...
}
```

**Three picker tiers:**

| Tier | Coverage | Where defined |
|------|----------|---------------|
| Fully declarative (`picker` JSON) | ~60% | `bat.json` |
| Thin `.ps1` calling `Invoke-DFPicker` | ~25% | `bat.ps1` (5–10 lines) |
| Custom logic using shared helpers | ~15% | `bat.ps1` (full function) |

### `Get-DFCachedCompletion`

Mtime-based completion caching. Only regenerates when the tool binary is newer than
the cached `.ps1`.

```powershell
Get-DFCachedCompletion -CacheKey 'rg' -ExePath (Get-Command rg.exe).Path `
    -Generate { rg --generate complete-powershell }
```

Cache stored in `$Env:XDG_CACHE_HOME/dotforge/completions/<key>.ps1`.

---

## Public Cmdlets

### `Register-DFTool [-Name <string[]>] [-All]`

Profile-time. Reads tool JSON, applies XDG config, registers completions, defines
aliases, runs companion `.ps1` if present.

```powershell
Register-DFTool -Name bat, eza, fzf   # configure specific tools
Register-DFTool -All                   # configure all known installed tools
```

Skips tools not found on PATH. Silent by default; `-Verbose` for detail.

### `Install-DFTool -Name <string[]> [-PackageManager <string>]`

One-time. Installs tools via the user's preferred package manager. Respects a
user-configured priority list (`$DFConfig.PackageManagerOrder`).

```powershell
Install-DFTool -Name bat, eza, ripgrep
Install-DFTool -Name bat -PackageManager winget  # override for this call
```

### `Initialize-DFEnvironment`

One-time bootstrap. Creates XDG directories, detects available package managers,
reports gaps.

```powershell
Initialize-DFEnvironment
```

### `Update-DFCompletions [-Name <string[]>]`

Invalidates and regenerates completion cache for dynamic completers.

```powershell
Update-DFCompletions           # all tools with dynamic completions
Update-DFCompletions -Name rg  # specific tool
```

### `Get-DFTool [-Name <string>] [-Tag <string>]`

Queries the tool registry.

```powershell
Get-DFTool -Name bat          # returns tool record
Get-DFTool -Tag pager         # returns all pager tools
Get-DFTool                    # returns all known tools
```

---

## Package Manager Support (v0.1)

Priority order (user-configurable via `$DFConfig.PackageManagerOrder`):

1. `scoop` (default first — most common in this ecosystem)
2. `winget`
3. `choco`

`Resolve-DFPackageManager` detects which are available at init time and stores the
result. `Install-DFTool` walks the priority list until it finds a manager that knows
the tool.

---

## XDG Environment

`Initialize-DFEnvironment` sets the four XDG base dirs if not already set:

```powershell
$Env:XDG_CONFIG_HOME  = "$HOME\.config"
$Env:XDG_DATA_HOME    = "$HOME\.local\share"
$Env:XDG_STATE_HOME   = "$HOME\.local\state"
$Env:XDG_CACHE_HOME   = "$HOME\.cache"
```

`Register-DFTool` assumes these are set (either by DotForge or by the user's profile).

---

## Configuration

Users configure DotForge via a `$DFConfig` hashtable in their profile (before
importing the module):

```powershell
$DFConfig = @{
    PackageManagerOrder = @('scoop', 'winget')
    SkipTools           = @('lsd')              # never configure these
    Verbose             = $false
}
Import-Module DotForge
Register-DFTool -All
```

If `$DFConfig` is not set, DotForge uses safe defaults.

---

## Testing Strategy

Pester 5+ tests for:
- All public cmdlets (mock filesystem, mock external commands)
- `Add-DFToPath`: normalization, dedup, prepend, empty/relative guards
- `Ensure-DFDir`: creates, idempotent, handles errors
- `Invoke-DFPicker`: mocked fzf, all parameter combinations
- `Get-DFCachedCompletion`: cache hit, cache miss, stale cache
- Tool JSON schema validation (all `Tools/*.json` files pass schema check)

---

## Initial Tool Set (v0.1)

Seed the `Tools/` directory with tools already fully understood from
`cli_tools_config.ps1`:

**Group 1 — File/directory:** `bat`, `eza`, `fd`, `ripgrep`, `broot`
**Group 2 — Text/data:** `jq`, `glow`
**Group 3 — System:** `procs`, `winfetch`
**Group 4 — Network:** `curl`, `wget`
**Group 5 — Navigation/fuzzy:** `fzf`, `zoxide`
**Group 6 — Pagers:** `less`, `moor`
**Group 7 — Package managers:** `scoop`, `winget`
**Group 8 — Dev tools:** `rustup`, `cargo`, `nvm`, `npm`, `gh`, `delta`, `lazygit`
**Group 9 — Python:** `uv`
**Group 10 — Dotfiles/config:** `chezmoi`
**Group 11 — Security:** `bitwarden`
**Group 12 — PS modules:** `PSFzf`, `posh-git`, `Terminal-Icons`, `oh-my-posh`

---

## Phased Delivery

**Phase 1 — Core primitives + schema**
`Add-DFToPath`, `Ensure-DFDir`, `Invoke-DFPicker`, `Get-DFCachedCompletion`,
tool JSON schema + validator, 5 seed tool records (`bat`, `eza`, `fzf`, `ripgrep`, `zoxide`).
Tests for all primitives.

**Phase 2 — Registry + Register-DFTool**
`Import-DFToolDb`, `Get-DFTool`, `Find-DFTool`, `Register-DFTool`.
Full initial tool set (25+ tools). Tests for registry and registration.

**Phase 3 — Install + Init**
`Install-DFTool`, `Initialize-DFEnvironment`, `Resolve-DFPackageManager`.
`$DFConfig` support. Tests for install path.

**Phase 4 — Completions + polish**
`Update-DFCompletions`, all dynamic completers wired up.
CLAUDE.md, README, module manifest `FunctionsToExport` finalized.
