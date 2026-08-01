# Markdown Viewers: mdv + mdcat — Design

**Status:** Draft
**Date:** 2026-07-24
**Related:** `Tools/glow.ps1` (the wrapper pattern this builds on), `Tools/psreadline.ps1` (theme
resolution precedent)

## Context

DotForge configures `glow` as its markdown viewer. The user wants two more terminal markdown
viewers folded into the tool collection with catppuccin theming and the same "behaves like our other
tools" polish (theming, completions, installability).

The request named `github.com/xrfang/mdv` and `github.com/BIRSAx2/mdcat`. Investigation on the
machine established that **the installed `mdv` is a different project from the one named**:

| Tool | Named in request | Actually installed | Verified facts |
|---|---|---|---|
| `mdv` | `xrfang/mdv` — Go, serves markdown over HTTP to a browser | crate **`mdv` 4.2.1** from **`WhoSowSee/mdv`** — Rust terminal renderer, at `~/.cargo/bin/mdv` | Built-in `catppuccin` theme. **No config auto-discovery** — redirecting `HOME`, `USERPROFILE`, `APPDATA`, and `XDG_CONFIG_HOME` all loaded nothing; output was byte-identical to `--no-config`. **No theme env var** — `MDV_THEME`/`MDV_STYLE`/`MDV_COLOR_THEME` all ignored. Config is found only via `MDV_CONFIG_PATH` or `-F <dir>`, pointing at a dir holding `config.yaml`. |
| `mdcat` | `BIRSAx2/mdcat` | **`mdcat` 2.13.0**, copyright Wiesner/Sabir — matches that fork | `MDCAT_THEME` env var **works** (output byte-identical to `--theme`; a bogus value errors with the valid list) and is honored from any shell. **XDG-native** — a redirected `XDG_CONFIG_HOME/mdcat/config.toml` was honored. Built-ins include `catppuccin-mocha`, `catppuccin-latte`. |

The user confirmed they meant the **installed Rust `mdv`**, not the Go project.

Neither tool is reachable through DotForge's current package managers: `mdv` is cargo-only (no
scoop/winget/choco), and scoop's `mdcat` is 2.7.1 versus the installed 2.13.0.

Outcome wanted: `mdv` and `mdcat` render catppuccin out of the box, complete on Tab, install through
DotForge, and share the theme-configuration convention with `glow` and `psreadline`.

## Decisions locked with the user

1. **Installed Rust `mdv`**, not the Go `xrfang/mdv`.
2. **mdv mechanism:** `xdg.method: env` sets `MDV_CONFIG_PATH`; a sidecar seeds `config.yaml` when
   absent (never clobbers). Not a wrapper — chosen so plain `mdv README.md` is themed from any shell,
   and because mdv's config path actually works (unlike glow's broken env vars, which forced glow's
   wrapper).
3. **cargo package manager:** add a `cargo` case so both tools are installable at their real versions.
4. **Theme config — shared key, per-tool override, PSReadLine included** (the "C" model).
5. **In-scope polish:** `$DFConfig` theme overrides, mdcat native completions, a bundled carapace
   spec for mdv. **Out of scope:** a shared markdown-file fzf picker.

## Design

### 1. Shared theme configuration

New private helper **`Get-DFConfiguredTheme`** (`Private/Get-DFConfiguredTheme.ps1`):

```powershell
Get-DFConfiguredTheme -ToolKey 'MdvTheme' -Default 'catppuccin'
# returns $Global:DFConfig['MdvTheme'] ?? $Global:DFConfig['Theme'] ?? 'catppuccin'
```

It tests `$null -ne $Global:DFConfig` (the value, not the variable — the crash class fixed earlier
this session), then the per-tool key, then the shared `Theme` key, then the caller's default. This
fallback chain is the *only* genuinely shared piece and is what this helper owns.

Every themed tool routes its theme name through it:

| Tool | per-tool key | default (no config) | "catppuccin" → tool dialect |
|---|---|---|---|
| glow | `GlowTheme` | `catppuccin-mocha` | `catppuccin` → `catppuccin-mocha` (bundled JSON) |
| mdcat | `MdcatTheme` | `catppuccin-mocha` | built-in name, verbatim |
| mdv | `MdvTheme` | `catppuccin` | `catppuccin-*` → `catppuccin` |
| psreadline | `PSReadLineTheme` | `dark` (**unchanged**) | `catppuccin` → `catppuccin-mocha` (bundled JSON) |

