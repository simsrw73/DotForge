# TODO

## Priority 1 — Release Readiness

- [ ] **Promote to stable 1.0.0** — fix all open Problems below, bump `ModuleVersion` to `1.0.0`, remove `Prerelease = 'preview'` from psd1, move CHANGELOG `[Unreleased]` → `[1.0.0]`, republish via `Publish-DotForge.ps1`
- [ ] **User tool extension guide** — document how users add their own tool JSON records, argument completers, and pickers without forking the module; move into README or a separate `docs/extending.md`

## Priority 2 — Open Problems

- [ ] **Legacy profile fold-in is incomplete — the remainder is silently inactive** — see [the design spec](docs/superpowers/specs/2026-07-15-legacy-profile-fold-in-design.md) for the full audit. `cli_tools_config.ps1` is no longer dot-sourced by any profile, so everything not yet folded in is a **live regression**, not a backlog. Remaining: 12 fzf pickers, 5 uncovered completers, small functions, and 6 tools with no record. Sub-items:
  - [x] **Restore `fzf` and `delta` env vars** — done 2026-07-15 (`Tools/fzf.json`, `Tools/delta.json`). Caveat: `DELTA_FEATURES=catppuccin-mocha` is a **no-op** — no `[delta "catppuccin-mocha"]` feature is defined in any git config scope and delta silently ignores unknown features. Define it to make it live.
  - [x] **Decide Carapace vs. a DotForge completion engine** — done 2026-07-15: **carapace adopted**, no engine built. Now a DotForge tool (`Tools/carapace.json` + `.ps1`), picked up by the existing `Register-DFTool -All`; no profile change needed. Covers 11/16 (`eza`, `bat`, `fd`, `rg`, `npm`, `gh`, `glow`, `procs`, `rustup`, `chezmoi`, `winget`). Composes with PSFzf because it registers argument completers and never binds Tab.
  - [ ] **5 tools still lack completions** — `broot`, `sfsu`, `nvm`, `uv`, `bw`. Prefer a carapace custom spec (`$XDG_CONFIG_HOME/carapace/specs/*.yaml`) over reviving a completion engine.
  - [x] **`"picker": "custom"` is unverified** — done 2026-07-15. **11** tools declared it with no sidecar picker (`gh`, `jq`, `glow`, `docker`, `rustup`, `npm`, `uv`, `chezmoi`, `bitwarden`, `scoop`, and `gsudo`), and `psreadline` under-declared `null` while its sidecar builds `fprl`. Records are now honest and `tests/Tools.PickerDeclaration.Tests.ps1` fails the suite in both directions. The 12 unported pickers remain tracked in the spec (§3).
  - [ ] **`Register-DFTool` help claims it "registers argument completers"** (`Public/Register-DFTool.ps1:11`) — only indirectly true now, via the carapace sidecar; the wording still implies a schema-driven feature that does not exist. Fix the wording.
  - [ ] **`xdg.method` can't express `env` + config seeding** — `ripgrep` needs `RIPGREP_CONFIG_PATH` *and* a seeded default `ripgreprc`; `wget` needs `WGETRC` *and* an empty file. `method` is a single value and the `config` branch sets no env vars. Consider allowing an array, or a `seed` block independent of `method`.
- [x] **Clipboard tests are flaky — they use the real OS clipboard** — done 2026-07-24: `tests/DFHelpers.Clipboard.Tests.ps1` now mocks `Set-Clipboard`/`Get-Clipboard` (the `Invoke-DFFzf` pattern) instead of round-tripping the real clipboard, asserting the wrapper's join/pipeline logic deterministically. Verified 0 failures across 10 consecutive runs.
- [ ] **Refresh the coreutils tripwire fixture on coreutils upgrades** — `tests/data/coreutils-commands.json` was captured from Coreutils for Windows 2026.6.16 on 2026-07-15. A newer release may add utilities the list lacks, which weakens the dev-time tripwire (never the runtime check, which always reads the live set). Refresh with `coreutils-manager status`. See [docs/external-dependencies.md](docs/external-dependencies.md).
- [ ] **`AliasesToExport` is decorative** — DotForge's helper aliases are created with `Set-Alias -Scope Global` at dot-source time, so the module never owns them: `(Get-Module DotForge).ExportedAliases` is empty and `Remove-Module DotForge` leaves the aliases behind. `Get-DFCommandConflict` reads `AliasesToExport` out of the manifest for exactly this reason. Related to the `-Force` alias item below; fixing that would likely fix this.
- [ ] **Help header colorization misses `ABOUT_ALIAS_PROVIDER`-style headers** — `Invoke-DFHelp` regex matches ALL-CAPS headers but fails when they contain underscores (e.g. `ABOUT_ALIAS_PROVIDER`). Extend the regex to allow underscores.
- [ ] **`'Out-String" 2>nul' is not recognized`** — error appears in some contexts; investigate source (likely a companion script using CMD-style stderr redirect instead of PowerShell `2>$null`)
- [ ] **Red `?` on a line by itself in some Help output** — appears at the same indentation as surrounding content; investigate whether it's a broken ANSI sequence or a `Get-Help` rendering artifact
- [ ] **`Error: unknown command "completion" for "oh-my-posh"`** — may be version-specific; verify against current oh-my-posh release and fix or suppress if the subcommand was removed

