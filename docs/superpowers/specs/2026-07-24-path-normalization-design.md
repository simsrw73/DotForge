# Path Normalization — Design

**Status:** Draft
**Date:** 2026-07-24
**Related:** `Private/Expand-DFXdgPath.ps1`, `Public/Add-DFToPath.ps1`, `Public/New-DFShim.ps1`,
`Public/New-DFDirectory.ps1`, `Public/Initialize-DFEnvironment.ps1`

## Context

DotForge constructs, stores, compares, and emits filesystem paths in ~148 places across 30 files.
Today those paths are inconsistent:

- **Mixed separators.** `Initialize-DFEnvironment` sets the XDG roots with `Join-Path` (clean native
  `\` on Windows), but `Expand-DFXdgPath` then substitutes a root into a `/`-joined JSON template
  (`${XDG_CONFIG_HOME}/bat/bat.conf`), producing `C:\Users\…\.config/bat/bat.conf`. Every env-method
  tool that stores a config path (bat, chezmoi, curl, docker, fnm, lazygit, less, micro, npm,
  oh-my-posh, ripgrep, uv, wget, winfetch, zoxide, mdv) inherits the mix. Windows tolerates it, so
  nothing breaks — but it is brittle (the `mdv` sidecar needed a local normalization patch to make a
  `Should -Be (Join-Path …)` test pass) and cosmetically wrong.
- **Embedded relative markers.** Defaults like `Join-Path $PSScriptRoot '../Tools'` are absolute but
  carry a literal `..`.
- **No canonical form.** Nothing guarantees absolute, no-`.`/`..`, no-trailing-separator paths, so
  path comparisons (PATH dedup, coreutils conflict detection) can mismatch on spelling.

**Goal:** a single canonical-path convention, enforced by one helper, applied at the boundaries that
matter. Every path DotForge stores, compares, emits, or accepts is absolute, native-separator,
free of `.`/`..`, and without a trailing separator; user-supplied `~` is expanded to `$HOME`.

This is a cross-cutting review-and-change, scoped deliberately (see **Application scope**) to the
boundaries where path shape is observable — not a blanket wrap of every `Join-Path`.

## Decisions locked with the user

1. **Relative input** → `Write-Warning` and return unchanged (do not silently bind to CWD).
2. **Application is boundary-focused** — normalize where paths are stored/compared/emitted/accepted;
   leave transient `Join-Path` results that are immediately consumed by a cmdlet.
3. **Flag-string safety** — `Expand-DFXdgPath` normalizes only when it substituted an XDG token, so
   non-path flag strings pass through verbatim. Enforced as a documented contract, not a schema flag.
4. **`~` is a synonym for `$HOME`** — internal code always writes `$HOME`; any user-supplied path is
   `~`-expanded (leading `~` only) by the helper.
5. **The helper is private.**

## Design

### 1. The normalizer: `ConvertTo-DFPath` (`Private/ConvertTo-DFPath.ps1`)

```
ConvertTo-DFPath -Path <string> → [string]
```

Steps, in order:

1. **Null/empty** → return as-is (callers stay terse, matching `New-DFDirectory`'s null tolerance).
2. **Leading-`~` expansion.** If `$Path` is exactly `~`, or starts with `~/` or `~\`, replace that
   leading `~` with `$HOME`. Only a leading `~` that is the whole path or immediately followed by a
   separator is expanded — never a `~` elsewhere in the path. This deliberately avoids Windows 8.3
   short names (`C:\PROGRA~1\…`) and literal filenames (`foo~bar`).
3. **Relative check.** If, after `~`-expansion, `-not [System.IO.Path]::IsPathRooted($Path)`, emit
   `Write-Warning "ConvertTo-DFPath: '<path>' is not an absolute path — returned unchanged."` and
   return the (unexpanded) input. `~foo` (leading `~`, no separator) lands here.
4. **Canonicalize.** `$full = [System.IO.Path]::GetFullPath($Path)` — makes the path absolute,
   collapses `.`/`..`, and converts to the **native** separator.
5. **Root-aware trailing-separator strip.** `GetFullPath` does *not* remove a trailing separator
   (verified: `C:\a\b\` stays `C:\a\b\`), so strip it explicitly — but never below the root. Compute
   `$root = [System.IO.Path]::GetPathRoot($full)` and, only when `$full.Length -gt $root.Length`,
   `TrimEnd` the directory-separator chars. This yields `C:\a\b\` → `C:\a\b` while preserving `C:\`
   → `C:\` (and `\\server\share` for UNC). Return `$full`.

`GetFullPath` works on paths that do **not** exist yet (verified: `C:\no\such\x\..\y` →
`C:\no\such\y`), so the helper never needs the target to be present — unlike `Resolve-Path`. One
caveat, accepted as beneficial: when a path segment *does* exist as an 8.3 short name, `GetFullPath`
expands it to the long form (`C:\PROGRA~1\x` → `C:\Program Files\x`), which touches the filesystem for
that segment. This is desirable — it gives one canonical spelling, which is exactly what path
comparisons want — and it does not affect non-existent paths.

The function is idempotent: `ConvertTo-DFPath (ConvertTo-DFPath $p)` equals `ConvertTo-DFPath $p`
(verified), which matters because some paths pass through more than one boundary.

`GetFullPath` (+ trailing strip) is the same pattern `Add-DFToPath` and `New-DFShim` already use
inline — `New-DFShim` already pairs `GetFullPath` with a `TrimEnd`. This helper names and centralizes
it, adding the root-aware guard those inline versions lack.

### 2. Application map (boundary-focused)

| Site | Change |
|---|---|
| `Private/Expand-DFXdgPath.ps1` | Normalize the result **only when at least one `${XDG_*}` token was substituted** (§3). This is the separator fix at its source. |
| `Public/Initialize-DFEnvironment.ps1` | Route the five XDG roots (`XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_STATE_HOME`, `XDG_CACHE_HOME`, `XDG_BIN_HOME`) through the helper **when DotForge sets them**, so substitutions start from a canonical root. (Respect a user-provided value by normalizing it too.) |
| `Public/New-DFDirectory.ps1` | Normalize input before `New-Item`. Every created directory is canonical. |
| `Public/Add-DFToPath.ps1` | Re-point its inline `GetFullPath` normalization at the helper so there is one implementation; keep the existing relative-reject + dedup behavior. |
| `Public/New-DFShim.ps1` | Re-point its `GetFullPath` + `TrimEnd` at the helper. |
| `Public/Register-DFTool.ps1` | Normalize the `ToolsPath` default (`Join-Path $PSScriptRoot '../Tools'`) and the analogous `../` default so the `..` collapses. |
| Path **comparisons** | `Public/Get-DFCommandConflict.ps1` and `Add-DFToPath`'s dedup — normalize both sides before comparing so spelling differences never cause a false (mis)match. |
| Sidecar config paths | `Tools/mdv.ps1` and `Tools/glow.ps1` build their config paths through the helper; **`mdv` drops its local separator-normalization patch** (now subsumed by the helper + the `Expand-DFXdgPath` fix). |

**Left alone:** transient `Join-Path` results handed straight to `Test-Path` / `Get-Content` /
`Set-Content` and never stored or compared. They are already native and wrapping them changes
nothing observable — only adds noise.

### 3. Flag-string safety rule

`Expand-DFXdgPath` is dual-use: `Register-DFTool`'s `env` method runs both path templates
(`${XDG_CONFIG_HOME}/bat/bat.conf`) and non-path flag strings (`LESS = --RAW-CONTROL-CHARS …`,
`FZF_DEFAULT_OPTS = --color=…`) through it. Separator-normalizing a flag string could corrupt it.

**Rule:** `Expand-DFXdgPath` normalizes its result **only when it actually substituted at least one
`${XDG_*}` token.** Verified against every env-method tool: every token-bearing value today is a pure
filesystem path, and no flag string contains an XDG token — so paths get normalized and flag strings
are returned byte-for-byte.

**Documented contract** (in the function's comment, `docs/external-dependencies.md`, and CLAUDE.md's
existing "vars values are XDG path templates OR plain strings" line): a `vars` value is *either* an
XDG path template *or* a literal flag string with no XDG token — never a flag string that embeds an
XDG path. Nothing today violates it. A per-var `type: path|string` schema flag was considered and
rejected as more machinery than the current data warrants (YAGNI); it can be added if a real mixed
case ever appears.

### 4. Edge cases (all verified empirically)

- **Drive roots** — `C:\` → `C:\`. The root-aware guard (step 5) never trims below `GetPathRoot`, so
  a root is never mangled to `C:`.
- **UNC** — `\\server\share\a\.\b\..\c` → `\\server\share\a\c`. `GetPathRoot` returns `\\server\share`,
  so the share root is preserved.
- **Trailing separator** — `C:\a\b\` and `C:\a\b\\` → `C:\a\b` (explicit strip in step 5;
  `GetFullPath` alone does not do this).
- **8.3 short names** — an *existing* `C:\PROGRA~1\x` → `C:\Program Files\x` (canonical long form;
  see §1 caveat). A non-existent short-name path is left as-is by `GetFullPath`.
- **Leading `~`** — `~` → `$HOME`; `~/glow` → `$HOME\glow`; mid-path `~` (`C:\PROGRA~1`) untouched by
  the `~` rule.
- **Non-existent paths** — canonicalized without error (`C:\no\such\x\..\y` → `C:\no\such\y`).
- **Idempotent** — canonical input returns unchanged.
- **Null/empty** — passthrough, no warning.
- **Cross-platform** — native separator is `/` on the planned macOS/Linux, so normalization is a
  no-op there; no platform branching in the code.

### 5. Convention (CLAUDE.md)

Add to the Conventions section:

> **Paths are canonical.** All paths DotForge stores, compares, emits, or accepts as input go through
> `ConvertTo-DFPath`: absolute, native separator, no `.`/`..`, no trailing separator. Write `$HOME`
> in module code — never `~`; user-supplied `~` paths are expanded by `ConvertTo-DFPath`. New path
> boundaries (a stored value, a comparison, an emitted path, a user/param input) must route through it.

## Testing

- **`tests/ConvertTo-DFPath.Tests.ps1`** (new) — separator normalization, `.`/`..` collapse,
  trailing-separator removal, root preservation, UNC, leading-`~` expansion (`~`, `~/x`), mid-path-`~`
  untouched, `~foo`→relative-warn, relative→warn+unchanged, null/empty passthrough, idempotency.
- **`tests/Expand-DFXdgPath.Tests.ps1`** — the 6 existing assertions currently expect the mixed output
  (`C:\config/bat/bat.conf`); update them to canonical native paths. Add a case proving a flag string
  with no token is returned verbatim (the §3 safety rule).
- **Touched primitives** — extend `Add-DFToPath`, `New-DFShim`, `New-DFDirectory`, `Register-DFTool`,
  and the `mdv`/`glow` sidecar suites where a normalization is newly observable. The `mdv` test that
  asserts the (previously locally-patched) config path stays green once the patch moves into the
  helper.
- **Full suite** green, plus a spot-check that a real `Register-DFTool -All` produces all-native,
  no-trailing-separator env vars (`$Env:BAT_CONFIG_PATH`, `$Env:MDV_CONFIG_PATH`, …).

Some test churn is expected and intended — the changed assertions are exactly the ones that baked in
the mixed-separator bug.

## Out of scope

- Blanket wrapping of every internal `Join-Path` (the "exhaustive" option) — behavior-neutral churn.
- A `type: path|string` schema flag for `vars` — deferred behind the documented contract until a real
  mixed case exists.
- The systemic follow-up is fully addressed here; no separate ticket remains for the separator issue.

## Verification

```powershell
pwsh -NoProfile -Command 'Invoke-Pester tests/ConvertTo-DFPath.Tests.ps1 -Output Detailed'
pwsh -NoProfile -Command 'Invoke-Pester tests/ -Output Detailed'   # full suite, no regressions
```

Live:

```powershell
Import-Module ./DotForge.psd1 -Force
Register-DFTool -All
$Env:BAT_CONFIG_PATH      # C:\Users\…\.config\bat\bat.conf  (all native, no trailing sep)
$Env:MDV_CONFIG_PATH      # C:\Users\…\.config\mdv
ConvertTo-DFPath '~/glow'                    # C:\Users\…\glow   (in-module; not exported)
ConvertTo-DFPath 'C:\a\.\b\..\c'             # C:\a\c
```
