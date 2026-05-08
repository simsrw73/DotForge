# TODO

## Priority 1 — Must Fix (bugs / PSGallery blockers)

- [x] **Guard `XDG_CACHE_HOME` null in `Get-DFCachedCompletion` and `Get-DFHelpTopicList`** — both functions throw an opaque null error if `$Env:XDG_CACHE_HOME` is unset; needs an early-exit `Write-Warning` pointing the user to `Initialize-DFEnvironment`
- [x] **Resolve `fcd` alias ownership conflict** — renamed zoxide picker alias from `fcd` to `fzo`; `fcd` now cleanly belongs to `Select-DFLocation`
- [x] **`Register-DFTool`: make `-Name` and `-All` mutually exclusive** — added `ParameterSetName` to enforce mutual exclusivity at the parameter binder level

## Priority 2 — Documentation (before release)

- [x] **Update CHANGELOG for Phase 5+ General Helpers** — added `[Unreleased]` section covering Phase 5 additions, verb rename, alias and parameter set changes
- [x] **Update README "Exported Cmdlets" table** — expanded to all 30 exported functions across 6 grouped sections with aliases
- [x] **Add `bitwarden` to README "Included Tools" table**
- [x] **Document `Invoke-DFPagerExe` quoted-args limitation** — added `Write-Warning` when `$Pager` contains quotes, and noted `--key=value` workaround in SYNOPSIS
- [x] **Fix misleading comment in `examples/02-standard.ps1`**

## Priority 3 — Code Quality

- [x] **`Get-DFTopProcess`: remove `Format-Table -AutoSize`** — returns pipeline-composable objects; callers that want a table can pipe to `Format-Table` themselves
- [x] **`Expand-DFXdgPath`: use `-creplace` instead of `-replace`** — all 4 replacements updated; consistent with CLAUDE.md convention
- [x] **`Add-DFToPath`: add `[Parameter(Position=0)]`** — declared positional for `Get-Help` discoverability
- [x] **`Select-DFVerb`: swap column order to `Verb Group`** — verb is now first; Parse index updated from `[1]` to `[0]`; test mock updated
- [x] **`zoxide.json`: fix `flags` array** — added `--help` and `--version` so the array contains both subcommands and actual flags

## Priority 4 — Test Coverage

- [x] **Add direct unit test for `Invoke-DFPagerExe`** — 4 tests added covering pipeline passthrough, arg splitting (single and multi-arg), and quoted-arg warning; also fixed a real bug where `$pagerArgs` was scalar-unrolled for single-arg pager strings (`[string[]]` declaration prevents it)
- [x] **`Update-DFCompletions`: add test that regeneration actually runs** — added test using a `Write-Output`-based generation command; verified cache file is written when tool is on PATH

## Priority 5 — Improvements

- [x] **Suggest standard env vars** — added "Recommended Setup" section to README documenting `$Env:EDITOR`, `$Env:VISUAL`, `$Env:PAGER`, `$Env:Picker`
- [x] **`$Env:Picker` abstraction** — `Invoke-DFFzf` now reads `$Env:Picker` (defaults to `fzf`); skim and any fzf-compatible picker work as drop-in replacements
- [x] **printenv / env alias** — added `Get-DFEnv` with `env` alias; outputs KEY=VALUE, supports `-Pattern` wildcard filter
- [x] **Scoop dependency check** — `Tools/scoop.ps1` companion warns if git is missing on registration
- [x] **Scoop search improvements** — `Tools/scoop.ps1` companion auto-hooks scoop-search when installed; README documents how to install it

## Priority 6 — Features

- [ ] **More tool configs** — add XDG, completions, and pickers for: `ssh`, `scoop` (completions), `choco`, `winget` (search picker)
      — document (or automate via companion `.ps1`) `scoop config use_sqlite_cache true` for PS7+, and suggest `scoop-search` / `fastscoop` as drop-in replacements
- [ ] **Maintenance interval feature** — `Invoke-DFMaintenance` that runs tasks (purge completion cache, update help topics, `scoop cleanup *`) on a configurable schedule; use a last-run timestamp file similar to the existing help-topics cache key pattern
- [ ] **Dynamic fzf preview sizing** — instead of hardcoded `60%`, explore sizing based on content length or terminal width

## Priority 7 — Future Consideration

- [ ] **User tool extension guide** — document how users add their own tool JSON records, argument completers, and pickers without forking the module
- [ ] **Scripting language tool paths** — evaluate whether managing `python`, `node`, `ruby`, `lua` bin/module paths belongs in DotForge or is out of scope