## Priority 2 — Review Follow-ups

- [x] **Port `Initialize-DFCompletionStack.Tests.ps1` to Pester 6** — done 2026-07-24. Its 11 `Assert-MockCalled` calls (removed in Pester 6.0.1) are now `Should -Invoke`; the four "never called" checks use `-Times 0 -Exactly` so they stay meaningful under Pester 6 (plain `-Times 0` is "at least 0" there = vacuous). The full suite is now **899/0 under both Pester 5.8.0 and 6.0.1** — the `-RequiredVersion 5.8.0` pin is no longer needed.
- [ ] **Path-normalization follow-ups** — from the `ConvertTo-DFPath` branch review (2026-07-24): (a) add a shared test bootstrap that dot-sources the `Private/` dependency graph so a new low-level dependency doesn't require adding its dot-source to every consumer-sourcing test file; (b) strengthen the `Register-DFTool` ToolsPath test to exercise a sidecar load via a `..`-bearing `-ToolsPath` (currently re-tests `ConvertTo-DFPath` directly); (c) resolve `$ToolsPath` once *before* `Import-DFToolDb` in `Register-DFTool` to remove the raw-vs-resolved asymmetry; (d) tests are Windows-only (`C:\` literals) — the macOS/Linux goal is unverified by CI though the runtime code is separator-agnostic.
- [ ] **Stop force-creating global aliases at import time** — importing DotForge currently sets global aliases such as `copy`, `env`, `open`, and `touch` with `-Force`, which can overwrite user/session aliases. Prefer module-scope aliases exported by the manifest, or make short aliases opt-in.
- [ ] **Fix `Register-DFTool` `list_accepts_path` command splitting** — generated picker functions split the list command on whitespace, breaking quoted arguments and single-word commands. Add tests that invoke generated picker functions, not just tests that verify they exist.
- [ ] **Key `Import-DFToolDb` cache by `ToolsPath`** — the current single `$script:DFToolDb` cache can return the wrong registry when callers use different `-ToolsPath` values without `-Force`.
- [ ] **Key `Resolve-DFPackageManager` cache by priority order** — a prior default lookup can make later custom `-Priority` calls return stale ordering.
- [ ] **Harden `New-DFShim` PATH normalization** — malformed PATH entries can throw during the shims-dir-on-PATH check. Match `Add-DFToPath` behavior by safely handling invalid entries.
- [ ] **Expand tool schema validation** — validate shapes for `packages`, `aliases`, `picker`, `xdg.vars`, `xdg.dirs`, and `dependsOn` so malformed records fail early instead of during profile registration.
- [ ] **Improve `Install-DFTool` failure diagnostics** — installer output is suppressed and failures only report `failed`. Capture and show output on failure, or expose it under `-Verbose`.
- [ ] **Make `New-DFDirectory` failures visible** — it currently uses `-ErrorAction SilentlyContinue`, which can hide permissions/path issues and cause later failures elsewhere.
- [ ] **Reduce `Get-DFHelpTopicList` cached-path cost** — cache validation still enumerates all installed modules to compute the fingerprint. Consider a TTL or cheaper fingerprint strategy.
- [ ] **Add review coverage gaps** — add tests for cache isolation across two `ToolsPath` values, custom package-manager priority after a default lookup, generated `list_accepts_path` functions with single-word and quoted commands, malformed PATH during `New-DFShim`, duplicate tool names, and schema rejection for malformed `aliases`, `picker`, `packages`, and `dependsOn`.
- [ ] **trifle `-Readme`: gate the npm tier on repo match** — the npm registry readme currently wins whenever the merged group contains an npm source, so name collisions surface the wrong readme (e.g. `trifle ripgrep -Readme` shows the unrelated npm `ripgrep` wrapper's readme instead of BurntSushi's). Recommended fix from the branch review: use the npm readme only when no GitHub repo resolves, or when the npm detail's `RepositoryUrl` matches the resolved repo; collisions then fall through to the GitHub readme tier.
- [ ] **trifle qualified winget ids: better sibling search** — `trifle winget:BurntSushi.ripgrep.MSVC` searches sibling catalogs with the full dotted id (only scoop ids split on `/`), so the card misses cross-catalog versions and the installed overlay. Recommended fix: use the matched winget index row's `Name` as the cross-catalog sibling query (trailing-segment-after-dot is wrong — it would yield `MSVC`). Current behavior degrades to a correct single-source card.

