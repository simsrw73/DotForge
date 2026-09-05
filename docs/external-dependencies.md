# External Dependencies

DotForge configures other people's tools, so some of its behavior rests on how those tools work
internally. This page lists every such assumption, so you can tell what might break when you upgrade
a tool — and what DotForge does when it breaks.

Two categories, and the difference matters:

- **[Undocumented internals](#undocumented-internals)** — behavior the tool's authors never promised.
  These can change in any release, with no deprecation. Every one degrades safely (see each entry).
- **[Documented but load-bearing](#documented-but-load-bearing)** — public, but worth naming because
  DotForge would visibly misbehave if it changed.

---

## Undocumented internals

### 1. coreutils: the `$__COREUTILS__` variable

| | |
|---|---|
| **What** | Coreutils for Windows builds a `HashSet[string]` named `$__COREUTILS__` at profile top level, listing the utilities its readline hook will rewrite. |
| **Where** | `Private/Get-DFCoreutilsShadowSet.ps1` |
| **Why** | It is the exact set the hook itself consults, so it is both the cheapest source (O(1), in-memory) and the only one that is *host-accurate* — see #4. `coreutils-manager status` costs ~22 ms per shell and answers a different question. |
| **If it changes** | `Get-DFCommandConflict` reports nothing and the conflict warning goes quiet. Nothing else breaks: this is a diagnostic, never a correctness dependency. |

### 2. coreutils: the section marker GUID and the generated code shape

| | |
|---|---|
| **What** | The installer wraps its injected profile block in `# DO NOT MODIFY -- coreutils -- 60b36fc6-2d59-49df-be51-28dd2f4c3c9a`, and writes the utility list as `__COREUTILS__ = ...@('arch','b2sum',...)`. DotForge matches the GUID to identify the block and regex-parses the array out of it. |
| **Where** | `Private/Get-DFCoreutilsShadowSet.ps1` |
| **Why** | Needed because of load order (#3): at the moment DotForge runs, the variable in #1 does not exist yet, so the list has to be read from the file that will define it. |
| **If it changes** | Same as #1 — the check silently disables itself. |

> **Do not** try to read the list out of the hook function's own definition instead. The array lives at
> profile top level, *outside* `PSConsoleHostReadLine`; the function body only contains the `'ls'`/`'la'`
> literals of its `switch` statement. Matching there reports the exact inverse of the truth.

### 3. coreutils: hook load order vs. `Register-DFTool`

| | |
|---|---|
| **What** | PowerShell loads `CurrentUserAllHosts` (`profile.ps1`) before `CurrentUserCurrentHost` (`Microsoft.PowerShell_profile.ps1`). Since `Register-DFTool -All` is typically called from the former and coreutils injects its hook into the latter, **the hook has not loaded yet** when DotForge checks for conflicts. |
| **Where** | `Private/Get-DFCoreutilsShadowSet.ps1` (the file-scan fallback exists solely for this) |
| **Why** | Reading only `$__COREUTILS__` makes the conflict check dead code in a real profile — it silently finds nothing, every time. |
| **If it changes** | If the hook ever loads first, the variable path takes over and the fallback is skipped. Both paths are live and tested. |

### 4. coreutils: the hook is injected per-host

| | |
|---|---|
| **What** | The installer targets `$PROFILE.CurrentUserCurrentHost` and the `AllUsers` equivalent — both *CurrentHost* paths. Hosts with their own profile (the VS Code terminal reads `Microsoft.VSCode_profile.ps1`) never load the hook. |
| **Where** | `Private/Get-DFCoreutilsShadowSet.ps1` |
| **Why** | This is why the conflict is host-specific, and why DotForge does not consult the registry or `coreutils-manager`: those report *machine* state and would warn about conflicts in hosts where the hook never runs. |
| **If it changes** | If coreutils starts injecting into all hosts, DotForge under-reports in hosts it does not scan. Behavior stays correct where it does scan. |

### 5. coreutils: `la` is synthesized, not a utility

| | |
|---|---|
| **What** | There is no `la.cmd`. The installer adds `la` to the hook only while `ls` is enabled (`if ($aliases.Contains('ls')) { $aliases.Add('la') }` in `pwsh-install.ps1`), and `coreutils-manager disable la` is **rejected**. |
| **Where** | `Public/Get-DFCommandConflict.ps1` — the `DisableWith` property maps `la` → `ls` |
| **Why** | Without the mapping, DotForge would hand you a fix command that fails. Disabling `ls` removes `la` with it. |
| **If it changes** | If `la` becomes a real utility, the mapping sends you to `ls` — still correct for eza users, but review it. `tests/Coreutils.Conflicts.Tests.ps1` asserts `la` is absent from the utility list and will fail if this flips. |

### 6. PSReadLine: `Colors` is suppressed in non-VT terminals

| | |
|---|---|
| **What** | `Get-PSReadLineOption().Colors` returns `$null` when output is redirected or the terminal is not VT-capable, even after a successful `Set-PSReadLineOption -Colors`. |
| **Where** | `Tools/psreadline.ps1` — sets `$global:DFPSReadLineColors` as a test-observable side channel |
| **Why** | There is no other way to assert the theme was applied in CI. |
| **If it changes** | Nothing user-facing; only the test seam becomes redundant. |

### 7. zoxide: prompt hooking and its re-hook guard

| | |
|---|---|
| **What** | `zoxide init --hook pwd` wraps `function:prompt` (not `LocationChangedAction`), and guards against double-hooking with `$global:__zoxide_hooked = 1`. |
| **Where** | `Tools/zoxide.ps1`; ordering rules in `CLAUDE.md` |
| **Why** | It forces an ordering constraint: oh-my-posh must initialize **before** zoxide so zoxide wraps OMP's prompt. `Register-DFTool -All` gets this right alphabetically (`oh-my-posh` < `zoxide`). |
| **If it changes** | **Known live limitation:** after a theme switch via `fpot`, OMP re-inits and replaces `function:prompt`, but zoxide's guard prevents re-hooking — so directory tracking stops until the next shell. No clean workaround. |

### 8. fnm: the `cd` hook shape (`Set-LocationWithFnm` / `Set-FnmOnLoad`)

| | |
|---|---|
| **What** | `fnm env --use-on-cd --shell powershell` emits a global `Set-LocationWithFnm` function that calls plain `Set-Location`, a `Set-FnmOnLoad` helper, and `Set-Alias -Option AllScope -Scope global cd Set-LocationWithFnm`. `Tools/fnm.ps1` (a) captures the pre-fnm `cd` target from zoxide's alias via `(Get-Alias 'cd').ReferencedCommand`, then (b) **redefines `global:Set-LocationWithFnm`** to route through that captured command so zoxide's jump and fnm's version switch both run. |
| **Where** | `Tools/fnm.ps1` |
| **Why** | fnm's wrapper hardcodes `Set-Location`, so without the re-wrap fnm silently clobbers zoxide's smart `cd`. The re-wrap depends on the exact names `Set-LocationWithFnm` (the function fnm's `cd` alias points at) and `Set-FnmOnLoad` (the per-directory switch), plus zoxide binding `cd` as an alias so `.ReferencedCommand` is callable. `fnm.json` declares `"dependsOn": ["zoxide"]` so the capture in step 1 sees zoxide's binding, not the built-in `cd`. |
| **If it changes** | If fnm renames `Set-LocationWithFnm`/`Set-FnmOnLoad` or stops routing `cd` through the function, the re-wrap no longer chains: `cd` falls back to whatever fnm's newer init installs (still a working `cd`, just without zoxide's jump). If zoxide ever binds `cd` as a function instead of an alias, `(Get-Alias 'cd')` returns nothing and `$global:cdBeforeFnm` falls back to `Set-Location` — fnm keeps working, zoxide's jump is lost. Both degrade to a functional `cd`, never an error. |

---

### 9. carapace: completion results are ANSI-styled only when console-attached

| | |
|---|---|
| **What** | Carapace emits colour escape sequences inside each completion's `ListItemText` (and `ToolTip`), but **only when it detects an attached console**. When stdout is redirected — as in every headless test — the same results come back as plain text. |
| **Where** | `Private/Initialize-DFCompletionStack.ps1` (`Enable-DFFzfAnsiOption`) |
| **Why** | With PSFzf owning Tab, those styled strings are piped to `fzf`. Without `--ansi`, `fzf` prints the escapes literally, so the picker (and any common-prefix insert) shows garbage like `^[[33m…`. The resolver adds `--ansi` to `FZF_DEFAULT_OPTS` — a documented fzf option, set via the documented env var, touching no PSFzf internal — when both PSFzf and Carapace are registered. The **`CompletionText`** carapace returns is never styled, so the text inserted at the prompt stays clean regardless. |
| **If it changes** | If carapace stops styling `ListItemText`, `--ansi` becomes a harmless no-op (fzf renders plain text unchanged). If it styles `CompletionText` too, inserted text could gain escapes — caught quickly at the prompt, not silently. Because the console-only behavior is invisible to redirected output, unit tests cannot observe it; this entry is the record that the styling is real at an interactive prompt. |

---

### 10. carapace: init codegen shape (`[CompletionResult]::new($_.CompletionText, …)`) and the trailing space

| | |
|---|---|
| **What** | `carapace _carapace powershell` emits a completer that appends a trailing space to each `CompletionText` ("token complete" convention) and builds results with the literal call `[CompletionResult]::new($_.CompletionText, …)`. When PSFzf owns Tab, its `FixCompletionResult` quotes any completion containing a space, so a fuzzy-picked `docker build` is inserted as `docker "build "`. |
| **Where** | `Tools/carapace.ps1` |
| **Why** | Only in Native mode with PSFzf available, `Tools/carapace.ps1` string-replaces that constructor call to wrap the first argument in `.TrimEnd()`, dropping the trailing space so PSFzf does not quote. PSFzf re-adds a single trailing space itself, so the picked value lands clean and unquoted. The space is left intact when PSFzf is not in play because PSReadLine's `MenuComplete` needs it to chain into subcommand completion. |
| **If it changes** | If carapace renames the constructor call or drops the trailing space, the `.Replace` matches nothing and no-ops — completions still work; at worst the old `"build "` quoting reappears in the PSFzf path (cosmetic, self-evident at the prompt). The transform touches only the `CompletionText` argument, never `ListItemText`/`ToolTip`, so styling and the `--ansi` path are unaffected. |

---

## Documented but load-bearing

These are public API. They are listed because DotForge visibly misbehaves if they change.

| Dependency | Where | Notes |
|---|---|---|
| `carapace _carapace powershell` emits the init script | `Tools/carapace.ps1` | Underscore-prefixed but listed in `carapace --help`. Carapace registers argument completers and does not bind Tab; this observed behavior lets the coordinator choose the final binding. |
| Carapace Native completion and `CARAPACE_BRIDGES` | `Private/Initialize-DFCompletionStack.ps1`, `Tools/carapace.ps1` | In a Carapace-only Native session, the coordinator binds Tab to `MenuComplete` for styled results. It merges `inshellisense` into `CARAPACE_BRIDGES` only in Native mode and only when `is` (or `inshellisense`) is available, preserving user bridge entries. If Carapace changes its Tab behavior or bridge contract, completion may lose this composition but remains usable. |
| PSFzf's Tab completion | `Private/Initialize-DFCompletionStack.ps1`, `Tools/PSFzf.ps1` | PSFzf configures Tab expansion but does not bind Tab itself. After PSReadLine's edit mode is applied, the coordinator alone binds Tab to `Invoke-FzfTabCompletion` when PSFzf registered; this takes precedence over Carapace's `MenuComplete`. |
| inshellisense direct session | `Private/Initialize-DFCompletionStack.ps1`, `Tools/inshellisense.ps1` | Direct `CompletionMode = 'Inshellisense'` requires the `is` command and starts last, after tool registration. `Start-DFInshellisense` first runs `is -c`; a zero exit code leaves the existing session alone, otherwise `is init pwsh` is evaluated. If `is` is unavailable, DotForge warns and uses Native completion. |
| carapace's init prepends `$XDG_CONFIG_HOME/carapace/bin` to `PATH` itself | `Tools/carapace.ps1` | A deviation from DotForge's rule that all PATH edits go through `Add-DFToPath`. The line is emitted by carapace and cannot be rerouted. |
| `zoxide init` emits `Set-Alias -Name cd -Option AllScope -Force` | `Tools/zoxide.ps1` | Replaces the built-in `cd` alias in place, so no function-shadowing is needed. Verified against zoxide's emitted init. |
| `scoop-search --hook` emits a search hook | `Tools/scoop.ps1` | Requires `Invoke-Expression`; no alternative exists. The hook emits `function scoop { … }` with **no scope modifier**; because the companion is dot-sourced inside `Invoke-DFToolCompanion`, the function would land in that function's scope and vanish on return. `Tools/scoop.ps1` rewrites `function scoop {` → `function global:scoop {` before `Invoke-Expression` so the hook reaches the prompt. The rewrite no-ops (degrading to the pre-fix, local-scope behavior) if scoop-search changes its codegen. |
| `oh-my-posh init pwsh --config` emits the prompt init | `Tools/oh-my-posh.ps1` | Requires `Invoke-Expression`. Also reads `POSH_THEME` / `POSH_THEMES_PATH`. |
| `Set-PsFzfOption`, `Invoke-FzfTabCompletion` | `Tools/PSFzf.ps1` | Public PSFzf API. The completion coordinator owns the Tab key binding. |
| `TabExpansion2` consults registered argument completers | `Tools/carapace.ps1` | Documented PowerShell behavior; the reason carapace results reach PSFzf's Tab UI. |
| carapace loads user specs from `$XDG_CONFIG_HOME/carapace/specs/*.yaml` | `Tools/carapace.ps1`, `Tools/carapace/specs/scoop.yaml` | Documented in `carapace --help` ("Specs are loaded from …"). DotForge deploys bundled specs there to complete tools carapace ships no completer for (e.g. `scoop`). Spec flag syntax is short-first (`-g, --global`); a `$(…)` macro runs in carapace's shell, not PowerShell, so dynamic PowerShell-command completion is not used. |
| `fzf` merges `FZF_DEFAULT_OPTS` into every invocation | `Private/Initialize-DFCompletionStack.ps1` | Documented fzf behavior. Used to inject `--ansi` for Carapace's styled results without touching PSFzf's command construction. |
| eza's `--icons`/`--hyperlink` take an **optional** value | `Tools/eza.json` | Documented in `eza --help`. A trailing bare flag consumes the next positional, so all values are bound (`--icons=auto`). Guarded by `tests/eza.Tests.ps1`. |
| `lsd --config-file <path>` panics on a nonexistent path | `Tools/lsd.json` | Verified (lsd 1.2.0): `thread 'main' panicked at src\main.rs:116:33: Provided file path is invalid` — a hard crash, not a clean exit. DotForge never passes `--config-file`; `xdg.method` is `manual` for exactly this reason. A malformed-but-existing config is handled more gracefully (a field-name error is printed) but this workstream does not wire config at all. |
| glow's `--config` / `-s` flags and its built-in style names | `Tools/glow.ps1`, `Tools/glow.json` | Both flags are documented in `glow --help` and are cobra-persistent (verified: they pass through `completion`, `help`, and `--version` unharmed). DotForge depends on them because **nothing else works** — glow ignores `GLOW_CONFIG_DIR`/`GLOW_CONFIG_HOME`/`GLOW_CONFIG`/`GLOW_CONFIG_FILE` (its config path is a Win32 known-folder lookup, unmoved even when `APPDATA`/`LOCALAPPDATA` are redirected), never reads `GLAMOUR_STYLE`, and reads `GLOW_STYLE` but lets its non-TTY downgrade override it. `--config` is passed for `glow config`/TUI mode only; its contents do not affect single-file rendering (a bogus path, malformed YAML, and a bogus `style:` all pass silently). If the built-in style list changes, `Resolve-DFGlowStyle` warns and falls back to `auto` — it never hands `-s` an unresolved value, because glow exits 1 on one rather than degrading. Guarded by `tests/glow.Tests.ps1`. Conformance ledger: claim `glow/honors-env:GLOW_CONFIG_DIR` = `fail` in `data/tool-conformance.json`; `Tools/glow.ps1` carries the matching `# adapter for glow/honors-env:GLOW_CONFIG_DIR` comment. |
| mdcat's `MDCAT_THEME` env var and `--completions powershell` | `Tools/mdcat.ps1`, `Tools/mdcat.json` | Both documented (mdcat 2.13.0). Env var honored from any shell; `--completions` emits one `-Native` completer. carapace ships no mdcat spec, so no conflict. An unrecognized theme falls back to `auto`. |
| mdv's config path (`MDV_CONFIG_PATH`) and `config.yaml` theme key | `Tools/mdv.setup.ps1`, `Tools/mdv.json` | mdv 4.2.1 has **no config auto-discovery** (redirecting HOME/APPDATA/XDG_CONFIG_HOME loads nothing) and **no theme env var**; theme lives only in `config.yaml` found via `MDV_CONFIG_PATH`. DotForge seeds that file the first time mdv is ever registered on a machine (via the tool-setup-lifecycle primitive, `Tools/mdv.setup.ps1`), never clobbering user edits and never reasserting after an explicit deletion — so a theme change after that first run needs a manual edit, or clearing mdv's entry from `$XDG_STATE_HOME/dotforge/setup-state.json` to reseed. |
| carapace loads `Tools/carapace/specs/mdv.yaml` | `Tools/carapace.ps1`, `Tools/carapace/specs/mdv.yaml` | mdv has no completion generator and carapace ships no spec (`carapace mdv export` → 0 bytes). Hand-authored spec, deployed like `scoop.yaml`; can drift from the binary. |
| delta's `DELTA_FEATURES` is a plain, unvalidated env var | `Tools/delta.ps1`, `Tools/delta.json` | Documented delta behavior: `DELTA_FEATURES` names one or more config-defined feature sections; an unrecognized name is silently ignored (delta degrades on its own, no DotForge involvement needed). DotForge sets it from the resolved theme (`Get-DFConfiguredTheme` + `Resolve-DFThemeName`) so it tracks `$DFConfig.Theme`/`DeltaTheme`, prefixed with `+` so it *adds* to the user's own `features` list rather than replacing it (verified directly: a bare, unprefixed value discards the entire list, not just overlapping keys). DotForge also bundles [catppuccin/delta](https://github.com/catppuccin/delta)'s `catppuccin.gitconfig` (verbatim, MIT-licensed) so the feature name resolves to a real style block rather than a dead pointer — see the git-config-resolution row below for how it's wired in. |
| git's global config resolves via XDG, and `--config`/`include.path` differ in kind | `Tools/delta.setup.ps1` | `git config --global` resolves to `$XDG_CONFIG_HOME/git/config` when no `~/.gitconfig` exists (documented git behavior, not delta-specific) — DotForge never computes or hardcodes this path itself, only ever `git config --global --add/--get-all include.path`, so it stays correct regardless of which physical file git resolves to. Two ways exist to hand delta a style block: `delta --config <path>` *replaces* delta's entire config resolution outright (any of the user's own `[delta ...]` settings would be silently shadowed), while `[include] path = ...` in the real global config is additive — DotForge uses the latter specifically because it doesn't clobber settings it doesn't own. See `docs/superpowers/specs/2026-09-04-delta-catppuccin-design.md`. |
| vivid's `generate`/`themes`/`preview` subcommand contracts | `Tools/vivid.ps1`, `Tools/vivid.json` | `vivid generate <theme>` writes the `LS_COLORS` string to stdout and exits non-zero with a message on stderr for an unrecognized theme (verified: `Error: Could not find theme '...'`) — DotForge relies on the exit code alone, no output parsing. `vivid themes` emits one bare theme name per line (the `fls` picker's list); `vivid preview <theme>` renders ANSI-colored filetype samples (the picker's preview pane). All three are documented `vivid --help` subcommands. **The real payload this depends on is external to vivid, and is itself documented by each consuming tool** (not an undocumented internal): `eza` reads plain `LS_COLORS` per its own `man eza_colors` (verified there, and by overriding `di=` and observing eza render exactly that color instead of its own built-in blue); `lsd` reads it too, per its README FAQ "How can I set custom color schemes for Windows?" — explicitly the Windows-relevant path, since that's this project's platform (verified the same way: a `di=` override rendered as set). Both degrade to their own built-in palette if `LS_COLORS` is absent — this feature's env var still gets set correctly either way; only the visible payoff would disappear if a tool ever dropped the (documented) behavior. `Invoke-DFApplyLSColorsTheme` calls `vivid` via a raw `&`, not the mockable `Private/Invoke-DFCommandCapture.ps1` seam other sidecars use for their *own* internal logic (e.g. `Resolve-DFCliHelpFlag.ps1`) — it can't: as a detached `function:global:` (required so it stays callable after `Register-DFTool` returns and from the `fls` picker), its `.GetNewClosure()` body cannot resolve any Private module function regardless of dot-sourcing, confirmed empirically. `tests/vivid.Tests.ps1`'s sidecar tests are real-binary-only (`-Skip` when `vivid.exe` is absent) for this reason — the same pattern `mdcat`/`glow`/`delta` already use. |

---

## Internal to DotForge (not an external dependency, but surprising)

- **`AliasesToExport` is real for general-helper aliases, intentionally absent for tool/picker
  aliases.** The module's own aliases (`pg`, `hm`, `touch`, `yank`, …) are created via a bare
  `Set-Alias` in module scope, so the manifest's `AliasesToExport` genuinely exports them —
  `(Get-Module DotForge).ExportedAliases` reports them and `Remove-Module DotForge` cleans them up.
  Tool and picker aliases (`ls`, `cat`, `ff`, …) are created dynamically by `Register-DFTool` from
  `Tools/*.json` and are NOT in the manifest — they cannot be, since their existence depends on
  which tools are installed and what `$DFConfig.Defaults` selects. `Get-DFCommandConflict` reads
  them directly from the tool database for this reason; that split is by design, not a gap. See
  `ToolAcquisitionSpec.md` §9.1.
- **`Expand-DFXdgPath` normalizes only token-bearing values.** A `Tools/*.json` `xdg.vars` value is
  an XDG path template (`${XDG_CONFIG_HOME}/…`) — canonicalized to a native path via
  `ConvertTo-DFPath`. Token-less flag strings (`LESS`, `FZF_DEFAULT_OPTS`, …) no longer arrive via
  `xdg.vars`; they arrive from a tool's top-level `env` block, which is expanded through the same
  `Expand-DFXdgPath` function and passes through byte-for-byte when it carries no XDG token. A flag
  string must never embed an XDG path token, or its separators would be rewritten. Nothing ships
  that way today; this is the assumption that lets one function serve both value kinds — path
  templates and flag strings — without a per-var `type` flag. (`delta`'s `DELTA_FEATURES` is set
  directly by its sidecar via `Resolve-DFThemeName`, not through the `env` block/`Expand-DFXdgPath`
  — it is a theme name, not a path or a flag string.)
- **`Resolve-DFThemeName` is per-tool, not centralized.** Per `docs/plugin-architecture.md`, the
  theme family→dialect mapping lives in each tool's own optional `themeMap`, read from the
  already-loaded tool record — no central `data/*.json` registry and no extra startup file-read.
  Adding a themed tool whose dialect matches the canonical needs no declaration at all.

## Keeping this honest

- `tests/Coreutils.Conflicts.Tests.ps1` is a dev-time tripwire: it fails when a new DotForge alias
  collides with a coreutils utility, so contributors without coreutils installed still find out.
  Its fixture (`tests/data/coreutils-commands.json`) records the coreutils version it came from.
- `Get-DFCommandConflict` is the runtime counterpart, and always reads the live set from the user's
  machine rather than that fixture.
