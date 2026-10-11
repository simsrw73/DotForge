# Updating and Removing Tools Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `Update-DFTool` and `Remove-DFTool`, driven by declarations in each package manager's record, with a shared elevation chain and a manager-command runner.

**Architecture:** Each manager's `installs` block gains `install` (renamed from `command`), `update`, `remove`, `list` and `outdated`. `list`/`outdated` are functions in a new on-demand file `Tools/<manager>.manage.ps1`. Core finds where a tool came from by asking only the tool's own sources' managers, in install precedence. One runner (`Invoke-DFManagerCommand`) and one batch executor (`Invoke-DFManagerBatch`) serve install, update and remove; one elevation chain (`Get-DFElevationMethod`) decides how to get admin rights.

**Tech Stack:** PowerShell 7.2+, Pester 6.2.0.

**Spec:** `docs/superpowers/specs/2026-10-10-update-remove-design.md`

## Global Constraints

- Core never names a manager (plugin invariant; `tests/TabCompletionRole.Tests.ps1` "core plugin invariant" enforces it). Manager specifics live in `Tools/<manager>.json` and `Tools/<manager>.manage.ps1`.
- No test runs a real package manager: everything goes through `Invoke-DFManagerCommand`, which tests mock.
- `list` / `outdated` return objects `{ Id; Installed; Available }`; anything else is treated as "unknown", never a crash.
- `installs.command` is a schema error: `installs.command was renamed to installs.install`.
- Runtimes managed by fnm, mise, uv's `python` block and pymanager get no `update`/`remove` (out of scope).
- New public commands: full comment-based help, listed in `DotForge.psd1` `FunctionsToExport`, documented in `docs/guide/`, `docs/reference.md` regenerated.
- Regenerate `Bundle/` after any change to `Shared/`, `Private/`, `Public/`; regenerate `data/tool-registry.json` after any change to `Tools/*.json`.
- Gate: `build/Test-DFFull.ps1` (targeted `-Path` during a task, whole suite before merge).

## Rulings (deviations from the spec's wording, with reasons)

1. **`list`/`outdated` live in `Tools/<manager>.manage.ps1`, not the manager's companion.** A companion is dot-sourced only when its tool is active; npm may have installed tools without npm being in `Tools`. The `.manage.ps1` file is loaded on demand (`Import-DFManagerOps`), like `.setup.ps1`. Cost if wrong: one file per manager instead of edits to companions.
2. **"One planner" means one shared executor and one elevation chain**, not merging `New-DFInstallPlan` into the new commands. Install keeps its staged planner (stages, gaps, ProvidedBy); update and remove plan by grouping per manager and source, and all three run batches through `Invoke-DFManagerBatch`. Cost if wrong: a later merge of two small planners.
3. **Shape of the new operations:** `update`/`remove` are an argv array (with `{id}`) or `{ "function": "...", "args": { ... } }`; `list`/`outdated` are a function name string. `install` stays an argv array, and the existing block-level `function`/`args` (psresource) keep meaning "install".
4. **Source detection ignores `ExcludeSources`:** a tool already installed through an excluded source is still found (those sources are asked last).

## Review Focus

- A manager's `list` output that is empty, malformed, or throws → that manager counts as "doesn't have it", detection moves on (tests in Task 4).
- A tool whose `packages` names a source with no installed manager → "can't tell where it came from", listed, not an error (Task 4).
- `Update-DFTool -All` with nothing outdated → a clear "everything is up to date", exit without running anything (Task 5).
- A batched update where the manager fails partway → each tool's result is checked individually, as install does (Task 5, reusing `Invoke-DFManagerBatch`).
- `Remove-DFTool` on a tool that isn't installed anywhere → "not installed", no manager call (Task 6).

## File Structure

| File | Responsibility | Task |
| --- | --- | --- |
| `Shared/Test-DFToolSchema.ps1` | `install`/`update`/`remove`/`list`/`outdated` shapes; `command` is an error | 1 |
| `Shared/Import-DFToolDb.ps1` (`ConvertTo-DFInstallsBlock`) | normalize the five operations | 1 |
| `Tools/*.json` (14 managers) | `command` → `install` | 1 |
| `Shared/Format-DFInstallCommand.ps1`, `Private/Invoke-DFInstallPlan.ps1` | read `install` | 1 |
| `Private/Invoke-DFManagerCommand.ps1` (renamed from `Invoke-DFInstallCommand.ps1`) | the one place a manager runs; elevation methods | 2 |
| `Private/Get-DFElevationMethod.ps1` | the elevation chain | 2 |
| `Private/Invoke-DFManagerBatch.ps1` | run one batch (op, ids, elevation, per-tool result) | 3 |
| `Tools/<manager>.manage.ps1` (scoop, winget, choco, npm, pnpm, bun, pip, pipx, uv, cargo, psresource) | `list`/`outdated` parsers | W1–W3 |
| `tests/fixtures/managers/<manager>/*.txt` | recorded outputs | W1–W3 |
| `Private/Find-DFToolSource.ps1` | where a tool came from | 4 |
| `Public/Update-DFTool.ps1`, `Private/Get-DFToolUpdate.ps1` | the update table and command | 5 |
| `Public/Remove-DFTool.ps1`, `Private/Get-DFToolDependent.ps1` | removal, dependents, leftovers | 6 |
| docs, manifest, CHANGELOG, TODO | | 7 |

Owner: tasks 1–6 the coordinator; W1–W3 Orca workers (after Task 1 lands, in parallel with Tasks 2–4); Task 7 a worker.

---

### Task 1: Rename `command` to `install` and accept the new operations