So `$DFConfig = @{ Theme = 'catppuccin' }` themes all four; `$DFConfig = @{ Theme = 'catppuccin';
MdvTheme = 'nord' }` makes mdv differ. psreadline keeps its `dark` default, so existing users see no
change unless they set `Theme`.

**The family→dialect mapping stays per-tool, by design.** glow and psreadline map the family name
*up* to `catppuccin-mocha`; mdv maps it *down* to bare `catppuccin`. A single shared dialect resolver
would just branch on which tool called it — a bad abstraction. Each sidecar keeps a two-or-three-entry
alias map. Every tool also falls back safely when handed a theme it does not support (glow already
falls back to `auto` with a warning; mdcat to `auto`; mdv to its `terminal` default; psreadline warns
and keeps its current theme).

### 2. mdcat

- **`Tools/mdcat.json`** — `executable: mdcat.exe`, `packages: { scoop: "mdcat", cargo: "mdcat" }`,
  `xdg.method: "env"` with `vars: { MDCAT_THEME: "catppuccin-mocha" }` (static default so mdcat is
  themed even if the sidecar is skipped), `picker: null`.
- **`Tools/mdcat.ps1`** — (a) recompute the theme via `Get-DFConfiguredTheme -ToolKey 'MdcatTheme'
  -Default 'catppuccin-mocha'`, validate against mdcat's built-in list, and set `MDCAT_THEME`
  (overriding the JSON default when `$DFConfig` asks for something else); (b) register native
  completions: `mdcat --completions powershell | Out-String | Invoke-Expression`. mdcat emits exactly
  one `-Native` completer for `mdcat`; carapace ships no spec for mdcat (0-byte export), so there is
  no conflict, and it composes with PSFzf's Tab (which routes through `TabExpansion2`). No wrapper —
  the executable is untouched.

### 3. mdv

- **`Tools/mdv.json`** — `executable: mdv.exe`, `packages: { cargo: "mdv" }`, `xdg.method: "env"`
  with `vars: { MDV_CONFIG_PATH: "${XDG_CONFIG_HOME}/mdv" }` and `dirs: [ "${XDG_CONFIG_HOME}/mdv" ]`
  (core creates the dir), `picker: null`.
- **`Tools/mdv.ps1`** — resolve the theme via `Get-DFConfiguredTheme -ToolKey 'MdvTheme' -Default
  'catppuccin'`, map `catppuccin-*` → `catppuccin` and validate against mdv's theme list, then seed
  `config.yaml` with `theme: "<resolved>"` **only when the file is absent**. This mirrors
  `Register-DFTool`'s existing `config` method (`if (-not (Test-Path $path)) { write }`) and the
  carapace-spec deploy pattern — DotForge never overwrites a user-edited config.

  Verified: `MDV_CONFIG_PATH=<dir> mdv file.md` with a seeded `theme: "catppuccin"` produces output
  byte-identical to `mdv -t catppuccin file.md`.

  **Known limitation (documented in README + `docs/external-dependencies.md`):** because the seed is
  write-when-absent and mdv has no theme env var, changing `MdvTheme`/`Theme` after first run has no
  effect until `config.yaml` is edited or deleted and mdv re-registered. This is the accepted
  trade-off of the env+seed mechanism over a wrapper.

- **`Tools/carapace/specs/mdv.yaml`** — a hand-authored carapace spec (mdv has no completion
  generator, and carapace ships none). Deployed to `$XDG_CONFIG_HOME/carapace/specs/` by the existing
  `Tools/carapace.ps1` logic, exactly like `scoop.yaml`. Covers mdv's flags (`-t/--theme` with its
  value list, `-F/--config-file`, `-p/--pager`, `-H/--html`, etc.). Being hand-written, it can drift
  from the binary; catalogued as such.

### 4. cargo package manager

Confirmed by reading the code: `Install-DFTool` iterates `$pmOrder` (from `Resolve-DFPackageManager`,
default `scoop, winget, choco`, or `$DFConfig['PackageManagerOrder']`, or the `-PackageManager`
override) and looks up `packages.<pm>` for each. cargo is in none of those lists, so a cargo-only tool
like `mdv` currently warns "Could not install" — cargo is unreachable unless added.

