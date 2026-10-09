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
| **Where** | `Tools/zoxide.ps1`, `Tools/zoxide.json` (`after`); ordering rules in `CLAUDE.md` |
| **Why** | It forces an ordering constraint: the prompt engine (oh-my-posh or starship) must initialize **before** zoxide so zoxide wraps its prompt. `zoxide.json` declares `"after": ["oh-my-posh", "starship"]` so the session topo-sorts the engine first. The order is not alphabetical: the tool DB is a hashtable. |
| **If it changes** | **Known live limitation:** after a theme switch via `fpot`, OMP re-inits and replaces `function:prompt`, but zoxide's guard prevents re-hooking — so directory tracking stops until the next shell. No clean workaround. |

### 8. fnm: the `cd` hook shape (`Set-LocationWithFnm` / `Set-FnmOnLoad`)

| | |
|---|---|
| **What** | `fnm env --use-on-cd --shell powershell` emits a global `Set-LocationWithFnm` function that calls plain `Set-Location`, a `Set-FnmOnLoad` helper, and `Set-Alias -Option AllScope -Scope global cd Set-LocationWithFnm`. `Tools/fnm.ps1` (a) captures the pre-fnm `cd` target from zoxide's alias via `(Get-Alias 'cd').ReferencedCommand`, then (b) **redefines `global:Set-LocationWithFnm`** to route through that captured command so zoxide's jump and fnm's version switch both run. |
| **Where** | `Tools/fnm.ps1` |
| **Why** | fnm's wrapper hardcodes `Set-Location`, so without the re-wrap fnm silently clobbers zoxide's smart `cd`. The re-wrap depends on the exact names `Set-LocationWithFnm` (the function fnm's `cd` alias points at) and `Set-FnmOnLoad` (the per-directory switch), plus zoxide binding `cd` as an alias so `.ReferencedCommand` is callable. `fnm.json` declares `"after": ["zoxide"]` so the capture in step 1 sees zoxide's binding, not the built-in `cd`. |
| **If it changes** | If fnm renames `Set-LocationWithFnm`/`Set-FnmOnLoad` or stops routing `cd` through the function, the re-wrap no longer chains: `cd` falls back to whatever fnm's newer init installs (still a working `cd`, just without zoxide's jump). If zoxide ever binds `cd` as a function instead of an alias, `(Get-Alias 'cd')` returns nothing and `$global:cdBeforeFnm` falls back to `Set-Location` — fnm keeps working, zoxide's jump is lost. Both degrade to a functional `cd`, never an error. |

---

### 9. carapace: completion results are ANSI-styled only when console-attached

| | |
|---|---|
| **What** | Carapace emits colour escape sequences inside each completion's `ListItemText` (and `ToolTip`), but **only when it detects an attached console**. When stdout is redirected — as in every headless test — the same results come back as plain text. |
| **Where** | `Tools/PSFzf.ps1` (`Enable-DFFzfAnsiOption`) |
| **Why** | With PSFzf owning Tab, those styled strings are piped to `fzf`. Without `--ansi`, `fzf` prints the escapes literally, so the picker (and any common-prefix insert) shows garbage like `^[[33m…`. The resolver adds `--ansi` to `FZF_DEFAULT_OPTS` — a documented fzf option, set via the documented env var, touching no PSFzf internal — when both PSFzf and Carapace are registered. The **`CompletionText`** carapace returns is never styled, so the text inserted at the prompt stays clean regardless. |
| **If it changes** | If carapace stops styling `ListItemText`, `--ansi` becomes a harmless no-op (fzf renders plain text unchanged). If it styles `CompletionText` too, inserted text could gain escapes — caught quickly at the prompt, not silently. Because the console-only behavior is invisible to redirected output, unit tests cannot observe it; this entry is the record that the styling is real at an interactive prompt. |

---

### 10. carapace: init codegen shape (`[CompletionResult]::new($_.CompletionText, …)`) and the trailing space