**Files:**
- Modify: `Shared/Test-DFToolSchema.ps1` (`Get-DFInstallsSchemaError`, known-field list)
- Modify: `Shared/Import-DFToolDb.ps1` (`ConvertTo-DFInstallsBlock`)
- Modify: `Shared/Format-DFInstallCommand.ps1:34`, `Private/Invoke-DFInstallPlan.ps1:99`
- Modify: `Tools/{bun,cargo,choco,fnm,mise,npm,pip,pipx,pnpm,pymanager,scoop,uv,winget}.json` (psresource has no `command`)
- Modify: `docs/guide/writing-a-tool.md` (installs section), CLAUDE.md (Tool JSON Schema, `installs` line)
- Test: `tests/Installs.Schema.Tests.ps1`, `tests/ConvertTo-DFToolRecord.Tests.ps1`

**Interfaces:**
- Produces: normalized block fields `install` ([string[]] or $null), `update`, `remove` (each $null, a [string[]] argv, or `[pscustomobject]@{ function; args }`), `list`, `outdated` ([string] function name or $null). `command` no longer exists.

- [ ] **Step 1: Write the failing tests** (`tests/Installs.Schema.Tests.ps1`)

```powershell
Describe 'installs operations' {
    BeforeAll {
        $script:schema = { param($installs)
            $t = [pscustomobject]@{ name = 'm'; executable = 'm.exe'; installs = $installs }
            Test-DFToolSchema -Tool $t }
    }
    It 'rejects the old command field, naming the new one' {
        $r = & $script:schema ([pscustomobject]@{ from = 'scoop'; command = @('scoop', 'install', '{id}') })
        $r.Valid | Should -BeFalse
        $r.Errors -join ' ' | Should -BeLike '*installs.command was renamed to installs.install*'
    }
    It 'accepts install, update and remove argv, and list/outdated function names' {
        $r = & $script:schema ([pscustomobject]@{
            from = 'scoop'; install = @('scoop', 'install', '{id}'); update = @('scoop', 'update', '{id}')
            remove = @('scoop', 'uninstall', '{id}'); list = 'Get-DFScoopInstalled'; outdated = 'Get-DFScoopOutdated' })
        $r.Valid | Should -BeTrue -Because ($r.Errors -join '; ')
    }
    It 'accepts update and remove as a function with args' {
        $r = & $script:schema ([pscustomobject]@{ from = 'psgallery'; function = 'Install-PSResource'; args = [pscustomobject]@{ Name = '{id}' }
            update = [pscustomobject]@{ function = 'Update-PSResource'; args = [pscustomobject]@{ Name = '{id}' } } })
        $r.Valid | Should -BeTrue -Because ($r.Errors -join '; ')
    }
    It 'rejects a list that is not a function name' {
        $r = & $script:schema ([pscustomobject]@{ from = 'scoop'; install = @('scoop', 'install', '{id}'); list = @('scoop', 'list') })
        $r.Errors -join ' ' | Should -BeLike '*installs.list must be a function name*'
    }
}
```

And in `tests/ConvertTo-DFToolRecord.Tests.ps1`:

```powershell
It 'normalizes every installs operation' {
    $raw = '{ "name": "m", "executable": "m.exe", "installs": { "from": "scoop", "install": ["scoop","install","{id}"], "update": ["scoop","update","{id}"], "list": "Get-X" } }' | ConvertFrom-Json
    $b = @((ConvertTo-DFToolRecord $raw).installs)[0]
    $b.install | Should -Be @('scoop', 'install', '{id}')
    $b.update | Should -Be @('scoop', 'update', '{id}')
    $b.remove | Should -BeNullOrEmpty
    $b.list | Should -Be 'Get-X'
    $b.PSObject.Properties['command'] | Should -BeNullOrEmpty
}
```

- [ ] **Step 2: Run them; expect FAIL** — `pwsh -NoProfile -Command "./build/Test-DFFull.ps1 -Path tests/Installs.Schema.Tests.ps1, tests/ConvertTo-DFToolRecord.Tests.ps1"`. Expected: the five new tests fail (command still accepted; `install` unknown).

- [ ] **Step 3: Implement.** In `Get-DFInstallsSchemaError`, per block `$at`:

```powershell
if ($ins.PSObject.Properties['command']) { "$at.command was renamed to $at.install" }
foreach ($op in 'install', 'update', 'remove') {
    $v = $ins.PSObject.Properties[$op]?.Value   # read directly: a helper would unroll ["x"]
    if ($null -eq $v) { continue }
    $isArgv = $v -is [array]
    $isFn = $v -is [pscustomobject] -and $v.PSObject.Properties['function'] -and $v.function -is [string]
    if ($op -eq 'install' -and -not $isArgv) { "$at.install must be an array (argv)" }
    elseif (-not ($isArgv -or $isFn)) { "$at.$op must be an array (argv) or { function, args }" }
}
foreach ($op in 'list', 'outdated') {
    $v = $ins.PSObject.Properties[$op]?.Value
    if ($null -ne $v -and $v -isnot [string]) { "$at.$op must be a function name" }
}
```

Replace the old `command` checks (the "must be an array (argv)" and the "needs command or function" rule) with the same rules on `install`: a block needs `install` or `function`. Update the known-field list to `'from', 'install', 'update', 'remove', 'list', 'outdated', 'function', 'args', 'batch', 'elevate', 'reactivate', 'feeds'`. Keep the existing message texts for every rule that is not about `command`.

In `ConvertTo-DFInstallsBlock`, replace the `command` lines with:

```powershell
$install = Get-DFToolRecordProperty $block 'install' $null
$normalizeOp = { param($v) if ($null -eq $v) { $null } elseif ($v -is [array]) { [string[]]@($v) } else {
    [pscustomobject]@{ function = Get-DFToolRecordProperty $v 'function' $null; args = Get-DFToolRecordProperty $v 'args' $null } } }
```
and in the object: `install = $(if ($null -ne $install) { [string[]]@($install) })`, `update = & $normalizeOp (Get-DFToolRecordProperty $block 'update' $null)`, `remove = & $normalizeOp (Get-DFToolRecordProperty $block 'remove' $null)`, `list = Get-DFToolRecordProperty $block 'list' $null`, `outdated = Get-DFToolRecordProperty $block 'outdated' $null`.

In `Shared/Format-DFInstallCommand.ps1:34` and `Private/Invoke-DFInstallPlan.ps1:99` read `.install` instead of `.command`. In each `Tools/*.json` listed, rename the key `"command"` inside `installs` to `"install"` (uv has two blocks).

- [ ] **Step 4: Run the tests; expect PASS**, plus `tests/Test-DFToolSchema.Tests.ps1, tests/ToolRegistry.Tests.ps1, tests/Install-DFTool.Tests.ps1, tests/Format-DFInstallCommand.Tests.ps1` (any test that builds an installs block with `command` is updated to `install`; search `tests/` for `command = @(` and `"command"` inside installs).

- [ ] **Step 5: Regenerate and commit.** `./build/Build-DFToolRegistry.ps1; ./build/Build-DFCoreBundle.ps1`, update `docs/guide/writing-a-tool.md` and CLAUDE.md's `installs` line (`install` (argv, `{id}`) or `function`/`args`, plus `update`, `remove`, `list`, `outdated`), then
`git commit -m "feat(install)!: installs.command is now installs.install; declare update/remove/list/outdated"`.

---

### Task 2: One runner for every manager operation, and the elevation chain

**Files:**
- Rename: `Private/Invoke-DFInstallCommand.ps1` → `Private/Invoke-DFManagerCommand.ps1` (`git mv`; `Expand-DFInstallArgv` stays in it)
- Create: `Private/Get-DFElevationMethod.ps1`
- Modify: every caller and mock of `Invoke-DFInstallCommand` (search `Private/`, `Public/`, `tests/`, CLAUDE.md, `docs/`)
- Modify: `Private/New-DFInstallPlan.ps1` (`$canElevate`, batch `Elevate`/`ElevateWith` → `Elevation`), `Private/Invoke-DFInstallPlan.ps1` (the "needs an elevated shell" skip), `Private/Write-DFInstallPlan.ps1` (say how a step elevates)
- Test: `tests/Get-DFElevationMethod.Tests.ps1`, `tests/Invoke-DFManagerCommand.Tests.ps1` (renamed from the install-command test file)

**Interfaces:**
- Produces: `Get-DFElevationMethod [-ToolDb <hashtable>] [-Planned <string[]>]` → `[pscustomobject]@{ Method = 'None'|'Direct'|'Elevator'|'WindowsSudo'|'RunAs'|'Unavailable'; Executable = <string or $null>; Detail = <string> }`. `None` is never returned by the chain; callers use it for blocks that don't need elevation.
- Produces: `Invoke-DFManagerCommand -Operation <string> -Manager <record> [-Argv <string[]>] [-Function <string>] [-Arguments <hashtable>] [-Elevation <pscustomobject>]` → `{ ExitCode; Output }`. `-Elevate`/`-ElevateWith` are removed.
- Produces: `Test-DFWindowsSudoInline` → [bool] (registry `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Sudo` value `Enabled` -eq 3 and `sudo.exe` on PATH).

- [ ] **Step 1: Write the failing tests** (`tests/Get-DFElevationMethod.Tests.ps1`)

```powershell
BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
}
Describe 'Get-DFElevationMethod' {
    BeforeEach {
        Mock Test-DFElevated { $false }
        Mock Test-DFInteractiveHost { $true }
        Mock Test-DFWindowsSudoInline { $false }
        Mock Get-DFRole { $null }
        $script:db = @{ gsudo = [pscustomobject]@{ name = 'gsudo'; executable = 'gsudo'; type = 'exe' } }
    }
    It 'runs directly in an elevated shell' { (Get-DFElevationMethod).Method | Should -Be 'Direct' }  # after: Mock Test-DFElevated { $true }
    It 'uses the elevator role winner when it is installed' {
        Mock Get-DFRole { [pscustomobject]@{ Winner = 'gsudo' } }
        Mock Test-DFToolAvailable { $true }
        $m = Get-DFElevationMethod -ToolDb $script:db
        $m.Method | Should -Be 'Elevator'; $m.Executable | Should -Be 'gsudo'
    }
    It 'uses Windows sudo when it is on in inline mode and there is no elevator' {
        Mock Test-DFWindowsSudoInline { $true }
        (Get-DFElevationMethod -ToolDb $script:db).Method | Should -Be 'WindowsSudo'
    }
    It 'falls back to Start-Process RunAs' { (Get-DFElevationMethod -ToolDb $script:db).Method | Should -Be 'RunAs' }
    It 'is Unavailable with no one to answer a prompt' {
        Mock Test-DFInteractiveHost { $false }
        (Get-DFElevationMethod -ToolDb $script:db).Method | Should -Be 'Unavailable'
    }
    It 'counts a planned elevator (installed earlier in the same plan)' {
        Mock Get-DFRole { [pscustomobject]@{ Winner = 'gsudo' } }
        Mock Test-DFToolAvailable { $false }
        (Get-DFElevationMethod -ToolDb $script:db -Planned @('gsudo')).Method | Should -Be 'Elevator'
    }
}
```
(Write the first `It` with its own `Mock Test-DFElevated { $true }` inside it.)

