# `vivid` LS_COLORS Theming — Design

**Date:** 2026-09-03
**Status:** Approved design; ready for implementation planning.
**Parent standard:** `ToolAcquisitionSpec.md` §6 (Theme), §8 (Pickers).
**Governed by:** `docs/plugin-architecture.md` (core invariant — adding a tool
never modifies core; per-tool declaration over central registries).
**Backlog items closed:** `TODO.md` Priority 4 "Themes via LS_COLORS — use
`vivid` to setup LS_COLORS"; contributes to Priority 3 "Color theme system
across all tools".

## Purpose

Wire `LS_COLORS` into DotForge's existing theme system via `vivid` (a
themeable `LS_COLORS` generator), defaulting to the system theme
`catppuccin-mocha`, following the exact resolution-chain and per-tool-map
conventions `docs/superpowers/specs/2026-07-25-theme-centralization-design.md`
already established for `glow`/`psreadline`/`mdcat`/`mdv`/`delta`.

`vivid` is a **suggested, not required**, tool: like every other optional
DotForge tool, `Register-DFTool` already skips a tool's JSON application and
sidecar entirely when its `executable` isn't on PATH
(`Public/Register-DFTool.ps1:121-126`). No special-case degradation logic is
needed in `Tools/vivid.ps1` itself — installing `vivid` is what turns the
feature on.

## Verified facts (informing this design)

