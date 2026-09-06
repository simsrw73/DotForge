# Async Module Prewarm Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Revision note (2026-09-05, final whole-branch review):** The Architecture section below
> originally stated this applies to "every `type: module` tool ... with no new declarative JSON
> field." That was revised during the final review: `Tools/psreadline.json` now declares
> `"prewarm": false` and is excluded from the prewarm-eligible set. Reasoning: `Start-ThreadJob`
> shares the caller's *process* (only PowerShell-level session state is isolated per-runspace),
> so a module whose import touches process-global .NET/CLR static state is a real, if narrow,
> concurrency risk — PSReadLine keeps its key-handler dispatch table on exactly such a static
> singleton, and PSFzf's import touches it. Compounding that risk, `psreadline` gets zero benefit
> from prewarming anyway: `Tools/psreadline.ps1` never calls `Import-Module` (PSReadLine is
> always pre-loaded by the PS7 host before any profile runs). The rest of this document is left
> as originally written; treat any statement below that the mechanism is opt-out-free as
> superseded by this note.

**Goal:** Cut the real, per-session cost of importing `Terminal-Icons`, `PSFzf`, and `posh-git` (measured 352ms + 258ms + 288ms = 898ms cold, on a representative machine) by warming each module's OS/CLR-level caches in a background job before `Register-DFTool`'s own per-tool loop reaches that tool's existing, unchanged `Import-Module` call.