## Priority 3 — Features

- [ ] **Color theme system across all tools** — PSReadLine has per-tool theming; explore a unified palette that also applies to `bat`, `delta`, `glow`, and terminal colors so the whole environment shares one theme
- [ ] **More tool configs** — add XDG, completions, and pickers for: `ssh`, `choco`, `winget` (search picker), `dotnet`; document or automate `scoop config use_sqlite_cache true` for PS7+
- [ ] **`Invoke-DFMaintenance` and scheduled maintenance guide** — provide a manual, opt-in maintenance command for purging the completion cache, refreshing the help-topic index, and running `scoop cleanup *`; use the last-run timestamp pattern from the existing help-topics cache. DotForge must not create scheduled tasks or perform package updates automatically. Document user-owned Task Scheduler recipes for separately scheduling cache refreshes, cleanups, and explicit package-update workflows, including how to inspect, disable, and remove each task.
- [ ] **trifle: alternatives / related commands** — deferred from trifle v1. Surface "alternatives" (e.g. ripgrep ↔ other tools tagged `search`) and related commands on the `Find-DFPackage` card. Candidate sources: shared `tags` in `Tools/*.json`, a curated `alternatives` field, or catalog keyword overlap. Revisit together with the name-collision merge wart (npm `bat` vs scoop `bat` currently merge into one row).
- [ ] **Expand the trifle category-db seed corpus** — currently 73 hand-picked
  tools (33 curated from `Tools/*.json` + 40 well-known extras). The spec's
  long-run target is the full CLI-tool-union corpus (~300-500 tools). Growing
  toward that is pure content authoring — add more `build/categories/*.jsonc`
  fragments and rerun `build/Build-DFCategoryDb.ps1` — no code changes needed.
- [ ] **trifle category-db phase 2: automated gathering pipeline** — deferred
  from the discovery v1 spec (`docs/superpowers/specs/2026-07-05-trifle-discovery-v1-design.md`).
  Auto-populate/maintain the category database from live external sources:
  debtags, crates.io/PyPI trove classifiers, Homebrew analytics, Repology
  identity resolution, GitHub topics, distro package-section mining. Also
  covers making `popularity` a live, periodically-refreshed metric instead of
  a build-time editorial tier.
- [ ] **Grow the tool-identity guide past the 29 curated seed tools** — v1's
  guide only links tools where `Tools/*.json` already provides multiple
  known catalog ids to compare (that's what makes automated repo/homepage
  verification possible in the first place). Of the 33 `Tools/*.json`
  candidates, 4 (`npm`, `psreadline`, `scoop`, `winget` — catalog/companion
  tooling, not standalone CLI tools) have an empty `packages` block and get
  filtered out by `build/Build-DFToolIdentities.ps1`, leaving 29. Growing
  coverage requires first discovering candidate `(source, packageId)` pairs
  for not-yet-curated tools — e.g. a future crawl, or mining co-occurrences
  from live search results over time — deferred alongside the category
  database's own phase-2 pipeline (`docs/superpowers/specs/2026-07-06-trifle-tool-identity-guide-design.md`).

## Priority 4 — Improvements

- [ ] **Dynamic fzf preview sizing** — replace the hardcoded `right:60%` default with sizing derived from content length or terminal width
- [ ] **PSGallery icon** — add `IconUri` to `PrivateData.PSData` in psd1 for a better gallery page presentation
- [ ] **Themes via LS_COLORS** — use `vivid` to setup LS_COLORS
- [ ] **$HOME vs $LOCALAPPDATA** — We could allow users to choose between `$HOME` and `$LOCALAPPDATA` for the root of XDG directories.
