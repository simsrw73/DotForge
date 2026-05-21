# TODO

## Priority 1 — Release Readiness

- [ ] **Promote to stable 1.0.0** — fix all open Problems below, bump `ModuleVersion` to `1.0.0`, remove `Prerelease = 'preview'` from psd1, move CHANGELOG `[Unreleased]` → `[1.0.0]`, republish via `Publish-DotForge.ps1`
- [ ] **User tool extension guide** — document how users add their own tool JSON records, argument completers, and pickers without forking the module; move into README or a separate `docs/extending.md`

## Priority 2 — Open Problems

- [ ] **Help header colorization misses `ABOUT_ALIAS_PROVIDER`-style headers** — `Invoke-DFHelp` regex matches ALL-CAPS headers but fails when they contain underscores (e.g. `ABOUT_ALIAS_PROVIDER`). Extend the regex to allow underscores.
- [ ] **`'Out-String" 2>nul' is not recognized`** — error appears in some contexts; investigate source (likely a companion script using CMD-style stderr redirect instead of PowerShell `2>$null`)
- [ ] **Red `?` on a line by itself in some Help output** — appears at the same indentation as surrounding content; investigate whether it's a broken ANSI sequence or a `Get-Help` rendering artifact
- [ ] **`Error: unknown command "completion" for "oh-my-posh"`** — may be version-specific; verify against current oh-my-posh release and fix or suppress if the subcommand was removed

## Priority 3 — Features

- [ ] **Color theme system across all tools** — PSReadLine has per-tool theming; explore a unified palette that also applies to `bat`, `delta`, `glow`, and terminal colors so the whole environment shares one theme
- [ ] **More tool configs** — add XDG, completions, and pickers for: `ssh`, `choco`, `winget` (search picker), `dotnet`; document or automate `scoop config use_sqlite_cache true` for PS7+
- [ ] **`Invoke-DFMaintenance`** — maintenance command that runs on a configurable schedule: purge completion cache, refresh help topic index, `scoop cleanup *`; use the last-run timestamp pattern from the existing help-topics cache

## Priority 4 — Improvements

- [ ] **Dynamic fzf preview sizing** — replace the hardcoded `right:60%` default with sizing derived from content length or terminal width
- [ ] **PSGallery icon** — add `IconUri` to `PrivateData.PSData` in psd1 for a better gallery page presentation
