# Install Environment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every install, update, remove and feed command DotForge runs through a package manager sees the location variables of the tools it acts on, of the manager, and of the tools the manager requires, for that command only.

**Architecture:** A new private `Get-DFInstallEnvironment` builds an ordered variable → value dictionary from records. `Invoke-DFManagerCommand` (still the only place a manager runs) gains `-Environment`: it sets what isn't owned from outside, runs the command, and restores in a `finally`, leaving any value the command itself changed. The three callers (`Invoke-DFManagerBatch`, `Invoke-DFInstallPlan`, `Invoke-DFManagerOperation`) pass it through.

**Tech Stack:** PowerShell 7.2+, Pester 6.

**Spec:** `docs/superpowers/specs/2026-10-25-install-environment-design.md`

## Global Constraints

- Only `xdg.vars` of records whose `xdg.method` is `env`; never the top-level `env` map. Values through `Expand-DFXdgPath`.
- Source order, later wins on a different value (with a verbose message naming both): tools → manager → manager's `requires` chain (transitive, tool references only via `ConvertFrom-DFToolReference`; `role:` never followed; a name missing from `-ToolDb` skipped).
- A variable is set only if unset or equal to `(Get-DFEnvState).Written[<name>]`; otherwise kept, with a verbose message.
- `Get-DFEnvState` is never modified by any of this.
- After the command (also when it throws), each variable DotForge set goes back to its previous value (removed if it was unset) — unless its current value is no longer the one DotForge set, in which case the command's value stays.
- `list` and `outdated` commands get no environment. `RunAs` cannot carry it (documented, not worked around).
- No test runs a real package manager (`Invoke-DFManagerCommand` is mocked, or a stub function / tiny `pwsh -NoProfile -Command` stands in).
- Work in worktree `../DotForge-install-env` on branch `install-env`. The spec, this plan, the notes edit and the `TODO.md` edits are uncommitted in the main checkout: move them into the worktree first, so the main checkout is clean. Commits are signed; batch them in Task 4.
- The dotfiles half of the spec (packages script) is out of this plan: it waits for a Gallery release.

## Review Focus

1. A command whose executable doesn't exist (`& $exe` throws) — variables must still be restored. Test in Task 2.
2. An outside value that already equals what the tool wants — kept as is, and *not removed* afterwards. Test in Task 2.
3. Two manager commands in a row (feed add, then install) — the second starts from the session's values, nothing leaks from the first. Test in Task 3.
4. A manager with no `xdg` block and tools with none (most records) — empty environment, command runs exactly as before. Test in Task 1 and Task 3 (existing tests stay green).
5. A cycle in `requires` (a → b → a) — the chain walk terminates. Test in Task 1.

---

### Task 1: `Get-DFInstallEnvironment`

**Files:**
- Create: `Private/Get-DFInstallEnvironment.ps1`
- Test: `tests/Get-DFInstallEnvironment.Tests.ps1`

**Interfaces:**
- Produces: `Get-DFInstallEnvironment -Tool <pscustomobject[]> -Manager <pscustomobject> -ToolDb <hashtable>` → `[System.Collections.Specialized.OrderedDictionary]` (name → expanded string). `-Tool` may be empty (`@()`) for feed commands.

