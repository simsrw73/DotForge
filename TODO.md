# TODO

Open work only. Each item has an ID (`T-12`): name it in the commit that resolves the item
(`Closes T-12`), and delete the item in that same commit. Finished work lives in `CHANGELOG.md` and
git history, not here. IDs are never reused; the next free one is **T-56**.

## Priority 1 — Release Readiness

- [ ] **T-1 Promote to stable 1.0.0** — fix the open Problems below, then follow CLAUDE.md's Releasing steps with `Prerelease` removed. `trifle` stays experimental and outside 1.0 (see After 1.0 at the end).
- [ ] **T-2 User tool extension guide** — how users add their own tool JSON records, argument completers and pickers without forking the module (a `docs/guide/` page).

## Priority 2 — Open Problems

- [ ] **T-3 Legacy profile fold-in is incomplete** — see [the design spec](docs/superpowers/specs/2026-07-15-legacy-profile-fold-in-design.md). `cli_tools_config.ps1` is no longer dot-sourced, so whatever isn't folded in is inactive: 12 fzf pickers (spec §3), small functions, and 6 tools with no record.
- [ ] **T-4 5 tools lack completions** — `broot`, `sfsu`, `nvm`, `uv`, `bw`. Prefer a carapace custom spec (`$XDG_CONFIG_HOME/carapace/specs/*.yaml`).
- [ ] **T-5 Seed default configs for ripgrep and wget** — use `setup.seed`: `ripgrep` needs `RIPGREP_CONFIG_PATH` and a seeded `ripgreprc`; `wget` needs `WGETRC` and an empty file.
- [ ] **T-6 Refresh the coreutils tripwire fixture on coreutils upgrades** — `tests/data/coreutils-commands.json` is from Coreutils for Windows 2026.6.16. Refresh with `coreutils-manager status`. See [docs/external-dependencies.md](docs/external-dependencies.md).
- [ ] **T-9 Red `?` on a line by itself in some help output** — a broken ANSI sequence or a `Get-Help` rendering artifact; investigate.
- [ ] **T-10 Path-normalization follow-ups** — (b) exercise a sidecar load through a `..`-bearing `-ToolsPath` in the `Register-DFTool` test; (c) resolve `$ToolsPath` once before `Import-DFToolDb` in `Register-DFTool`; (d) tests use `C:\` literals, so macOS/Linux stays unverified.
- [ ] **T-13 Improve `Install-DFTool` failure diagnostics** — a failed batch reports the last three lines of output; show the full output under `-Verbose`.
- [ ] **T-15 Reduce `Get-DFHelpTopicList` cached-path cost** — cache validation enumerates every installed module to compute the fingerprint. Consider a TTL or a cheaper fingerprint.
- [ ] **T-16 Review coverage gaps** — tests for: custom package-manager priority after a default lookup; generated `list_accepts_path` functions with single-word and quoted commands; malformed PATH in `New-DFShim`; duplicate tool names.
## Priority 2 — Architecture Backlog

From the audits consolidated on 2026-10-10 (read them at commit `c1d172a`) and the improve-code-quality journey (`docs/IMPROVE-CODE-QUALITY-PLAN.md`).

- [ ] **T-21 Declarative tool effects** — themes, executable wrappers and env-var precedence are hand-written in ~30 sidecars. Add declarative fields the core applies with one set of rules (`setup.seed` already covers config files). Large.
- [ ] **T-25 Conformance coverage** — probes exist for 3 of ~57 tools (`build/conformance/*.jsonc`).
- [ ] **T-26 Small cleanups** — companions repeat `Get-Command` lookups `Test-DFToolAvailable` already made (scoop, PSFzf, carapace, gsudo, choco, winget); `mise activate` and `oh-my-posh init` run uncached at every start; session globals with no cleanup (`$global:cdBeforeFnm`, `DFGlowStyle`, `DFDotenvLocationHook`, `DFPSReadLineColors`).
- [ ] **T-27 One home for the `role:<name>` reference syntax** — parsed in five places (`Private/Invoke-DFSessionActivation.ps1` ×3, `Private/New-DFInstallPlan.ps1` ×2); "the requested members of a role" is computed in `Resolve-DFToolRequirements` and `Get-DFActivationOrder`. Add `ConvertFrom-DFToolReference` and `Get-DFRoleMember`. Do it with the next change to that syntax.
- [ ] **T-28 Status `Detail` is a "; "-joined string built in three places** — `Add-DFRoleOutcomeStatus`, `Get-DFActivationBlocker`, `Add-DFInstallHint`. If a fourth appears, make `Detail` a list rendered once.
- [ ] **T-29 Wait for a third case (rule of three)** — a shared `Get-DFToolTheme` for the theme chain + `themeMap` pair repeated in 9 sidecars; a declarative XDG executable wrapper (glow, fastfetch so far).

## Priority 2 — Readability

From improve-code-quality Phase 2 (starting module now 8/10). Pin the gaps listed in `docs/TESTING.md` before touching these.

- [ ] **T-30 Split `Test-DFToolSchema`** (206 lines, `Shared/Test-DFToolSchema.ps1`) into one validator per section behind the same interface.
- [ ] **T-31 Split `ConvertTo-DFToolRecord`** (116 lines, `Shared/Import-DFToolDb.ps1`) into one normalizer per block.
- [ ] **T-32 Split `Get-DFRoleWinners`** (84 lines, `Private/Register-DFToolSteps.ps1`): ranking apart from fallback.
- [ ] **T-33 `Test-DFToolSchema` returns `{ Valid; Errors; Warnings }`** instead of `[ref]` output parameters. Do it with T-30.

## Priority 3 — Features

- [ ] **T-34 Role-level behavior specs for competing tools** — tools sharing a role (eza, lsd for `listing`) each hand-write `ls`/`ll`/`la`/`tree` in their own flags, and the two have drifted (lsd's `ll` includes `--all`). Describe alias behavior once per role in `data/roles.json` and let each tool map behavior names to its own flags. No central tool-keyed table. Brainstorm and spec first.
- [ ] **T-35 Onboard more tools into roles** — each batch its own small spec: editor (nano, vim); picker (skim; television needs its own adapter); file-manager (yazi, superfile, broot); url-fetch (httpie, xh, curlie, aria2); suggested roles: shell-history (atuin), git-tui (lazygit, gitui), process-viewer (procs, btop, bottom), disk-usage (dust, dua, gdu), json (jq, jaq, fx, jless), dotfiles (chezmoi, yadm), quick-help (tealdeer), secrets (bitwarden), replace (sd), watch (watchexec), code-stats (tokei, scc). Promote `markdown-viewer` from category to single once something consumes a winner.
- [ ] **T-36 Survey more per-directory env tools** — beyond ps-dotenv, mise and direnv. Also: write direnv's Git Bash `bash_path` config (setup lifecycle) and record its variable-unloading bug in `docs/external-dependencies.md`.
- [ ] **T-37 Audit theming for silent overrides of the user's own config** — `bat`'s `BAT_THEME`, `mdcat`'s `MDCAT_THEME` and `vivid`'s `LS_COLORS` outrank each tool's own config file, so a theme the user set there is overridden without notice or a per-tool opt-out. Weigh each case; the user must be able to see and override what DotForge changed.
- [ ] **T-38 Setup teardown** — an `Uninstall-DFToolSetup` that reads the recorded `actions` back. Spec it once there's more than delta's one `actions` shape.
- [ ] **T-39 Defer inshellisense's session check** — `is -c` runs at every start; see `docs/superpowers/specs/2026-09-05-startup-perf-audit.md`. Never defer oh-my-posh or fnm.
- [ ] **T-40 A general prewarm primitive for the user's own profile** — let a profile prewarm its own module imports (`powershell-yaml`, SecretManagement, `Microsoft.WinGet.CommandNotFound`, ~0.2 s measured) like DotForge's tool prewarm.
- [ ] **T-41 Catppuccin for lazygit, micro and procs** — no integration yet; each needs its own look at how to point it at a theme.
- [ ] **T-42 Prompt themes and the `Theme` chain** — oh-my-posh's theme is the user's own `$Env:POSH_THEME`; decide how a prompt engine's theme fits `Theme`. fastfetch's seeded config hardcodes catppuccin hex.
- [ ] **T-43 Opt-in/opt-out control over which aliases DotForge binds** — allow/deny lists per alias or per tool. Sketch: tools declare aliases; one function filters by config before binding. See `docs/builtin-safety-policy.md`.
- [ ] **T-44 Updating and removing tools (`Update-DFTool`, uninstall)** — reuse the managers' `installs` blocks (add `update`/`remove` commands) and the session graph. See [the install spec](docs/superpowers/specs/2026-10-09-install-design.md) non-goals.
- [ ] **T-46 Idle activation for slow, non-urgent tools** — `"activate": "idle"`, set up from `OnIdle` after the first prompt. Candidate: carapace (~0.3 s). Must stay eager: psreadline, PSFzf, starship, fnm, zoxide.
- [ ] **T-47 More tool configs** — XDG, completions and pickers for `ssh`, `choco`, `winget` (search picker), `dotnet`; document or automate `scoop config use_sqlite_cache true`.
- [ ] **T-48 `Invoke-DFMaintenance` and a scheduled-maintenance guide** — a manual, opt-in command to purge the completion cache, refresh the help-topic index and run `scoop cleanup *`. DotForge never creates scheduled tasks or updates packages itself; document user-owned Task Scheduler recipes.
## Priority 4 — Improvements

- [ ] **T-53 Dynamic fzf preview sizing** — replace the hardcoded `right:60%` with sizing from content length or terminal width.
- [ ] **T-54 `$HOME` vs `$LOCALAPPDATA`** — let users choose the root of the XDG folders.

## After 1.0: trifle (frozen)

Decided 2026-10-10: `trifle` (`Find-DFPackage`, the `DotForge.Catalog` module) and the package-universe build
pipeline are **frozen until every other item above is done**. They keep shipping as they are, labeled
experimental and outside what 1.0 covers (`docs/guide/package-catalog.md`). Don't start any item here, or
change catalog code beyond a bug that breaks something else, until then. The pipeline's working data (the
winget-pkgs clone, `universe.db`) lives in `$XDG_CACHE_HOME/dotforge/package-universe/`, outside the checkout.

- [ ] **T-55 Make trifle fast first** — before any feature below: measure a cold and a warm `trifle <query>`, set a
  time budget, and meet it. Speed is the reason this is frozen.
- [ ] **T-17 trifle `-Readme`: gate the npm tier on a repo match** — a name collision shows the wrong readme (`trifle ripgrep -Readme` shows the npm `ripgrep` wrapper's). Use the npm readme only when no GitHub repo resolves, or when its `RepositoryUrl` matches.
- [ ] **T-18 trifle qualified winget ids: better sibling search** — `trifle winget:BurntSushi.ripgrep.MSVC` searches other catalogs with the full dotted id. Use the matched index row's `Name` instead.
- [ ] **T-22 Finish one package-identity vocabulary** — `build/categories/dotforge-curated.jsonc` copies 47 package ids and `data/tool-identities.json` copies the ids in `Tools/*.json`. The identity guide should ship only what tool records can't say; categories should reference tools by name. `ConvertTo-DFCatalogSource` only lowercases and can be deleted.
- [ ] **T-23 The catalog cache owns its layout** — providers become fetch + parse; cache paths, freshness and enumeration move behind one interface (`Update-DFPackageCache` and `Get-DFCatalogLocalPackages` reach into the layout). Tests use recorded responses.
- [ ] **T-24 A build kit for build scripts** — four build scripts dot-source all of `Private/` and call private names; a rename silently breaks a pipeline that can run ~54 minutes. Parked with the package-universe pipeline.
- [ ] **T-45 PyPI installed overlay: include uv tools** — `trifle`'s PyPI installed state comes only from `pipx list`; add `uv tool list` (or read each `python-package-manager`'s list command from its record).
- [ ] **T-49 trifle: alternatives and related commands** — on the `Find-DFPackage` card, from shared `tags`, a curated `alternatives` field, or catalog keyword overlap. Revisit with the name-collision merge (npm `bat` vs scoop `bat`).
- [ ] **T-50 Expand the trifle category-db corpus** — 73 tools now; the long-run target is ~300–500. Content only: add `build/categories/*.jsonc` fragments and rerun `build/Build-DFCategoryDb.ps1`.
- [ ] **T-51 trifle category-db phase 2: automated gathering** — debtags, crates.io/PyPI classifiers, Homebrew analytics, Repology, GitHub topics; a live `popularity`. See `docs/superpowers/specs/2026-07-05-trifle-discovery-v1-design.md`.
- [ ] **T-52 Grow the tool-identity guide past 29 tools** — needs a way to discover candidate `(source, packageId)` pairs for tools not yet curated. See `docs/superpowers/specs/2026-07-06-trifle-tool-identity-guide-design.md`.
