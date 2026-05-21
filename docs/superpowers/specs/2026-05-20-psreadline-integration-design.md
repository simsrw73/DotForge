# PSReadLine Integration — Design Spec

**Date:** 2026-05-20
**Status:** Approved

---

## Context

DotForge configures CLI tools declaratively from JSON. PSFzf already integrates with PSReadLine
(key bindings for history, file picker, tab completion), but PSReadLine itself has no tool entry.
Without one, there is no guaranteed registration order — PSFzf can register before PSReadLine is
configured, and PSReadLine has no theme or settings management.

This spec adds PSReadLine as a first-class DotForge tool, introduces `dependsOn` ordering to
the tool schema, and establishes a theme system (bundled + user-defined) with a live picker.

---

## Files to Create / Modify

| File | Action |
|------|--------|
| `Tools/psreadline.json` | Create |
| `Tools/psreadline.ps1` | Create |
| `Tools/psreadline/dark.json` | Create |
| `Tools/psreadline/light.json` | Create |
| `Tools/psreadline/catppuccin-mocha.json` | Create |
| `Tools/PSFzf.json` | Modify — add `dependsOn`, remove stale comment |
| `Tools/PSFzf.ps1` | Modify — remove stale comment |
| `Public/Register-DFTool.ps1` | Modify — topological sort + `$DFCurrentTool` |
| `CLAUDE.md` | Modify — document `$DFCurrentTool` convention |
| `tests/Register-DFTool.Tests.ps1` | Modify — topological sort tests |
| `tests/psreadline.Tests.ps1` | Create |

---

## 1. Tool JSON Schema: `dependsOn`

Add optional `dependsOn: string[]` field to the tool JSON schema. Absence means no
dependencies. Consumers: `Register-DFTool` only.

```json
// Example — PSFzf.json
"dependsOn": ["psreadline"]
```

### Topological sort in Register-DFTool

After collecting `$tools` (either from `-All` or `-Name`), sort topologically using
Kahn's algorithm before the `foreach` loop:

1. Build adjacency from `dependsOn` fields, restricted to tools in the current registration set
2. Repeatedly extract tools with zero unmet dependencies
3. **Cycle detected** → `Write-Warning "DotForge: circular dependency …"`, fall back to original order
4. **Dep not in registration set** → skip constraint silently, continue

This guarantees PSReadLine runs before PSFzf when both are registered (via `-All` or
explicit `-Name psreadline, PSFzf`).

### $DFCurrentTool sidecar contract

Immediately before dot-sourcing a companion `.ps1`, set:

```powershell
$DFCurrentTool = $tool
. ($companion)
Remove-Variable -Name DFCurrentTool -ErrorAction Ignore
```

Sidecars read `$DFCurrentTool.settings`, `$DFCurrentTool.name`, etc. Documented in CLAUDE.md.
Existing sidecars do not use `$DFCurrentTool` — no breaking change.

---

## 2. psreadline.json

```json
{
  "name": "psreadline",
  "type": "module",
  "executable": "PSReadLine",
  "description": "Enhanced command-line editing and syntax highlighting for PowerShell",
  "tags": ["readline", "completion", "theme", "module"],
  "dependsOn": [],
  "xdg": { "compliance": "none", "method": "default" },
  "settings": {
    "editMode":            "Windows",
    "predictionSource":    "HistoryAndPlugin",
    "predictionViewStyle": "InlineView",
    "bellStyle":           "None",
    "historyNoDuplicates": true,
    "historySaveStyle":    "SaveIncrementally"
  },
  "aliases": {},
  "picker": null
}
```

PSReadLine ships with PowerShell 7+ — no `packages` field needed.

---

## 3. psreadline.ps1 (sidecar)

Responsibilities (in order):

1. **Apply settings** — read `$DFCurrentTool.settings`, map each key to a
   `Set-PSReadLineOption` parameter. Unknown keys: `Write-Warning` and skip.

2. **Resolve theme** — priority order:
   - `$DFConfig['PSReadLineTheme']` (name string or absolute path)
   - If name: search `$XDG_CONFIG_HOME/psreadline/themes/<name>.json` first,
     then `Join-Path $PSScriptRoot 'psreadline' '<name>.json'` (bundled)
   - If absolute path: load directly
   - Fallback: bundled `dark.json`

3. **Apply theme** — load JSON, convert hex strings to `[System.Drawing.Color]` via
   `[System.Drawing.ColorTranslator]::FromHtml($hex)`, call `Set-PSReadLineOption -Colors @{…}`.

4. **Register `Select-PSReadLineTheme` + `fprl` alias** — fzf picker over all discovered
   themes (XDG + bundled, deduped by name, XDG wins on collision).

