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
- [x] **`AliasesToExport` is decorative** — done 2026-07-31: all 27 general-helper aliases now
  created via a bare `Set-Alias` (module scope, no `-Force`), so the manifest's `AliasesToExport`
  is a genuine export — `(Get-Module DotForge).ExportedAliases` and `Remove-Module` both work
  correctly now. Tool/picker aliases remain intentionally outside the manifest (see
  `ToolAcquisitionSpec.md` §9.1) — that split is by design, not the gap this item described.
- [ ] **Help header colorization misses `ABOUT_ALIAS_PROVIDER`-style headers** — `Invoke-DFHelp` regex matches ALL-CAPS headers but fails when they contain underscores (e.g. `ABOUT_ALIAS_PROVIDER`). Extend the regex to allow underscores.
- [ ] **`'Out-String" 2>nul' is not recognized`** — error appears in some contexts; investigate source (likely a companion script using CMD-style stderr redirect instead of PowerShell `2>$null`)
- [ ] **Red `?` on a line by itself in some Help output** — appears at the same indentation as surrounding content; investigate whether it's a broken ANSI sequence or a `Get-Help` rendering artifact
- [ ] **`Error: unknown command "completion" for "oh-my-posh"`** — may be version-specific; verify against current oh-my-posh release and fix or suppress if the subcommand was removed

## Priority 2 — Review Follow-ups

- [x] **`Get-DFCategoryDb.Tests.ps1` fixture-isolation bug (found 2026-09-03)** — fixed
  2026-09-06. Root cause was not the module-level singleton cache (the `-Force`/cache-reset
  ordering hypothesis was wrong) — `Get-DFCategoryDb`'s refreshed-vs-shipped comparison against
  `$Env:XDG_DATA_HOME` runs unconditionally even when `-Path` overrides the "shipped" side (by
  design, per its own doc comment, so tests can exercise the full resolution algorithm). This
  dev machine has a real `$Env:XDG_DATA_HOME/dotforge/tool-categories.json` from actual DotForge
  usage, dated newer than the tests' fixed fixture date — so it silently outranked the fixture in
  every test that didn't isolate `$Env:XDG_DATA_HOME` itself. Confirmed by reproducing standalone
  (`Invoke-Pester tests/Get-DFCategoryDb.Tests.ps1` alone still failed 9/9 — ruling out cross-file
  pollution) and by reading the real ambient file directly (`updated` newer than the fixture's
  `2026-07-01`). Fixed by isolating `$Env:XDG_DATA_HOME` in all three `Describe` blocks in
  `tests/Get-DFCategoryDb.Tests.ps1` and in `tests/Get-DFCategoryList.Tests.ps1`'s `BeforeEach`
  (which mocks `Get-DFCategoryDb` but still calls through to the real implementation) — matching
  the isolation pattern the file's own "refreshed copy" tests already used correctly. Full suite:
  **1115/0** (previously 1105+/10, tolerated as baseline noise all session). Two of the file's
  tests ("resolves via plain name as a last resort", "returns `$null` for an unmapped tool") had
  been silently passing against the wrong (real) data by coincidence — worth knowing if this
  class of bug recurs elsewhere, since a passing assertion doesn't always mean correct isolation.
- [x] **Port `Initialize-DFCompletionStack.Tests.ps1` to Pester 6** — done 2026-07-24. Its 11 `Assert-MockCalled` calls (removed in Pester 6.0.1) are now `Should -Invoke`; the four "never called" checks use `-Times 0 -Exactly` so they stay meaningful under Pester 6 (plain `-Times 0` is "at least 0" there = vacuous). The full suite is now **899/0 under both Pester 5.8.0 and 6.0.1** — the `-RequiredVersion 5.8.0` pin is no longer needed.
- [ ] **Path-normalization follow-ups** — from the `ConvertTo-DFPath` branch review (2026-07-24): (a) add a shared test bootstrap that dot-sources the `Private/` dependency graph so a new low-level dependency doesn't require adding its dot-source to every consumer-sourcing test file; (b) strengthen the `Register-DFTool` ToolsPath test to exercise a sidecar load via a `..`-bearing `-ToolsPath` (currently re-tests `ConvertTo-DFPath` directly); (c) resolve `$ToolsPath` once *before* `Import-DFToolDb` in `Register-DFTool` to remove the raw-vs-resolved asymmetry; (d) tests are Windows-only (`C:\` literals) — the macOS/Linux goal is unverified by CI though the runtime code is separator-agnostic.
- [x] **Stop force-creating global aliases at import time** — done 2026-07-31: all 27 general-helper
  aliases drop `-Scope Global -Force`. Correction to this item's original framing: real module
  ownership does NOT change import-time clobbering behavior (verified empirically — a genuinely
  exported alias still silently overwrites a same-named pre-existing global alias, with no
  warning, identical to the old `-Force` behavior). That's normal PowerShell module behavior for
  every module, not a DotForge-specific defect, so it is not addressed. The `copy` alias — the one
  case that actually needed `-Force` to override a builtin — is renamed to `yank` instead, removing
  the need for `-Force` entirely rather than working around it.
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

