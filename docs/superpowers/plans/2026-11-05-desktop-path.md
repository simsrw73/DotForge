# Desktop Path Entries Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tool records declare folders desktop apps need on the Windows user `PATH` (`desktopPath`); `Set-DFDesktopEnv` adds them on request, `Remove-DFDesktopEnv`/`Remove-DFTool` remove only what DotForge added, and `Get-DFToolStatus` notes what's missing.

**Architecture:** A new record field normalized at load; stateless `PATH` primitives and the status note in `Shared/DFDesktopPath.ps1` (the load and `Remove-DFTool` need them); planning, the prompt and writing in `Modules/DotForge.Helpers/Private/DFDesktopPath.Steps.ps1`, driven by the existing `Set-DFDesktopEnv`. The state file `desktop-env.json` gains a `path` section beside `vars`.

**Tech Stack:** PowerShell 7.2+, Pester 6, `Microsoft.Win32.Registry`.

**Spec:** `docs/superpowers/specs/2026-11-03-desktop-path-design.md` (extends `2026-10-26-desktop-variables-design.md`). Read both.

## Global Constraints

- User `PATH` only (`HKCU\Environment`, through `Get-DFDesktopEnvKey`); the system `PATH` is read, never written.
- Never `[Environment]::SetEnvironmentVariable`. The user `Path` keeps its registry kind (`ExpandString` stays `ExpandString`; a new value is `ExpandString`) and every other segment byte-for-byte.
- Nothing is written during a shell load. Whatever is already present is the user's: `AlreadySet` is never recorded, for variables or `PATH`.
- No test reads or writes the real user or system `PATH`: user `Path` lives in the scratch key (`DFTestDesktopEnvKey`), the system `PATH` comes from the mocked `Get-DFSystemPathValue`, folders live under `$TestDrive`, prompts are mocked.
- Pester 6 only; tests load with `TestSupport.ps1` + `Get-DFTestModuleFile`, `Set-DFTestXdg`/`Restore-DFTestXdg` around each test, `-Skip:(-not $IsWindows)` where the registry is touched.
- Every new function has comment-based help (private: `.SYNOPSIS`, `.PARAMETER`s, `.OUTPUTS`, matching the files they join; public changes: full help, `tests/Docs.Help.Tests.ps1`).
- Optional properties are read StrictMode-safe (`$obj.PSObject.Properties['x']?.Value`). Readability rules from CLAUDE.md (full names, result objects, split past ~60 lines).
- After changing `Shared/`, `Private/` or `Public/`: `./build/Build-DFCoreBundle.ps1`. After `Tools/*.json` or normalization: `./build/Build-DFToolRegistry.ps1`. After help or records: `./build/Build-DFReferenceDocs.ps1`. Include the regenerated files in that task's commit.
- Test runs: `pwsh -NoProfile -Command "./build/Test-DFFull.ps1 -Path <files>"`; expected tail `Failed 0 ... FailedContainers 0 SentinelFiles 0 StrayFolders 0`.
- Commits are GPG-signed; if signing times out, ask the user to unlock (`! 'unlock' | gpg --clearsign | Out-Null`); never bypass.

## Review Focus

1. **No user `Path` value at all, or an empty one** (new account): adding creates an `ExpandString` value holding just the folder, with no leading `;`. → Task 3 test `adds to a missing or empty Path`.
2. **A `Path` ending in `;` or holding empty segments (`a;;b`)**: they're kept as they were, and an append never produces `;;`. → Task 3 test `keeps empty segments and never doubles a separator`.
3. **DotForge's folder already present in another spelling** (other case, trailing `\`, `%USERPROFILE%\...`, or a junction to it): `AlreadySet`, no second entry. → Task 3 test `matches the folder written differently or through a junction`, Task 5 test `a differently written existing entry is AlreadySet and not recorded`.
4. **`Path` segments that are relative (`.`), missing folders, or garbage**: skipped silently in matching and in the other-copy scan; no `ConvertTo-DFPath` relative-path warning reaches the user. → Task 3 test `skips relative, missing and empty segments without warnings`.
5. **Two tools in one run declaring the same folder**: added once; the first tool owns the record. → Task 5 test `two tools declaring the same folder: added once, the first owns it`.

---

### Task 1: The `desktopPath` record field

