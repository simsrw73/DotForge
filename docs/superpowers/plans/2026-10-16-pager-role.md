# Pager Role Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** moor, ov and less page alike (quit if one screen, colors, keep screen, mouse), `more` pages when none wins, ov follows the theme, and bat pages the same way (`BAT_PAGER`).

**Architecture:** Two generic role features in `data/roles.json`, read by `ConvertTo-DFRoleRecord`: `fallback` (env applied when a single role has no winner anywhere in the session) and `behaviors.env` (variables built from the winner's flags, like behavior aliases). A member's flag value may hold conditional groups (`ifFile`/`unlessFile`, `{theme}`, `{file}`), resolved by the existing `Resolve-DFRoleWords`. The pager role, less, ov and moor are migrated; ov gets bundled catppuccin configs.

**Tech Stack:** PowerShell 7.2+, Pester 6. Run tests with `pwsh -NoProfile -Command "./build/Test-DFFull.ps1 -Path <files>"`.

**Spec:** `docs/superpowers/specs/2026-10-16-pager-role-design.md`

## Global Constraints

- No tool names in core code; `data/roles.json` is keyed by role (docs/plugin-architecture.md).
- Every env write goes through `Set-DFEnv` (`Private/Set-DFEnv.ps1`): a value set outside DotForge is kept; an explicit `Defaults` choice overrides with a warning.
- Paths are canonical (`ConvertTo-DFPath`); group paths expand `${XDG_*}`, `{settings.<name>}` (`Expand-DFToolToken`) and `{theme}`.
- No new process spawns or file reads at startup beyond `Test-Path` on group files.
- A function past ~60 lines is split into named steps; functions return result objects.
- New config keys go in `$script:DFConfigKeys` (`Private/DFSessionConfig.ps1`); `OvTheme` is one.
- Regenerate after changes: bundle (`build/Build-DFCoreBundle.ps1`), tool registry (`build/Build-DFToolRegistry.ps1`), reference (`build/Build-DFReferenceDocs.ps1`).
- Commits GPG-signed (never bypass); write the message to a file and `git commit -F`. Trailer:
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` / `Claude-Session: https://claude.ai/code/session_01PCJ8NCZhH2mTdAwuq8KLar`.

**Naming ruling made while planning:** `Get-DFRoleWinners` already uses the reason `'fallback'` (a `Defaults` tool that is missing). The role key stays `fallback` (spec), but `Get-DFRole` reports it in a new `Fallback` property (variable = value), never as a winner or a reason.

## Review Focus

1. **A later `Register-DFTool -Name <other>` in the same session** (no pager in that registration): the fallback must not overwrite the `PAGER` an earlier winner set. Test: Task 2, "does not apply the fallback while a member is active in the session".
2. **The user's own `PAGER`/`BAT_PAGER`** with the fallback or a winner: kept, noted. Test: Task 2 "keeps a PAGER set outside DotForge"; Task 5 covers the winner case through `Set-DFEnv`.
3. **less installed only as Git's MSYS build** (`executableExclude`): `PAGER` names the bare `less` as today, never the excluded path. Test: Task 5, "less PAGER uses the native-build token".
4. **ov with the user's own config:** no `--config` in `PAGER`. Test: Task 5, "ov with your own config passes no --config".
5. **A theme without an ov folder (dracula):** ov's `PAGER` has no `--config`, no warning. Test: Task 5, "ov with a theme it has no config for".

---

### Task 1: Role definitions read `fallback` and `behaviors.env`

**Files:** Modify `Private/Get-DFRoleDb.ps1` (`ConvertTo-DFRoleRecord`, `ConvertTo-DFRoleBehaviors`). Test `tests/Get-DFRoleDb.Tests.ps1`.

**Interfaces:**
- Produces: role record `fallback` = `$null` or `[pscustomobject]@{ env = <pscustomobject var -> string> }`; `behaviors.env` = `[ordered]` var -> `[string[]]` words (empty when absent); `reserved.env` includes the `behaviors.env` variable names.

- [ ] **Step 1: Failing tests** (append):

```powershell
Describe 'ConvertTo-DFRoleRecord fallback and env behaviors' {
    BeforeAll { function script:Read-Role([string]$Json) { $Json | ConvertFrom-Json } }

    It 'reads a fallback of reserved env' {
        $r = ConvertTo-DFRoleRecord -Name 'pager' -Role (Read-Role '{ "kind": "single", "hook": "Initialize-DFRolePager",
            "reserved": { "env": ["PAGER"] }, "fallback": { "env": { "PAGER": "more" } } }')
        $r.fallback.env.PAGER | Should -Be 'more'
    }
    It 'rejects a fallback that sets a variable the role does not reserve' {
        $role = Read-Role '{ "kind": "single", "hook": "Initialize-DFRolePager", "reserved": { "env": ["PAGER"] },
            "fallback": { "env": { "EDITOR": "notepad" } } }'
        ConvertTo-DFRoleRecord -Name 'pager' -Role $role -WarningVariable w 3>$null | Should -BeNullOrEmpty
        "$w" | Should -Match 'EDITOR'
    }
    It 'rejects a fallback on a category role' {
        ConvertTo-DFRoleRecord -Name 'grep' -Role (Read-Role '{ "kind": "category", "fallback": { "env": { "X": "y" } } }') 3>$null |
            Should -BeNullOrEmpty
    }
    It 'reads behaviors.env and reserves its variables' {
        $r = ConvertTo-DFRoleRecord -Name 'pager' -Role (Read-Role '{ "kind": "single", "hook": "Initialize-DFRolePager",
            "reserved": { "env": ["PAGER"] },
            "behaviors": { "words": { "quit": "q", "color": "c" }, "env": { "PAGER": ["quit", "color"], "BAT_PAGER": ["quit"] } } }')
        $r.behaviors.env['PAGER'] | Should -Be @('quit', 'color')
        $r.reserved.env | Should -Be @('PAGER', 'BAT_PAGER')
    }
    It 'rejects behaviors.env that uses an undefined word' {
        $role = Read-Role '{ "kind": "single", "hook": "Initialize-DFRolePager",
            "behaviors": { "words": { "quit": "q" }, "env": { "PAGER": ["quit", "nope"] } } }'
        ConvertTo-DFRoleRecord -Name 'pager' -Role $role 3>$null | Should -BeNullOrEmpty
    }
}
```

- [ ] **Step 2: Run, expect FAIL** — `pwsh -NoProfile -Command "./build/Test-DFFull.ps1 -Path tests/Get-DFRoleDb.Tests.ps1"`.

- [ ] **Step 3: Implement.** In `ConvertTo-DFRoleBehaviors`, read `env` like `aliases` (name -> `[string[]]`), add its words to `$used`, and return it as `env` in `Value` (an empty `[ordered]@{}` when absent). In `ConvertTo-DFRoleRecord`:

```powershell
    $reservedEnv = [string[]]@(if ($null -ne $resProps) { $resProps['env']?.Value })
    if ($behaviors.Value -and $behaviors.Value.env.Count) {
        $reservedEnv = [string[]]@(@($reservedEnv) + @($behaviors.Value.env.Keys) | Select-Object -Unique)
    }
    $fallback = $props['fallback']?.Value
```

Use `$reservedEnv` for `reserved.env`; add `fallback = $fallback` to the record. Problems: for `single`, after the behaviors problem, `elseif ($fallback) { $bad = @($fallback.env.PSObject.Properties.Name | Where-Object { $_ -notin $reservedEnv }); if ($bad) { "fallback sets $($bad -join ', '), which the role does not reserve" } }`. For `category`, add `-or $record.fallback` to the rejection and name `fallback` in its message. Update `.DESCRIPTION`.

- [ ] **Step 4: Run, expect PASS** (same command plus `tests/Roles.Registration.Tests.ps1`).
- [ ] **Step 5: Commit** — "feat: role definitions read fallback and behaviors.env".

---

### Task 2: Apply a role's fallback when nothing in the session won it

**Files:** Create `Private/Set-DFRoleFallback.ps1`. Modify `Private/Invoke-DFSessionActivation.ps1` (call it after the activation loop, before `Add-DFRoleOutcomeStatus`), `Public/Get-DFRole.ps1` (`Fallback` property). Test `tests/Set-DFRoleFallback.Tests.ps1`.

**Interfaces:**
- Consumes: role record `fallback` (Task 1); `Set-DFEnv -Name -Value -Tool`; `Test-DFToolActive`; `Get-DFRoleMember`.
- Produces: `Set-DFRoleFallback -RoleDb <hashtable> -RoleWinners <hashtable> -SessionTools <object[]>` → names of the roles whose fallback it applied (`[string[]]`).

- [ ] **Step 1: Failing tests:**

```powershell
BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
}

Describe 'Set-DFRoleFallback' {
    BeforeEach {
        Reset-DFTestSession
        $script:SavedPager = $Env:DF_T_FB_PAGER
        Remove-Item Env:DF_T_FB_PAGER -ErrorAction Ignore
        $file = Join-Path $TestDrive 'roles-fb.json'
        '{ "tpager": { "kind": "single", "hook": "Initialize-DFRoleTpager", "reserved": { "env": ["DF_T_FB_PAGER"] },
           "fallback": { "env": { "DF_T_FB_PAGER": "more" } } } }' | Set-Content $file
        $script:Roles = Get-DFRoleDb -Path $file
        $script:Member = ConvertTo-DFToolRecord ('{ "name": "tp", "executable": "tp.exe", "roles": { "tpager": {} } }' | ConvertFrom-Json)
    }
    AfterEach { if ($null -eq $script:SavedPager) { Remove-Item Env:DF_T_FB_PAGER -ErrorAction Ignore } else { $Env:DF_T_FB_PAGER = $script:SavedPager } }

    It 'sets the fallback when the role has no winner' {
        Set-DFRoleFallback -RoleDb $script:Roles -RoleWinners @{} -SessionTools @() | Should -Be @('tpager')
        $Env:DF_T_FB_PAGER | Should -Be 'more'
    }
    It 'does nothing when the role has a winner' {
        Set-DFRoleFallback -RoleDb $script:Roles -RoleWinners @{ tpager = [pscustomobject]@{ Winner = 'tp' } } -SessionTools @($script:Member) |
            Should -BeNullOrEmpty
        $Env:DF_T_FB_PAGER | Should -BeNullOrEmpty
    }
    It 'does not apply the fallback while a member is active in the session' {
        Mock Test-DFToolActive { $true } -ParameterFilter { $Name -eq 'tp' }
        Mock Test-DFToolActive { $false }
        Set-DFRoleFallback -RoleDb $script:Roles -RoleWinners @{} -SessionTools @($script:Member) | Should -BeNullOrEmpty
    }
    It 'keeps a PAGER set outside DotForge' {
        $Env:DF_T_FB_PAGER = 'mine'
        Set-DFRoleFallback -RoleDb $script:Roles -RoleWinners @{} -SessionTools @() | Out-Null
        $Env:DF_T_FB_PAGER | Should -Be 'mine'
    }
}
```

Plus in `tests/Get-DFRole.Tests.ps1`: with the shipped roles and no pager requested, `(Get-DFRole pager).Fallback` is `@{ PAGER = 'more'; BAT_PAGER = 'more' }` (compare keys and values). Write this after Task 4 lands (it needs the shipped pager fallback); mark it in Task 4's Step 1.

- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement** `Private/Set-DFRoleFallback.ps1`:

```powershell
#Requires -Version 7.2

function Set-DFRoleFallback {
    <#
    .SYNOPSIS
        Applies each single role's fallback env when no tool in the session fills the role.
    .DESCRIPTION
        A role in data/roles.json may name a fallback (pager: PAGER = more). It applies
        only when this activation picked no winner and no member is active in the session
        (a later Register-DFTool -Name for another tool must not undo an earlier winner).
        Written through Set-DFEnv, so a value set outside DotForge is kept.
    .PARAMETER RoleDb
        Get-DFRoleDb.
    .PARAMETER RoleWinners
        This activation's Get-DFRoleWinners result.
    .PARAMETER SessionTools
        The session's tool records (members of each role are found among them).
    .OUTPUTS
        System.String[]: the roles whose fallback was applied.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][hashtable]$RoleDb,
        [Parameter(Mandatory)][hashtable]$RoleWinners,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$SessionTools
    )
    [string[]]@(foreach ($role in $RoleDb.Values) {
        if (-not $role.fallback -or $RoleWinners.ContainsKey($role.name)) { continue }
        $active = @(Get-DFRoleMember -Role $role.name -Tools $SessionTools | Where-Object { Test-DFToolActive $_.name })
        if ($active) { continue }
        foreach ($var in $role.fallback.env.PSObject.Properties) {
            Set-DFEnv -Name $var.Name -Value ([string]$var.Value) -Tool "$($role.name) role"
        }
        $role.name
    })
}
```

In `Invoke-DFSessionActivation`, after the `try/finally` loop: `Set-DFRoleFallback -RoleDb $roleDb -RoleWinners $winners -SessionTools @($script:DFSessionToolDb.Values) | Out-Null`.

In `Get-DFRole`, add `Fallback = if (-not $w -and $role.fallback) { $map = [ordered]@{}; foreach ($v in $role.fallback.env.PSObject.Properties) { $map[$v.Name] = [string]$v.Value }; [pscustomobject]$map }` to the output object, and to the format view if `Get-DFRole` has one (check `DotForge.Format.ps1xml` or the function's `PSTypeName` usage; add a `Fallback` column only if a table view lists columns).

- [ ] **Step 4: Run, expect PASS** — `tests/Set-DFRoleFallback.Tests.ps1, tests/Get-DFRole.Tests.ps1, tests/Register-DFTool.Tests.ps1`.
- [ ] **Step 5: Commit** — "feat: a role's fallback applies when no tool in the session fills it".

---

### Task 3: Flag groups and env behaviors

**Files:** Modify `Private/Get-DFRoleBehavior.ps1` (`Resolve-DFRoleWords`, new `Get-DFRoleBehaviorEnv`), `Private/Register-DFToolSteps.ps1` (`Invoke-DFWonRoles`). Test `tests/Get-DFRoleBehavior.Tests.ps1`, `tests/Roles.Registration.Tests.ps1`.

**Interfaces:**
- Consumes: `Expand-DFToolToken -Tool -Text` (`Private/New-DFToolWrapper.ps1`); `Get-DFToolTheme -Tool` (`.Value`); `ConvertTo-DFToolExePathToken -Tool` (`Private/Resolve-DFToolExecutable.ps1`); `ConvertTo-DFPath`.
- Produces:
  - `Resolve-DFRoleWords -Words -Flags -Tool` (new `-Tool` parameter; optional, needed only for groups): a flag item that is an object `{ ifFile?, unlessFile?, args }` contributes `args` only when `ifFile` exists and `unlessFile` doesn't; `{file}` in args is the `ifFile` path.
  - `Get-DFRoleBehaviorEnv -RoleDefinition -Block -Tool` → `[ordered]` var -> command string (`<exe token> <args>`), noting missing words like aliases.

- [ ] **Step 1: Failing tests** (append to `tests/Get-DFRoleBehavior.Tests.ps1`):

```powershell
Describe 'flag groups' {
    BeforeEach { Clear-DFToolNote -Tool 'lsx'; Set-DFTestXdg }
    AfterEach { Restore-DFTestXdg }

    It 'passes a group only while ifFile exists and unlessFile does not' {
        $cfg = Join-Path $TestDrive 'c.yaml'; $own = Join-Path $Env:XDG_CONFIG_HOME 'own.yaml'
        $flags = [pscustomobject]@{ theme = @([pscustomobject]@{ ifFile = $cfg; unlessFile = '${XDG_CONFIG_HOME}/own.yaml'; args = @('--config', '{file}') }) }
        $tool = [pscustomobject]@{ name = 'lsx'; executable = 'lsx.exe'; settings = $null; theme = $null }
        (Resolve-DFRoleWords -Words @('theme') -Flags $flags -Tool $tool).Args | Should -BeNullOrEmpty
        Set-Content $cfg 'x'
        (Resolve-DFRoleWords -Words @('theme') -Flags $flags -Tool $tool).Args | Should -Be @('--config', $cfg)
        New-Item -ItemType File -Force $own | Out-Null
        (Resolve-DFRoleWords -Words @('theme') -Flags $flags -Tool $tool).Args | Should -BeNullOrEmpty
    }
    It 'expands {theme} in a group path from the tool''s theme' {
        $folder = Join-Path $TestDrive 'flavor'; New-Item -ItemType Directory -Force $folder | Out-Null; Set-Content (Join-Path $folder 'c.yaml') 'x'
        Mock Get-DFToolTheme { [pscustomobject]@{ Value = $folder } }
        $flags = [pscustomobject]@{ theme = @([pscustomobject]@{ ifFile = '{theme}/c.yaml'; args = @('--config', '{file}') }) }
        $tool = [pscustomobject]@{ name = 'lsx'; executable = 'lsx.exe'; settings = $null; theme = [pscustomobject]@{ key = 'X' } }
        (Resolve-DFRoleWords -Words @('theme') -Flags $flags -Tool $tool).Args | Should -Be @('--config', (Join-Path $folder 'c.yaml'))
    }
    It 'treats {theme} with no theme value as a missing file' {
        Mock Get-DFToolTheme { [pscustomobject]@{ Value = $null } }
        $flags = [pscustomobject]@{ theme = @([pscustomobject]@{ ifFile = '{theme}/c.yaml'; args = @('--config', '{file}') }) }
        $tool = [pscustomobject]@{ name = 'lsx'; executable = 'lsx.exe'; settings = $null; theme = [pscustomobject]@{ key = 'X' } }
        (Resolve-DFRoleWords -Words @('theme') -Flags $flags -Tool $tool).Args | Should -BeNullOrEmpty
    }
}

Describe 'Get-DFRoleBehaviorEnv' {
    It 'builds each variable as the winner''s executable and its flags' {
        $role = ConvertTo-DFRoleRecord -Name 'pager' -Role ('{ "kind": "single", "hook": "Initialize-DFRolePager",
            "behaviors": { "words": { "quit": "q", "color": "c" }, "env": { "PAGER": ["quit", "color"] } } }' | ConvertFrom-Json)
        $tool = ConvertTo-DFToolRecord ('{ "name": "lsx", "executable": "lsx.exe", "roles": { "pager": { "flags": { "quit": ["-F"], "color": ["-R"] } } } }' | ConvertFrom-Json)
        Mock ConvertTo-DFToolExePathToken { 'lsx' }
        (Get-DFRoleBehaviorEnv -RoleDefinition $role -Block $tool.roles.pager -Tool $tool)['PAGER'] | Should -Be 'lsx -F -R'
    }
}
```

`ConvertTo-DFRoleFlags` (`Shared/Import-DFToolDb.ps1`) casts each value with `[string[]]`, which would flatten a group object to a string. Add a test to `tests/ConvertTo-DFToolRecord.Tests.ps1`: a flag `[ "-x", { "ifFile": "a", "args": ["-c", "{file}"] } ]` keeps item 2 as an object with `ifFile` and `args`. The schema (`Test-DFToolSchema`) must accept it: add a test that it does, and that `{ "args": "x" }` (args not an array) is rejected.

In `tests/Roles.Registration.Tests.ps1`, add to the role-behaviors fixture an env role and assert a winner sets its variable: role `tpg` `{ "kind": "single", "hook": "Initialize-DFRoleTpg", "behaviors": { "words": { "q": "q" }, "env": { "DF_T_PG": ["q"] } } }`, member `{ "name": "tpga", "executable": "tpga.exe", "roles": { "tpg": { "flags": { "q": ["-q"] } } } }` → after `Register-DFTool -Name tpga`, `$Env:DF_T_PG` is `tpga -q` (clear and restore `DF_T_PG` in the fixture; mock `ConvertTo-DFToolExePathToken { 'tpga' }` or accept the bare name it returns when no path is found).

- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.**

`ConvertTo-DFRoleFlags`: keep each value as an array whose items are strings or `[pscustomobject]` groups: `$map[$p.Name] = @($p.Value | ForEach-Object { if ($_ -is [pscustomobject]) { $_ } else { [string]$_ } })`.

`Test-DFToolSchema` flags check: each item is a string, or an object whose `args` is an array of strings and whose `ifFile`/`unlessFile`, when present, are strings.

`Resolve-DFRoleWords` gains `[PSCustomObject]$Tool` and expands items:

```powershell
        if ($mapped) {
            foreach ($item in @($mapped.Value)) {
                if ($item -is [pscustomobject]) { foreach ($a in Resolve-DFRoleFlagGroup -Group $item -Tool $Tool) { $argList.Add($a) } }
                elseif ($item) { $argList.Add($item) }
            }
        } else { $missing.Add($word) }
```

New function in the same file:

```powershell
function Resolve-DFRoleFlagGroup {
    <#
    .SYNOPSIS
        A conditional flag group's arguments: passed only while ifFile exists and unlessFile doesn't.
    .PARAMETER Group
        { ifFile?, unlessFile?, args }.
    .PARAMETER Tool
        The tool record (for {settings.<name>}, ${XDG_*} and {theme}).
    .OUTPUTS
        System.String[].
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][PSCustomObject]$Group, [PSCustomObject]$Tool)
    $expand = {
        param([string]$Template)
        if (-not $Template) { return }
        if ($Template.Contains('{theme}')) {
            $theme = if ($Tool -and $Tool.theme) { (Get-DFToolTheme -Tool $Tool).Value }
            if (-not $theme) { return }
            $Template = $Template.Replace('{theme}', [string]$theme)
        }
        Expand-DFToolToken -Tool $Tool -Text $Template
    }
    $ifFile = $Group.PSObject.Properties['ifFile']?.Value
    $unlessFile = $Group.PSObject.Properties['unlessFile']?.Value
    $file = if ($ifFile) { & $expand $ifFile }
    if ($ifFile -and -not ($file -and (Test-Path -LiteralPath $file -PathType Leaf))) { return }
    if ($unlessFile) { $other = & $expand $unlessFile; if ($other -and (Test-Path -LiteralPath $other -PathType Leaf)) { return } }
    [string[]]@(foreach ($arg in @($Group.args)) { if ($file) { ([string]$arg).Replace('{file}', $file) } else { [string]$arg } })
}
```

Pass `-Tool $Tool` from `Get-DFRoleBehaviorAlias` and `Get-DFRolePicker`. New:

```powershell
function Get-DFRoleBehaviorEnv {
    <#
    .SYNOPSIS
        Builds a won role's behavior variables: the winner's executable and each word's flags.
    .DESCRIPTION
        The executable is the ${DF_TOOL_EXE} token (ConvertTo-DFToolExePathToken: the
        winner's own build, quoted when it has a space). A missing word is noted as for aliases.
    .PARAMETER RoleDefinition
        The role record, with behaviors.env.
    .PARAMETER Block
        The winner's normalized block for the role.
    .PARAMETER Tool
        The winner's tool record.
    .OUTPUTS
        System.Collections.Specialized.OrderedDictionary: variable -> command line.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$RoleDefinition, [Parameter(Mandatory)][PSCustomObject]$Block, [Parameter(Mandatory)][PSCustomObject]$Tool)
    $command = ConvertTo-DFToolExePathToken -Tool $Tool
    $values = [ordered]@{}
    $missing = [ordered]@{}
    foreach ($name in $RoleDefinition.behaviors.env.Keys) {
        $resolved = Resolve-DFRoleWords -Words $RoleDefinition.behaviors.env[$name] -Flags $Block.flags -Tool $Tool
        $values[$name] = (@($command) + $resolved.Args) -join ' '
        foreach ($word in $resolved.Missing) { $missing[$word] = @(@($missing[$word]) + $name | Where-Object { $_ }) }
    }
    if ($missing.Count) { Add-DFRoleMissingWordNote -Tool $Tool -Role $RoleDefinition.name -Missing $missing }
    $values
}
```

An argument holding a space (a theme path under `Program Files`) must stay one argument when a program splits `PAGER`: quote any arg containing a space with double quotes when joining (`if ($a -match '\s') { "`"$a`"" } else { $a }`), and add that case to the `Get-DFRoleBehaviorEnv` test.

In `Invoke-DFWonRoles`, inside `if ($behaviors) { ... }`, after the aliases and pickers:

```powershell
            if ($roleDefinition.behaviors.env.Count) {
                $explicit = if ($won.Reason -eq 'Defaults') { "`$DFConfig.Defaults.$roleName is '$($won.Winner)'; using $($won.Winner)" }
                $built = Get-DFRoleBehaviorEnv -RoleDefinition $roleDefinition -Block $block -Tool $Tool
                foreach ($var in $built.Keys) { Set-DFEnv -Name $var -Value $built[$var] -Tool $Tool.name -ExplicitReason $explicit }
            }
```

(The existing `$explicit` computation in the env block can be hoisted and shared.)

- [ ] **Step 4: Run, expect PASS** — `tests/Get-DFRoleBehavior.Tests.ps1, tests/ConvertTo-DFToolRecord.Tests.ps1, tests/Test-DFToolSchema.Tests.ps1, tests/Roles.Registration.Tests.ps1, tests/Listing.Behaviors.Tests.ps1`.
- [ ] **Step 5: Commit** — "feat: role behaviors build env variables; flags may be conditional groups".

---

### Task 4: Migrate the pager role, less and moor

**Files:** Modify `data/roles.json` (`pager`), `Tools/less.json`, `Tools/moor.json`. Test `tests/Pager.Behaviors.Tests.ps1` (new), `tests/Roles.Contract.Tests.ps1`, `tests/Get-DFRole.Tests.ps1` (fallback, from Task 2).

- [ ] **Step 1: Failing tests.** `tests/Pager.Behaviors.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    $script:Pager = (Get-DFRoleDb -Path "$PSScriptRoot/../data/roles.json")['pager']
    function script:Get-PagerEnv([string]$Name) {
        $tool = Get-DFTestToolRecord $Name
        Get-DFRoleBehaviorEnv -RoleDefinition $script:Pager -Block $tool.roles.pager -Tool $tool
    }
}

Describe 'pager behaviors' {
    BeforeEach { Set-DFTestXdg; Mock ConvertTo-DFToolExePathToken { $Tool.name } }
    AfterEach { Restore-DFTestXdg }

    It 'less' { (Get-PagerEnv 'less')['PAGER'] | Should -Be 'less -F -R -X --mouse' }
    It 'moor' { (Get-PagerEnv 'moor')['PAGER'] | Should -Be 'moor -quit-if-one-screen -no-clear-on-exit -mousemode scroll' }
    It 'sets BAT_PAGER the same: <_>' -ForEach @('less', 'moor', 'ov') {
        $env = Get-PagerEnv $_
        $env['BAT_PAGER'] | Should -Be $env['PAGER']
    }
    It 'falls back to more' { $script:Pager.fallback.env.PAGER | Should -Be 'more'; $script:Pager.fallback.env.BAT_PAGER | Should -Be 'more' }
    It 'moor''s MOOR keeps only its style' { (Get-DFTestToolRecord 'moor').theme.env.MOOR | Should -Be '-style {theme}' }
    It 'less PAGER uses the native-build token' {
        # Not mocked here: the real token honors executableExclude (Git's MSYS less).
        Mock ConvertTo-DFToolExePathToken { 'C:/tools/less.exe' } -ParameterFilter { $Tool.name -eq 'less' }
        (Get-PagerEnv 'less')['PAGER'] | Should -BeLike 'C:/tools/less.exe *'
    }
}
```

In `tests/Get-DFRole.Tests.ps1`, add the Task 2 fallback test (no pager requested → `Fallback.PAGER` and `Fallback.BAT_PAGER` are `more`).

- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Migrate.** `data/roles.json` `pager`:

```json
  "pager": {
    "kind": "single",
    "exclusive": false,
    "hook": "Initialize-DFRolePager",
    "reserved": { "env": ["PAGER"], "aliases": [], "code": [] },
    "description": "Pages long output. The winner sets PAGER and BAT_PAGER, which DotForge's own pager also reads; with no pager, more.",
    "fallback": { "env": { "PAGER": "more", "BAT_PAGER": "more" } },
    "behaviors": {
      "words": {
        "quit-if-one-screen": "don't page output that fits one screen",
        "raw-color": "pass color codes through",
        "keep-screen": "leave the output on screen when quitting",
        "mouse": "scroll with the mouse wheel",
        "theme": "the session theme, where the pager takes it as an argument"
      },
      "env": {
        "PAGER":     ["quit-if-one-screen", "raw-color", "keep-screen", "mouse", "theme"],
        "BAT_PAGER": ["quit-if-one-screen", "raw-color", "keep-screen", "mouse", "theme"]
      }
    }
  },
```

`Tools/less.json` role block: `"pager": { "priority": 10, "flags": { "quit-if-one-screen": ["-F"], "raw-color": ["-R"], "keep-screen": ["-X"], "mouse": ["--mouse"], "theme": [] } }` (remove its `env`).
`Tools/moor.json` role block: `"pager": { "priority": 30, "flags": { "quit-if-one-screen": ["-quit-if-one-screen"], "raw-color": [], "keep-screen": ["-no-clear-on-exit"], "mouse": ["-mousemode", "scroll"], "theme": [] } }`; `theme.env.MOOR` → `"-style {theme}"`.

Contract test (`tests/Roles.Contract.Tests.ps1`): the "maps every word" check must include `behaviors.env` words (`$used` adds `@($behaviors['env'].Values | ForEach-Object { $_ })` when present); add "sets no behaviors.env variable in its role block env". `$script:AllReservedEnv` must include `behaviors.env` keys.

Run `build/Build-DFToolRegistry.ps1`. Update older tests that read `roles.pager.env.PAGER` or `MOOR`'s old value (`git grep -n "roles.pager.env\|quit-if-one-screen" -- tests`) to the new meaning; never drop an assertion.

- [ ] **Step 4: Run, expect PASS** — `tests/Pager.Behaviors.Tests.ps1, tests/Roles.Contract.Tests.ps1, tests/Get-DFRole.Tests.ps1, tests/less.Tests.ps1, tests/moor.Tests.ps1, tests/ToolRegistry.Tests.ps1, tests/DefaultToolRoles.Tests.ps1, tests/Roles.Registration.Tests.ps1`.
- [ ] **Step 5: Commit** — "feat: pager role pages alike across moor and less, falls back to more".

---

### Task 5: ov — flags and a theme that follows `Theme`

**Files:** Create `Tools/ov/catppuccin-{mocha,macchiato,frappe,latte}/config.yaml`, `build/New-DFOvTheme.ps1` (author-time generator). Modify `Tools/ov.json`, `Private/DFSessionConfig.ps1` (`OvTheme`). Test `tests/ov.Tests.ps1` (create if absent).

- [ ] **Step 1: Failing tests:**

```powershell
BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    Import-Module powershell-yaml -ErrorAction Stop
    $script:Pager = (Get-DFRoleDb -Path "$PSScriptRoot/../data/roles.json")['pager']
}