- [x] **zsh-parity gaps (found 2026-09-06, comparing against the user's real `~/.zshrc`/`.zshenv`/
  `.zimrc`)** — all closed. The clear-cut drift (eza `ll`/`la`, fzf match-mode/previews) and all
  four "genuinely absent, not drift" gaps (see Added/Changed in `CHANGELOG.md`):
  - [x] **`direnv`** — done 2026-09-06: new `Tools/direnv.json`/`.ps1`. Natively XDG-compliant
    (no `xdg.vars` needed); hook uses `LocationChangedAction`, not `function:prompt`, so no
    ordering dependency on oh-my-posh/zoxide. Initially excluded from the first batch pending a
    checklist update (a pure shell-hook tool didn't fit the original four-item XDG/defaults/
    theme/picker checklist); pulled in once the user extended the checklist to six items,
    explicitly adding shell integrations/hooks and carapace completions.
  - [x] **Rust toolchain env** (`RUSTUP_HOME`, `CARGO_HOME` under XDG paths) — done 2026-09-06:
    `Tools/rustup.json` (`xdg.method: "env"`), `Tools/rustup.ps1` (new, adds `$CARGO_HOME/bin`
    to PATH).
  - [x] **vcpkg env** (`VCPKG_ROOT`, `VCPKG_DOWNLOADS`) — done 2026-09-06: new
    `Tools/vcpkg.json`/`.ps1`, plus `build/categories/dotforge-curated.jsonc` and
    `build/identities/`-derived `data/tool-categories.json`/`data/tool-identities.json`
    regenerated for the new tool.
  - [x] **PSReadLine history isn't XDG-relocated.** done 2026-09-06: `HistorySavePath` now
    `$XDG_STATE_HOME/psreadline/history` (`Tools/psreadline.json` `xdg.dirs` +
    `Tools/psreadline.ps1`), `MaximumHistoryCount` set to `10000` (new `settings` key).
- [x] **`LS_COLORS` via `vivid`** — done 2026-09-03: `Tools/vivid.json`/`.ps1`, design
  `docs/superpowers/specs/2026-09-03-vivid-ls-colors-design.md`, plan
  `docs/superpowers/plans/2026-09-03-vivid-ls-colors.md`. `eza` (the `listing`-role default)
  confirmed to read plain `LS_COLORS` directly, so this closes eza's catppuccin gap.
- [ ] **Audit theming mechanisms for silent-override risk against the user's own pre-existing
  config (found 2026-09-04, during the delta catppuccin investigation)** — the governing
  principle: the user must be able to easily *see* what DotForge changed and have an easy way
  to *override* it; DotForge must never silently discard a preference the user already set,
  even as a side effect of "just setting an env var." This is **not** a blanket rule (some
  cases genuinely have no competing file-based config to clobber) — each tool needs its own
  explicit weighing, case by case:
  - **Already right:** `psreadline`'s `Set-PSReadLineOption -Colors` has no competing
    persistent-file mechanism to silently override — it *is* the only way psreadline theme
    state is set in a live session, so there's nothing to weigh here.
  - **Found to be subtly wrong (2026-09-04, during the tool-setup-lifecycle design), fixed
    2026-09-05:** `mdv`'s `config.yaml` was seeded only when *absent* — but "absent" couldn't
    be told apart from "DotForge seeded it once, and the user deleted it on purpose." Migrated
    to the tool-setup-lifecycle primitive (`Tools/mdv.setup.ps1`) rather than patching the
    presence check in place — see the coverage-audit list's `mdv` entry below.
  - **Needs weighing:** `bat`'s `BAT_THEME`, `mdcat`'s `MDCAT_THEME`, and `vivid`'s `LS_COLORS`
    all set an env var that — per each tool's own documented precedence — outranks that same
    tool's file-based config. If a user had already hand-set a theme in `bat.conf`, or already
    exported `LS_COLORS` themselves before DotForge runs, these currently override it with no
    visibility into why and no easy per-tool opt-out beyond unregistering the whole tool.
  - **Decided differently on purpose:** `delta`'s catppuccin wiring (this same investigation)
    will use an `[include]` line in `~/.gitconfig` specifically *because* `--config <path>`
    would have replaced delta's entire config resolution outright, not layered on top of it —
    the more invasive-looking option was actually the more transparent, non-clobbering one here.
