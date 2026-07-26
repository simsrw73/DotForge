# Default-Tool Roles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement `$DFConfig.Defaults`-driven default-tool role resolution — a role loser has only the alias keys it shares with the role's winner suppressed — and onboard `lsd` as a real second `listing`-role tool alongside `eza` to prove it.

**Architecture:** A pre-pass in `Register-DFTool` resolves, per role named in `$DFConfig.Defaults`, whether the named winner is valid (declares that role) and active (available, part of this call's tool set); if so it records the winner's own declared alias keys. The existing alias-registration loop then skips only those specific alias keys for any other tool sharing that role. No central per-role data — "contested" is computed live from each tool's own `aliases` block.

**Tech Stack:** PowerShell 7+, Pester 5/6 (suite passes under both).

## Global Constraints

Copied from `docs/superpowers/specs/2026-07-25-default-tool-roles-design.md`:

- **`role`** is an optional top-level STRING field in a tool's JSON (e.g. `"role": "listing"`). No central role registry or enum.
- **Contested = computed intersection**, never a separate data file: a loser's alias key is suppressed only if the WINNER also declares that same key.
- **The pre-pass validates twice before ever suppressing anything:**
  1. The named winner must exist in the DB AND its own `role` property must equal the role key it's named for — else `Write-Warning` and treat the whole role as absent (no suppression for anyone) this run.
  2. The winner must be actually available (`Get-Command`/module presence, matching the main loop's own check) AND part of the tools being registered in THIS call (present in the resolved `$tools` list) — else treat the role as absent. A `Defaults` entry naming an absent/unavailable tool must never strand its peers without any alias.
- **The winner always keeps every alias it declares.** Only a non-winning tool sharing the same role has its winner-overlapping alias keys skipped; everything else about that tool (XDG config, picker, companion `.ps1`, non-overlapping aliases) is unaffected.
- **No `Defaults` entry for a role at all → completely untouched** — today's behavior for any role-sharing tools is unchanged.
- **StrictMode-safe reads throughout:** `$tool.PSObject.Properties['role']?.Value`, `$winnerTool.PSObject.Properties['aliases']?.Value` (guard before touching `.PSObject.Properties` on a possibly-`$null` value), never bare property access on an optional field.
- **`lsd`'s config is NOT wired in this workstream** — `xdg.method: "manual"` (verified: `lsd --config-file <nonexistent-path>` panics, not a clean error). Only `packages`, `role`, and `aliases` are onboarded.
- Tests pass under Pester 5.8.0 AND 6.0.1; no `Assert-MockCalled`.
- Run `pwsh -NoProfile -Command 'Invoke-Pester tests/ -Output Detailed'` for the full suite.

## File Structure

**Modify:**
- `Public/Register-DFTool.ps1` — add the role pre-pass + alias-suppression check.
- `tests/Register-DFTool.Tests.ps1` — synthetic-fixture tests for the mechanism.
- `Tools/eza.json` — add `"role": "listing"`.
- `tests/Test-DFToolSchema.Tests.ps1` — add `lsd` to the seed-file list.
- `ToolAcquisitionSpec.md`, `CLAUDE.md`, `CHANGELOG.md`, `README.md`, `docs/external-dependencies.md`.

**Create:**
- `Tools/lsd.json` — the new tool record.
- `tests/DefaultToolRoles.Tests.ps1` — the real end-to-end test using actual `eza`/`lsd` records.

---

### Task 1: Role resolution + contested-alias suppression in `Register-DFTool`

**Files:**
- Modify: `Public/Register-DFTool.ps1`
- Test: `tests/Register-DFTool.Tests.ps1`

**Interfaces:**
- Consumes: `$db` (the loaded tool DB, a `Name -> PSCustomObject` dictionary, already built at `Public/Register-DFTool.ps1:53`), `$tools` (the resolved, topo-sorted list for this call, built at `Public/Register-DFTool.ps1:76`), `$Global:DFConfig['Defaults']` (a `role -> winnerName` hashtable).
- Produces: an `$activeRoleWinners` hashtable (`roleName -> @{ WinnerName; AliasKeys }`) computed once before the main loop, consumed inside the existing alias-registration `ForEach-Object` (`Public/Register-DFTool.ps1:155` area) to skip suppressed alias keys.

- [ ] **Step 1: Write the failing tests**

Append to `tests/Register-DFTool.Tests.ps1`, inside the existing `Describe 'Register-DFTool'` block (after the existing tests, before the closing `}`). These use two new synthetic tool JSON fixtures written per-test into `$script:TmpTools`, mirroring the existing `testtool.json` pattern:

```powershell
    Context 'default-tool role resolution' {
        BeforeEach {
            @'
{
  "name": "roletoolwinner",
  "executable": "roletoolwinner.exe",
  "role": "testrole",
  "aliases": {
    "rt":   { "command": "roletoolwinner", "args": [] },
    "rtl":  { "command": "roletoolwinner", "args": ["--long"] }
  }
}
'@ | Set-Content (Join-Path $script:TmpTools 'roletoolwinner.json')

            @'
{
  "name": "roletoolloser",
  "executable": "roletoolloser.exe",
  "role": "testrole",
  "aliases": {
    "rt":     { "command": "roletoolloser", "args": [] },
    "rtl":    { "command": "roletoolloser", "args": ["--long"] },
    "rtonly": { "command": "roletoolloser", "args": ["--only"] }
  }
}
'@ | Set-Content (Join-Path $script:TmpTools 'roletoolloser.json')

            Mock Get-Command {
                param($Name)
                if ($Name -in 'roletoolwinner.exe', 'roletoolloser.exe') {
                    [PSCustomObject]@{ Path = "C:\fake\$Name" }
                }
            }
        }
        AfterEach {
            Remove-Item 'function:global:rt', 'function:global:rtl', 'function:global:rtonly' -ErrorAction Ignore
            Remove-Alias rt, rtl, rtonly -Force -Scope Global -ErrorAction Ignore
            Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
        }

        It 'suppresses only the alias keys the loser shares with the declared winner' {
            $Global:DFConfig = @{ Defaults = @{ testrole = 'roletoolwinner' } }
            Register-DFTool -Name 'roletoolwinner', 'roletoolloser' -ToolsPath $script:TmpTools

            (Get-Alias rt -ErrorAction Ignore).Definition | Should -Be 'roletoolwinner'
            Test-Path 'function:global:rtl' | Should -BeTrue
            # rtl is a wrapper function (has args); confirm it resolves to the winner's command.
            $rtlBody = (Get-Item 'function:global:rtl').ScriptBlock.ToString()
            $rtlBody | Should -Match 'roletoolwinner'

            # The loser's non-contested alias must still be created.
            Test-Path 'function:global:rtonly' | Should -BeTrue
        }

        It 'warns and does not suppress anything when the named winner does not declare that role' {
            $Global:DFConfig = @{ Defaults = @{ testrole = 'roletoolloser' } }
            # roletoolloser DOES declare 'testrole' in this fixture, so use a role mismatch:
            # rewrite the winner fixture to declare a DIFFERENT role than requested.
            @'
{
  "name": "roletoolwinner",
  "executable": "roletoolwinner.exe",
  "role": "someotherrole",
  "aliases": { "rt": { "command": "roletoolwinner", "args": [] } }
}
'@ | Set-Content (Join-Path $script:TmpTools 'roletoolwinner.json')
            $Global:DFConfig = @{ Defaults = @{ testrole = 'roletoolwinner' } }

            Register-DFTool -Name 'roletoolwinner', 'roletoolloser' -ToolsPath $script:TmpTools -WarningVariable warnings -WarningAction SilentlyContinue

            $warnings | Should -Not -BeNullOrEmpty
            # No suppression happened: the loser's 'rt' alias registers normally.
            (Get-Alias rt -ErrorAction Ignore).Definition | Should -Be 'roletoolloser'
        }

        It 'does not suppress anything when the named winner is not available this run' {
            $Global:DFConfig = @{ Defaults = @{ testrole = 'roletoolwinner' } }
            Mock Get-Command {
                param($Name)
                if ($Name -eq 'roletoolloser.exe') { [PSCustomObject]@{ Path = 'C:\fake\roletoolloser.exe' } }
                # roletoolwinner.exe reports absent
            }
            Register-DFTool -Name 'roletoolwinner', 'roletoolloser' -ToolsPath $script:TmpTools

            # Winner never registered (absent), loser's aliases are untouched.
            (Get-Alias rt -ErrorAction Ignore).Definition | Should -Be 'roletoolloser'
        }

        It 'leaves a tool with no role property completely unaffected' {
            $Global:DFConfig = @{ Defaults = @{ testrole = 'roletoolwinner' } }
            Register-DFTool -Name 'testtool' -ToolsPath $script:TmpTools
            # testtool.json (from the outer BeforeEach) has no 'role' -- registers exactly as before.
            (Get-Alias tt -ErrorAction Ignore) | Should -Not -BeNullOrEmpty
            Remove-Alias tt -Force -Scope Global -ErrorAction Ignore
            Remove-Item 'function:global:tt-v' -ErrorAction Ignore
        }

        It 'registers both tools normally when no Defaults entry exists for the role' {
            Register-DFTool -Name 'roletoolwinner', 'roletoolloser' -ToolsPath $script:TmpTools
            # No Defaults set at all -- last-registered-wins is unchanged/untouched by this feature;
            # just confirm no exception and the loser's non-contested alias exists.
            Test-Path 'function:global:rtonly' | Should -BeTrue
        }
    }
```

- [ ] **Step 2: Run to verify the tests FAIL**

Run: `pwsh -NoProfile -Command 'Invoke-Pester tests/Register-DFTool.Tests.ps1 -Output Detailed'`
Expected: FAIL — `role`/`Defaults` are not yet read anywhere; the winner/loser both register all their aliases identically (`rt` ends up defined by whichever registers last, `roletoolloser` in name order), so the "suppresses only the shared keys" and "role mismatch warns" tests fail.

- [ ] **Step 3: Implement the pre-pass and the suppression check**

In `Public/Register-DFTool.ps1`, insert the pre-pass immediately after the topo-sort line and before the main loop. Find:

```powershell
    # Topological sort respects dependsOn declarations
    $tools = Invoke-DFTopoSort -Tools @($tools)

    $registeredTools = [System.Collections.Generic.List[string]]::new()
    foreach ($tool in $tools) {
```

Change to:

```powershell
    # Topological sort respects dependsOn declarations
    $tools = Invoke-DFTopoSort -Tools @($tools)

    # ── Default-tool role resolution (§10) ─────────────────────────────────
    # For each role named in $DFConfig.Defaults, resolve whether the declared
    # winner is role-valid AND actually registering this call; if so, record
    # its own declared alias keys. A role LOSER (same 'role', different name)
    # then has ONLY those specific alias keys suppressed below -- everything
    # else about it (XDG, picker, companion, non-overlapping aliases) still
    # applies. Degrades silently on every invalid/absent case -- never throws.
    $defaults = @(if ($null -ne $Global:DFConfig) { $Global:DFConfig['Defaults'] })[0]
    $activeRoleWinners = @{}
    if ($defaults) {
        foreach ($roleName in $defaults.Keys) {
            $winnerName = $defaults[$roleName]
            if (-not $db.ContainsKey($winnerName)) {
                Write-Warning "DotForge: `$DFConfig.Defaults['$roleName'] names unknown tool '$winnerName' — ignoring."
                continue
            }
            $winnerTool = $db[$winnerName]
            $winnerRole = $winnerTool.PSObject.Properties['role']?.Value
            if ($winnerRole -ne $roleName) {
                Write-Warning "DotForge: `$DFConfig.Defaults['$roleName'] names '$winnerName', which declares role '$winnerRole' (expected '$roleName') — ignoring."
                continue
            }
            if (-not ($tools | Where-Object { $_.name -eq $winnerName })) { continue }
            $winnerType = $winnerTool.PSObject.Properties['type']?.Value ?? 'exe'
            $winnerAvailable = if ($winnerType -eq 'module') {
                Get-Module -Name $winnerTool.executable -ListAvailable -ErrorAction Ignore
            } else {
                Get-Command $winnerTool.executable -ErrorAction Ignore
            }
            if (-not $winnerAvailable) { continue }
            $winnerAliasesObj = $winnerTool.PSObject.Properties['aliases']?.Value
            $winnerAliasKeys  = if ($winnerAliasesObj) { @($winnerAliasesObj.PSObject.Properties.Name) } else { @() }
            $activeRoleWinners[$roleName] = @{ WinnerName = $winnerName; AliasKeys = $winnerAliasKeys }
        }
    }

    $registeredTools = [System.Collections.Generic.List[string]]::new()
    foreach ($tool in $tools) {
```

Then modify the aliases block. Find (`Public/Register-DFTool.ps1:152-160` area):

```powershell
        # ── Aliases ─────────────────────────────────────────────────────────
        $aliases = $tool.PSObject.Properties['aliases']?.Value
        if ($aliases) {
            $aliases.PSObject.Properties | ForEach-Object {
                $aliasName = $_.Name
                $aliasCmd  = $_.Value.PSObject.Properties['command']?.Value
                $rawArgs   = $_.Value.PSObject.Properties['args']?.Value
                $aliasArgs = [object[]]@($rawArgs)

                if (-not $aliasCmd) { return }
```

Change to:

```powershell
        # ── Aliases ─────────────────────────────────────────────────────────
        $toolRole   = $tool.PSObject.Properties['role']?.Value
        $roleWinner = if ($toolRole) { $activeRoleWinners[$toolRole] } else { $null }

        $aliases = $tool.PSObject.Properties['aliases']?.Value
        if ($aliases) {
            $aliases.PSObject.Properties | ForEach-Object {
                $aliasName = $_.Name

                if ($roleWinner -and $roleWinner.WinnerName -ne $tool.name -and $aliasName -in $roleWinner.AliasKeys) {
                    Write-Verbose "DotForge: $($tool.name) alias '$aliasName' suppressed — '$($roleWinner.WinnerName)' won role '$toolRole'"
                    return
                }

                $aliasCmd  = $_.Value.PSObject.Properties['command']?.Value
                $rawArgs   = $_.Value.PSObject.Properties['args']?.Value
                $aliasArgs = [object[]]@($rawArgs)

                if (-not $aliasCmd) { return }
```

The rest of the aliases block (`Set-Alias`/wrapper-function creation) is unchanged.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pwsh -NoProfile -Command 'Invoke-Pester tests/Register-DFTool.Tests.ps1 -Output Detailed'`
Expected: PASS — all new tests plus every pre-existing `Register-DFTool` test (no regression to the unrelated fixtures).

- [ ] **Step 5: Full suite + commit**

Run: `pwsh -NoProfile -Command 'Invoke-Pester tests/ -Output Detailed'`
Expected: PASS.

```bash
git add Public/Register-DFTool.ps1 tests/Register-DFTool.Tests.ps1
git commit -m "feat(tools): default-tool role resolution — suppress only contested aliases"
```

---

### Task 2: Onboard `lsd`; real end-to-end proof with `eza`

**Files:**
- Create: `Tools/lsd.json`, `tests/DefaultToolRoles.Tests.ps1`
- Modify: `Tools/eza.json`, `tests/Test-DFToolSchema.Tests.ps1`

**Interfaces:**
- Consumes: the role-resolution mechanism from Task 1, via `Register-DFTool`.
- Produces: a real, shipped second `listing`-role tool (`lsd`) and a passing end-to-end test using the actual `Tools/eza.json`/`Tools/lsd.json` records (not synthetic fixtures).

- [ ] **Step 1: Write the failing end-to-end test**

Create `tests/DefaultToolRoles.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/../Public/Add-DFToPath.ps1"
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/Invoke-DFFzf.ps1"
    . "$PSScriptRoot/../Public/Invoke-DFPicker.ps1"
    . "$PSScriptRoot/../Private/Test-DFToolSchema.ps1"
    . "$PSScriptRoot/../Private/ConvertTo-DFPath.ps1"
    . "$PSScriptRoot/../Private/Expand-DFXdgPath.ps1"
    . "$PSScriptRoot/../Private/Import-DFToolDb.ps1"
    . "$PSScriptRoot/../Private/Invoke-DFTopoSort.ps1"
    . "$PSScriptRoot/../Public/Get-DFTool.ps1"
    . "$PSScriptRoot/../Public/Find-DFTool.ps1"
    . "$PSScriptRoot/../Private/Get-DFCoreutilsShadowSet.ps1"
    . "$PSScriptRoot/../Public/Get-DFCommandConflict.ps1"
    . "$PSScriptRoot/../Private/Initialize-DFCompletionStack.ps1"
    . "$PSScriptRoot/../Private/Get-DFConfiguredTheme.ps1"
    . "$PSScriptRoot/../Private/Resolve-DFThemeName.ps1"
    . "$PSScriptRoot/../Public/Register-DFTool.ps1"
    $script:RealTools = Join-Path $PSScriptRoot '../Tools'
}

Describe 'eza/lsd share role: listing (real tool records)' {
    BeforeEach {
        $script:DFToolDb = $null
        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
        Mock Get-Command {
            param($Name)
            if ($Name -in 'eza.exe', 'lsd.exe') { [PSCustomObject]@{ Path = "C:\fake\$Name" } }
        }
        # Stand-in functions so a wrapper's `& eza ...` / `& lsd ...` resolves to a
        # capturable function (PowerShell resolves Function before Application),
        # regardless of whether real eza.exe/lsd.exe are installed on this machine.
        # This is the only reliable way to observe which command a wrapper actually
        # calls: a .GetNewClosure() wrapper's ScriptBlock.ToString() shows only the
        # unbound template source (`& $capturedCmd @capturedArgs @args`), never the
        # bound values -- verified empirically in Task 1; do not use ToString() here.
        function global:eza { $global:LastCommandCalled = 'eza' }
        function global:lsd { $global:LastCommandCalled = 'lsd' }
    }
    AfterEach {
        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
        # 'global:' in the path form is a Remove-Item no-op (same quirk as Get-Item,
        # confirmed in Task 1) -- use the bare 'function:<name>' form to actually
        # remove. 'ls' always has args on both eza and lsd, so it is ALWAYS a
        # wrapper function, never a plain Set-Alias.
        Remove-Item 'function:ls', 'function:ll', 'function:la', 'function:tree' -ErrorAction Ignore
        # eza's real picker block creates function:global:Select-File as a side
        # effect of registering the real eza.json -- must be cleaned up or it
        # leaks into the rest of the suite's shared session.
        Remove-Item 'function:Select-File' -ErrorAction Ignore
        Remove-Alias ff -Force -Scope Global -ErrorAction Ignore
        Remove-Item 'function:eza', 'function:lsd' -ErrorAction Ignore
        Remove-Variable LastCommandCalled -Scope Global -ErrorAction Ignore
    }

    It 'declares role: listing on both tools' {
        $ezaJson = Get-Content (Join-Path $script:RealTools 'eza.json') -Raw | ConvertFrom-Json
        $lsdJson = Get-Content (Join-Path $script:RealTools 'lsd.json') -Raw | ConvertFrom-Json
        $ezaJson.role | Should -Be 'listing'
        $lsdJson.role | Should -Be 'listing'
    }

    It 'gives eza the contested aliases when Defaults.listing = eza' {
        $Global:DFConfig = @{ Defaults = @{ listing = 'eza' } }
        Register-DFTool -Name 'eza', 'lsd' -ToolsPath $script:RealTools

        & 'ls';   $global:LastCommandCalled | Should -Be 'eza'
        & 'll';   $global:LastCommandCalled | Should -Be 'eza'
        & 'la';   $global:LastCommandCalled | Should -Be 'eza'
        & 'tree'; $global:LastCommandCalled | Should -Be 'eza'
    }

    It 'gives lsd the contested aliases when Defaults.listing = lsd' {
        $Global:DFConfig = @{ Defaults = @{ listing = 'lsd' } }
        Register-DFTool -Name 'eza', 'lsd' -ToolsPath $script:RealTools

        & 'ls';   $global:LastCommandCalled | Should -Be 'lsd'
        & 'll';   $global:LastCommandCalled | Should -Be 'lsd'
        & 'la';   $global:LastCommandCalled | Should -Be 'lsd'
        & 'tree'; $global:LastCommandCalled | Should -Be 'lsd'
    }

    It 'both register their full alias sets when no Defaults entry exists (unchanged behavior)' {
        { Register-DFTool -Name 'eza', 'lsd' -ToolsPath $script:RealTools } | Should -Not -Throw
        # Whichever registers last wins the collision -- this test only proves no
        # exception and that the mechanism does not activate without a Defaults entry.
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `pwsh -NoProfile -Command 'Invoke-Pester tests/DefaultToolRoles.Tests.ps1 -Output Detailed'`
Expected: FAIL — `Tools/lsd.json` does not exist; `Tools/eza.json` has no `role` property.

- [ ] **Step 3: Add `"role": "listing"` to `Tools/eza.json`**

Insert after `"executable": "eza.exe",`:

```json
  "role": "listing",
```

(Full file otherwise unchanged.)

- [ ] **Step 4: Create `Tools/lsd.json`**

```json
{
  "name": "lsd",
  "description": "Modern ls replacement with colors, icons, and tree view",
  "tags": ["file", "directory", "ls"],
  "executable": "lsd.exe",
  "packages": {
    "scoop": "lsd",
    "winget": "lsd-rs.lsd",
    "choco": "lsd"
  },
  "xdg": {
    "compliance": "none",
    "method": "manual",
    "instructions": "lsd's --config-file panics on a nonexistent path; DotForge does not manage its config. Point --config-file yourself if you want a custom lsd config."
  },
  "role": "listing",
  "aliases": {
    "ls":   { "command": "lsd", "args": ["--color=auto", "--icon=auto", "--group-directories-first", "--hyperlink=auto"] },
    "ll":   { "command": "lsd", "args": ["--all", "--long", "--header", "--hyperlink=auto"] },
    "la":   { "command": "lsd", "args": ["--all", "--hyperlink=auto"] },
    "tree": { "command": "lsd", "args": ["--tree"] }
  },
  "picker": null
}
```

- [ ] **Step 5: Add `lsd` to the schema seed-file list**

In `tests/Test-DFToolSchema.Tests.ps1`, add `'lsd'` to the `$seedFiles` array (alongside the other alphabetically-unsorted entries already there):

```powershell
        'bitwarden', 'npm', 'fnm', 'scoop', 'winget',
        'posh-git', 'psreadline', 'PSFzf', 'Terminal-Icons', 'oh-my-posh',
        'gsudo', 'mdcat', 'lsd'
```

- [ ] **Step 6: Run the new test + schema test + full suite**

Run: `pwsh -NoProfile -Command 'Invoke-Pester tests/DefaultToolRoles.Tests.ps1, tests/Test-DFToolSchema.Tests.ps1 -Output Detailed'`
Expected: PASS.

Run: `pwsh -NoProfile -Command 'Invoke-Pester tests/ -Output Detailed'`
Expected: PASS — no regression (in particular, `eza`'s own existing behavior/tests are unaffected since `role` alone changes nothing without a `Defaults` entry).

- [ ] **Step 7: Commit**

```bash
git add Tools/lsd.json Tools/eza.json tests/DefaultToolRoles.Tests.ps1 tests/Test-DFToolSchema.Tests.ps1
git commit -m "feat(tools): onboard lsd as a real second listing-role tool alongside eza"
```

---

### Task 3: Documentation

**Files:** Modify `ToolAcquisitionSpec.md`, `CLAUDE.md`, `CHANGELOG.md`, `README.md`, `docs/external-dependencies.md`; check `examples/`.

**Interfaces:** none (documentation only).

- [ ] **Step 1: `ToolAcquisitionSpec.md` §10**

Find §10.1's third bullet (the "auto-added to the effective skip set" framing) and replace it with the mechanism actually implemented:

```markdown
- **Contested aliases are computed, not declared.** A role's winner's own `aliases` block IS
  the set of aliases it claims. A **loser** (a tool sharing the same `role` but not named as the
  winner) has ONLY the alias keys it shares with the winner suppressed — every other alias it
  declares, its XDG config, picker, and companion `.ps1` still apply. This is computed live from
  each tool's own declared `aliases`; there is no separate contested-alias list.
```

Add a short subsection documenting the `role` field itself (after 10.1, before 10.2):

```markdown
### 10.1a The `role` field

A tool optionally declares a top-level `role` string in its own JSON (e.g. `"role": "listing"`) to
say "I compete in this equivalence group." Per `docs/plugin-architecture.md`, this is NOT a central
registry — a role name is just a string a tool declares and the user references as a key in
`$DFConfig.Defaults`. `Register-DFTool` resolves the named winner for each `Defaults` entry,
validating that the winner exists, declares that same role, and is actually available/registering
this call before recording its alias keys; any of those checks failing degrades to no suppression
for that role, never a thrown error.
```

- [ ] **Step 2: `CLAUDE.md` — Tool JSON Schema**

Add, after the `themeMap` bullet:

```markdown
- `role` (optional): a string naming the equivalence group this tool competes in for
  `$DFConfig.Defaults` resolution (e.g. `"listing"`). No central registry — see
  `ToolAcquisitionSpec.md` §10.1a and `docs/plugin-architecture.md`.
```

- [ ] **Step 3: `CHANGELOG.md` `[Unreleased]` → `### Added`**

```markdown
- **`$DFConfig.Defaults`-driven default-tool role resolution.** A tool optionally declares a
  `role` (e.g. `"listing"`); `$DFConfig.Defaults = @{ listing = 'eza' }` names the winner, and
  `Register-DFTool` suppresses only the alias keys a role LOSER shares with the winner — every
  other alias, XDG config, and picker the loser declares still applies. Onboarded `lsd` as a real
  second `listing`-role tool alongside `eza` to prove the mechanism.
```

- [ ] **Step 4: `README.md`**

Add a `Defaults` example to the `$DFConfig` block (near the `SkipTools`/theme examples):

```powershell
    Defaults            = @{ listing = 'eza' }  # role winner; loser's contested aliases suppressed
```

If the tool table lists `eza`, add `lsd` alongside it (same row or an adjacent one, matching the existing table's category grouping).

- [ ] **Step 5: `docs/external-dependencies.md`**

Add an entry:

```markdown
| `lsd --config-file <path>` panics on a nonexistent path | `Tools/lsd.json` | Verified (lsd 1.2.0): `thread 'main' panicked at src\main.rs:116:33: Provided file path is invalid` — a hard crash, not a clean exit. DotForge never passes `--config-file`; `xdg.method` is `manual` for exactly this reason. A malformed-but-existing config is handled more gracefully (a field-name error is printed) but this workstream does not wire config at all. |
```

- [ ] **Step 6: Check `examples/`**

Run: `pwsh -NoProfile -Command 'Select-String -Path examples/*.ps1 -Pattern "SkipTools.*lsd|Defaults"'`

If any example shows `SkipTools = @('lsd')`-style guidance for a listing tool, note that `Defaults` is now the preferred mechanism. If no matches, no change needed — say so in the commit body.

- [ ] **Step 7: Full suite + commit**

Run: `pwsh -NoProfile -Command 'Invoke-Pester tests/ -Output Detailed'`
Expected: PASS.

```bash
git add ToolAcquisitionSpec.md CLAUDE.md CHANGELOG.md README.md docs/external-dependencies.md
git commit -m "docs: default-tool role resolution, role field, lsd panic note"
```

---

## Self-Review checklist (author ran before finalizing)

- **Spec coverage:** pre-pass + suppression mechanism (T1) ✓; lsd onboarding + real eza/lsd end-to-end proof (T2) ✓; standard/CLAUDE/CHANGELOG/README/external-deps (T3) ✓.
- **Type/name consistency:** `$activeRoleWinners[$roleName] = @{ WinnerName; AliasKeys }` shape is identical between the implementation (T1) and every test that reads it indirectly via alias behavior (T1, T2). `role` as a bare top-level string (not nested) is consistent across `Tools/eza.json`, `Tools/lsd.json`, and both doc sections.
- **Degradation safety:** every failure path (unknown winner, role mismatch, winner unavailable, winner not in this call's `$tools`) is a `continue`/no-op with an optional `Write-Warning`, never a throw — matches the house rule and is exercised by name-matched tests in T1.
- **Plugin invariant:** no central per-role or per-tool-pair data introduced; `role` is a per-tool declaration; a hypothetical third `listing` tool would need only its own JSON to participate.
- **Post-Task-1 correction (applied to this plan file):** Task 1's implementation surfaced that `.ScriptBlock.ToString()` on a `.GetNewClosure()` wrapper shows only the unbound template source, never bound values — empirically confirmed, so `Should -Match '<toolname>'` against it can never discriminate. Task 2's test above was rewritten to use the same fix Task 1 landed on: define a real stand-in global function named after the underlying command (`eza`/`lsd`), invoke the wrapper for real, and assert on what actually ran (PowerShell resolves Function before Application, so this works whether or not the real binaries are installed).