Describe 'ov' {
    BeforeEach { Reset-DFTestSession; Set-DFTestXdg; Remove-Item $Env:XDG_CONFIG_HOME -Recurse -Force -ErrorAction Ignore; Set-DFTestConfig $null; Mock ConvertTo-DFToolExePathToken { 'ov' } }
    AfterEach { Set-DFTestConfig $null; Restore-DFTestXdg }

    It 'ov PAGER passes the theme''s config' {
        $tool = Get-DFTestToolRecord 'ov'
        $cfg = Join-Path (Get-DFToolTheme -Tool $tool).Value 'config.yaml'
        (Get-DFRoleBehaviorEnv -RoleDefinition $script:Pager -Block $tool.roles.pager -Tool $tool)['PAGER'] |
            Should -Be "ov -F -X --config $cfg"
    }
    It 'ov with your own config passes no --config' {
        New-Item -ItemType File -Force (Join-Path $Env:XDG_CONFIG_HOME 'ov' 'config.yaml') | Out-Null
        $tool = Get-DFTestToolRecord 'ov'
        (Get-DFRoleBehaviorEnv -RoleDefinition $script:Pager -Block $tool.roles.pager -Tool $tool)['PAGER'] | Should -Be 'ov -F -X'
    }
    It 'ov with a theme it has no config for' {
        Set-DFTestConfig @{ Theme = 'dracula' }
        $tool = Get-DFTestToolRecord 'ov'
        (Get-DFRoleBehaviorEnv -RoleDefinition $script:Pager -Block $tool.roles.pager -Tool $tool -WarningVariable w)['PAGER'] | Should -Be 'ov -F -X'
        "$w" | Should -BeNullOrEmpty
    }
    It 'ships a config per flavor that parses and uses the flavor''s colors: <Flavor>' -ForEach @(
        @{ Flavor = 'catppuccin-mocha'; Text = '#cdd6f4' }, @{ Flavor = 'catppuccin-macchiato'; Text = '#cad3f5' },
        @{ Flavor = 'catppuccin-frappe'; Text = '#c6d0f5' }, @{ Flavor = 'catppuccin-latte'; Text = '#4c4f69' }
    ) {
        $file = Join-Path $PSScriptRoot '..' 'Tools' 'ov' $Flavor 'config.yaml'
        { Get-Content $file -Raw | ConvertFrom-Yaml } | Should -Not -Throw
        (Get-Content $file -Raw) | Should -Match ([regex]::Escape($Text))
        (Get-Content $file -Raw) | Should -Not -Match '"(blue|lime|aqua|gray|red|yellow|white|fuchsia|crimson|lightsalmon|slateblue|darkgoldenrod|yellowgreen)"'
    }
    It 'ov accepts each bundled config' -Skip:(-not (Get-Command ov.exe -ErrorAction Ignore)) {
        foreach ($cfg in Get-ChildItem (Join-Path $PSScriptRoot '..' 'Tools' 'ov') -Recurse -Filter config.yaml) {
            & ov.exe --config $cfg.FullName --help *> $null
            $LASTEXITCODE | Should -Be 0 -Because $cfg.FullName
        }
    }
}
```

- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.**

`build/New-DFOvTheme.ps1` (author-time, never loaded by the module): runs `ov --generate-config=default` and, per flavor, replaces each `Foreground:`/`Background:` color by this map, writing `Tools/ov/catppuccin-<flavor>/config.yaml` with a header comment naming the source (catppuccin palette, MIT) and the ov version. Foreground map: `blue→blue, lime→green, yellowgreen→green, aqua→sky, red→red, yellow→yellow, fuchsia→pink, crimson→maroon, lightsalmon→peach, gray→overlay0, white→text, #CCCCCC→text`. Background map: `#333333→surface0, gray→surface1, blue→surface1, darkgoldenrod→surface2, slateblue→surface2, #c0c0c0→overlay0`. A color not in the map stops the script with an error naming it. Palettes:

| name | mocha | macchiato | frappe | latte |
|---|---|---|---|---|
| red | #f38ba8 | #ed8796 | #e78284 | #d20f39 |
| maroon | #eba0ac | #ee99a0 | #ea999c | #e64553 |
| peach | #fab387 | #f5a97f | #ef9f76 | #fe640b |
| yellow | #f9e2af | #eed49f | #e5c890 | #df8e1d |
| green | #a6e3a1 | #a6da95 | #a6d189 | #40a02b |
| sky | #89dceb | #91d7e3 | #99d1db | #04a5e5 |
| blue | #89b4fa | #8aadf4 | #8caaee | #1e66f5 |
| pink | #f5c2e7 | #f5bde6 | #f4b8e4 | #ea76cb |
| text | #cdd6f4 | #cad3f5 | #c6d0f5 | #4c4f69 |
| overlay0 | #6c7086 | #6e738d | #737994 | #9ca0b0 |
| surface2 | #585b70 | #5b6078 | #626880 | #acb0be |
| surface1 | #45475a | #494d64 | #51576d | #bcc0cc |
| surface0 | #313244 | #363a4f | #414559 | #ccd0da |

Run it once to create the four files; commit the files and the script.

`Tools/ov.json`: role block `"pager": { "priority": 20, "flags": { "quit-if-one-screen": ["-F"], "raw-color": [], "keep-screen": ["-X"], "mouse": [], "theme": [ { "ifFile": "{theme}/config.yaml", "unlessFile": "${XDG_CONFIG_HOME}/ov/config.yaml", "args": ["--config", "{file}"] } ] } }` (remove its `env`); add `"theme": { "key": "OvTheme", "default": "catppuccin-mocha", "files": "ov" }`. Add `OvTheme = 'ov theme'` to `$script:DFConfigKeys`. Ship `Tools/ov/LICENSE-catppuccin` (copy of `Tools/eza/LICENSE-catppuccin`: the palette's MIT notice).

Run `build/Build-DFToolRegistry.ps1`.

- [ ] **Step 4: Run, expect PASS** — `tests/ov.Tests.ps1, tests/Pager.Behaviors.Tests.ps1, tests/DFSessionConfig.Tests.ps1, tests/Roles.Contract.Tests.ps1, tests/ToolRegistry.Tests.ps1`.
- [ ] **Step 5: Try it.** In a clean shell with sandbox XDG: `Start-DFSession -Config @{ Tools = @('ov') }` → `$Env:PAGER` and `$Env:BAT_PAGER` are the ov command with `--config`; `Start-DFSession -Config @{ Tools = @() }` → both `more`; `Get-ChildItem C:\Windows\System32 | Out-String | pg` exits (ov quits on `q`; skip if no console). Ask the user to look at ov's colors in their terminal.
- [ ] **Step 6: Commit** — "feat: ov pages like the other pagers, with a catppuccin theme that follows Theme".

---

### Task 6: Docs, backlog, full run, merge

**Files:** `docs/guide/configuration.md` (pager role: words, fallback, `OvTheme` in the theme-key table), `docs/guide/writing-a-tool.md` (env behaviors, flag groups, `fallback`), `docs/guide/tools.md` (less, moor, ov rows), `CLAUDE.md` (roles bullet: `fallback`, `behaviors.env`, flag groups), `docs/external-dependencies.md` (ov's `--config` and `General.Style*`; bat's `BAT_PAGER` over `PAGER`; less `--mouse`), `CHANGELOG.md`, `TODO.md` (T-35: drop the pager mention, note "pagers done (2026-10-16)").

- [ ] **Step 1:** Write the docs. Changelog: Changed — "**Pagers behave alike.** moor, ov and less now all quit when output fits one screen, keep colors, leave the output on screen and scroll with the mouse wheel; `BAT_PAGER` follows the same pager, so bat pages the same way." Added — "**`more` pages when no pager is installed.** A role can now name a fallback." and "**ov follows your theme** (`OvTheme`, else `Theme`): catppuccin colors, unless you have your own ov config."
- [ ] **Step 2:** Regenerate bundle, registry, reference; run `pwsh -NoProfile -File build/Test-DFFull.ps1`. Expected: exit 0.
- [ ] **Step 3:** Commit ("docs: pager role" … `Refs T-35`), then (standing permission) fast-forward `main` and push.