**Architecture:** A new private helper, `Start-DFModulePrewarm`, fires one `Start-ThreadJob` that imports a list of module names inside its own throwaway runspace and discards the result — its only purpose is the side effect of warming caches. `Register-DFTool` collects every `type: module` tool actually being registered this call (post topo-sort, post `SkipTools` filtering, post `Test-DFToolAvailable`), fires the prewarm job for those module names right before the per-tool loop starts, lets the loop run exactly as it does today (each module-type tool's own companion still does the real, synchronous `Import-Module`), and cleans up the job afterward. No sidecar file changes. No new declarative JSON field — this applies automatically to every `type: module` tool, present or future, based on the field that already exists.

**Tech Stack:** PowerShell 7+, Pester 5/6, `Microsoft.PowerShell.ThreadJob` (PS7 inbox module, auto-loads on first `Start-ThreadJob` call — verified empirically, no explicit `Import-Module` needed).

## Global Constraints

- No `$ErrorActionPreference = 'Stop'` in any module file (existing repo convention).
- Every public function needs complete comment-based help (`.SYNOPSIS`/`.DESCRIPTION`/`.PARAMETER`/`.EXAMPLE`/`.OUTPUTS`) — not applicable here since both new pieces of surface are `Private/`, but `Private` functions still get a `.SYNOPSIS`/`.DESCRIPTION` per existing repo convention (see `Private/Get-DFCachedCommandOutput.ps1`, `Private/Test-DFToolAvailable.ps1` for the house style).
- `[Diagnostics.CodeAnalysis.SuppressMessageAttribute(...)]`, if ever needed, MUST be placed **after** any comment-based help block, never before — a `SuppressMessageAttribute` placed before comment-based help breaks `Get-Help` silently (this exact bug has been found and fixed twice already this session: `Register-DFTool`, `Invoke-DFToolCompanion`).
- Never call `Receive-Job` or otherwise depend on the prewarm job's *output* for correctness — its entire contract is "may or may not have finished; either way, the real, unchanged `Import-Module` call downstream is what actually matters." A test that asserts on the prewarm job's return value defeats the point of it being fire-and-forget.
- This plan's scope is the three module imports only. `inshellisense`'s `is -c` session check (also flagged as an async-deferral candidate in `docs/superpowers/specs/2026-09-05-startup-perf-audit.md`) is a **separate, differently-shaped mechanism** (a native command's exit code, consumed later inside `Initialize-DFCompletionStack`, not a module import) and is explicitly out of scope for this plan — tracked as its own follow-up in `TODO.md`.
- `oh-my-posh` and `fnm` are never touched by this plan, in any task. Confirmed in the audit: deferring `oh-my-posh`'s init reproduces the documented oh-my-posh/zoxide prompt-hook bug (see `CLAUDE.md`'s "oh-my-posh + zoxide prompt hook ordering" section) on every session instead of only after a manual theme switch. Neither tool is `type: module` anyway, so this plan's mechanism does not reach them — this constraint exists to stop a future contributor from "generalizing" this pattern onto them.

---

### Task 1: `Start-DFModulePrewarm` private helper

**Files:**
- Create: `Private/Start-DFModulePrewarm.ps1`
- Test: `tests/Start-DFModulePrewarm.Tests.ps1`

**Interfaces:**
- Produces: `Start-DFModulePrewarm -ModuleNames <string[]>` → `[System.Management.Automation.Job]` (or `$null` when `-ModuleNames` is empty). Task 2 consumes this signature directly.

- [ ] **Step 1: Write the failing tests**

```powershell
BeforeAll {
    . "$PSScriptRoot/../Private/Start-DFModulePrewarm.ps1"
}

Describe 'Start-DFModulePrewarm' {
    It 'returns $null and starts no job when -ModuleNames is empty' {
        Start-DFModulePrewarm -ModuleNames @() | Should -BeNullOrEmpty
    }

    It 'returns a job that completes without throwing for a real, importable module' {
        $job = Start-DFModulePrewarm -ModuleNames @('Microsoft.PowerShell.Management')
        $job | Should -Not -BeNullOrEmpty
        $job | Wait-Job -Timeout 10 | Out-Null
        $job.State | Should -Be 'Completed'
        $job | Remove-Job -Force
    }

    It 'tolerates a module name that does not exist, without the job failing' {
        $job = Start-DFModulePrewarm -ModuleNames @('ThisModuleDoesNotExist12345')
        $job | Wait-Job -Timeout 10 | Out-Null
        $job.State | Should -Be 'Completed'
        $job | Remove-Job -Force
    }

    It 'imports every named module in its own runspace, never the caller''s' {
        # Regression for the exact invariant this function exists to exploit --
        # confirmed empirically in docs/superpowers/specs/2026-09-05-startup-perf-audit.md
        # that a background-job import never crosses into the caller's session.
        $job = Start-DFModulePrewarm -ModuleNames @('Microsoft.PowerShell.Archive')
        $job | Wait-Job -Timeout 10 | Out-Null
        Get-Module -Name 'Microsoft.PowerShell.Archive' | Should -BeNullOrEmpty
        $job | Remove-Job -Force
    }

    It 'imports multiple named modules from the same job' {
        $job = Start-DFModulePrewarm -ModuleNames @('Microsoft.PowerShell.Management', 'Microsoft.PowerShell.Archive')
        $job | Wait-Job -Timeout 10 | Out-Null
        $job.State | Should -Be 'Completed'
        $job | Remove-Job -Force
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Start-DFModulePrewarm.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Start-DFModulePrewarm` is not recognized (the file doesn't exist yet).

- [ ] **Step 3: Write the implementation**

```powershell
#Requires -Version 7.0

function Start-DFModulePrewarm {
    <#
    .SYNOPSIS
        Fires a background job that imports each named module in its own
        throwaway runspace, purely to warm OS/CLR-level caches.
    .DESCRIPTION
        PowerShell runspaces do not share loaded modules, defined functions,
        or $global: state (confirmed empirically -- see
        docs/superpowers/specs/2026-09-05-startup-perf-audit.md Part 2), so
        the import performed here is never visible to the caller's session.
        This function's only purpose is the side effect of touching the
        module's files once before the caller's own (unchanged)
        Import-Module call reaches them -- that later, real import is then
        fast, due to already-warm OS/CLR-level caches (measured ~77%
        reduction on a representative module, reproduced 3/3).

        Nothing depends on this job succeeding, finishing before the caller
        continues, or running at all: a module that fails to import here is
        silently ignored (the caller's own real import will report any real
        failure normally), and a caller that never waits on the returned
        job simply gets today's synchronous-import cost for whichever
        modules the job didn't reach in time -- never worse than not
        calling this function at all.

        Assumes the named modules have no import-time side effects beyond
        session-local state (defining functions, format/type data, etc.) --
        true of Terminal-Icons/PSFzf/posh-git, this function's motivating
        callers. A module whose import writes files, calls the network, or
        otherwise mutates state outside its own session would have that
        side effect run twice (once here, discarded; once for real) if
        pointed at this function -- not a fit for that kind of module.
    .PARAMETER ModuleNames
        Module names to pre-import, e.g. @('Terminal-Icons', 'PSFzf'). May
        be empty.
    .OUTPUTS
        [System.Management.Automation.Job] the started background job, or
        $null when -ModuleNames is empty. Never call Receive-Job on it for
        its result -- there is nothing meaningful to receive, since the
        import happened in a runspace the caller can't see into. The
        caller should Remove-Job -Force it once done with its own work,
        whether or not the job has finished by then.
    .EXAMPLE
        Start-DFModulePrewarm -ModuleNames @('Terminal-Icons', 'PSFzf', 'posh-git')
    #>
    [CmdletBinding()]
    [OutputType([System.Management.Automation.Job])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$ModuleNames
    )

    if (-not $ModuleNames) {
        return $null
    }

    Start-ThreadJob -ScriptBlock {
        param([string[]]$Names)
        foreach ($name in $Names) {
            try { Import-Module -Name $name -ErrorAction Stop } catch { }
        }
    } -ArgumentList (, $ModuleNames)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Start-DFModulePrewarm.Tests.ps1 -Output Detailed"`
Expected: PASS — 5/5.

- [ ] **Step 5: Commit**

```bash
git add Private/Start-DFModulePrewarm.ps1 tests/Start-DFModulePrewarm.Tests.ps1
git commit -m "feat: add Start-DFModulePrewarm background cache-warming helper"
```

---

### Task 2: Wire prewarming into `Register-DFTool`'s per-tool loop

**Files:**
- Modify: `Public/Register-DFTool.ps1`
- Test: `tests/Register-DFTool.Tests.ps1`

**Interfaces:**
- Consumes: `Start-DFModulePrewarm -ModuleNames <string[]>` → `[System.Management.Automation.Job]` / `$null` (Task 1).
- Consumes: `Test-DFToolAvailable -Executable <string> -Type 'module'` → `[bool]` (existing, `Private/Test-DFToolAvailable.ps1`).

The exact insertion points below are anchored to `Public/Register-DFTool.ps1`'s current content (see the file for full context — only the two new blocks are shown as diffs).

- [ ] **Step 1: Write the failing tests**

Add these to `tests/Register-DFTool.Tests.ps1`, inside the existing top-level `Describe` block (matching the file's established fixture style — inline here-string JSON into `$script:TmpTools`, `Mock Get-Command`/`Mock Get-Module` for availability):

```powershell
    It 'fires a background prewarm job for every type:module tool being registered' {
        @'
{ "name": "moduletool", "type": "module", "executable": "ModuleToolExe" }
'@ | Set-Content (Join-Path $script:TmpTools 'moduletool.json')
        $script:DFToolDb = $null

        Mock Get-Module { [PSCustomObject]@{ Name = 'ModuleToolExe' } }
        Mock Start-DFModulePrewarm { $null } -Verifiable

        Register-DFTool -Name 'moduletool' -ToolsPath $script:TmpTools

        Should -Invoke Start-DFModulePrewarm -Times 1 -ParameterFilter {
            @($ModuleNames) -contains 'ModuleToolExe'
        }

        Remove-Item (Join-Path $script:TmpTools 'moduletool.json') -ErrorAction Ignore
        $script:DFToolDb = $null
    }

    It 'does not fire a prewarm job when no type:module tool is being registered' {
        Mock Get-Command { [PSCustomObject]@{ Path = 'C:\fake\tool.exe' } }
        Mock Start-DFModulePrewarm { $null } -Verifiable

        Register-DFTool -Name 'testtool' -ToolsPath $script:TmpTools

        Should -Invoke Start-DFModulePrewarm -Times 0
    }

    It 'excludes a type:module tool that Test-DFToolAvailable reports unavailable' {
        @'
{ "name": "unavailmodule", "type": "module", "executable": "UnavailModuleExe" }
'@ | Set-Content (Join-Path $script:TmpTools 'unavailmodule.json')
        @'
{ "name": "moduletool", "type": "module", "executable": "ModuleToolExe" }
'@ | Set-Content (Join-Path $script:TmpTools 'moduletool.json')
        $script:DFToolDb = $null

        # Two separate -ParameterFilter mocks, not one conditional scriptblock body --
        # matches this file's own established pattern (see Find-DFPackage.Tests.ps1)
        # rather than relying on which automatic variables Pester exposes inside a
        # mock body that declares its own param() block.
        Mock Get-Module { [PSCustomObject]@{ Name = 'ModuleToolExe' } } -ParameterFilter { $Name -eq 'ModuleToolExe' }
        Mock Get-Module { $null } -ParameterFilter { $Name -eq 'UnavailModuleExe' }
        Mock Start-DFModulePrewarm { $null } -Verifiable

        Register-DFTool -Name 'moduletool', 'unavailmodule' -ToolsPath $script:TmpTools

        Should -Invoke Start-DFModulePrewarm -Times 1 -ParameterFilter {
            @($ModuleNames) -contains 'ModuleToolExe' -and
            @($ModuleNames) -notcontains 'UnavailModuleExe'
        }

        Remove-Item (Join-Path $script:TmpTools 'unavailmodule.json') -ErrorAction Ignore
        Remove-Item (Join-Path $script:TmpTools 'moduletool.json') -ErrorAction Ignore
        $script:DFToolDb = $null
    }

    It 'cleans up the prewarm job after the per-tool loop, even if it has not finished' {
        @'
{ "name": "moduletool", "type": "module", "executable": "ModuleToolExe" }
'@ | Set-Content (Join-Path $script:TmpTools 'moduletool.json')
        $script:DFToolDb = $null

        Mock Get-Module { [PSCustomObject]@{ Name = 'ModuleToolExe' } } -ParameterFilter { $Name -eq 'ModuleToolExe' }
        # A real, still-sleeping job stands in for "prewarm not finished yet" --
        # deliberately NOT mocking Remove-Job (that would make the assertion
        # below vacuously true without proving anything, and would leak this
        # real background job past the test, sleeping for 30s in the runner).
        $fakeJob = Start-ThreadJob -ScriptBlock { Start-Sleep -Seconds 30 }
        Mock Start-DFModulePrewarm { $fakeJob }

        Register-DFTool -Name 'moduletool' -ToolsPath $script:TmpTools

        # Register-DFTool force-removes the job whether or not it finished --
        # proven by using a job that is still running when the function
        # returns, then confirming it is really gone (not mocked away).
        Get-Job -Id $fakeJob.Id -ErrorAction Ignore | Should -BeNullOrEmpty

        Remove-Item (Join-Path $script:TmpTools 'moduletool.json') -ErrorAction Ignore
        $script:DFToolDb = $null
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Register-DFTool.Tests.ps1 -Output Detailed"`
Expected: The 4 new tests FAIL (`Start-DFModulePrewarm` is never called — the wiring doesn't exist yet). All pre-existing tests in this file still PASS (no regression from the test additions alone, since nothing in `Register-DFTool.ps1` has changed yet).

- [ ] **Step 3: Write the implementation**

In `Public/Register-DFTool.ps1`, insert a new block immediately after the topological sort (after the existing line `$tools = Invoke-DFTopoSort -Tools @($tools)`, before the `# ── Default-tool role resolution` comment):

```powershell
    # Topological sort respects dependsOn declarations
    $tools = Invoke-DFTopoSort -Tools @($tools)

    # ── Module prewarm (perf) ───────────────────────────────────────────────
    # Fire a background job that imports each type:module tool's module in its
    # own throwaway runspace, purely to warm OS/CLR-level caches before this
    # loop reaches that tool's own (unchanged) Import-Module call below --
    # measured ~77% reduction on a representative module (Get-DFCachedCommandOutput's
    # sibling optimization for exe-type tools; see
    # docs/superpowers/specs/2026-09-05-startup-perf-audit.md Part 2 for this one).
    # Automatic for every type:module tool actually being registered this call
    # (not a new declarative opt-in) -- see Start-DFModulePrewarm's own doc
    # comment for the one assumption this relies on.
    $prewarmModules = @(
        foreach ($t in $tools) {
            $tType = $t.PSObject.Properties['type']?.Value ?? 'exe'
            if ($tType -eq 'module' -and (Test-DFToolAvailable -Executable $t.executable -Type 'module')) {
                $t.executable
            }
        }
    )
    $prewarmJob = Start-DFModulePrewarm -ModuleNames $prewarmModules
```

Then, at the very end of the function — after the existing shadowed-command-notice block (the closing `}` of the `if (-not ($Global:DFConfig -and $Global:DFConfig['SkipConflictCheck']))` block, immediately before the function's own closing `}`) — add:

```powershell
    # Fire-and-forget cleanup: remove the prewarm job whether or not it
    # finished. Nothing downstream depends on its result (see
    # Start-DFModulePrewarm's own doc comment) -- if it's still running,
    # force-removing it is safe, since the only work it did was read/JIT
    # already-shared OS/CLR state that persists regardless of how the job
    # itself ends.
    if ($prewarmJob) {
        $prewarmJob | Remove-Job -Force -ErrorAction Ignore
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Register-DFTool.Tests.ps1 -Output Detailed"`
Expected: PASS — all tests in the file, including the 4 new ones.

Then run the full suite to confirm no cross-file regression (this function is dot-sourced by ~20 other test files):

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/ -Output Detailed" 2>&1 | Select-String 'Tests Passed'`
Expected: Same pass/fail counts as the pre-existing baseline (1093 passed / 10 failed, per the last full run this session) — the 10 failures are pre-existing and unrelated (`Get-DFCategoryDb`/`Get-DFCategoryList`), not something this task should change.

- [ ] **Step 5: Commit**

```bash
git add Public/Register-DFTool.ps1 tests/Register-DFTool.Tests.ps1
git commit -m "perf(startup): prewarm type:module tools' Import-Module in the background"
```

---

## Manual verification (not automated — do this once, by hand, before merging)

Pester mocks `Start-DFModulePrewarm` in Task 2's tests, so the suite never actually proves the *real* end-to-end win. Verify it directly, the same way this session verified every other perf claim (never trust an unmeasured claim):

```powershell
# From a fresh pwsh -NoProfile process:
Import-Module ./DotForge.psd1 -Force
Initialize-DFEnvironment
Measure-Command { Register-DFTool -All } | Select TotalMilliseconds
```

Compare against a baseline captured the same way with Task 2's changes temporarily reverted (`git stash`), on the same machine, same install state (Terminal-Icons/PSFzf/posh-git actually installed — this plan does nothing observable if none of them are). Expect `Register-DFTool -All`'s own wall-clock cost to drop by roughly the sum of (module's cold cost − module's warm cost) for however many of the three modules are installed and get their prewarm job started early enough to finish before the loop reaches them — per the audit, up to ~650ms combined, though real overlap depends on how much other per-tool work runs in between (alphabetically, several tools sort before `PSFzf`/`Terminal-Icons`/`posh-git`, giving the background job time to finish; a registration list containing *only* these three tools, with nothing else to overlap with, would see a smaller — but never negative — effect).

## Final whole-branch review

Dispatch on the most capable available model per `subagent-driven-development`'s Model Selection section — this touches `Register-DFTool`'s core per-tool loop, used by every other tool's test file in the suite. Pay particular attention to:
- Whether the `$prewarmModules` collection logic could ever misfire for a tool with `type: module` whose `executable` doesn't match the actual importable module name (schema allows any string; a real mismatch would just make the prewarm job's `Import-Module` fail harmlessly and silently, per the design, but worth a second look).
- That `Remove-Job -Force` at the end of `Register-DFTool` can't throw or warn when `$prewarmJob` is `$null` (guarded above) or already completed/removed by something else (defensive `-ErrorAction Ignore` already present).