In `tests/Invoke-DFManagerCommand.Tests.ps1`, keep the existing argv/function tests (renamed calls) and add:

```powershell
It 'runs through the elevator for the Elevator method' {
    function global:fake-elevator { $global:DFElevated = @($args) }
    try {
        $null = Invoke-DFManagerCommand -Operation install -Manager ([pscustomobject]@{ name = 'm' }) -Argv @('m', 'install', 'x') `
            -Elevation ([pscustomobject]@{ Method = 'Elevator'; Executable = 'fake-elevator' })
        $global:DFElevated | Should -Be @('m', 'install', 'x')
    } finally { Remove-DFTestGlobal -Function fake-elevator; Remove-Variable DFElevated -Scope Global -ErrorAction Ignore }
}
It 'uses Start-Process -Verb RunAs for the RunAs method and reports only the exit code' {
    Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }
    $r = Invoke-DFManagerCommand -Operation install -Manager ([pscustomobject]@{ name = 'm' }) -Argv @('m', 'install', 'a b') `
        -Elevation ([pscustomobject]@{ Method = 'RunAs' })
    $r.ExitCode | Should -Be 0
    $r.Output | Should -BeLike '*separate administrator window*'
    Should -Invoke Start-Process -Times 1 -ParameterFilter { $Verb -eq 'RunAs' -and $Wait -and $FilePath -eq 'm' -and $ArgumentList -contains '"a b"' }
}
It 'refuses to run a step that needs admin when elevation is Unavailable' {
    $r = Invoke-DFManagerCommand -Operation install -Manager ([pscustomobject]@{ name = 'm' }) -Argv @('m') `
        -Elevation ([pscustomobject]@{ Method = 'Unavailable'; Detail = 'no one to answer the admin prompt' })
    $r.ExitCode | Should -Not -Be 0
    $r.Output | Should -BeLike '*no one to answer the admin prompt*'
}
```

- [ ] **Step 2: Run; expect FAIL** (functions don't exist).

- [ ] **Step 3: Implement `Get-DFElevationMethod`:**

```powershell
function Test-DFWindowsSudoInline {
    <# .SYNOPSIS True when Windows' built-in sudo is enabled in inline mode (Settings > For developers). .OUTPUTS System.Boolean. #>
    [CmdletBinding()] [OutputType([bool])] param()
    $enabled = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Sudo' -Name Enabled -ErrorAction Ignore).Enabled
    $enabled -eq 3 -and [bool](Get-Command sudo.exe -CommandType Application -ErrorAction Ignore)
}