No key handler removal — PSFzf owns its own overrides via `Set-PsFzfOption`.

### Select-PSReadLineTheme

```
List:    all theme names from XDG + bundled (deduplicated)
Preview: render synthetic PS snippet with theme colors applied (ANSI escape sequences)
Action:  load + apply theme for session; Write-Host confirmation
Alias:   fprl
```

### Bundled theme path

Sidecar uses `Join-Path $PSScriptRoot 'psreadline'` — `$PSScriptRoot` resolves to
the `Tools/` directory at dot-source time. No dependency on caller-scope variables.

---

## 4. Theme Format

**Bundled:** `Tools/psreadline/<name>.json`
**User:** `$XDG_CONFIG_HOME/psreadline/themes/<name>.json`

```json
{
  "name": "dark",
  "colors": {
    "Command":           "#569cd6",
    "Parameter":         "#9cdcfe",
    "String":            "#ce9178",
    "Operator":          "#d4d4d4",
    "Variable":          "#9cdcfe",
    "Comment":           "#6a9955",
    "Keyword":           "#c586c0",
    "Error":             "#f44747",
    "InlinePrediction":  "#4a4a4a",
    "ListPrediction":    "#3794ff"
  }
}
```

Color values: hex `#rrggbb`. Bundled themes to ship: `dark`, `light`, `catppuccin-mocha`.

The XDG theme directory is NOT auto-created. If `$XDG_CONFIG_HOME/psreadline/themes/`
does not exist, bundled themes are used silently.

---

## 5. PSFzf.json + PSFzf.ps1 Changes

**PSFzf.json** — add `dependsOn`:

```json
"dependsOn": ["psreadline"]
```

**PSFzf.ps1** — remove stale comment (line 2):

```powershell
# Remove: "PSReadline.ps1 must have already removed the default Ctrl+T/R handlers before this runs."
```

PSFzf already replaces PSReadLine handlers via `Set-PsFzfOption -PSReadlineChordProvider`
and `-PSReadlineChordReverseHistory`. No other changes to PSFzf.ps1.

---

## 6. CLAUDE.md Additions

Add to **Key Design Decisions**:

- **`$DFCurrentTool` sidecar contract**: `Register-DFTool` sets `$DFCurrentTool = $tool`
  immediately before dot-sourcing a companion `.ps1`. Sidecars may read
  `$DFCurrentTool.settings` and other fields. Variable is cleared after the companion
  returns. Sidecars needing their own directory (e.g., bundled sub-resources) use
  `$PSScriptRoot`, which resolves to `Tools/` at dot-source time.
- **`dependsOn` ordering**: Tools with `dependsOn` arrays are topologically sorted before
  registration. Deps outside the registration set are skipped silently. Cycles emit
  `Write-Warning` and fall back to original order.
- **PSReadLine + PSFzf ordering**: PSFzf declares `dependsOn: ["psreadline"]`. PSReadLine
  applies settings and theme first; PSFzf then overlays its key bindings. Each tool owns
  only what it touches.

---

## 7. Testing

### Register-DFTool.Tests.ps1 additions

- `dependsOn` respected: psreadline registered before PSFzf when both present
- Cycle detection: `Write-Warning` emitted, order falls back gracefully
- Dep not in registration set: registration proceeds without error
- `$DFCurrentTool` set before dot-source, cleared after

### psreadline.Tests.ps1 (new)

- Settings applied: mock `Set-PSReadLineOption`, verify each `settings` key maps correctly
- Theme resolution priority: XDG overrides bundled on name collision
- Theme fallback: no `$DFConfig` key → `dark` applied
- Hex → Color conversion: valid hex parsed; invalid hex emits `Write-Warning`, skips
- `Select-PSReadLineTheme` registered as global function with `fprl` alias
- Missing XDG dir: graceful — no crash, bundled themes still available

---

## Verification

```powershell
# Load module
Import-Module ./DotForge.psd1 -Force

# Register both tools
Register-DFTool -Name psreadline, PSFzf -Verbose

# Verify settings applied
(Get-PSReadLineOption).EditMode           # → Windows
(Get-PSReadLineOption).PredictionSource   # → HistoryAndPlugin
(Get-PSReadLineOption).BellStyle          # → None

# Verify theme applied
(Get-PSReadLineOption).Colors.Command     # → non-null

# Verify picker registered
Get-Command Select-PSReadLineTheme        # → GlobalFunction
Get-Alias fprl                            # → Select-PSReadLineTheme

# Test theme switching via $DFConfig
$Global:DFConfig = @{ PSReadLineTheme = 'catppuccin-mocha' }
Register-DFTool -Name psreadline -Verbose

# Run full test suite
Invoke-Pester tests/ -Output Detailed
```
