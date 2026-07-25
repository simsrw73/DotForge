# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Project Is

DotForge is a PowerShell 7+ module that configures CLI tools (XDG paths, fzf pickers, aliases) from a JSON tool database.

PowerShell 7+ module that configures CLI tools (XDG paths, fzf pickers,
aliases) from a JSON tool database. Extracted and generalized from a real-world
PowerShell profile.

## Core Invariant: Plugin Architecture

**Adding or updating a tool never modifies core logic.** Each tool is a plugin
(`Tools/<tool>.json` + optional `Tools/<tool>.ps1`); a new core feature is an
optional declarative extension point the core reads when present and no-ops when
absent. Cross-tool queries resolve from the loaded tool DB or a build-time
generated index — never runtime reflection, and never a `switch ($tool.name)` in
core code. Startup speed is a first-class constraint; per-tool declarations are
free (JSON already loaded) and aggregation is paid once at build time. Full
statement, rules, and the realistic boundary (the psd1 manifest): **`docs/plugin-architecture.md`** —
read it before designing any new core feature or a central tool-keyed data file.

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
- **Paths are canonical.** Every path DotForge stores, compares, emits, or accepts as input goes
  through `ConvertTo-DFPath` (`Private/ConvertTo-DFPath.ps1`): absolute, native separator, no `.`/`..`,
  no trailing separator. Write `$HOME` in module code — never `~`; a user-supplied `~` path is
  expanded by `ConvertTo-DFPath`. A relative path is returned unchanged with a warning, never bound to
  CWD. New path boundaries must route through it.
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

Pester 5 or 6 (the suite passes under both Pester 5.8 and 6.0.1). Run all tests:

```powershell
Invoke-Pester tests/ -Output Detailed  # run from pwsh -NoProfile to avoid profile interference
```

Run a single file:

```powershell
Invoke-Pester tests/Add-DFToPath.Tests.ps1 -Output Detailed
```

## Before Commiting

- Update README.md with any changes.
- Update .\examples with any changes.
- **Every public function must have complete comment-based help**: `.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER` for each param, at least one `.EXAMPLE`, and `.OUTPUTS`. When adding or modifying a public function, verify its help block is complete before committing. Run `Get-Help <FunctionName> -Full` to confirm `Get-Help` renders all sections correctly.

## Releasing

Publishing to the PowerShell Gallery follows this exact sequence. **The release must be tagged before it is published** — a `PreToolUse` hook in `.claude/settings.json` blocks `Publish-PSResource`/`Publish-Module` (real publishes, not `-WhatIf`) whenever `git HEAD` is not sitting on an exact tag.

1. **Bump the version** in `DotForge.psd1` (`ModuleVersion`; keep/adjust `PrivateData.PSData.Prerelease`) and refresh `ReleaseNotes`. We follow SemVer; preview releases carry `Prerelease = 'preview'` (published as e.g. `0.3.0-preview`).
2. **Finalize `CHANGELOG.md`**: rename the `[Unreleased]` heading to `[<version>] - <YYYY-MM-DD>` and open a fresh empty `[Unreleased]` above it.
3. **Commit** the version bump + changelog (scope the commit to release files; leave unrelated working-tree changes out).
4. **Validate**: `Test-ModuleManifest ./DotForge.psd1` and a publish dry-run: `Publish-PSResource -Path . -Repository PSGallery -ApiKey DRYRUN -WhatIf`.
5. **Tag** the release commit: `git tag -a v<version> -m "DotForge <version>"` (tag format is `v` + the full prerelease string, e.g. `v0.3.0-preview`).
6. **Push** `main` and the tag: `git push origin main && git push origin v<version>`.
7. **GitHub Release**: `gh release create v<version> --title v<version> --prerelease --notes "<CHANGELOG section>"` (drop `--prerelease` for stable releases).
8. **Publish to PSGallery**: read the API key from the gitignored `.env` (`PSGALLERY_API_KEY=...`) — never hardcode or commit it — and run `Publish-PSResource -Path . -Repository PSGallery -ApiKey $key`.
9. **Verify** via the Gallery API (the local `Find-PSResource` view normalizes away the prerelease suffix, so confirm against the source of truth): `Invoke-RestMethod "https://www.powershellgallery.com/api/v2/FindPackagesById()?id='DotForge'"` and check the new `Version` / `IsPrerelease`.

## Tool JSON Schema

