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

## Documented but load-bearing

These are public API. They are listed because DotForge visibly misbehaves if they change.

| Dependency | Where | Notes |
|---|---|---|
| `carapace _carapace powershell` emits the init script | `Tools/carapace.ps1` | Underscore-prefixed but listed in `carapace --help`. |
| carapace registers argument completers and **never binds Tab** | `Tools/carapace.ps1` | This is *observed*, not promised. It is why carapace composes with PSFzf, which owns Tab and routes through `TabExpansion2`. If carapace ever bound Tab, the two would fight and PSFzf's fuzzy Tab would break. |
| carapace's init prepends `$XDG_CONFIG_HOME/carapace/bin` to `PATH` itself | `Tools/carapace.ps1` | A deviation from DotForge's rule that all PATH edits go through `Add-DFToPath`. The line is emitted by carapace and cannot be rerouted. |
| `zoxide init` emits `Set-Alias -Name cd -Option AllScope -Force` | `Tools/zoxide.ps1` | Replaces the built-in `cd` alias in place, so no function-shadowing is needed. Verified against zoxide's emitted init. |
| `scoop-search --hook` emits a search hook | `Tools/scoop.ps1` | Requires `Invoke-Expression`; no alternative exists. |
| `oh-my-posh init pwsh --config` emits the prompt init | `Tools/oh-my-posh.ps1` | Requires `Invoke-Expression`. Also reads `POSH_THEME` / `POSH_THEMES_PATH`. |
| `Set-PsFzfOption`, `Invoke-FzfTabCompletion` | `Tools/PSFzf.ps1` | Public PSFzf API. PSFzf owns the Tab key binding. |
| `TabExpansion2` consults registered argument completers | `Tools/carapace.ps1` | Documented PowerShell behavior; the reason carapace results reach PSFzf's Tab UI. |
| eza's `--icons`/`--hyperlink` take an **optional** value | `Tools/eza.json` | Documented in `eza --help`. A trailing bare flag consumes the next positional, so all values are bound (`--icons=auto`). Guarded by `tests/eza.Tests.ps1`. |

---

## Internal to DotForge (not an external dependency, but surprising)

- **`AliasesToExport` is decorative.** DotForge's helper aliases are created with
  `Set-Alias -Scope Global` at dot-source time, so the module never owns them:
  `(Get-Module DotForge).ExportedAliases` is empty and `Remove-Module DotForge` leaves them
  behind. `Get-DFCommandConflict` reads `AliasesToExport` out of the manifest file for exactly
  this reason. Tracked in `TODO.md`.

## Keeping this honest

- `tests/Coreutils.Conflicts.Tests.ps1` is a dev-time tripwire: it fails when a new DotForge alias
  collides with a coreutils utility, so contributors without coreutils installed still find out.
  Its fixture (`tests/data/coreutils-commands.json`) records the coreutils version it came from.
- `Get-DFCommandConflict` is the runtime counterpart, and always reads the live set from the user's
  machine rather than that fixture.