- `vivid generate catppuccin-mocha` takes **~42ms** on this machine — not free
  on a startup path this repo already treats as latency-sensitive (see the
  coreutils profile shim's own ~10ms inlining comment).
- `vivid themes` lists `catppuccin-mocha` **verbatim** — no `themeMap`
  translation needed (native dialect == canonical name), same case as
  glow/mdcat/psreadline/delta.
- `vivid generate <unknown-theme>` exits 1 with `Error: Could not find theme
  '...'` on stderr — vivid validates its own input, so the sidecar does not
  need a duplicate hardcoded theme whitelist (unlike `mdcat.ps1`, which needs
  one because `MDCAT_THEME` fails silently on a bad value).
- `eza` (this repo's `listing`-role winner) **reads plain `LS_COLORS`** for
  its base directory/file palette — confirmed by overriding `di=` and
  observing eza render exactly that color instead of its own built-in blue.
  This is not theoretical: it will visibly change `ls`/`ll`/`la`/`tree` output
  once wired up.
- `vivid preview <theme>` renders ANSI-colored per-filetype samples — a
  ready-made fzf preview-pane command, confirmed working.
- Package availability: `scoop` = `vivid` (main bucket), `winget` =
  `sharkdp.vivid`. **No Chocolatey package exists** — confirmed against the
  Chocolatey community feed directly (`community.chocolatey.org/api/v2/Packages()`)
  and re-confirmed via a working local `choco search vivid --exact` (0
  results) after the user's local Chocolatey install was repaired mid-session.

## Scope

**In scope:**
- New `Tools/vivid.json` + `Tools/vivid.ps1` (theme resolution, caching,
  applying `LS_COLORS`).
- A cache file pair under `$XDG_CACHE_HOME/dotforge`, mirroring
  `Private/Get-DFHelpTopicList.ps1`'s existing cache-plus-fingerprint pattern
  (the only precedent for this kind of cache in the codebase).
- A live picker, `Select-LSColorsTheme` / alias `fls`, mirroring
  `Select-PSReadLineTheme` / `fprl`.
- Tests (`tests/vivid.Tests.ps1`).
- Docs: README (tool table + `$DFConfig` key), `ToolAcquisitionSpec.md` §6.1
  (add `VividTheme` to the per-tool-key list — and, as a small drive-by fix
  while already editing that exact line, add the already-implemented
  `DeltaTheme`, which the list omits), CHANGELOG.

**Out of scope (unchanged from the theme-centralization spec's own
out-of-scope list, still applicable):**
- Extending theming to other static tools (`bat`, `lsd`, `oh-my-posh`, `fzf`
  colors, `lazygit`, `micro`, `procs`, `winfetch`). Covered instead by the
  separate coverage audit delivered alongside this spec.
- Making `lsd` (the non-winning `listing`-role tool) consume `LS_COLORS` —
  unconfirmed whether it reads the variable at all; out of scope to
  investigate here since `eza` is the configured default winner.
- Provisioning any theme *content* beyond what `vivid` ships built-in.

## Section 1 — `Tools/vivid.json`

```jsonc
{
  "name": "vivid",
  "description": "Themeable LS_COLORS generator",
  "tags": ["color", "theme", "listing"],
  "executable": "vivid.exe",
  "packages": {
    "scoop": "vivid",
    "winget": "sharkdp.vivid"
  },
  "xdg": { "compliance": "none", "method": "default" },
  "settings": { "theme": "catppuccin-mocha" },
  "aliases": {},
  "picker": "custom"
}
```

No `themeMap` — vivid's native dialect equals the canonical name.
`"picker": "custom"` per `ToolAcquisitionSpec.md` §8, since `fls` needs
bespoke cache/regenerate/persist logic beyond a plain
list→preview→act `Invoke-DFPicker` wrapper.

## Section 2 — Theme resolution and caching (`Tools/vivid.ps1`)

Resolution follows the uniform chain from the theme-centralization spec:

```powershell
$_settings = $DFCurrentTool.PSObject.Properties['settings']?.Value
$_default  = $_settings.PSObject.Properties['theme']?.Value ?? 'catppuccin-mocha'
$_theme    = Get-DFConfiguredTheme -ToolKey 'VividTheme' -Default $_default
$_theme    = Resolve-DFThemeName -Name $_theme -ThemeMap ($DFCurrentTool.PSObject.Properties['themeMap']?.Value)
```

Caching mirrors `Private/Get-DFHelpTopicList.ps1`: a cache file holding the
generated `LS_COLORS` string, and a key file holding the fingerprint that
invalidates it — here, just the resolved theme name (regenerate only on
theme change, per the approved design choice; a stale cache after a `vivid`
version upgrade with shifted palette values is accepted as a known edge case,
addressable with a `-Force` bypass — same shape as
`Get-DFHelpTopicList -Force`).

```
$cacheDir  = Join-Path $Env:XDG_CACHE_HOME 'dotforge'
$cacheFile = Join-Path $cacheDir 'ls-colors.txt'
$keyFile   = Join-Path $cacheDir 'ls-colors.key'

if cache valid (key file content -eq $_theme):
    $value = Get-Content $cacheFile -Raw
else:
    $result = & vivid generate $_theme 2>&1
    if ($LASTEXITCODE -ne 0):
        Write-Warning "DotForge: vivid theme '$_theme' failed — $result"
        return   # LS_COLORS left unset; eza/ls fall back to their own defaults
    New-DFDirectory $cacheDir
    Set-Content -Path $keyFile   -Value $_theme -Encoding UTF8
    Set-Content -Path $cacheFile -Value $result -Encoding UTF8
    $value = $result

[System.Environment]::SetEnvironmentVariable('LS_COLORS', $value, 'Process')
```

Matches `Get-DFHelpTopicList`'s own guard: warn and return (no-op) if
`$Env:XDG_CACHE_HOME` isn't set, rather than caching to an unpredictable
location.

## Section 3 — Live picker: `Select-LSColorsTheme` / `fls`

Registered the same way `Select-PSReadLineTheme`/`fprl` is — a global function
built in the sidecar via `Set-Item -Path function:global:...`, plus
`Set-Alias -Name fls -Value Select-LSColorsTheme -Scope Global -Force`.

```powershell
Invoke-DFPicker `
    -List    { vivid themes } `
    -Header  'Select LS_COLORS theme  [Enter to apply for this session]' `
    -Preview 'vivid preview {}' `
    -Ansi `
    -Action  {
        param($n)
        <resolve/generate/cache for $n, same path as Section 2, then:>
        [System.Environment]::SetEnvironmentVariable('LS_COLORS', $value, 'Process')
        Write-Host "Theme applied: $n  (to persist: set `$Global:DFConfig['VividTheme'] = '$n')" -ForegroundColor Green
    }
```

The applied `LS_COLORS` takes effect immediately for the current session —
unlike PSReadLine colors, no extra propagation step is needed, since child
processes (`eza`, coreutils `ls`) inherit the updated process environment
variable on their next invocation.

## Section 4 — Testing (`tests/vivid.Tests.ps1`)

Mirrors `tests/mdcat.Tests.ps1`'s precedent for a sidecar that shells out to
an external binary at registration time: the sidecar `Describe` block is
guarded with `-Skip:(-not (Get-Command vivid.exe -ErrorAction Ignore))` and
runs against the **real** `vivid` binary — the existing suite has no
external-process mocking seam (only `Invoke-DFFzf` is mockable), and
`mdcat`/`delta`/`glow` establish that real-binary-when-present, skip-when-absent
is the accepted pattern here, not a gap to fill. `vivid` is installed in this
dev environment, so the block runs.

- Registering sets `$Env:LS_COLORS` to vivid's `catppuccin-mocha` output by
  default (real `vivid generate catppuccin-mocha` output, asserted e.g. by
  checking it's non-empty and contains a `di=` segment).
- A cache hit does not re-invoke `vivid generate`: pre-seed the cache file
  with a synthetic value that could not be real `vivid` output (e.g. a
  recognizable sentinel string) and a matching key file, register, and assert
  `$Env:LS_COLORS` equals the sentinel verbatim — proving the cached value
  was used rather than freshly generated.
- A theme change (different `VividTheme`/`Theme` than what's cached)
  invalidates the cache and regenerates — assert the sentinel from the prior
  case is *not* what ends up applied.
- An unrecognized theme name warns and leaves `$Env:LS_COLORS` unset/unchanged
  rather than throwing.
- `Select-LSColorsTheme` / `fls` register as global function/alias.
- `$DFConfig.Theme = 'catppuccin-mocha'` (shared key, no per-tool override)
  also resolves correctly (chain fallback).
- Full suite green under Pester 5.8.0 and 6.0.1.

## Section 5 — Documentation

- **README.md**: add a `vivid` row to the tool support table; document
  `VividTheme` alongside the existing `$DFConfig` theme-key list (§ User
  Configuration); add an `fls` entry to a tool-functions table, matching the
  `fprl` row's format.
- **`ToolAcquisitionSpec.md` §6.1**: add `VividTheme` to the per-tool-key
  list; drive-by fix — add the already-shipped `DeltaTheme`, which the list
  currently omits.
- **CHANGELOG.md** `[Unreleased]` → Added: `vivid` LS_COLORS theming
  (`Tools/vivid.json`/`.ps1`), default `catppuccin-mocha`, cached generation,
  `fls` live picker.

## Acceptance criteria

- `Tools/vivid.json` + `Tools/vivid.ps1` exist; no core file changes.
- Registering `vivid` (when installed) sets `$Env:LS_COLORS` to the resolved
  theme's generated value; unavailable `vivid.exe` results in a silent no-op
  registration (existing core behavior, not new code).
- Default theme is canonical `catppuccin-mocha`; `$DFConfig.Theme` and
  `$DFConfig.VividTheme` both work per the standard resolution chain.
- Regeneration only happens when the resolved theme name changes from what's
  cached; a `-Force`-equivalent bypass exists.
- An unrecognized theme name warns and does not throw or leave a corrupted
  cache.
- `fls` / `Select-LSColorsTheme` exist, list vivid's themes, preview each via
  `vivid preview {}`, and applying one updates `$Env:LS_COLORS` for the
  current session immediately.
- `eza`'s directory-listing colors visibly change when `LS_COLORS` is set
  (already confirmed manually; a test only needs to assert the env var is
  set correctly, not eza's rendering).
- Tests pass under both supported Pester versions; no regression in the full
  suite.
- README, `ToolAcquisitionSpec.md` §6.1, and CHANGELOG updated.
