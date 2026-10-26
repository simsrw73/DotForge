# Desktop Variables Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tool records suggest desktop variables (`desktop`); `Set-DFDesktopEnv` writes them to the Windows user environment on request, `Remove-DFDesktopEnv`/`Remove-DFTool` remove what DotForge wrote, and the status says what desktop apps are missing; komorebi is the first record to use it.

**Architecture:** Registry access, the state file and the expected values live in one stateless file, `Shared/DFDesktopEnv.ps1`, shared by the startup core (status note, `Remove-DFTool`) and `DotForge.Helpers` (the two commands). Every registry read/write goes through one key-path function that tests redirect to a scratch key, so no test touches `HKCU\Environment`.

**Tech Stack:** PowerShell 7.2+, Pester 6, Windows registry (`HKCU:\Environment`), `SendMessageTimeout` P/Invoke.

**Spec:** `docs/superpowers/specs/2026-10-26-desktop-variables-design.md`

## Global Constraints

- Nothing is written to the Windows environment during a shell load, ever.
- Running `Set-DFDesktopEnv` is the opt-in; no config key.
- A different existing value: interactive console → ask per variable (keep yours / replace); otherwise keep it and report it.
- Remove only what DotForge recorded, and only while the current value equals the recorded one.
- One broadcast (`WM_SETTINGCHANGE`, `SMTO_ABORTIFHUNG`, 2000 ms) per command, only when something changed.
- State file: `$XDG_STATE_HOME\dotforge\desktop-env.json`, variable → `{ tool, value, since }`.
- Non-Windows: commands say they are Windows-only and do nothing; no status notes.
- `Shared/` holds no session state. Plugin rule: no tool names in core code.
- Status note wording (spec): missing → `KOMOREBI_CONFIG_HOME isn't set for desktop apps; Set-DFDesktopEnv komorebi sets it`; different → `desktop apps see KOMOREBI_CONFIG_HOME = <theirs>`.
- No XDG location is ever linked to a native root itself (`$HOME`, `%APPDATA%`, `%LOCALAPPDATA%`, `$SCOOP`).

## Review Focus