- [x] **One-time tool setup/teardown lifecycle primitive** — design done 2026-09-04, primitive
  and its first consumer (delta) both done 2026-09-05:
  `docs/superpowers/specs/2026-09-04-tool-setup-lifecycle-design.md`
  (`Tools/<name>.setup.ps1` + `Complete-DFToolSetup` + `$XDG_STATE_HOME/dotforge/setup-state.json`,
  run at most once ever per tool, tracked so a user's later edit/removal is never silently
  reasserted). `Tools/delta.setup.ps1` is the first consumer. Follow-ups, explicitly deferred
  out of the design's scope:
  - [x] Migrate `Tools/mdv.ps1`'s config-seeding to it — done 2026-09-05: closes the
    presence-check bug noted above. `Tools/mdv.ps1` retired (its whole job moved to
    `Tools/mdv.setup.ps1`); directory creation was already handled declaratively.
  - [ ] A real teardown/uninstall command (e.g. `Uninstall-DFToolSetup`) that reads the `actions`
    record back — needs its own spec once there's more than delta's single `actions` shape to
    generalize a safe, scoped undo from.
- [ ] **Startup-perf audit (2026-09-05) follow-up: async/deferred startup** — the module-import
  half is now implemented (below); `inshellisense`'s session-check deferral remains, still
  design-only: `docs/superpowers/specs/2026-09-05-startup-perf-audit.md`. **Never** apply this to
  `oh-my-posh` or `fnm` — the audit confirmed deferring `oh-my-posh`'s init reproduces the
  documented oh-my-posh/zoxide prompt-hook bug (see "oh-my-posh + zoxide prompt hook ordering"
  above) on every session instead of only after a manual theme switch.
  - [x] Caching half — done 2026-09-05: `carapace`/`zoxide`/`mdcat`/`scoop-search`'s
    deterministic init/completion output no longer spawns a process every session. New
    `Get-DFCachedCommandOutput` (`Private/Get-DFCachedCommandOutput.ps1`), fingerprinted on the
    resolved executable's own file identity. Measured ~200ms mean reduction in
    `Register-DFTool -All` on this machine (1451.4ms → 1245.9ms, `build/Measure-DFStartup.ps1`).
  - [x] Module-import half — done 2026-09-05: `Terminal-Icons`/`PSFzf`/`posh-git` now warm their
    `Import-Module` cost in a background `Start-ThreadJob` (`Private/Start-DFModulePrewarm.ps1`)
    before `Register-DFTool`'s per-tool loop reaches each one's own unchanged, synchronous
    `Import-Module` call — measured ~77% faster on a representative module (282ms → 65ms,
    reproduced 3/3). `psreadline` is deliberately excluded via a new `Tools/<name>.json`
    `"prewarm": false` opt-out: its sidecar never re-imports PSReadLine (always pre-loaded by the
    PS7 host), so prewarming it has no benefit, and it is the module most exposed to the
    shared-process CLR statics `Start-ThreadJob` implies (PSReadLine's key-handler dispatch table
    is a process-global static singleton that PSFzf's import touches).
  - [ ] `inshellisense`'s `is -c` session-check deferral — still out of scope, not yet
    implemented; a differently-shaped mechanism (a native command's exit code, consumed later
    inside `Initialize-DFCompletionStack`, not a module import) that was explicitly excluded from
    the module-import plan above.
  - [ ] **Real-profile follow-up (found 2026-09-05, analyzing the user's actual `profile.ps1`)**:
    - [x] Migrate the three PSReadLine lines at the bottom of `profile.ps1` — done 2026-09-06:
      landed in `Tools/psreadline.ps1`/`Tools/psreadline.json` (the tool's own sidecar), not
      `Initialize-DFEnvironment` as originally sketched — consistent with this codebase's
      convention that tool-specific settings live in that tool's own `Tools/<name>.ps1`, never
      core. `HistorySearchCursorMovesToEnd` is a new `settings` key; `Ctrl+p`/`Ctrl+n` are bound
      unconditionally, matching how the file's other opinionated defaults (e.g. `bellStyle`)
      already work. Along the way, also changed the default `EditMode` from `Windows` to `Emacs`
      (per-user decision) — override with `$DFConfig['PSReadLineEditMode'] = 'Windows'`.
    - Consider whether the async pre-warm mechanism this item builds should be a general
      DotForge primitive (not private to `Register-DFTool`'s three module imports), so the
      user's own `profile.ps1`/`Completers.ps1` could pre-warm its own extra module imports
      (`powershell-yaml`, `Microsoft.PowerShell.SecretManagement`,
      `Microsoft.WinGet.CommandNotFound` — measured 88ms + 128ms combined) and the cosmetic
      `FastFetch` + `Clear-Host` banner (measured 222ms) the same way. Not committed to yet —
      evaluate during the implementation plan below.
    - Not itself a DotForge-scope item, but worth the user's own attention: `Start-Transcript`/
      `Stop-Transcript` in `profile.ps1` cost ~132ms every session (not the recursive prune scan,
      which is only ~50ms combined) — real, recurring, unconditional per-session cost outside
      this repo's control.
- [ ] **Coverage audit (2026-09-03) — catppuccin-mocha status per tool**, to split into their
  own design/plan cycles (per user decision, not bundled into one workstream):
  - `mdcat`/`mdv`/`glow` — done, default to catppuccin-mocha out of the box.
  - [x] `psreadline` — done 2026-09-04: defaulted to `catppuccin-mocha` (was the only themed
    tool shipping a neutral `dark` default). `Tools/psreadline.ps1`.
  - [x] `delta` — done 2026-09-05: bundled and deployed catppuccin/delta's `catppuccin.gitconfig`
    (`Tools/delta.ps1`), and `Tools/delta.setup.ps1` adds the one-time `include.path` entry via
    the tool-setup-lifecycle primitive above. Also fixed `DELTA_FEATURES` to be `+`-prefixed
    (additive) along the way — it previously discarded the user's entire `features` list.
    Design: `docs/superpowers/specs/2026-09-04-delta-catppuccin-design.md` (Section 3 rewritten
    2026-09-05 to match the shipped primitive instead of its originally-drafted bespoke marker
    file).
  - [x] `bat` — done 2026-09-04: `BAT_THEME` set to bat's native `Catppuccin Mocha` (already
    built in, no external config needed). `Tools/bat.json`/`.ps1`.
  - [x] `lsd` — closed 2026-09-04, no code needed: confirmed `lsd` reads `LS_COLORS` for
    filetype-extension coloring — both empirically (`di=` override test) and per its own
    README FAQ ("How can I set custom color schemes for Windows?"), so it already gets
    catppuccin-mocha coloring for free once `vivid` is registered, same as `eza`. Documented
    in `README.md`'s vivid section and `docs/external-dependencies.md`. `lsd`'s *other* color
    categories (permissions, size, date — its own separate theme system, blocked by the
    existing `--config-file` panic-on-missing-path issue, see `Tools/lsd.json`) are unaffected
    and remain a distinct, larger potential follow-up, not part of this item.
  - `lazygit`, `micro`, `procs` — zero integration; each needs its own investigation into how
    it can be pointed at a catppuccin-mocha theme/config.
  - `oh-my-posh` — theme is entirely the user's own profile (`$Env:POSH_THEME`), outside
    `$DFConfig` — a real gap against the "one system-wide theme" goal, but changing it means
    deciding how a prompt-engine theme fits the `$DFConfig.Theme` chain; needs its own design.
  - `winfetch` — unrelated to theming, but flagged in the same pass: winfetch is abandoned
    upstream. Replace the `Tools/winfetch.json` entry with `fastfetch` (its actively maintained
    successor) — a tool-swap task, not a theming task; update `Tools/*.json`, README's Included
    Tools table (currently lists `winfetch` under "System"), and any doc/example references.
- [ ] **Opt-in/opt-out control over which aliases/functions DotForge binds** — a
  whitelist/blacklist mechanism (per-alias or per-tool granularity) so users can
  explicitly control global-namespace pollution instead of DotForge deciding
  uniformly for everyone. Design sketch (shelved, not implemented): wrap
  `Set-Alias` in a DotForge-owned function so tools/helpers *declare* an alias
  without directly creating it; a central function then iterates all
  declarations and filters per user config (allow-list or deny-list, at either
  the individual-alias or whole-tool level) before actually binding anything.
  Open question, unresolved: whether PowerShell's manifest system supports
  anything resembling "optional/conditional exports" this could piggyback on,
  or whether it would have to be entirely session-side (declarative data +
  runtime filtering, no manifest involvement). See
  `docs/builtin-safety-policy.md` for the related "never silently claim a
  builtin" policy this would complement.
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
- [ ] **$HOME vs $LOCALAPPDATA** — We could allow users to choose between `$HOME` and `$LOCALAPPDATA` for the root of XDG directories.