| | |
|---|---|
| **What** | `carapace _carapace powershell` emits a completer that appends a trailing space to each `CompletionText` ("token complete" convention) and builds results with the literal call `[CompletionResult]::new($_.CompletionText, …)`. When PSFzf owns Tab, its `FixCompletionResult` quotes any completion containing a space, so a fuzzy-picked `docker build` is inserted as `docker "build "`. |
| **Where** | `Tools/carapace.ps1` |
| **Why** | Only in Native mode with PSFzf available, `Tools/carapace.ps1` string-replaces that constructor call to wrap the first argument in `.TrimEnd()`, dropping the trailing space so PSFzf does not quote. PSFzf re-adds a single trailing space itself, so the picked value lands clean and unquoted. The space is left intact when PSFzf is not in play because PSReadLine's `MenuComplete` needs it to chain into subcommand completion. |
| **If it changes** | If carapace renames the constructor call or drops the trailing space, the `.Replace` matches nothing and no-ops — completions still work; at worst the old `"build "` quoting reappears in the PSFzf path (cosmetic, self-evident at the prompt). The transform touches only the `CompletionText` argument, never `ListItemText`/`ToolTip`, so styling and the `--ansi` path are unaffected. Because trimming could turn a whitespace-only `CompletionText` into `""` (which the constructor rejects — see #11), the same PSFzf-only path also inserts a `Where-Object` filter on the `ConvertFrom-Json \| ForEach-Object {` anchor that drops such items; if that anchor changes, the filter no-ops. |

### 11. carapace: the `return ""` empty-result sentinel

| | |
|---|---|
| **What** | When carapace has no completions, its generated completer ends with `return "" # prevent default file completion` to stop PowerShell falling back to filesystem completion. pwsh 7.6 turns that `""` into `[CompletionResult]::new('')`, which throws ("value of argument completionText is null"). PSFzf's Tab handler wraps `CompleteInput` in `try { } catch { return $false }`, so Tab silently does nothing. Triggered in practice by any input carapace cannot parse — e.g. the Windows-style `..\` prefix (`bat ..\<Tab>`), which carapace 1.8 answers with `[]` while handling `../` fine. |
| **Where** | `Tools/carapace.ps1` |
| **Why** | The sidecar string-replaces that exact line with a bare `return` in every mode, so an empty carapace answer falls through to PowerShell's built-in filesystem completion — the desired result for path arguments. Regression test: `tests/carapace.Tests.ps1` (`bat ..\` via `CompleteInput`). |
| **If it changes** | If carapace rewords the line, the `.Replace` no-ops and the throw returns on pwsh 7.6+ (Tab dead only for inputs carapace can't complete; the regression test catches it). If carapace drops the sentinel itself, the replace no-ops harmlessly. Reported upstream as [carapace#1301](https://github.com/carapace-sh/carapace/issues/1301) (sentinel) and [carapace#1300](https://github.com/carapace-sh/carapace/issues/1300) (backslash paths); revisit this rewrite once #1301 is fixed. |

### 12. direnv: the Windows variable-unloading bug, and `DIRENV_BASH`

| | |
|---|---|
| **What** | direnv 2.37.1 (latest as of 2026-10) on Windows unloads variables it never set (`ComSpec`, `ProgramFiles`, …) on each `cd` in and out of a project ([direnv#1488](https://github.com/direnv/direnv/issues/1488), [#1274](https://github.com/direnv/direnv/issues/1274)). direnv also needs bash, found as `bash_path` in `direnv.toml`, then the `DIRENV_BASH` variable, then `bash` on PATH (`internal/cmd/config.go`). |
| **Where** | `Tools/direnv.ps1` (`$DFDirenvLastBuggyVersion`, `Find-DFGitBash`) |
| **Why** | While direnv is the `project-env` tool, DotForge warns when `direnv version` is at or below `$DFDirenvLastBuggyVersion`, and sets `DIRENV_BASH` (when unset) to the first `bin\bash.exe` above `git.exe` (a scoop shim is first followed to the real `git.exe`), so it never writes `direnv.toml`. |
| **If it changes** | A fixed release silences the warning automatically; if a newer release still has the bug, raise the constant. An unparsable `direnv version` warns nothing. If Git's layout changes, the lookup finds nothing and warns, and a `bash_path` in `direnv.toml` still works. |

### 13. ps-dotenv: nested scoop install, shipped defaults, session-only approvals

| | |
|---|---|
| **What** | scoop's `ps-dotenv` install puts the manifest at `modules\Dotenv\Dotenv\Dotenv.psd1`, one level deeper than PowerShell expects: `Get-Module -ListAvailable Dotenv` finds it, `Import-Module Dotenv` by name fails. Module 1.1.0 ships with `SafeMode = True` and `Async = True` (the README calls safe mode opt-in). Approvals live in memory only. |
| **Where** | `Tools/ps-dotenv.ps1`, `Tools/ps-dotenv.json` (`prewarm: false`) |
| **Why** | The hook imports by the discovered `.Path`, sets `SafeMode` and `Async` explicitly (`Async` off so a script's `cd` sees the `.env` loaded), and re-applies `$DFConfig.DotenvApprovedDirs` each session. Prewarm is off because it imports by name. |
| **If it changes** | A fixed install layout still imports by path. If the `$Dotenv` object loses `SafeMode`/`Async`, setting them throws and registration warns that ps-dotenv failed to activate. Reported upstream as [ps-dotenv#10](https://github.com/insomnimus/ps-dotenv/issues/10) (fix: `"extract_dir": "Dotenv"` in the bucket manifest; see also #5); once fixed, importing by name would work, but importing by path keeps working either way. |

### 14. mise: activation embeds the current PATH

| | |
|---|---|
| **What** | `mise activate pwsh` output contains the session's PATH as literal text (`__MISE_ORIG_PATH`, `PATH`), wraps `function:prompt`, chains onto `LocationChangedAction`, and defines some top-level functions without `global:` (its `mise` wrapper, which `mise shell`/`deactivate` need). |
| **Where** | `Tools/mise.ps1`, `Tools/mise.json` (`after` the prompt engines) |
| **Why** | The hook generates activation live each session (~73 ms, only when mise is the `project-env` tool); caching it like zoxide's would restore a stale PATH. Before running it, the hook rewrites line-leading `function <name>` to `function global:<name>`, because the hook runs inside a DotForge function whose locals vanish on return. It registers after oh-my-posh/starship so it wraps their prompt. |
| **If it changes** | If mise stops embedding PATH, caching becomes possible as a startup optimization. If mise indents or renames those definitions, the rewrite no-ops: env loading still works (its hooks are already global), but `mise shell` is unavailable until the rewrite is updated (`tests/mise.Tests.ps1` pins the behavior). |

### 15. less: native Windows build vs Git for Windows' MSYS build

| | |
|---|---|
| **What** | scoop, winget (`jftuga.less`) and choco ship the native Windows `less` (jftuga/less-Windows), which uses the console API and ignores `TERM`. Git for Windows' `Git\usr\bin\less.exe` is an MSYS build that needs `TERM`/terminfo; when `Git\usr\bin` is on PATH ahead of the native one, a bare `less` is the MSYS build. Native less reads key bindings from `LESSKEYIN` (or `%XDG_CONFIG_HOME%\lesskey`); `LESSKEY` names the pre-582 compiled format. |
| **Where** | `Tools/less.json` (`executableExclude`, `${DF_TOOL_EXE}`, `LESSKEYIN`) |
| **Why** | When less is the `pager`, `PAGER` is the first `less.exe` on PATH outside `Git\usr\bin`, with forward slashes so git's `sh -c` keeps it intact. |
| **If it changes** | If Git moves its copy, the exclude pattern no-ops and `PAGER` may name the MSYS build again (still works with a sane `TERM`). With no native build, `PAGER` is plain `less`. |

### 16. bat: `PAGER=bat` falls back to less

| | |
|---|---|
| **What** | bat picks its pager from `--pager`/config, `BAT_PAGER`, then `PAGER`. When `PAGER` names bat (or `more`/`most`), it silently runs `less` instead (`src/pager.rs`). |
| **Where** | `Tools/bat.json` (no `pager` role) |
| **Why** | As a `pager` member bat would only ever have run less, so it isn't one; its own paging follows the role's `PAGER`. |
| **If it changes** | Nothing DotForge sets depends on the fallback. |

### 17. moor: `MOOR` options and style names

| | |
|---|---|
| **What** | moor (renamed from moar at v2.0.0) reads default options from `MOOR`; `-style` takes a highlighting style name (`catppuccin-mocha` among them) and falls back to its default for an unknown one. |
| **Where** | `Tools/moor.ps1` |
| **Why** | The companion sets `MOOR=-style <theme> -quit-if-one-screen` only when `MOOR` is empty, so a user's own value wins. |
| **If it changes** | If `-style` is renamed, moor rejects the option: set `MOOR` yourself, or update the companion. |

---

## Documented but load-bearing

These are public API. They are listed because DotForge visibly misbehaves if they change.

| Dependency | Where | Notes |
|---|---|---|
| scoop shim format: `shims\<name>.exe` + sibling `<name>.shim` containing `path = "<real exe>"` | `Private/Get-DFCachedCommandOutput.ps1` (`Resolve-DFExecutableTarget`) | Scoop never rewrites the shim `.exe` on upgrade, so the init-output cache fingerprints the `.shim`'s target instead. If the format changes or the target is missing, it degrades silently to fingerprinting the shim — the cache then goes stale across upgrades until `$XDG_CACHE_HOME/dotforge/<name>.*` is deleted. Symlinks (winget Links) are followed via `[IO.File]::ResolveLinkTarget`. |
| `carapace _carapace powershell` emits the init script | `Tools/carapace.ps1` | Underscore-prefixed but listed in `carapace --help`. Carapace registers argument completers and does not bind Tab; this observed behavior lets the coordinator choose the final binding. |
| Carapace completion and `CARAPACE_BRIDGES` | `Tools/carapace.ps1` | The `tab-completion` winner binds Tab to `MenuComplete`. When inshellisense is installed but does not win Tab, carapace merges it into `CARAPACE_BRIDGES`, preserving user bridge entries. |
| PSFzf's Tab completion | `Tools/PSFzf.ps1` | The `tab-completion` winner binds Tab to `Invoke-FzfTabCompletion`; when carapace is registered it enables fzf ANSI rendering. |
| starship's `Enable-TransientPrompt` / `Disable-TransientPrompt`, defined inside a dynamic module (`New-Module starship`) in the init script | `Tools/starship.ps1` | The functions are documented; that they live in a dynamic module is not. `New-Module` imports into the calling scope, which for a companion is DotForge's module session state, so the sidecar re-imports the module globally via `(Get-Command Enable-TransientPrompt).Module`. If starship renames or drops the function, the lookup returns nothing and the re-import is skipped: the prompt still works, only the transient helpers are unavailable. Regression test: `tests/starship.Tests.ps1`. |
| inshellisense direct session | `Tools/inshellisense.ps1` | When selected as the `tab-completion` winner, `Start-DFInshellisense` starts the IDE-style completion session unless one is already active. |
| carapace's init prepends `$XDG_CONFIG_HOME/carapace/bin` to `PATH` itself | `Tools/carapace.ps1` | A deviation from DotForge's rule that all PATH edits go through `Add-DFToPath`. The line is emitted by carapace and cannot be rerouted. |
| `zoxide init` emits `Set-Alias -Name cd -Option AllScope -Force` | `Tools/zoxide.ps1` | Replaces the built-in `cd` alias in place, so no function-shadowing is needed. Verified against zoxide's emitted init. |
| `scoop-search --hook` emits a search hook | `Tools/scoop.ps1` | Requires `Invoke-Expression`; no alternative exists. The hook emits `function scoop { … }` with **no scope modifier**; because the companion is dot-sourced inside `Invoke-DFToolCompanion`, the function would land in that function's scope and vanish on return. `Tools/scoop.ps1` rewrites `function scoop {` → `function global:scoop {` before `Invoke-Expression` so the hook reaches the prompt. The rewrite no-ops (degrading to the pre-fix, local-scope behavior) if scoop-search changes its codegen. |
| `oh-my-posh init pwsh --config` emits the prompt init | `Tools/oh-my-posh.ps1` | Requires `Invoke-Expression`. Also reads `POSH_THEME` / `POSH_THEMES_PATH`. |
| `Set-PsFzfOption`, `Invoke-FzfTabCompletion` | `Tools/PSFzf.ps1` | Public PSFzf API. The completion coordinator owns the Tab key binding. |
| `TabExpansion2` consults registered argument completers | `Tools/carapace.ps1` | Documented PowerShell behavior; the reason carapace results reach PSFzf's Tab UI. |
| carapace loads user specs from `$XDG_CONFIG_HOME/carapace/specs/*.yaml` | `Tools/carapace.ps1`, `Tools/carapace/specs/scoop.yaml` | Documented in `carapace --help` ("Specs are loaded from …"). DotForge deploys bundled specs there to complete tools carapace ships no completer for (e.g. `scoop`). Spec flag syntax is short-first (`-g, --global`); a `$(…)` macro runs in carapace's shell, not PowerShell, so dynamic PowerShell-command completion is not used. |
| `fzf` merges `FZF_DEFAULT_OPTS` into every invocation | `Tools/PSFzf.ps1` | Documented fzf behavior. Used to inject `--ansi` for Carapace's styled results without touching PSFzf's command construction. |
| eza's `--icons`/`--hyperlink` take an **optional** value | `Tools/eza.json` | Documented in `eza --help`. A trailing bare flag consumes the next positional, so all values are bound (`--icons=auto`). Guarded by `tests/eza.Tests.ps1`. |
| `lsd --config-file <path>` panics on a nonexistent path | `Tools/lsd.json` | Verified (lsd 1.2.0): `thread 'main' panicked at src\main.rs:116:33: Provided file path is invalid` — a hard crash, not a clean exit. DotForge never passes `--config-file`; `xdg.method` is `manual` for exactly this reason. A malformed-but-existing config is handled more gracefully (a field-name error is printed) but this workstream does not wire config at all. |
| glow's `--config` / `-s` flags and its built-in style names | `Tools/glow.ps1`, `Tools/glow.json` | Both flags are documented in `glow --help` and are cobra-persistent (verified: they pass through `completion`, `help`, and `--version` unharmed). DotForge depends on them because **nothing else works** — glow ignores `GLOW_CONFIG_DIR`/`GLOW_CONFIG_HOME`/`GLOW_CONFIG`/`GLOW_CONFIG_FILE` (its config path is a Win32 known-folder lookup, unmoved even when `APPDATA`/`LOCALAPPDATA` are redirected), never reads `GLAMOUR_STYLE`, and reads `GLOW_STYLE` but lets its non-TTY downgrade override it. `--config` is passed for `glow config`/TUI mode only; its contents do not affect single-file rendering (a bogus path, malformed YAML, and a bogus `style:` all pass silently). If the built-in style list changes, `Resolve-DFGlowStyle` warns and falls back to `auto` — it never hands `-s` an unresolved value, because glow exits 1 on one rather than degrading. Guarded by `tests/glow.Tests.ps1`. Conformance ledger: claim `glow/honors-env:GLOW_CONFIG_DIR` = `fail` in `data/tool-conformance.json`; `Tools/glow.ps1` carries the matching `# adapter for glow/honors-env:GLOW_CONFIG_DIR` comment. |
| fastfetch's `--config` flag | `Tools/fastfetch.ps1`, `Tools/fastfetch.json` | Documented in `fastfetch --help`. DotForge depends on it because fastfetch's Windows config auto-discovery ignores `$XDG_CONFIG_HOME` entirely: `fastfetch --list-config-paths` (fastfetch 2.68.1) returns an unchanged, hardcoded list of Win32 known-folder paths (`~/.config/fastfetch/`, `%PROGRAMDATA%/fastfetch/`, `%APPDATA%/fastfetch/`, `%LOCALAPPDATA%/fastfetch/`, `~/fastfetch/`) regardless of what `XDG_CONFIG_HOME` is set to. The original design (`xdg.method: "config"`) only ever worked by coincidence, because DotForge's own default `XDG_CONFIG_HOME` (`$HOME\.config`) matches fastfetch's first hardcoded search path — a relocated `XDG_CONFIG_HOME` silently broke discovery. `Tools/fastfetch.ps1` seeds the themed config (only when absent, never overwriting a user edit) and always passes it via an explicit `--config` flag, so discovery no longer depends on where `XDG_CONFIG_HOME` points. Conformance ledger: claim `fastfetch/honors-env:XDG_CONFIG_HOME` = `fail`; `Tools/fastfetch.ps1` carries the matching `# adapter for fastfetch/honors-env:XDG_CONFIG_HOME` comment. |
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
- **`Get-DFCachedCommandOutput`'s fingerprint needs a real file, not just a resolved command.**
  It keys the cache on the resolved executable's path + `LastWriteTimeUtc` via `Get-Item
  $cmd.Source` — but `Get-Command` can resolve a name to a function or alias instead of a file
  (`.Source` is then empty or not a real path). Found via `tests/scoop.Tests.ps1`'s existing
  `scoop-search` stand-in, which is a `function global:scoop-search { ... }`, not a real binary:
  fingerprinting a function stand-in would throw, or silently key the cache on garbage. The
  function falls back to always calling `-Generate`, uncached, whenever the resolved command has
  no backing file — a stubbed/aliased/function-shadowed command degrades to "slower but correct"
  rather than failing. This is why `tests/carapace.Tests.ps1`/`zoxide.Tests.ps1`'s caching tests
  call the *real* binaries instead of stubbing them the way `scoop.Tests.ps1` stubs `scoop-search`
  — a stub would make the cache path itself untestable.

## Keeping this honest

- `tests/Coreutils.Conflicts.Tests.ps1` is a dev-time tripwire: it fails when a new DotForge alias
  collides with a coreutils utility, so contributors without coreutils installed still find out.
  Its fixture (`tests/data/coreutils-commands.json`) records the coreutils version it came from.
- `Get-DFCommandConflict` is the runtime counterpart, and always reads the live set from the user's
  machine rather than that fixture.