function Get-DFElevationMethod {
    <# (full help: synopsis, the order, each parameter, outputs) #>
    [CmdletBinding()]
    param([hashtable]$ToolDb = @{}, [string[]]$Planned = @())
    if (Test-DFElevated) { return [pscustomobject]@{ Method = 'Direct'; Executable = $null; Detail = 'already elevated' } }
    $winner = (Get-DFRole 'elevator' -ErrorAction Ignore).Winner
    $elevator = if ($winner) { $ToolDb[$winner] }
    if ($elevator -and ($elevator.name -in $Planned -or (Test-DFToolAvailable -Executable $elevator.executable -Type $elevator.type))) {
        return [pscustomobject]@{ Method = 'Elevator'; Executable = $elevator.executable; Detail = "through $($elevator.name)" }
    }
    if (-not (Test-DFInteractiveHost)) {
        return [pscustomobject]@{ Method = 'Unavailable'; Executable = $null; Detail = 'no one to answer the admin prompt' }
    }
    if (Test-DFWindowsSudoInline) { return [pscustomobject]@{ Method = 'WindowsSudo'; Executable = 'sudo'; Detail = "through Windows' sudo" } }
    [pscustomobject]@{ Method = 'RunAs'; Executable = $null; Detail = 'in a separate administrator window (exit code only)' }
}
```
Note the non-interactive check comes after the elevator: gsudo also prompts, but `New-DFInstallPlan` already treats a planned/installed elevator as usable today; keep that, and only the prompt-only methods (WindowsSudo, RunAs) need a person.

In `Invoke-DFManagerCommand`, replace the `$exe, $rest = ...` line with:

```powershell
$method = $Elevation?.Method ?? 'None'
if ($method -eq 'Unavailable') { return [pscustomobject]@{ ExitCode = 1; Output = "$($Manager.name) needs administrator rights: $($Elevation.Detail)" } }
if ($method -eq 'RunAs') {
    $quoted = @($Argv | Select-Object -Skip 1 | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } })
    $p = Start-Process -FilePath $Argv[0] -ArgumentList $quoted -Verb RunAs -Wait -PassThru
    return [pscustomobject]@{ ExitCode = $p.ExitCode; Output = "ran in a separate administrator window (exit code $($p.ExitCode))" }
}
$exe, $rest = if ($method -in 'Elevator', 'WindowsSudo') { $Elevation.Executable, $Argv } else { $Argv[0], @($Argv | Select-Object -Skip 1) }
```
`-Operation` is used in messages only (`"$($Manager.name) $Operation failed"` in callers).

In `New-DFInstallPlan`: compute `$elevation = Get-DFElevationMethod -ToolDb $ToolDb -Planned $want` once; `$canElevate = $elevation.Method -ne 'Unavailable'`; each batch gets `Elevation = $(if ($blk.elevate -and $elevation.Method -ne 'Direct') { $elevation } else { $null })` instead of `Elevate`/`ElevateWith`. In `Invoke-DFInstallPlan`, drop the "needs an elevated shell" skip (the runner reports Unavailable) and pass `-Elevation $batch.Elevation`. In `Write-DFInstallPlan`, print `(<Detail>)` after a batch that has an Elevation.

- [ ] **Step 4: Run** `tests/Get-DFElevationMethod.Tests.ps1, tests/Invoke-DFManagerCommand.Tests.ps1, tests/Install-DFTool.Tests.ps1, tests/New-DFInstallPlan.Tests.ps1, tests/Invoke-DFInstallPlan.Tests.ps1` (rename every `Mock Invoke-DFInstallCommand` to `Mock Invoke-DFManagerCommand`; tests that asserted "skipped: needs an elevated shell" now assert the RunAs/Unavailable behavior). Expected: PASS. Update CLAUDE.md ("`Invoke-DFInstallCommand` is the only place a manager runs" → `Invoke-DFManagerCommand`).

- [ ] **Step 5: Bundle, commit:** `git commit -m "feat(install): one manager-command runner; elevation falls back to Windows sudo and Start-Process RunAs"`; CHANGELOG (Changed): choco and other admin installs no longer need gsudo.

---

### Task 3: A shared batch executor

**Files:**
- Create: `Private/Invoke-DFManagerBatch.ps1`
- Modify: `Private/Invoke-DFInstallPlan.ps1` (its inner batch loop calls the new function)
- Test: `tests/Invoke-DFManagerBatch.Tests.ps1`

**Interfaces:**
- Consumes: `Invoke-DFManagerCommand`, `Expand-DFInstallArgv` (Task 2).
- Produces: `Invoke-DFManagerBatch -Operation <install|update|remove> -Manager <record> -Block <normalized block> -Ids <string[]> [-Elevation <obj>]` → one result per id: `[pscustomobject]@{ Id; ExitCode; Output }`. Batches when `Block.batch`, else one call per id. For a batched call every id gets the same ExitCode/Output; callers verify per tool (install already does with `Test-DFToolAvailable`).
  Operation spec: `install` → `Block.install` argv, or `Block.function`/`Block.args`; `update`/`remove` → `Block.$Operation` (argv, or `{ function; args }` with `'{id}'` args replaced by the ids). A missing operation → results with `ExitCode = -1; Output = "can't <op> through <manager>"` and no call.

- [ ] **Step 1: Failing tests:**

```powershell
Describe 'Invoke-DFManagerBatch' {
    BeforeEach { Mock Invoke-DFManagerCommand { [pscustomobject]@{ ExitCode = 0; Output = 'ok' } } }
    $m = [pscustomobject]@{ name = 'm' }
    It 'makes one call for a batching manager' {
        $b = [pscustomobject]@{ batch = $true; update = [string[]]@('m', 'update', '{id}') }
        $r = Invoke-DFManagerBatch -Operation update -Manager $m -Block $b -Ids @('a', 'b')
        @($r).Count | Should -Be 2
        Should -Invoke Invoke-DFManagerCommand -Times 1 -Exactly -ParameterFilter { ($Argv -join ' ') -eq 'm update a b' }
    }
    It 'makes one call per id otherwise' {
        $b = [pscustomobject]@{ batch = $false; remove = [string[]]@('m', 'rm', '{id}') }
        $null = Invoke-DFManagerBatch -Operation remove -Manager $m -Block $b -Ids @('a', 'b')
        Should -Invoke Invoke-DFManagerCommand -Times 2 -Exactly
    }
    It 'calls a function operation with {id} replaced' {
        $b = [pscustomobject]@{ batch = $true; update = [pscustomobject]@{ function = 'Update-X'; args = [pscustomobject]@{ Name = '{id}'; Scope = 'CurrentUser' } } }
        $null = Invoke-DFManagerBatch -Operation update -Manager $m -Block $b -Ids @('a')
        Should -Invoke Invoke-DFManagerCommand -ParameterFilter { $Function -eq 'Update-X' -and $Arguments.Name -contains 'a' -and $Arguments.Scope -eq 'CurrentUser' }
    }
    It 'reports an operation the manager does not declare, without calling it' {
        $r = @(Invoke-DFManagerBatch -Operation update -Manager $m -Block ([pscustomobject]@{ batch = $true }) -Ids @('a'))
        $r[0].ExitCode | Should -Be -1
        $r[0].Output | Should -Be "can't update through m"
        Should -Invoke Invoke-DFManagerCommand -Times 0
    }
}
```

- [ ] **Step 2: Run; expect FAIL.**
- [ ] **Step 3: Implement** by moving the id-grouping and call code from `Invoke-DFInstallPlan` (the `$groups` / `$r = if ($blk.function) ... else ...` block) into the function, generalized by `-Operation`; `Invoke-DFInstallPlan` keeps feeds, `$idOf`, per-tool result checks and reactivation, and calls `Invoke-DFManagerBatch -Operation install`.
- [ ] **Step 4: Run** the new test plus `tests/Invoke-DFInstallPlan.Tests.ps1, tests/Install-DFTool.Tests.ps1`; expect PASS (install behavior unchanged).
- [ ] **Step 5: Commit** `refactor(install): a shared batch executor for install, update and remove`.

---

### Tasks W1–W3 (workers, after Task 1): each manager's operations

One worker per group: **W1** scoop, winget, choco · **W2** npm, pnpm, bun · **W3** pip, pipx, uv (its `pypi` block only), cargo, psresource. fnm, mise, pymanager and uv's `python` block get nothing (out of scope).

**Files (per manager `<m>`):**
- Modify: `Tools/<m>.json` — add `update`, `remove` (argv or function form), `list`, `outdated` (function names) to the block. Commands:

| Manager | update | remove | list / outdated source |
| --- | --- | --- | --- |
| scoop | `scoop update {id}` (batch) | `scoop uninstall {id}` | `scoop list` / `scoop status` |
| winget | `winget upgrade --id {id} --exact --silent --accept-source-agreements --accept-package-agreements` | `winget uninstall --id {id} --exact --silent` | `winget list --source winget` / `winget upgrade --source winget` (use `Get-WinGetPackage` when the Microsoft.WinGet.Client module is available, as `Tools/winget.ps1` does) |
| choco | `choco upgrade {id} -y` (elevate) | `choco uninstall {id} -y` (elevate) | `choco list --limit-output` / `choco outdated --limit-output` |
| npm | `npm install -g {id}@latest` | `npm uninstall -g {id}` | `npm ls -g --depth=0 --json` / `npm outdated -g --json` |
| pnpm | `pnpm add -g {id}@latest` | `pnpm remove -g {id}` | `pnpm ls -g --json` / `pnpm outdated -g --format json` |
| bun | `bun add -g {id}@latest` | `bun remove -g {id}` | `bun pm ls -g` / none (`outdated` omitted) |
| pip | `pip install --user --upgrade {id}` | `pip uninstall -y {id}` | `pip list --user --format=json` / `pip list --user --outdated --format=json` |
| pipx | `pipx upgrade {id}` | `pipx uninstall {id}` | `pipx list --json` / none (omit) |
| uv (pypi block) | `uv tool upgrade {id}` | `uv tool uninstall {id}` | `uv tool list` / none (omit) |
| cargo | `cargo install --force {id}` | `cargo uninstall {id}` | `cargo install --list` / none (omit) |
| psresource | `{ function: Update-PSResource, args: { Name: {id}, Scope: CurrentUser, TrustRepository: true } }` | `{ function: Uninstall-PSResource, args: { Name: {id}, Scope: CurrentUser } }` | `Get-InstalledPSResource -Scope CurrentUser` / compare with `Find-PSResource` |

- Create: `Tools/<m>.manage.ps1` defining `Get-DF<M>Installed` and (where listed) `Get-DF<M>Outdated`, each `[CmdletBinding()]`, full comment-based help, returning `[pscustomobject]@{ Id; Installed; Available }` (`Available` = `$null` from `list`). They run the manager through `Invoke-DFManagerCommand -Operation list -Manager $DFCurrentManager -Argv @(...)` (never `& scoop` directly), so tests mock it. Parsing code may be copied from `Modules/DotForge.Catalog/Private/DFCatalog.<Source>.ps1`; never call it.
- Create: `tests/fixtures/managers/<m>/list.txt`, `outdated.txt` — real output captured once on this machine (`scoop status > ...`), trimmed to ~5 packages, plus `empty.txt`.
- Test: `tests/<m>.Manage.Tests.ps1`, per function: the recorded sample parses to the expected objects (assert 2–3 exact rows); empty output → empty array; garbage output (`"error: something"`) → empty array, no throw.

Contract test each worker adds (copy into each manage test file):

```powershell
It 'returns only { Id; Installed; Available } objects' {
    Mock Invoke-DFManagerCommand { [pscustomobject]@{ ExitCode = 0; Output = (Get-Content "$PSScriptRoot/fixtures/managers/scoop/outdated.txt" -Raw) } }
    $rows = @(Get-DFScoopOutdated)
    $rows.Count | Should -BeGreaterThan 0
    foreach ($r in $rows) { ($r.PSObject.Properties.Name | Sort-Object) -join ',' | Should -Be 'Available,Id,Installed' }
}
```

After each worker: `./build/Build-DFToolRegistry.ps1`; run `tests/<m>.Manage.Tests.ps1, tests/Installs.Schema.Tests.ps1, tests/ToolRegistry.Tests.ps1`. Workers follow `RULES.md` (no commits; coordinator integrates).

---

### Task 4: Find where a tool came from

**Files:**
- Create: `Private/Find-DFToolSource.ps1` (`Import-DFManagerOps`, `Get-DFManagerInstalled`, `Find-DFToolSource`)
- Test: `tests/Find-DFToolSource.Tests.ps1`

**Interfaces:**
- Consumes: `Get-DFInstallSourceOrder`, `Get-DFSourceManager`, `Get-DFInstallBlock`, `Get-DFPackageRef` (existing); `list` function names (Task 1, W1–W3).
- Produces: `Import-DFManagerOps -Manager <record> [-ToolsPath]` (dot-sources `Tools/<name>.manage.ps1` once per session, into script scope; no-op if absent).
- Produces: `Get-DFManagerInstalled -Manager <record> -Block <block> [-Cache <hashtable>]` → rows `{ Id; Installed; Available }`; empty when the function is missing, throws, or returns the wrong shape (shape check: every row has a non-empty string `Id`). Cached per manager name in `-Cache` for one command run.
- Produces: `Find-DFToolSource -Tool <record> -ToolDb <hashtable> [-Cache <hashtable>]` → `[pscustomobject]@{ Tool; Source; Manager; Block; Id; Installed; Detail }`; `Manager = $null` with `Detail` ("not installed through any of: scoop, winget" / "no manager for <source> is installed") when not found.

- [ ] **Step 1: Failing tests:**

```powershell
Describe 'Find-DFToolSource' {
    BeforeEach {
        $script:scoop = [pscustomobject]@{ name = 'scoop'; executable = 'scoop'; type = 'exe'; installs = @([pscustomobject]@{ from = 'scoop'; list = 'Get-FakeScoopInstalled' }) }
        $script:winget = [pscustomobject]@{ name = 'winget'; executable = 'winget'; type = 'exe'; installs = @([pscustomobject]@{ from = 'winget'; list = 'Get-FakeWingetInstalled' }) }
        $script:tool = [pscustomobject]@{ name = 'rg'; executable = 'rg'; packages = [pscustomobject]@{ scoop = 'ripgrep'; winget = 'BurntSushi.ripgrep.MSVC' }; install = $null }
        $script:db = @{ scoop = $script:scoop; winget = $script:winget; rg = $script:tool }
        Mock Import-DFManagerOps { }
        Mock Test-DFToolAvailable { $true }
        Set-DFTestConfig @{ InstallOrder = @('scoop', 'winget') }
        function script:Get-FakeScoopInstalled { [pscustomobject]@{ Id = 'ripgrep'; Installed = '14.1.0'; Available = $null } }
        function script:Get-FakeWingetInstalled { throw 'should not be asked' }
    }
    AfterEach { Set-DFTestConfig $null }
    It 'asks the first manager in precedence order and stops at a match' {
        $r = Find-DFToolSource -Tool $script:tool -ToolDb $script:db
        $r.Manager.name | Should -Be 'scoop'; $r.Installed | Should -Be '14.1.0'
    }
    It 'moves on when the first manager does not have it' {
        function script:Get-FakeScoopInstalled { }
        function script:Get-FakeWingetInstalled { [pscustomobject]@{ Id = 'BurntSushi.ripgrep.MSVC'; Installed = '14.0'; Available = $null } }
        (Find-DFToolSource -Tool $script:tool -ToolDb $script:db).Manager.name | Should -Be 'winget'
    }
    It 'treats a list function that throws as not having it' {
        function script:Get-FakeScoopInstalled { throw 'boom' }
        function script:Get-FakeWingetInstalled { }
        $r = Find-DFToolSource -Tool $script:tool -ToolDb $script:db
        $r.Manager | Should -BeNullOrEmpty; $r.Detail | Should -BeLike 'not installed through any of: scoop, winget'
    }
    It 'skips a manager that is not installed' {
        Mock Test-DFToolAvailable { $false } -ParameterFilter { $Executable -eq 'scoop' }
        function script:Get-FakeWingetInstalled { [pscustomobject]@{ Id = 'BurntSushi.ripgrep.MSVC'; Installed = '14.0'; Available = $null } }
        (Find-DFToolSource -Tool $script:tool -ToolDb $script:db).Manager.name | Should -Be 'winget'
    }
    It 'asks a manager once per command run, however many tools' {
        $cache = @{}
        Mock Get-FakeScoopInstalled { [pscustomobject]@{ Id = 'ripgrep'; Installed = '1'; Available = $null } }
        $null = Find-DFToolSource -Tool $script:tool -ToolDb $script:db -Cache $cache
        $null = Find-DFToolSource -Tool $script:tool -ToolDb $script:db -Cache $cache
        Should -Invoke Get-FakeScoopInstalled -Times 1 -Exactly
    }
}
```
(The "not installed" probe needs a default `Mock Test-DFToolAvailable { $true }` alongside the filtered one.)

- [ ] **Step 2: Run; expect FAIL.**
- [ ] **Step 3: Implement.** Source order: `Get-DFInstallSourceOrder -Tool $Tool -ToolDb $ToolDb`, then append the tool's remaining package sources (excluded ones), unique. For each source, for each manager from `Get-DFSourceManager` that `Test-DFToolAvailable` reports installed: `Import-DFManagerOps`; rows = `Get-DFManagerInstalled`; id = `(Get-DFPackageRef $Tool.packages.$source).Id`; match case-insensitively on `Id`, also matching `<feed>/<id>` for feed packages (scoop buckets). First match wins. Wrap the list call in try/catch; validate shape.
- [ ] **Step 4: Run; expect PASS.**
- [ ] **Step 5: Commit** `feat(install): find which manager a tool was installed through`.

---

### Task 5: `Update-DFTool`

**Files:**
- Create: `Private/Get-DFToolUpdate.ps1`, `Public/Update-DFTool.ps1`
- Modify: `DotForge.psd1` (`FunctionsToExport`)
- Test: `tests/Update-DFTool.Tests.ps1`

**Interfaces:**
- Consumes: `Find-DFToolSource`, `Get-DFManagerInstalled` (Task 4); `Invoke-DFManagerBatch` (Task 3); `Get-DFElevationMethod` (Task 2).
- Produces: `Get-DFToolUpdate -Name <string[]> -ToolDb <hashtable>` → `DotForge.ToolUpdate` objects `{ Tool; Manager; Installed; Available; State }` with `State` = `Outdated` | `UpToDate` | `Unknown` | `NotFound` | `Runtime`. `Available` comes from the manager's `outdated` rows (one call per manager, cached); a manager without `outdated` → `Unknown`. A tool whose source is a version manager (`fnm`, `mise`, `uv`'s python block, `pymanager`: a block without `update`) → `Runtime` with the hint "managed by <manager>".
- Produces: `Update-DFTool [-Name <string[]>] [-All] [-ToolsPath] [-WhatIf] [-Confirm]` (`SupportsShouldProcess`): no `-Name`/`-All` → returns the `Get-DFToolUpdate` rows for active tools and stops. `-All` / `-Name` → updates rows with `State` `Outdated` or `Unknown`, grouped by manager+source, through `Invoke-DFManagerBatch -Operation update`, elevation from `Get-DFElevationMethod` for blocks with `elevate`; then re-activates tools whose block has `reactivate`; returns `{ Tool; Result = Updated|Failed|Skipped; Detail }`. Nothing to update → writes "Everything is up to date." and runs nothing.

- [ ] **Step 1: Failing tests** — mock `Find-DFToolSource`, `Get-DFManagerInstalled` (outdated rows), `Invoke-DFManagerBatch`; cover: bare call runs no batch and returns the table; `-All` updates only Outdated+Unknown; `-WhatIf` runs no batch; a Runtime tool is reported with its hint and not updated; nothing outdated → message, no batch; a failed batch marks its tools Failed with the manager's last output lines.

```powershell
It 'shows the table and updates nothing when called bare' {
    $rows = Update-DFTool -ToolsPath $script:Tools
    @($rows | Where-Object State -eq 'Outdated').Tool | Should -Be @('fzf')
    Should -Invoke Invoke-DFManagerBatch -Times 0
}
It 'updates outdated and unknown tools with -All' {
    $null = Update-DFTool -All -Confirm:$false -ToolsPath $script:Tools
    Should -Invoke Invoke-DFManagerBatch -ParameterFilter { $Operation -eq 'update' -and ($Ids -join ',') -eq 'fzf' } -Times 1
    Should -Invoke Invoke-DFManagerBatch -ParameterFilter { ($Ids -join ',') -eq 'lazygit' } -Times 1   # Unknown
    Should -Invoke Invoke-DFManagerBatch -ParameterFilter { $Ids -contains 'bat' } -Times 0          # UpToDate
}
```
(Set up three active tools: fzf Outdated via scoop, bat UpToDate via winget, lazygit Unknown via a manager without `outdated`.)

- [ ] **Step 2–4:** fail, implement, pass (plus `tests/Docs.Help.Tests.ps1, tests/PublicSurface.Tests.ps1, tests/ModuleSplit.Tests.ps1`).
- [ ] **Step 5: Commit** `feat: Update-DFTool`.

---

### Task 6: `Remove-DFTool`

**Files:**
- Create: `Private/Get-DFToolDependent.ps1`, `Public/Remove-DFTool.ps1`
- Modify: `DotForge.psd1`
- Test: `tests/Remove-DFTool.Tests.ps1`, `tests/Get-DFToolDependent.Tests.ps1`

**Interfaces:**
- Consumes: `Find-DFToolSource`, `Get-DFManagerInstalled`, `Invoke-DFManagerBatch`, `Get-DFElevationMethod`, `Get-DFToolSetupState`, `New-DFToolStatus`.
- Produces: `Get-DFToolDependent -Name <string> -ToolDb <hashtable> -Active <string[]> [-Transitive]` → names of active tools that `requires` it, or `requires role:<r>` where it is the only active member of `<r>`; with `-Transitive`, the full chain, ordered dependents-first (deepest first).
- Produces: `Remove-DFTool -Name <string[]> [-Force] [-IncludeDependents] [-ToolsPath] [-WhatIf] [-Confirm]` (`ConfirmImpact = 'High'`) → `{ Tool; Result = Removed|Refused|NotInstalled|Failed; Detail }`, then the leftovers report (Write-Host lines): seeded files that still exist (from the tool's `setup.seed` destinations), recorded setup actions (from `setup-state.json` `actions`), and "remove '<tool>' from Tools in your profile". Status: `$script:DFSessionStatus[<tool>]` set to Missing, Detail "removed by Remove-DFTool", and one line "its aliases and functions stay until you open a new shell".

- [ ] **Step 1: Failing tests:**
  - refused when an active tool requires it: result `Refused`, Detail names PSFzf, no batch;
  - `-Force` removes anyway;
  - `-IncludeDependents` removes PSFzf then fzf (assert call order with a recording mock), one ShouldProcess prompt (`-Confirm:$false` in the test; assert `-WhatIf` removes nothing);
  - the only member of a required role counts as required (`inshellisense` requires `role:js-runtime`, only `node` active);
  - a manager with installed tools (its `Get-DFManagerInstalled` returns rows) → `Refused` naming them, even with `-IncludeDependents`; with `-Force` it removes and does not cascade;
  - a tool not installed anywhere → `NotInstalled`, no batch;
  - leftovers: a seeded file that exists is listed; a recorded action is listed; the `Tools` line is printed.
- [ ] **Step 2–4:** fail, implement, pass.
- [ ] **Step 5: Commit** `feat: Remove-DFTool with dependent checks and a leftovers report`.

---

### Task 7: Docs and wrap-up (worker)

- [ ] `docs/guide/` — a section "Updating and removing tools" in the page that documents `Install-DFTool` (find it with `rg -l "Install-DFTool -Missing" docs/guide`): the table, `-All`, `-Name`, `-WhatIf`; `Remove-DFTool` with the dependents rules and the leftovers report. Examples that would change the machine get `<!-- system -->`.
- [ ] `docs/guide/writing-a-tool.md` — the five operations and `Tools/<manager>.manage.ps1` (contract `{ Id; Installed; Available }`, recorded-sample tests).
- [ ] CHANGELOG `[Unreleased]`: Added (`Update-DFTool`, `Remove-DFTool`), Changed (elevation fallbacks; `installs.command` → `installs.install`, breaking for hand-written manager records).
- [ ] `./build/Build-DFReferenceDocs.ps1`, `./build/Build-DFCoreBundle.ps1`, `./build/Build-DFToolRegistry.ps1`.
- [ ] `TODO.md`: delete T-44 (`Closes T-44` in the commit); add `-Purge` as a new item next to T-38.
- [ ] Full gate: `pwsh -NoProfile -File build/Test-DFFull.ps1` → `Failed 0 ... FailedContainers 0 SentinelFiles 0`.