- [ ] **Step 1: Write the failing tests.** BeforeAll: the shared loader, plus `function script:Rec([string]$Json) { ConvertTo-DFToolRecord ($Json | ConvertFrom-Json) }`. BeforeEach `Set-DFTestXdg`, AfterEach `Restore-DFTestXdg`. Records: `rustup` (env; `RUSTUP_HOME=${XDG_DATA_HOME}/rustup`, `CARGO_HOME=${XDG_DATA_HOME}/cargo`), `cargo` (`requires: ["rustup"]`, no xdg), `fnm` (env; `FNM_DIR=${XDG_DATA_HOME}/fnm`), `bat` (env; `BAT_CONFIG_DIR=${XDG_CONFIG_HOME}/bat`; top-level `env: { BAT_THEME: "x" }`), `wrapped` (method `wrapper`, vars `{ W: "${XDG_CONFIG_HOME}/w" }`), `pipx` (`requires: ["role:python-runtime"]`), `ghost` (`requires: ["nothere"]`), `a`/`b` requiring each other. Tests:
  - `returns the tool's own variables` — `-Tool bat -Manager scoop(no xdg)` → keys `@('BAT_CONFIG_DIR')`, value `Join-Path $env:XDG_CONFIG_HOME 'bat'` (compare through `ConvertTo-DFPath`).
  - `adds the manager's variables` — `-Tool @() -Manager fnm` → `FNM_DIR`.
  - `follows the manager's requires chain` — `-Tool @() -Manager cargo` → keys contain `RUSTUP_HOME`, `CARGO_HOME`.
  - `doesn't follow a role requirement` — `-Manager pipx` → `Count | Should -Be 0`.
  - `skips a required tool with no record` — `-Manager ghost` → `Count 0`, no error.
  - `stops on a requires cycle` — `-Manager a` returns (both a's and b's vars if given; give `a` var `A_HOME`, `b` var `B_HOME` → both keys).
  - `ignores the env map and non-env methods` — `-Tool bat, wrapped` → keys `@('BAT_CONFIG_DIR')`.
  - `lets the later source win a clash, verbosely` — tool `t1` with `FNM_DIR=${XDG_CACHE_HOME}/x`, `-Manager fnm` → value is fnm's; `-Verbose 4>&1` output matches `*FNM_DIR*`.

- [ ] **Step 2: Run** `./build/Test-DFFull.ps1 -Path tests/Get-DFInstallEnvironment.Tests.ps1`. Expected: FAIL, `Get-DFInstallEnvironment` not recognized.

- [ ] **Step 3: Implement** in the new file, with full comment-based help in the style of `Invoke-DFManagerBatch` (SYNOPSIS, DESCRIPTION, PARAMETER each, OUTPUTS). The chain walk is a queue over `requires` with a visited set; read each entry through `ConvertFrom-DFToolReference` and take `Kind -eq 'Tool'` only. Add per source in order: each `-Tool`, `-Manager`, then the chain. Expand with `Expand-DFXdgPath`.

- [ ] **Step 4: Run** the same command. Expected: PASS, 8/8.

- [ ] **Step 5: Confirm the loader picks the file up**: `./build/Build-DFCoreBundle.ps1`, then `./build/Test-DFFull.ps1 -Path tests/CoreBundle.Tests.ps1, tests/ModuleSplit.Tests.ps1`. Expected: PASS. (If the module or bundle uses a hand-kept file list, add the file there.) No commit yet.

### Task 2: `Invoke-DFManagerCommand -Environment`

**Files:**
- Modify: `Private/Invoke-DFManagerCommand.ps1` (`Invoke-DFManagerCommand`)
- Test: `tests/Invoke-DFManagerCommand.Tests.ps1` (new `Describe 'Invoke-DFManagerCommand -Environment'`)

**Interfaces:**
- Consumes: nothing from Task 1 (takes any `IDictionary`).
- Produces: `Invoke-DFManagerCommand ... [-Environment <System.Collections.IDictionary>]`; omitted or empty = today's behavior.

- [ ] **Step 1: Write the failing tests.** Use a variable name unique per test, `DF_TEST_<guid8>`, and remove it in `AfterEach` (`Remove-Item Env:\$name -ErrorAction Ignore`). Save and restore `$global:DFEnvState` around the Describe (`BeforeEach`: `$script:SavedState = $global:DFEnvState; $global:DFEnvState = $null`; `AfterEach` puts it back). The probe is a stub `function script:Probe { param($Name) [Environment]::GetEnvironmentVariable($Name) }` called through `-Function Probe -Arguments @{ Name = $name }` (its output is `ExitCode 0; Output = <value>`). Tests:
  - `passes an unset variable to the command` — Output trimmed `| Should -Be 'C:\x'`; afterwards `Test-Path Env:\$name | Should -BeFalse`.
  - `updates a variable DotForge wrote` — `$env:<name> = 'old'`, `(Get-DFEnvState).Written[$name] = 'old'`; command sees `'new'`; afterwards value is `'old'`.
  - `keeps a variable set outside DotForge` — `$env:<name> = 'mine'` (not in Written); command sees `'mine'`; `-Verbose 4>&1` has a line matching `*$name*`; afterwards `'mine'`.
  - `leaves an outside value that equals the wanted one in place` — `$env:<name> = 'C:\x'`, Environment wants `'C:\x'`; afterwards still `'C:\x'` (not removed).
  - `restores after the command throws` — stub `function script:Boom { throw 'no' }`; result `ExitCode 1`; variable unset afterwards.
  - `restores after an argv whose program doesn't exist` — `-Argv 'df-no-such-exe-zz'` inside `try {} catch {}`; variable unset afterwards.
  - `keeps a value the command itself set` — stub `function script:SetsIt { param($Name) Set-Item Env:\$Name 'from-manager' }`; afterwards `'from-manager'`.
  - `passes the variables to a child process` — `-Argv (Get-Process -Id $PID).Path, '-NoProfile', '-Command', "`$env:$name"`; Output trimmed `'C:\x'`.
  - `leaves Get-DFEnvState unchanged` — after a run, `(Get-DFEnvState).Written.Count | Should -Be 0` and `Kept.Count` 0.