Each `Tools/*.json` must have at minimum:

- `name` (string, required)
- `executable` (string, required)
- `xdg.method`: one of `default | env | config | wrapper | manual`
- `xdg.vars`: env vars to set when applying XDG config — values are `${XDG_*}` path templates only (expanded via `Expand-DFXdgPath`). Non-path values (flag strings, etc.) belong in `env` below, never in `xdg.vars`.
- `env` (optional): a top-level map of environment variable → value for **non-XDG** session
  settings (fzf options, `GIT_PAGER`, `LESS`, theme names, …). Applied unconditionally by
  `Register-DFTool` via `[Environment]::SetEnvironmentVariable(..., 'Process')` through
  `Expand-DFXdgPath` (flag strings pass through; `${XDG_*}` still expands). Keep `xdg.vars`
  for `${XDG_*}` path templates only.

## External Dependencies

DotForge relies on undocumented internals of several tools it configures (coreutils' `$__COREUTILS__`
variable and section-marker GUID, PSReadLine's `Colors` suppression, zoxide's prompt hooking, …).
**All of them are catalogued in `docs/external-dependencies.md` — read it before changing
`Private/Get-DFCoreutilsShadowSet.ps1` or any `Tools/*.ps1` sidecar, and add an entry there when you
take a new dependency on another tool's internals.** Each entry records what breaks and how it
degrades; the rule is that undocumented dependencies must degrade silently, never fail.

## Tool Conformance (author-time)

Whether a tool actually honors its configuration is verified, not assumed. The harness
`build/Test-DFToolConformance.ps1` reads probe descriptors (`build/conformance/*.jsonc`),
spawns the real tool through an injectable seam (defaulting to a real isolated
`ProcessStartInfo`; tests inject a canned scriptblock — same pattern as
`build/Build-DFToolIdentities.ps1`'s `-ResolveLinkage`), and writes per-claim verdicts to
the versioned ledger `data/tool-conformance.json` plus `reports/tool-conformance-issues.md`.
Sidecar adapters cite the failing claim (`# adapter for <claim-id>`); the harness flags
orphaned and upstream-fixed adapters. **Author-time only** — the module never loads or runs
any of it, and there is no runtime cost. The shared logic lives in `build/DFConformance.ps1`
(dot-sourced by the harness and by `tests/DFConformance.Tests.ps1`). Optional `[pscustomobject]`
fields parsed from fragments must be read StrictMode-safe (`$obj.PSObject.Properties['name']?.Value`).

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
  initialize _before_ zoxide so zoxide correctly wraps OMP's prompt. `Register-DFTool -All`
  handles this automatically via alphabetical processing (`oh-my-posh` < `zoxide`). Selective
  registration must explicitly register oh-my-posh before zoxide. After a theme switch via
  `fpot`/`Select-PoshTheme`, OMP re-inits and replaces `function:prompt`; zoxide's
  `$global:__zoxide_hooked = 1` guard prevents re-hooking, so directory tracking stops
  until the next shell session. This is a known limitation with no clean workaround.
- **`dependsOn` ordering**: Any tool JSON may declare `"dependsOn": ["othertool"]`. `Register-DFTool` calls `Invoke-DFTopoSort` (private, `Private/Invoke-DFTopoSort.ps1`) to sort the registration list using Kahn's algorithm before iterating. Dependencies outside the current registration set are skipped silently. Cycles emit `Write-Warning` and fall back to original order.
- **`$DFCurrentTool` sidecar contract**: `Register-DFTool` sets `$DFCurrentTool = $tool` immediately before dot-sourcing a companion `.ps1` and clears it after. Sidecars may read `$DFCurrentTool.settings` and other fields. Existing sidecars that do not reference `$DFCurrentTool` are unaffected. Sidecars needing their own subdirectory use `$PSScriptRoot`, which resolves to `Tools/` at dot-source time.
- **PSReadLine + PSFzf ordering**: PSFzf declares `"dependsOn": ["psreadline"]`. `psreadline.ps1` runs first and applies `Set-PSReadLineOption` settings + theme via `$DFCurrentTool.settings`. PSFzf then overlays its key bindings via `Set-PsFzfOption`. Each tool owns only what it touches. The global `$DFPSReadLineColors` hashtable is set by `Invoke-DFApplyPSReadLineTheme` as a test-observable side channel (PSReadLine suppresses `Colors` in non-VT terminals).