- **`Public/Install-DFTool.ps1`** — two changes: (a) add a `'cargo' { cargo install $pkgId 2>&1 }`
  arm to the install switch; (b) after `$pmOrder` is built, **append `'cargo'` as a last-resort entry
  when the tool declares `packages.cargo` and `cargo` is on PATH** (skipped when `-PackageManager`
  pins a specific manager). Appending — not prepending — keeps scoop/winget/choco tried first, so
  `Install-DFTool -Name mdcat` still prefers scoop while `Install-DFTool -Name mdv` falls through to
  cargo. `cargo`'s availability check reuses the existing `Get-Command $pm` branch (no `psresource`-style
  special-casing needed).
- **`Private/Resolve-DFPackageManager.ps1`** — left unchanged. cargo is deliberately **not** in the
  auto-detect priority; it is reached only via the per-tool append above, so it never competes for
  tools that have a scoop/winget/choco package.

### 5. Testing

- `tests/Get-DFConfiguredTheme.Tests.ps1` — per-tool key wins; shared `Theme` fallback; default when
  neither set; `$DFConfig = $null` tolerated.
- `tests/mdcat.Tests.ps1` — registering sets `MDCAT_THEME` to the resolved value; `MdcatTheme` and
  shared `Theme` override; native completer registered (mock/guard on the binary); `$DFConfig = $null`
  tolerated.
- `tests/mdv.Tests.ps1` — `MDV_CONFIG_PATH` set and dir created; `config.yaml` seeded with the
  resolved theme when absent; an existing `config.yaml` is **not** overwritten; `catppuccin-mocha` →
  `catppuccin` mapping; `$DFConfig = $null` tolerated.
- `tests/Install-DFTool.Tests.ps1` — cargo arm invoked for a cargo-only tool (mock `cargo`).
- Guard binary-dependent assertions with `Get-Command`, as `tests/glow.Tests.ps1` does.

### 6. Files

**New:** `Tools/mdv.json`, `Tools/mdv.ps1`, `Tools/mdcat.json`, `Tools/mdcat.ps1`,
`Tools/carapace/specs/mdv.yaml`, `Private/Get-DFConfiguredTheme.ps1`, and the four test files above.

**Modified:** `Public/Install-DFTool.ps1` (cargo arm + per-tool cargo append), `Tools/glow.ps1`
and `Tools/psreadline.ps1` (route theme through the helper + family alias), README, CHANGELOG,
`docs/external-dependencies.md` (mdcat completions, mdv carapace spec + seed limitation, mdv's
env-immune config path), `examples/02-standard.ps1` (shared `Theme` key).
(`Private/Resolve-DFPackageManager.ps1` and `Tools/glow.json` are **not** modified.)

## Scope note

Items 1 and 4 touch shared core code (`Install-DFTool`, `Resolve-DFPackageManager`) and rework two
already-shipped sidecars (`glow.ps1`, `psreadline.ps1`). This is meaningfully larger than "add two
JSON files" and is inherent in the C theme model and cargo support the user chose. Flagged so it is
not a surprise during implementation.

## Out of scope

A shared markdown-file fzf picker (`fmd`) that finds `.md` files and opens them in a chosen viewer —
the `fgl`/`Read-MarkdownFile` idea from the fold-in spec. Additive, serves all three viewers, and
belongs in its own change.

## Verification

```powershell
pwsh -NoProfile -Command 'Invoke-Pester tests/ -Output Detailed'   # full suite, no regressions
```

Live session:

```powershell
Import-Module ./DotForge.psd1 -Force
$DFConfig = @{ Theme = 'catppuccin' }
Register-DFTool -Name mdcat, mdv, glow, psreadline
$Env:MDCAT_THEME                              # catppuccin-mocha
mdcat README.md                               # catppuccin
mdcat --th<Tab>                               # completes --theme + its values
Get-Content (Join-Path $Env:XDG_CONFIG_HOME 'mdv/config.yaml')   # theme: "catppuccin"
mdv README.md                                 # catppuccin, from any shell
mdv <Tab>                                     # carapace spec completes mdv
Install-DFTool -Name mdv -WhatIf              # resolves to cargo
```