1. A test that forgets to redirect the registry key writes the developer's real `HKCU\Environment`: the redirect must be on for every test file by default (TestSupport), like `DFTestNativeRoot`.
2. `-Confirm:$false` in an interactive console (the restore under chezmoi) must not stop for the per-variable question: it keeps the existing value.
3. A variable recorded by DotForge and since changed by the user: `Remove-DFDesktopEnv` / `Remove-DFTool` leave it and say so.
4. Two records declaring the same desktop variable: the first recorded owner stays; the second reports `AlreadySet` and doesn't take over the record.
5. An unreadable `desktop-env.json`: `Set-DFDesktopEnv` writes nothing (it couldn't record it) and says why; removal does nothing and says why.

Each line has a test in the task that owns it (marked **RF1**–**RF5**).

---

### Task 1: The `desktop` field and the native-root guard

**Files:**
- Modify: `Shared/Test-DFToolSchema.ps1` (known fields list ~line 449; validation near the `env` check ~line 217)
- Modify: `Shared/Import-DFToolDb.ps1` (`ConvertTo-DFToolRecord`, ~line 547)
- Modify: `Shared/DFToolOwnership.ps1` (`Find-DFToolConflict`, native loop ~line 237)
- Test: `tests/Test-DFToolSchema.Tests.ps1` (or the schema test file that covers `install.avoid`), `tests/Activation.Ownership.Tests.ps1`

**Interfaces:**
- Produces: every normalized record has `desktop` (`string[]`, `@()` when absent). Schema error text contains `desktop` and the bad name.

- [ ] **Step 1: Write the failing tests**
  - `desktop naming a variable defined in xdg.vars or env passes` — record with `xdg.vars.FOO` and `env.BAR`, `desktop: ['FOO','BAR']` → no errors.
  - `desktop naming an undefined variable is an error` — `desktop: ['NOPE']` → an error matching `*desktop*NOPE*`.
  - `desktop must be a list of strings` — `desktop: 'FOO'` → error.
  - `a record without desktop normalizes to an empty list` — `@((ConvertTo-DFToolRecord ...).desktop).Count | Should -Be 0`.
  - `never links an XDG location to a native root itself` (Activation.Ownership) — record with `native = @{ OWN_A = @('${HOME}') }`, a file under the fake `$HOME`; `Register-DFTool -Name owna` → `Get-DFToolLinkTarget` of the XDG path is empty and the tool is `Active`.

- [ ] **Step 2: Run them**

Run: `pwsh -NoProfile -File build/Test-DFFull.ps1 -Path <schema test file>,tests/Activation.Ownership.Tests.ps1`
Expected: the five new tests FAIL.

- [ ] **Step 3: Implement**
  - Schema: add `'desktop'` to the top-level known fields; validate it is an array of strings, each a key of `xdg.vars` or `env`.
  - `ConvertTo-DFToolRecord`: `desktop` defaults to `@()`.
  - `Find-DFToolConflict`: skip a native path equal to `Get-DFNativeRoot` of any of its four roots (compare canonical paths, case-insensitive).

- [ ] **Step 4: Run them**

Expected: PASS, and the rest of both files still pass.

- [ ] **Step 5: Regenerate** `./build/Build-DFCoreBundle.ps1` and `./build/Build-DFToolRegistry.ps1`. Commit at the end of the plan (signed commits batched).

---

### Task 2: `Shared/DFDesktopEnv.ps1` — store, state, expected values

**Files:**
- Create: `Shared/DFDesktopEnv.ps1`
- Modify: `tests/TestSupport.ps1` (redirect key, next to `DFTestNativeRoot`)
- Test: `tests/DFDesktopEnv.Tests.ps1`

**Interfaces:**
- Produces (all in `Shared/DFDesktopEnv.ps1`):
  - `Get-DFDesktopEnvKey` → `[string]`: `$script:DFTestDesktopEnvKey` when set, else `'HKCU:\Environment'`.
  - `Get-DFDesktopEnvValue -Name <string>` → `[string]` or `$null` (absent, or not Windows).
  - `Set-DFDesktopEnvValue -Name <string> -Value <string>`: keeps the existing value's kind (`ExpandString` stays `ExpandString`); a new value is `String`.
  - `Remove-DFDesktopEnvValue -Name <string>`.
  - `Send-DFEnvironmentChange`: one `SendMessageTimeout(HWND_BROADCAST 0xffff, WM_SETTINGCHANGE 0x1A, 0, 'Environment', SMTO_ABORTIFHUNG 2, 2000)`; no-op when `$script:DFTestDesktopEnvKey` is set.
  - `Get-DFDesktopEnvExpected -Tool <pscustomobject>` → `[pscustomobject[]]` `{ Name, Value }` per `desktop` entry, value from `xdg.vars` or `env` through `Expand-DFXdgPath` (canonical path for `xdg.vars`).
  - `Get-DFDesktopEnvStatePath` → `<XDG_STATE_HOME>\dotforge\desktop-env.json` (via `Get-DFXdgPath State`).
  - `Read-DFDesktopEnvState` → `[hashtable]` (empty when no file; `$null` when unreadable).
  - `Save-DFDesktopEnvState -State <hashtable>`.
  - `Get-DFDesktopEnvNote -Tool <pscustomobject>` → `[string[]]`, the spec's two wordings; nothing on non-Windows or when every value matches.

- [ ] **Step 1: Write the failing tests** (`tests/DFDesktopEnv.Tests.ps1`, `-Skip:(-not $IsWindows)` on the registry ones; `AfterEach` removes the scratch key)
  - `tests never use the real user environment` — `Get-DFDesktopEnvKey | Should -Not -Be 'HKCU:\Environment'` (**RF1**).
  - `writes, reads and removes a value` — set `DFTEST_A` = `x`, read `x`, remove, read `$null`.
  - `keeps an ExpandString value's kind when replacing` — create `DFTEST_B` as `ExpandString`, set it, `(Get-Item $key).GetValueKind('DFTEST_B') | Should -Be 'ExpandString'`.
  - `expected values come from xdg.vars and env` — record `xdg.vars.FOO = '${XDG_CONFIG_HOME}/foo'`, `env.BAR = 'plain'`, `desktop = FOO,BAR` → `FOO` = `Join-Path $Env:XDG_CONFIG_HOME foo`, `BAR` = `plain`.
  - `the note says a missing variable isn't set` — `Get-DFDesktopEnvNote` matches `FOO isn't set for desktop apps; Set-DFDesktopEnv <name> sets it`.
  - `the note says what desktop apps see when it differs` — set `FOO` = `C:\theirs` → matches `desktop apps see FOO = C:\theirs`.
  - `no note when the value matches`.
  - `state round-trips, and an unreadable file reads as $null`.

- [ ] **Step 2: Run them** — `build/Test-DFFull.ps1 -Path tests/DFDesktopEnv.Tests.ps1`. Expected: FAIL (functions missing).

- [ ] **Step 3: Implement** `Shared/DFDesktopEnv.ps1` per the interfaces; in `tests/TestSupport.ps1` set `$script:DFTestDesktopEnvKey = "HKCU:\Software\DotForge-Tests\$([guid]::NewGuid())"` with a comment matching the `DFTestNativeRoot` one. The P/Invoke type is added once (`Add-Type` guarded by `-not ('DotForge.UserEnv' -as [type])`).

- [ ] **Step 4: Run them.** Expected: PASS.

- [ ] **Step 5: Regenerate the bundle.**

---

### Task 3: `Set-DFDesktopEnv`

**Files:**
- Create: `Modules/DotForge.Helpers/Public/Set-DFDesktopEnv.ps1`, `Modules/DotForge.Helpers/Private/DFDesktopEnv.Steps.ps1`
- Modify: `Modules/DotForge.Helpers/DotForge.Helpers.psd1` (`FunctionsToExport`)
- Test: `tests/Set-DFDesktopEnv.Tests.ps1`

**Interfaces:**
- Consumes: Task 2's functions; `Test-DFConflictPrompt` (Helpers private, "can ask").
- Produces: `Set-DFDesktopEnv [-Name <string[]>]` (`SupportsShouldProcess`, `ConfirmImpact = 'High'`) → `DotForge.DesktopEnvResult` per variable: `Tool`, `Name`, `Value`, `Current`, `Action` ∈ `Set | AlreadySet | Kept | Replaced`. `Read-DFDesktopEnvChoice -Name -Current -Value` → `'K'` or `'R'` (private, mockable).

Order inside the command: resolve tools (`-Name` → `Import-DFToolDb -Name`; else `@(Get-DFConfig Tools)` expanded the way the session expands groups — call the existing expander, don't re-implement) → expected values → classify each against `Get-DFDesktopEnvValue` → for differing ones, ask (`Read-DFDesktopEnvChoice`) only when `Test-DFConflictPrompt` and `$ConfirmPreference -ne 'None'`, else `Kept` → one `ShouldProcess` listing every write → write → `Send-DFEnvironmentChange` once if anything was written → record `Set`/`Replaced`/`AlreadySet` in the state (an `AlreadySet` variable already recorded for another tool keeps its owner) → print one line: new programs see the change, running ones don't.

- [ ] **Step 1: Write the failing tests** (komorebi-shaped user record `deska` with `xdg.vars.DESK_A = '${XDG_CONFIG_HOME}/deska'`, `desktop = DESK_A`; registry at the scratch key; `Mock Send-DFEnvironmentChange {}`)
  - `writes a missing variable, broadcasts once and records it` — Action `Set`, value in the scratch key, `Should -Invoke Send-DFEnvironmentChange -Times 1 -Exactly`, state `DESK_A.tool -eq 'deska'`.
  - `an equal value is AlreadySet, recorded, and not broadcast` — `-Times 0`.
  - `a different value is kept, and reported, when it can't ask` — `Mock Test-DFConflictPrompt { $false }` → `Kept`, value unchanged, not recorded.
  - `asks per differing variable in a console; R replaces` — `Mock Test-DFConflictPrompt { $true }`, `Mock Read-DFDesktopEnvChoice { 'R' }` → `Replaced`.
  - `-Confirm:$false never asks, and keeps yours` — prompt mocks as above → `Read-DFDesktopEnvChoice` invoked 0 times, `Kept` (**RF2**).
  - `-WhatIf writes and records nothing`.
  - `a second tool declaring the same variable doesn't take over its record` (**RF4**).
  - `writes nothing when the state file can't be read` — corrupt `desktop-env.json` → error mentioning the path; value absent (**RF5**).
  - `without -Name, covers the session's requested tools` — `Set-DFTestConfig @{ Tools = @('deska') }`.
  - `says it's Windows-only off Windows` — `Mock Test-DFIsWindows { $false }` (add that one-line seam to `Shared/DFDesktopEnv.ps1` if no such seam exists) → nothing written, a message.

- [ ] **Step 2: Run them.** Expected: FAIL (command missing).
- [ ] **Step 3: Implement** with complete comment-based help (`.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER Name`, two `.EXAMPLE`s incl. `-WhatIf`, `.OUTPUTS`); add to `FunctionsToExport`. Check `Get-Command Set-DFDesktopEnv` has no collision.
- [ ] **Step 4: Run them.** Expected: PASS, plus `tests/ModuleSplit.Tests.ps1` and `tests/Docs.Help.Tests.ps1`.

---

### Task 4: Removing — `Remove-DFDesktopEnv` and `Remove-DFTool`

**Files:**
- Modify: `Shared/DFDesktopEnv.ps1` (shared removal step)
- Create: `Modules/DotForge.Helpers/Public/Remove-DFDesktopEnv.ps1`
- Modify: `Public/Remove-DFTool.ps1` (next to `Remove-DFToolLinkSet`, ~line 98), `Modules/DotForge.Helpers/DotForge.Helpers.psd1`
- Test: `tests/Set-DFDesktopEnv.Tests.ps1`, `tests/Remove-DFTool.Tests.ps1`

**Interfaces:**
- Produces: `Remove-DFDesktopEnvSet -Tool <string[]>` (Shared) → result per recorded variable, `Action` ∈ `Removed | Changed` (left: value no longer DotForge's); removes the state entries it handled; broadcasts once if it removed any. `Remove-DFDesktopEnv [-Name <string[]>]` (`SupportsShouldProcess`, High) calls it for the named tools, or every tool in the state when no name.

- [ ] **Step 1: Write the failing tests**
  - `removes a variable DotForge wrote, and its record`.
  - `leaves a variable you changed since, and says so` — recorded `x`, current `y` → `Changed`, still `y`, record dropped (**RF3**).
  - `Remove-DFTool removes the tool's desktop variables` (Remove-DFTool tests, with the scratch key and the existing manager mocks).
  - `does nothing, and says why, when the state can't be read` (**RF5**).
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement**; help as in Task 3.
- [ ] **Step 4: Run them.** Expected: PASS.
- [ ] **Step 5: Regenerate the bundle.**

---

### Task 5: Status note at load

**Files:**
- Modify: `Private/Invoke-DFSessionActivation.ps1` (~line 108, the Active `-Detail`)
- Test: `tests/Activation.Ownership.Tests.ps1` (or a new `tests/Activation.DesktopEnv.Tests.ps1`)

**Interfaces:**
- Consumes: `Get-DFDesktopEnvNote -Tool`.

- [ ] **Step 1: Write the failing tests**
  - `an active tool's status says which desktop variables desktop apps lack` — `Register-DFTool -Name deska` → `(Get-DFToolStatus deska).Detail` matches `isn't set for desktop apps`.
  - `no note once the value is set` — value written to the scratch key first.
  - `a record without desktop reads no registry` — `Mock Get-DFDesktopEnvValue {}`; registering a plain tool → invoked 0 times.
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement**: append `@(Get-DFDesktopEnvNote -Tool $tool)` to the Active detail; it returns early for an empty `desktop`.
- [ ] **Step 4: Run them.** Expected: PASS.
- [ ] **Step 5: Regenerate the bundle; measure** `./build/Measure-DFStartup.ps1` before (on `main`) and after. Expected: no measurable change for a config without komorebi.

---

### Task 6: komorebi record, docs, close T-78

**Files:**
- Create: `Tools/komorebi.json`
- Modify: `docs/guide/configuration.md` (new "Desktop apps" section), `docs/guide/writing-a-tool.md` (`desktop`), `docs/guide/tools.md` (komorebi), `CLAUDE.md` (schema bullet for `desktop`), `CHANGELOG.md` ([Unreleased]), `docs/superpowers/specs/2026-10-24-restore-install-locations-notes.md` (Phase 2: done), `TODO.md` (delete T-78), regenerate registry and reference.

- [ ] **Step 1:** Write `Tools/komorebi.json`: `executable: komorebic`, `packages`: scoop `komorebi` (extras; check the bucket spelling other extras records use) and winget `LGUG2Z.komorebi` (verify with `winget show LGUG2Z.komorebi` — read-only), `xdg.method: env`, `xdg.vars.KOMOREBI_CONFIG_HOME = ${XDG_CONFIG_HOME}/komorebi`, `xdg.native`: `KOMOREBI_CONFIG_HOME` → `[]`, plus target keys `${XDG_CONFIG_HOME}/komorebi/komorebi.json` → `${HOME}/komorebi.json`, `…/applications.json` → `${HOME}/applications.json`, `…/komorebi.bar.json` → `${HOME}/komorebi.bar.json`; `desktop: ["KOMOREBI_CONFIG_HOME"]`; a short `description`.
- [ ] **Step 2:** Run `tests/ToolNative.Coverage.Tests.ps1`, `tests/ToolRegistry.Tests.ps1` and the schema tests after `Build-DFToolRegistry.ps1`. Expected: PASS.
- [ ] **Step 3:** Docs. Doc code blocks that would write the registry are marked `<!-- system -->`.
- [ ] **Step 4:** `Build-DFReferenceDocs.ps1`, `Build-DFCoreBundle.ps1`; full gate `pwsh -NoProfile -File build/Test-DFFull.ps1`. Expected: 0 failed, no sentinel files, and the scratch registry root `HKCU:\Software\DotForge-Tests` holds no keys afterwards.
- [ ] **Step 5: Commit** (one signed commit, `Closes T-78`).