- [ ] **Step 2: Run** `./build/Test-DFFull.ps1 -Path tests/Invoke-DFManagerCommand.Tests.ps1`. Expected: the new tests FAIL (parameter `Environment` not found); the old ones pass.

- [ ] **Step 3: Implement.** Add `[System.Collections.IDictionary]$Environment`, help `.PARAMETER Environment` (the rules above and that RunAs can't carry them), and wrap the body: a private helper pair in the same file, `Set-DFCommandEnvironment -Environment` → returns a list of `{ Name; Previous; Set }` for what it changed (writes nothing to `Get-DFEnvState`; verbose line for each kept one: `DotForge: keeping <name>=<value> set outside DotForge for this <manager> command`), and `Restore-DFCommandEnvironment -Changes` (restores only where current value `-ceq` `Set`). Call the restore in `finally` around both the function path and the argv path (so the early `return`s go through it).

- [ ] **Step 4: Run** the same command. Expected: PASS, all tests in the file.

- [ ] **Step 5: Verify elevation by hand (no test).** With gsudo present, run in a scratch pwsh: `$env:DF_PROBE='yes'; gsudo pwsh -NoProfile -Command '$env:DF_PROBE'`; and, if Windows sudo is enabled in inline mode, `sudo pwsh -NoProfile -Command '$env:DF_PROBE'`. This prompts UAC, so ask the user to run them (`! ...`) if needed. Record the result in the spec's table. Ruling if either prints nothing: when `-Environment` is non-empty and the method is that one, append to the result's Output `"(DotForge's install variables were not passed through <method>: <names>)"`, with a test. If both print `yes`, no code change.

### Task 3: Callers pass the environment

**Files:**
- Modify: `Private/Invoke-DFManagerBatch.ps1` (`Invoke-DFManagerBatch`, `Invoke-DFManagerOperation`)
- Modify: `Private/Invoke-DFInstallPlan.ps1`
- Modify: `Public/Update-DFTool.ps1:80`, `Public/Remove-DFTool.ps1:94`
- Test: `tests/Invoke-DFManagerBatch.Tests.ps1`, `tests/Invoke-DFInstallPlan.Tests.ps1`, `tests/Update-DFTool.Tests.ps1`, `tests/Remove-DFTool.Tests.ps1`

**Interfaces:**
- Consumes: Task 1's `Get-DFInstallEnvironment`, Task 2's `-Environment`.
- Produces: `Invoke-DFManagerBatch ... [-Environment <IDictionary>]`; `Invoke-DFManagerOperation ... -Tool <pscustomobject[]>` (Mandatory).

- [ ] **Step 1: Write the failing tests.**
  - `Invoke-DFManagerBatch`: `passes -Environment to every manager command` — mock `Invoke-DFManagerCommand`, non-batch block with two ids, `-Environment ([ordered]@{ X = 'y' })` → `Should -Invoke Invoke-DFManagerCommand -Times 2 -Exactly -ParameterFilter { $Environment['X'] -eq 'y' }`. Same for a `{ function; args }` block.
  - `Invoke-DFInstallPlan`: give `fnm` in the test Db `"xdg": { "method": "env", "vars": { "FNM_DIR": "${XDG_DATA_HOME}/fnm" } }` and `glow` `"xdg": { "method": "env", "vars": { "GLOW_X": "${XDG_CONFIG_HOME}/glow" } }`. Make the existing mock also record `$Environment` keys per call (`$script:Envs.Add((@($Environment.Keys) -join ','))`, empty when null). Tests: `gives a batch its tools' variables` (scoop batch installing fnm, glow → that call's keys contain `FNM_DIR` and `GLOW_X`); `gives the manager's variables to its own installs` (fnm installing node → keys contain `FNM_DIR`); `gives feed commands the manager's variables only` (dotenv via insomnia feed, scoop given an xdg var `SCOOP_X`: the `bucket list`/`bucket add` calls have `SCOOP_X` and not the tool's). Review Focus 3: `doesn't carry a feed command's variables into the next command` — covered by asserting each call's own key set.
  - `Update-DFTool` / `Remove-DFTool`: the existing mocks of `Invoke-DFManagerBatch` gain an assertion `Should -Invoke Invoke-DFManagerBatch -ParameterFilter { $Environment -and $Environment.Contains('<VAR>') }` with the tested tool given an env xdg var.

- [ ] **Step 2: Run** `./build/Test-DFFull.ps1 -Path tests/Invoke-DFManagerBatch.Tests.ps1, tests/Invoke-DFInstallPlan.Tests.ps1, tests/Update-DFTool.Tests.ps1, tests/Remove-DFTool.Tests.ps1`. Expected: the new assertions FAIL; the rest pass.

- [ ] **Step 3: Implement.**
  - `Invoke-DFManagerBatch`: add `-Environment`, pass it on both `Invoke-DFManagerCommand` calls; help line.
  - `Invoke-DFInstallPlan`: per batch, `$environment = Get-DFInstallEnvironment -Tool @($ready | ForEach-Object { $ToolDb[$_.Tool] }) -Manager $m -ToolDb $ToolDb` passed to `Invoke-DFManagerBatch`; the feed `list`/`add` calls get `Get-DFInstallEnvironment -Tool @() -Manager $m -ToolDb $ToolDb`. Add a bullet to the DESCRIPTION.
  - `Invoke-DFManagerOperation`: add Mandatory `[pscustomobject[]]$Tool` (help: the tools being updated or removed, for their variables) and build the environment from it, `$Found.Manager` and `$ToolDb`.
  - `Update-DFTool`: `-Tool @($tools | ForEach-Object { $db[$_] })`; `Remove-DFTool`: `-Tool $db[$toolName]`.

- [ ] **Step 4: Run** the same command. Expected: PASS.

### Task 4: Docs, generated files, backlog, gate, merge

**Files:**
- Modify: `docs/guide/safety.md` (section "Programs DotForge runs"), `docs/guide/tools.md` (section "rustup, vcpkg and other relocated tools"), `CHANGELOG.md` (`[Unreleased]` → `### Changed`), `TODO.md` (delete T-76 and T-77), `docs/superpowers/specs/2026-10-24-restore-install-locations-notes.md` (mark piece 3 done)
- Regenerate: `Bundle/DotForge.Core.ps1`, `docs/reference.md`

- [ ] **Step 1: Docs.** safety.md: one paragraph — while a manager runs, DotForge sets the location variables of the tools involved for that command only, never over a value set outside DotForge, and puts them back afterwards; a separate administrator window (choco) doesn't get them. tools.md: say that installing rustup or a crate with cargo now lands in the relocated folders without setting anything first. CHANGELOG bullet naming T-76/T-77 behavior. Mark any code block `<!-- system -->` if it installs.

- [ ] **Step 2: Regenerate** `./build/Build-DFCoreBundle.ps1` and `./build/Build-DFReferenceDocs.ps1`.

- [ ] **Step 3: Full gate** `./build/Test-DFFull.ps1`. Expected: 0 failed.

- [ ] **Step 4: Commit** (signed; one commit for code, one for docs is fine), including the spec, this plan and the notes edit:

```bash
git add -A
git commit -m "feat: installers see their tools' location variables (Closes T-76, Closes T-77)"
```

- [ ] **Step 5: Fast-forward `main` and push** (standing permission after a green full run); remove the worktree after leaving it.