**Files:**
- Modify: `Shared/Test-DFToolSchema.ps1` (`Get-DFDesktopSchemaError` ~253; the call ~238; known fields ~487)
- Modify: `Shared/Import-DFToolDb.ps1` (`ConvertTo-DFToolRecord` ~623)
- Modify: `Tools/fnm.json`
- Regenerate: `data/tool-registry.json`, `Bundle/DotForge.Core.ps1`, `docs/reference.md`
- Test: `tests/Desktop.Schema.Tests.ps1`

**Interfaces:**
- Produces: normalized `$tool.desktopPath` — `[object[]]` of `[pscustomobject]@{ path = [string]; commands = [string[]] }`, `@()` when absent. `$tool.desktop` unchanged.

- [ ] **Step 1: Write the failing tests** in a new `Describe 'desktopPath (schema)'` (reuse the file's `Get-Errs`):
  - `accepts a list of { path, commands }`: `desktopPath = @([pscustomobject]@{ path = '${XDG_DATA_HOME}/t/bin'; commands = @('t') })` → no errors; `commands` omitted → no errors.
  - `rejects a non-list, a missing path or non-string commands`: `desktopPath = 'x'`, `@([pscustomobject]@{ commands = @('t') })`, `@([pscustomobject]@{ path = 'p'; commands = @(1) })` → each `Should -Match 'desktopPath must be a list of \{ path, commands \} objects'`.
  - `desktop can't name Path`: `env = @{ Path = 'x' }; desktop = @('PATH')` → `Should -Match "desktop can't name Path; use desktopPath"`.
  - `normalizes to an empty list, and commands to an empty list` (StrictMode Latest): bare record → `@($bare.desktopPath).Count` is 0; `desktopPath = @([pscustomobject]@{ path = 'p' })` → `$rec.desktopPath[0].commands.Count` is 0 and `$rec.desktopPath[0].path` is `'p'`.
  - `no typo warning for desktopPath`: a record with `desktopPath` yields no warning naming it.
- [ ] **Step 2: Run** `./build/Test-DFFull.ps1 -Path tests/Desktop.Schema.Tests.ps1`. Expected: the new tests FAIL.
- [ ] **Step 3: Implement** `Get-DFDesktopPathSchemaError ([PSCustomObject]$Tool, $Entries)` beside `Get-DFDesktopSchemaError` (returns the message above or nothing), call it the way `desktop` is called; add the `Path` check (`-ieq 'Path'`) to `Get-DFDesktopSchemaError`; add `'desktopPath'` to the top-level known fields. In `ConvertTo-DFToolRecord`, add `desktopPath = [object[]]@(...)` built by a new `ConvertTo-DFDesktopPathBlock` in the same file (each entry → `path`, `[string[]]` `commands`).
- [ ] **Step 4: Add** to `Tools/fnm.json` after `"desktop"`: `"desktopPath": [{ "path": "${XDG_DATA_HOME}/fnm/aliases/default", "commands": ["node", "npm", "npx"] }],`. Rebuild registry, bundle, reference.
- [ ] **Step 5: Run** `-Path tests/Desktop.Schema.Tests.ps1, tests/ToolRegistry.Tests.ps1, tests/CoreBundle.Tests.ps1, tests/Docs.Reference.Tests.ps1, tests/ToolNative.Coverage.Tests.ps1`. Expected: PASS.
- [ ] **Step 6: Commit** `feat: desktopPath record field (T-90)`.

### Task 2: State file sections; `AlreadySet` stays the user's

**Files:**
- Modify: `Shared/DFDesktopEnv.ps1` (`Read-DFDesktopEnvState`, `Save-DFDesktopEnvState`, `Remove-DFDesktopEnvSet`)
- Modify: `Modules/DotForge.Helpers/Private/DFDesktopEnv.Steps.ps1` (`Write-DFDesktopEnvPlan`)
- Modify: `Modules/DotForge.Helpers/Public/Set-DFDesktopEnv.ps1`, `Modules/DotForge.Helpers/Public/Remove-DFDesktopEnv.ps1`, `Public/Remove-DFTool.ps1` (callers)
- Test: `tests/DFDesktopEnv.Tests.ps1`, `tests/Set-DFDesktopEnv.Tests.ps1`

**Interfaces:**
- Produces: `Read-DFDesktopEnvState` → `[pscustomobject]@{ Vars = [hashtable]; Path = [hashtable] }` or `$null` (unreadable). `Vars`: variable → `{ tool, value, since }` (unchanged). `Path`: canonical folder → `{ tool, since }`. `Save-DFDesktopEnvState -State <that object>` writes `{ "vars": {...}, "path": {...} }`. Every former `$State[...]` caller uses `$State.Vars[...]`.

- [ ] **Step 1: Write the failing tests** (`tests/DFDesktopEnv.Tests.ps1`):
  - `reads the old flat state as vars`: write `{ "FOO": { "tool":"deska","value":"x","since":"s" } }` to `Get-DFDesktopEnvStatePath`; `(Read-DFDesktopEnvState).Vars['FOO'].tool` is `'deska'`; `.Path.Count` is 0.
  - `writes and reads the sectioned state`: save `Vars = @{ FOO = ... }; Path = @{ 'C:\f' = [pscustomobject]@{ tool='deska'; since='s' } }`; raw JSON `ConvertFrom-Json -AsHashtable` has exactly keys `vars`, `path`; read back equals.
  - Keep `state round-trips, and an unreadable file reads as $null` passing with the new shape.
  In `tests/Set-DFDesktopEnv.Tests.ps1`, change `an equal value is AlreadySet, recorded, and not broadcast` to `an equal value is AlreadySet, not recorded, and not broadcast` asserting `(Read-DFDesktopEnvState).Vars.ContainsKey('DESK_A') | Should -BeFalse`; update the other `(Read-DFDesktopEnvState)['DESK_A']` reads to `.Vars['DESK_A']`.
- [ ] **Step 2: Run** `-Path tests/DFDesktopEnv.Tests.ps1, tests/Set-DFDesktopEnv.Tests.ps1`. Expected: FAIL.
- [ ] **Step 3: Implement.** Read: a JSON object whose keys are only `vars`/`path` with object values is the new form; any other object is the old flat form (all keys are variables). `Write-DFDesktopEnvPlan` records only `Set` and `Replaced`. `Set-DFDesktopEnv`'s nothing-to-write action text becomes `nothing to write`, and when the plan has no `Set`/`Replaced` it returns the plan without calling `ShouldProcess`. Update callers to `.Vars`. Rebuild bundle.
- [ ] **Step 4: Run** `-Path tests/DFDesktopEnv.Tests.ps1, tests/Set-DFDesktopEnv.Tests.ps1, tests/Remove-DFTool.Tests.ps1, tests/Activation.DesktopEnv.Tests.ps1, tests/CoreBundle.Tests.ps1`. Expected: PASS.
- [ ] **Step 5: Commit** `feat!: desktop state gains a path section; an existing value stays yours (T-90)`.

### Task 3: User and system `PATH` primitives

**Files:**
- Create: `Shared/DFDesktopPath.ps1` (`#Requires -Version 7.2`; the core, `DotForge.Helpers` and `Get-DFTestModuleFile` load `Shared/*.ps1` by folder, so nothing else lists it)
- Regenerate: `Bundle/DotForge.Core.ps1`
- Test: `tests/DFDesktopPath.Tests.ps1` (`-Skip:(-not $IsWindows)` on registry/junction tests; `AfterEach` removes `Get-DFDesktopEnvKey`)

**Interfaces:**
- Consumes: `Get-DFDesktopEnvValue`, `Open-DFDesktopEnvKey`, `Expand-DFDesktopEnvValue`, `ConvertTo-DFPath`, `Test-DFIsWindows`.
- Produces:
  - `Get-DFUserPathValue` → `[string]` raw unexpanded, `''` when absent.
  - `Set-DFUserPathValue -Value [string]` → none; keeps the existing kind, creates `ExpandString`; no broadcast.
  - `Get-DFSystemPathValue` → `[string]` raw machine `Path` (`HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment`, `DoNotExpandEnvironmentNames`); a seam tests mock.
  - `Resolve-DFDesktopPathFolder -Segment [string]` → `[string]` canonical final folder, or `$null` for empty/whitespace, not fully qualified after expansion, or unparseable. Expands with `Expand-DFDesktopEnvValue`, canonicalizes, and if the folder exists resolves links with `[IO.Directory]::ResolveLinkTarget($path, $true)` (leaf links only; parent junctions aren't followed — enough for fnm, whose junctions are leaves).
  - `Find-DFDesktopPathSegment -Value [string] -Folder [string]` → `[int]` index in `$Value -split ';'` of the first segment resolving to the same folder as `-Folder` (case-insensitive), else `-1`.
  - `Add-DFDesktopPathSegment -Value [string] -Segment [string] [-BeforeIndex [int] = -1]` → `[string]`. `-1` appends: `''` → `Segment`; ending in `;` → `Value + Segment`; else `Value + ';' + Segment`. Otherwise insert at that index of the split and join with `;`.
  - `Remove-DFDesktopPathSegment -Value [string] -Index [int]` → `[string]` (remove that one segment, join with `;`).
  - `Get-DFDesktopPathExt` → `[string[]]` from user `PATHEXT`, else machine, else `.COM;.EXE;.BAT;.CMD`.
  - `Find-DFDesktopPathOtherCopy -Command [string[]] -Folder [string] [-StopAtFolder]` → per command with a hit, `[pscustomobject]@{ Command; Path (resolved folder); Scope ('System'|'User'); Index (user-segment index, -1 for system) }`. Scans system then user segments (desktop order), skips segments resolving to `-Folder`, nonexistent folders and `$null` resolutions, looks for `<command><ext>` per `Get-DFDesktopPathExt`; first hit per command. `-StopAtFolder` stops at the first segment resolving to `-Folder` (only copies that come before it).

- [ ] **Step 1: Write the failing tests:**
  - `reads and writes the user Path keeping ExpandString and %VARS%`: create `Path` as `ExpandString` `'%USERPROFILE%\a;C:\b'`; `Set-DFUserPathValue (Add-DFDesktopPathSegment (Get-DFUserPathValue) 'C:\c')`; raw is `'%USERPROFILE%\a;C:\b;C:\c'`, kind `ExpandString`.
  - `adds to a missing or empty Path`: no value → result `'C:\c'`, kind `ExpandString`; `''` → `'C:\c'`.
  - `keeps empty segments and never doubles a separator`: `'a;;b;'` + `'c'` → `'a;;b;c'`; insert before index 2 of `'a;;b'` → `'a;;c;b'`; remove index 2 of `'a;;c;b'` → `'a;;b'`.
  - `matches the folder written differently or through a junction`: under `$TestDrive` create `real\` and junction `link\` → `real`; `Find-DFDesktopPathSegment` of `"X;$($real.ToUpper())\;Y"` and of `"$link"` for `-Folder $real` → `1` and `0`; with `$Env:DFTESTHOME` set in the scratch key to `$TestDrive`, segment `'%DFTESTHOME%\real'` matches.
  - `skips relative, missing and empty segments without warnings`: `Find-DFDesktopPathSegment '.;;C:\nope;relative\x' -Folder $real` → `-1` with `-WarningVariable w` empty; `Find-DFDesktopPathOtherCopy` over the same → nothing, no warning.
  - `finds another copy, system first, honoring PATHEXT`: `$TestDrive\sys\node.exe`, `$TestDrive\usr\node.cmd`; mock `Get-DFSystemPathValue { "$sys" }`; user Path `"$usr;$ours"` → one hit `Scope 'System'`, `Path $sys`; without the system copy → `Scope 'User'`, `Index 0`; with `-StopAtFolder` and user Path `"$ours;$usr"` → nothing.
  - `doesn't count DotForge's own folder, even through a junction`: user Path `"$link"` where `link` → `$ours` containing `node.exe` → nothing.
- [ ] **Step 2: Run** `-Path tests/DFDesktopPath.Tests.ps1`. Expected: FAIL (functions not defined).
- [ ] **Step 3: Implement** the functions above in `Shared/DFDesktopPath.ps1`. Rebuild bundle.
- [ ] **Step 4: Run** `-Path tests/DFDesktopPath.Tests.ps1, tests/CoreBundle.Tests.ps1, tests/ModuleSplit.Tests.ps1`. Expected: PASS.
- [ ] **Step 5: Commit** `feat: user and system PATH primitives for desktop entries (T-90)`.

### Task 4: Expected entries, the guard and the status note

**Files:**
- Modify: `Shared/DFDesktopPath.ps1`, `Shared/DFDesktopEnv.ps1` (`Get-DFDesktopEnvNote`)
- Regenerate: `Bundle/DotForge.Core.ps1`
- Test: `tests/DFDesktopPath.Tests.ps1`, `tests/Activation.DesktopEnv.Tests.ps1`

**Interfaces:**
- Consumes: Task 1's `$tool.desktopPath`; Task 3's primitives; `Expand-DFXdgPath`, `Test-DFDesktopEnvMatch`.
- Produces:
  - `Get-DFDesktopPathExpected -Tool` → per entry `[pscustomobject]@{ Path (canonical expanded); Commands [string[]]; Under (variable name or $null); UnderValue (DotForge's canonical expanded value or $null) }`. `Under` = the `xdg.vars` name whose template the entry's `path` template starts with (compare `/`-normalized, case-insensitive, whole path components), longest match wins.
  - `Test-DFDesktopPathGuard -Entry <expected> [-DesktopValue [hashtable]]` → `$null`, or `[pscustomobject]@{ Name; Current; Where ('in this shell'|'for desktop apps'); Suggested }`. Trips when `Under` is set and the process value of `Under` is non-empty and differs (canonical compare), or the desktop value (`$DesktopValue[$Under]` when the key is present, else `Get-DFDesktopEnvValue`) is non-empty and doesn't `Test-DFDesktopEnvMatch` `UnderValue`. Shell is checked first. `Suggested` = `Current` + the part of `Path` after `UnderValue`.
  - `Get-DFDesktopPathNote -Tool` → `[string]` notes, nothing off Windows or without `desktopPath` (no registry read then). Per entry, in order: guard → `"$($tool.name)'s Path entry is skipped: $Name is $Current $Where, so its folder isn't under $UnderValue"`; missing → `"$($tool.name)'s folder isn't on the desktop Path; Set-DFDesktopEnv $($tool.name) adds it"`; present but shadowed (`Find-DFDesktopPathOtherCopy -StopAtFolder`) → one `"desktop apps run $Command from $Path"` per command.
  - `Get-DFDesktopEnvNote` returns its variable notes followed by `Get-DFDesktopPathNote`; its early return now requires both `desktop` and `desktopPath` to be empty.

- [ ] **Step 1: Write the failing tests** (`tests/DFDesktopPath.Tests.ps1`, record built with `ConvertTo-DFToolRecord`, `xdg.vars = @{ DESKP_DIR = '${XDG_DATA_HOME}/deskp' }`, `desktopPath = @(@{ path = '${XDG_DATA_HOME}/deskp/current'; commands = @('deskp') })`):
  - `the entry lives under its own variable`: `Under` is `'DESKP_DIR'`, `UnderValue` is `ConvertTo-DFPath "$Env:XDG_DATA_HOME\deskp"`; a template `'${XDG_DATA_HOME}/deskpx/bin'` has `Under` `$null`.
  - `the guard trips on a different shell value`: `$Env:DESKP_DIR = 'C:\theirs'` → `Where 'in this shell'`, `Suggested 'C:\theirs\current'`; restore the variable after.
  - `the guard trips on a different desktop value, and on a planned one`: scratch key `DESKP_DIR = C:\theirs` → `Where 'for desktop apps'`; `-DesktopValue @{ DESKP_DIR = $UnderValue }` with the same key set → `$null`.
  - `no guard when the values match or are unset` → `$null`.
  - Notes: `missing` (empty user Path) → exactly the missing text; `shadowed` (system copy mocked, our folder on user Path) → `"desktop apps run deskp from $sys"`; `present and first` → nothing; `guard` → the skipped text; `no desktopPath reads no registry`: `Mock Get-DFUserPathValue {}`, record without the field → `Should -Invoke Get-DFUserPathValue -Times 0 -Exactly`.
  In `tests/Activation.DesktopEnv.Tests.ps1`: `an active tool's status notes a missing desktop Path entry` (record with `desktopPath`, empty scratch `Path`) → its `Detail` contains the missing text.
- [ ] **Step 2: Run** `-Path tests/DFDesktopPath.Tests.ps1, tests/Activation.DesktopEnv.Tests.ps1`. Expected: FAIL.
- [ ] **Step 3: Implement**, rebuild bundle.
- [ ] **Step 4: Run** the two files plus `tests/DFDesktopEnv.Tests.ps1, tests/CoreBundle.Tests.ps1`. Expected: PASS.
- [ ] **Step 5: Measure** `./build/Measure-DFStartup.ps1` with a session requesting `fnm`, on this commit and on `HEAD~1`. If the note adds more than 5 ms, drop the shadow check from `Get-DFDesktopPathNote` (keep guard and missing), adjust the shadow test to expect nothing, and record the measurement and the choice in the spec's Status note section.
- [ ] **Step 6: Commit** `feat: status notes for desktop Path entries (T-90)`.

### Task 5: `Set-DFDesktopEnv` adds `PATH` entries

**Files:**
- Create: `Modules/DotForge.Helpers/Private/DFDesktopPath.Steps.ps1`
- Modify: `Modules/DotForge.Helpers/Private/DFDesktopEnv.Steps.ps1` (`New-DFDesktopEnvResult`, `Write-DFDesktopEnvPlan`), `Modules/DotForge.Helpers/Public/Set-DFDesktopEnv.ps1` (body, help, `.OUTPUTS`)
- Test: `tests/Set-DFDesktopEnv.Tests.ps1` (new `Describe 'Set-DFDesktopEnv Path entries'`, same `BeforeEach` style; records `deska`/`deskb` gain `desktopPath` to `${XDG_DATA_HOME}/deska/current` with `commands = @('deska')`; `Mock Get-DFSystemPathValue { '' }`)

**Interfaces:**
- Consumes: Tasks 2–4.
- Produces:
  - `New-DFDesktopEnvResult` gains `-Kind [string] = 'Variable'` (`'Variable'|'Path'`), `-Shadowed [object[]] = @()` (Task 3's other-copy objects), `-Before [string] = $null` (the other copy's folder to insert before). For a `Path` result: `Name = 'Path'`, `Value` = folder, `Current` = matching segment as written or `$null`, `Action` `Set`|`AlreadySet`|`Skipped`.
  - `Get-DFDesktopPathPlan -Tools [object[]] -Ask [bool] -VarPlan [object[]]` → `Path` results. `-VarPlan` (the variable results) gives the guard's `-DesktopValue`: per variable, `Value` when `Set`/`Replaced`, else `Current`. A folder planned by an earlier tool in the run is `AlreadySet` for later ones.
  - `Read-DFDesktopPathChoice -Tool [string] -Other [object[]]` → `'B'`, `'A'` or `'S'`. Prints one line per distinct other folder, then reads one answer (first letter, case-insensitive; Enter → `'A'`). Exact text (spec):
    - user copy: `"  $Command is also at $Path (user Path)."` then `Read-Host "  Put $Tool's folder [B]efore it, [A]fter it or [S]kip (Enter: After)"`.
    - any system copy (wins over user copies): `"  $Command is also at $Path (system Path), which desktop apps find first whatever the user Path order."` then `Read-Host "  [A]dd $Tool's folder anyway or [S]kip (Enter: Add)"` (B is not offered; an answer starting with B counts as A).
  - `Write-DFDesktopEnvPlan -Plan -State` (now both kinds): records `Set`/`Replaced` variables and `Set` paths (`$State.Path[$folder] = { tool, since }`), saves once, writes variables, then one read-modify-write of the user `Path` (for each `Set` path in plan order: `-BeforeIndex` = `Find-DFDesktopPathSegment` of `Before` in the evolving value, `-1` if `Before` is `$null` or not found), broadcasts once if anything was written.

- [ ] **Step 1: Write the failing tests:**
  - `adds a missing folder at the end, records it, broadcasts once`: user Path `'C:\x'` → `'C:\x;' + $folder`; result `Kind 'Path'`, `Action 'Set'`; `(Read-DFDesktopEnvState).Path[$folder].tool` is `'deska'`; `Send-DFEnvironmentChange` once (also when a variable is set in the same run).
  - `a differently written existing entry is AlreadySet and not recorded`: user Path holds `$folder.ToUpper() + '\'` → `AlreadySet`, Path unchanged, `.Path.Count` 0, no broadcast.
  - `another user copy, asked: B puts it before, A at the end, S skips`: `$TestDrive\other\deska.cmd` on user Path `"C:\x;$other"`, `Mock Test-DFConflictPrompt { $true }`, `Mock Read-DFDesktopPathChoice { 'B' }` → `"C:\x;$folder;$other"`; `'A'` → `"C:\x;$other;$folder"`; `'S'` → unchanged, `Action 'Skipped'`, not recorded. `Shadowed` holds the other copy.
  - `the prompt names each other folder once and offers B only for user copies`: call `Read-DFDesktopPathChoice` with mocked `Read-Host { '' }` and `Write-Host`; user copy → `Read-Host` prompt matches `'\[B\]efore it, \[A\]fter it or \[S\]kip \(Enter: After\)'`, returns `'A'`; system copy → matches `'\[A\]dd deska''s folder anyway or \[S\]kip \(Enter: Add\)'`; two commands in the same other folder → one `Write-Host` line for it.
  - `unattended, another copy: appended and said so`: `-Confirm:$false` → end of Path, `Write-Host` called with text matching `"Added .* at the end of the user Path; deska at .* comes first"`; `Read-DFDesktopPathChoice` never invoked.
  - `the guard skips and says why`: scratch key `DESK_DIR` differs (record's `xdg.vars` `DESK_DIR = '${XDG_DATA_HOME}/deska'`) → `Action 'Skipped'`, Path unchanged, `Write-Host` matches `"Skipped deska's Path entry: DESK_DIR is C:\\theirs for desktop apps"`.
  - `a variable kept in the same run trips the guard; one replaced doesn't`: `DESK_DIR` declared in `desktop` too, `Read-DFDesktopEnvChoice` mocked `'K'` → path `Skipped`; `'R'` → path `Set`.
  - `two tools declaring the same folder: added once, the first owns it`: `-Name deska, deskb` with the same `desktopPath` → one segment added; `deskb`'s result `AlreadySet`; record owner `'deska'`.
  - `a folder that doesn't exist yet is still added`: `$folder` absent on disk → `Action 'Set'`, appended (a restore sets desktop values before installing).
  - `-WhatIf asks nothing and writes nothing`: `Read-DFDesktopPathChoice` never invoked; Path and state unchanged.
- [ ] **Step 2: Run** `-Path tests/Set-DFDesktopEnv.Tests.ps1`. Expected: new tests FAIL.
- [ ] **Step 3: Implement** the steps file; extend `New-DFDesktopEnvResult` and `Write-DFDesktopEnvPlan`. In `Set-DFDesktopEnv`: plan variables first, then `Get-DFDesktopPathPlan -VarPlan $varPlan`; the "none of these tools" message becomes `None of these tools suggests desktop variables or Path entries.`; the `ShouldProcess` action lists `Name=Value` for variables and `Path += <folder>` for paths; host lines for `Kept` (unchanged), guard skips (spec text, generic: `"Skipped $tool's Path entry: $Name is $Current $Where, so $tool's folder isn't under $UnderValue. Add $Suggested yourself, or let DotForge set $Name."`), and unattended shadowed appends (`"Added $folder at the end of the user Path; $Command at $Path comes first."`). Asking uses the existing `$ask`. Update help: "One already set to the same value is left as it is" gains "and stays yours: DotForge won't remove it"; a description paragraph on `PATH` entries and the new `.OUTPUTS` fields (`Kind`, `Shadowed`), an example `Set-DFDesktopEnv fnm`.
- [ ] **Step 4: Run** `-Path tests/Set-DFDesktopEnv.Tests.ps1, tests/DFDesktopEnv.Tests.ps1, tests/Docs.Help.Tests.ps1, tests/ModuleSplit.Tests.ps1`. Expected: PASS.
- [ ] **Step 5: Commit** `feat: Set-DFDesktopEnv adds desktop Path entries (T-90)`.

### Task 6: Removing `PATH` entries

**Files:**
- Modify: `Shared/DFDesktopEnv.ps1` (`Remove-DFDesktopEnvSet`), `Modules/DotForge.Helpers/Public/Remove-DFDesktopEnv.ps1` (selection, message, help), `Public/Remove-DFTool.ps1` (warning text only: "desktop variables" → "desktop variables and Path entries")
- Regenerate: `Bundle/DotForge.Core.ps1`
- Test: `tests/Set-DFDesktopEnv.Tests.ps1` (`Describe 'Remove-DFDesktopEnv'`), `tests/Remove-DFTool.Tests.ps1`

**Interfaces:**
- Consumes: Task 2's state, Task 3's `Find-DFDesktopPathSegment`/`Remove-DFDesktopPathSegment`/`Set-DFUserPathValue`.
- Produces: `Remove-DFDesktopEnvSet -Tool -State` also handles `$State.Path`: per recorded folder of those tools, removes the first matching segment wherever it is (one `Path` write for all), result `Kind 'Path'`, `Name 'Path'`, `Value` folder, `Current` the removed segment or `$null`, `Action 'Removed'`; drops the record either way; one broadcast if anything (variable or path) was removed; saves state.

- [ ] **Step 1: Write the failing tests:**
  - `removes a Path entry DotForge added, wherever it now is`: state `Path[$folder] = deska`; user Path `"$folder;C:\x"` (moved to the front) → `'C:\x'`, record gone, one broadcast.
  - `removes only one occurrence`: `"C:\x;$folder;$folder"` → `"C:\x;$folder"`.
  - `an entry already gone is Removed with nothing to write`: no broadcast when nothing else changed.
  - `never removes an entry it didn't record`: user Path holds `$folder`, state empty → unchanged; message `DotForge set no desktop variables or Path entries for these tools.`
  - `Remove-DFTool removes the tool's Path entry` (`tests/Remove-DFTool.Tests.ps1`, following that file's desktop-variable test).
- [ ] **Step 2: Run** `-Path tests/Set-DFDesktopEnv.Tests.ps1, tests/Remove-DFTool.Tests.ps1`. Expected: new tests FAIL.
- [ ] **Step 3: Implement**; `Remove-DFDesktopEnv`'s `$mine` includes `$state.Path` records of the named tools and its `ShouldProcess` action lists `Path -= <folder>`. Rebuild bundle.
- [ ] **Step 4: Run** those files plus `tests/CoreBundle.Tests.ps1, tests/Docs.Help.Tests.ps1`. Expected: PASS.
- [ ] **Step 5: Commit** `feat: remove desktop Path entries with the tool (T-90)`.

### Task 7: Docs, then the full gate

**Files:**
- Modify: `docs/guide/configuration.md` (Desktop apps), `docs/guide/tools.md` (fnm section), `docs/guide/writing-a-tool.md` (field table), `CLAUDE.md` (Tool JSON Schema, after the `desktop` bullet), `CHANGELOG.md` (`[Unreleased]`), `TODO.md` (delete T-90), `docs/superpowers/specs/2026-10-26-desktop-variables-design.md` (the "equal to DotForge's value" bullet points to the 11-03 spec)
- Regenerate: `docs/reference.md`
- Test: `tests/Docs.Examples.Tests.ps1`, full suite

- [ ] **Step 1: Write the docs.** configuration.md: list item 2 becomes "One already set to the same value is left as it is, and stays yours: DotForge won't remove it."; a new paragraph and `<!-- fragment -->` text block for the `PATH` entries (what's added, the two prompts from Task 5, unattended behavior, the guard), and the `Remove-DFDesktopEnv` sentence covers Path entries. tools.md fnm paragraph: replace the manual `PATH` sentence with `Set-DFDesktopEnv fnm, npm` adding `$XDG_DATA_HOME\fnm\aliases\default` (keep the `fnm_multishells` warning). writing-a-tool.md: a `desktopPath` row: `[{ "path": "${XDG_DATA_HOME}/fnm/aliases/default", "commands": ["node", "npm", "npx"] }]`, written only by `Set-DFDesktopEnv`. CLAUDE.md: one sentence after the `desktop` bullet naming `desktopPath`, `commands`, the ownership rule and the 11-03 spec. CHANGELOG: an Added entry for desktop Path entries; a Changed entry: an already-set desktop variable is no longer recorded as DotForge's, so removing the tool leaves it. Any new `powershell` block that changes the machine is `<!-- system -->`.
- [ ] **Step 2: Regenerate** the reference; run `-Path tests/Docs.Examples.Tests.ps1, tests/Docs.Reference.Tests.ps1, tests/Docs.Help.Tests.ps1`. Expected: PASS.
- [ ] **Step 3: Full gate:** `pwsh -NoProfile -Command "./build/Test-DFFull.ps1"`. Expected: `Failed 0`, `FailedContainers 0`, `SentinelFiles 0`, `StrayFolders 0`.
- [ ] **Step 4: Commit** `docs: desktop Path entries (Closes T-90)`; fast-forward `main` and push (standing permission after a green full run).
