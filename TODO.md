# TODO

## Priority 1 — Release Readiness

- [ ] **Promote to stable 1.0.0** — fix all open Problems below, bump `ModuleVersion` to `1.0.0`, remove `Prerelease = 'preview'` from psd1, move CHANGELOG `[Unreleased]` → `[1.0.0]`, republish via `Publish-DotForge.ps1`
- [ ] **User tool extension guide** — document how users add their own tool JSON records, argument completers, and pickers without forking the module; move into README or a separate `docs/extending.md`

## Priority 2 — Open Problems

- [ ] **Help header colorization misses `ABOUT_ALIAS_PROVIDER`-style headers** — `Invoke-DFHelp` regex matches ALL-CAPS headers but fails when they contain underscores (e.g. `ABOUT_ALIAS_PROVIDER`). Extend the regex to allow underscores.
- [ ] **`'Out-String" 2>nul' is not recognized`** — error appears in some contexts; investigate source (likely a companion script using CMD-style stderr redirect instead of PowerShell `2>$null`)
- [ ] **Red `?` on a line by itself in some Help output** — appears at the same indentation as surrounding content; investigate whether it's a broken ANSI sequence or a `Get-Help` rendering artifact
- [ ] **`Error: unknown command "completion" for "oh-my-posh"`** — may be version-specific; verify against current oh-my-posh release and fix or suppress if the subcommand was removed

## Priority 2 — Review Follow-ups

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

## Priority 3 — Features

- [ ] **Color theme system across all tools** — PSReadLine has per-tool theming; explore a unified palette that also applies to `bat`, `delta`, `glow`, and terminal colors so the whole environment shares one theme
- [ ] **More tool configs** — add XDG, completions, and pickers for: `ssh`, `choco`, `winget` (search picker), `dotnet`; document or automate `scoop config use_sqlite_cache true` for PS7+
- [ ] **`Invoke-DFMaintenance`** — maintenance command that runs on a configurable schedule: purge completion cache, refresh help topic index, `scoop cleanup *`; use the last-run timestamp pattern from the existing help-topics cache
- [ ] **trifle: alternatives / related commands** — deferred from trifle v1. Surface "alternatives" (e.g. ripgrep ↔ other tools tagged `search`) and related commands on the `Find-DFPackage` card. Candidate sources: shared `tags` in `Tools/*.json`, a curated `alternatives` field, or catalog keyword overlap. Revisit together with the name-collision merge wart (npm `bat` vs scoop `bat` currently merge into one row).

## Priority 4 — Improvements

- [ ] **Dynamic fzf preview sizing** — replace the hardcoded `right:60%` default with sizing derived from content length or terminal width
- [ ] **PSGallery icon** — add `IconUri` to `PrivateData.PSData` in psd1 for a better gallery page presentation
- [ ] **Themes via LS_COLORS** — use `vivid` to setup LS_COLORS
