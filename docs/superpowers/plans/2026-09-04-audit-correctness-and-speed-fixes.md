# DotForge Audit Fixes — Phase 1 (Correctness) & Phase 2 (Speed) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the two verified correctness bugs and the one verified speed problem from
`audit.claude.md`'s recommended order of work (items 1, 2, and part of 3/6), each with a
failing-test-first regression test and its own commit.

**Architecture:** Small, independent, surgical changes to existing `Public`/`Private` functions.
No new public surface, no `Tools/*.json` schema changes, no behavior changes beyond the bug fixes
themselves. Two of the three fixes (Import-DFToolDb, Resolve-DFPackageManager) apply a pattern
`Get-DFCategoryDb` already uses correctly elsewhere in the codebase — copy its shape, don't invent
a new one.

**Tech Stack:** PowerShell 7+, Pester 5/6 (dual-compatible per project convention).

## Global Constraints

- No `$ErrorActionPreference = 'Stop'` in any module file (`CLAUDE.md`).
- All directory creation goes through `New-DFDirectory`; all PATH additions through `Add-DFToPath`
  (`CLAUDE.md`) — not touched by this plan, noted for completeness since nothing here creates a
  directory or edits PATH.
- Every public function needs complete comment-based help (`.SYNOPSIS`/`.DESCRIPTION`/`.PARAMETER`/
  `.EXAMPLE`/`.OUTPUTS`) before commit (`CLAUDE.md` "Before Committing"). `Test-DFToolAvailable`
  (Task 5) is private, but gets full comment-based help anyway to match the codebase's existing
  private-function convention (e.g. `Import-DFToolDb`, `Get-DFCategoryDb` both have it).
- Run tests via `pwsh -NoProfile -Command "Invoke-Pester ... -Output Detailed"` to avoid profile
  interference (`CLAUDE.md`).
- Tests must pass under both Pester 5.8 and 6.0.1 (`CLAUDE.md`) — use `Should -Invoke ... -Times N
  -Exactly`, never the removed `Assert-MockCalled`.
- New/changed code uses the `DF` prefix convention and StrictMode-safe optional-property access
  (`$obj.PSObject.Properties['x']?.Value`) per `CLAUDE.md`/`docs/plugin-architecture.md`.
- Never use `git add -A`/`git add .`; stage the exact files each task lists.

---

## Phase 1 — Correctness

### Task 1: `New-DFShim` — stop changing directory before invoking the target

**Files:**
- Modify: `Public/New-DFShim.ps1`
- Test: `tests/New-DFShim.Tests.ps1`

**Interfaces:**
- Consumes: nothing new.
- Produces: `New-DFShim`'s public signature is unchanged (no parameter changes). The generated
  `.cmd` content changes shape — no other task depends on that content's exact bytes.

**Background:** The generated `.cmd` currently does `cd /d "<target's own directory>"` before
running the target with `%*`. That `cd` never leaks back into the calling PowerShell session (it
runs inside the shim's own `cmd.exe` child process), but it does change what the **target
executable** sees as its current directory — so a relative-path argument (`ripgrep pattern
.\notes.txt`) resolves against the tool's install directory instead of the directory the user
actually ran the shim from. Common shim generators (including Scoop's own) don't `cd` at all, for
exactly this reason.

- [ ] **Step 1: Write the failing test**

Open `tests/New-DFShim.Tests.ps1` and add this test immediately after the existing `'generated .cmd
contains the correct target path'` test (inside the same `Describe 'New-DFShim' { ... }` block):

```powershell
    It 'does not change directory before invoking the target (preserves the caller''s cwd for relative-path arguments)' {
        New-DFShim -Name 'myapp' -Target $script:FakeExe -ShimsPath $script:ShimsDir
        $content = Get-Content (Join-Path $script:ShimsDir 'myapp.cmd') -Raw
        $content | Should -Not -Match 'cd /d'
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/New-DFShim.Tests.ps1 -Output Detailed"`
Expected: FAIL on the new test — the generated content still contains `cd /d "..."`.

- [ ] **Step 3: Fix `Public/New-DFShim.ps1`**

First, update the comment-based help (`.SYNOPSIS`/`.DESCRIPTION` near the top of the function) —
find:

```powershell
    .SYNOPSIS
        Creates a .cmd shim that forwards invocations to a target executable,
        first changing the working directory to the executable's own directory.
    .DESCRIPTION
        Generates a Windows .cmd batch file in the shims directory that, when
        invoked, changes to the executable's own directory then runs it with all
        forwarded arguments and correctly propagates the exit code. Put the shims
        directory on $PATH once and create shims as needed.
        Accepts a DotForge tool name (DB lookup) or an explicit -Target path.
```

Replace with:

```powershell
    .SYNOPSIS
        Creates a .cmd shim that forwards invocations to a target executable,
        preserving the caller's working directory and exit code.
    .DESCRIPTION
        Generates a Windows .cmd batch file in the shims directory that, when
        invoked, runs the target executable with all forwarded arguments from
        the caller's own current directory -- so relative-path arguments
        resolve the way the user expects -- and correctly propagates the exit
        code. Put the shims directory on $PATH once and create shims as needed.
        Accepts a DotForge tool name (DB lookup) or an explicit -Target path.
```

Then find the app-directory computation and shim-writing block:

```powershell
    # 5. App directory (working dir for the shim)
    $appDir = Split-Path -Parent $resolvedTarget

    # 6. Shim existence check
    $shimPath = Join-Path $shimsDir "$Name.cmd"
    if ((Test-Path $shimPath) -and -not $Force -and -not $WhatIfPreference) {
        Write-Error "DotForge: Shim '$shimPath' already exists. Use -Force to overwrite."
        return
    }

    # 7. Write shim
    if ($PSCmdlet.ShouldProcess($shimPath, 'Create shim')) {
        $lines = @(
            '@echo off'
            'setlocal'
            "cd /d `"$appDir`""
            "`"$resolvedTarget`" %*"
            'set "_exit=%ERRORLEVEL%"'
            'endlocal & exit /b %_exit%'
        )
        Set-Content -Path $shimPath -Value ($lines -join "`r`n") -Encoding ASCII -NoNewline
        Write-Verbose "DotForge: shim created → $shimPath"
    }
```

Replace with (the app-directory step is removed entirely — nothing else in the function uses it):

```powershell
    # 5. Shim existence check
    $shimPath = Join-Path $shimsDir "$Name.cmd"
    if ((Test-Path $shimPath) -and -not $Force -and -not $WhatIfPreference) {
        Write-Error "DotForge: Shim '$shimPath' already exists. Use -Force to overwrite."
        return
    }

    # 6. Write shim
    # No `cd` here: the shim must preserve the caller's own working directory
    # so relative-path arguments resolve the way the user expects, not against
    # the target executable's install directory.
    if ($PSCmdlet.ShouldProcess($shimPath, 'Create shim')) {
        $lines = @(
            '@echo off'
            'setlocal'
            "`"$resolvedTarget`" %*"
            'set "_exit=%ERRORLEVEL%"'
            'endlocal & exit /b %_exit%'
        )
        Set-Content -Path $shimPath -Value ($lines -join "`r`n") -Encoding ASCII -NoNewline
        Write-Verbose "DotForge: shim created → $shimPath"
    }
```

- [ ] **Step 4: Run the full file to verify everything passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/New-DFShim.Tests.ps1 -Output Detailed"`
Expected: PASS, 0 failures (the new test passes; the existing `'generated .cmd contains the correct
target path'` test still passes since it only checks for `"$target" %*`, unaffected by removing the
`cd` line).

- [ ] **Step 5: Commit**

```bash
git add Public/New-DFShim.ps1 tests/New-DFShim.Tests.ps1
git commit -m "$(cat <<'EOF'
fix(New-DFShim): stop cd-ing into the target's directory before invoking it

The generated .cmd changed directory to the target executable's own
install directory before running it, so any relative-path argument the
user passed resolved against that directory instead of the caller's
actual cwd. The cd served no purpose the OS doesn't already provide
(DLL search order already checks an exe's own directory regardless of
cwd), so it's removed rather than worked around.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KjTXV8CBbqnMmRTZspmhfs
EOF
)"
```

---

### Task 2: `Import-DFToolDb` — an explicit `-ToolsPath` must never read or write the shared cache

**Files:**
- Modify: `Private/Import-DFToolDb.ps1`
- Test: `tests/Import-DFToolDb.Tests.ps1`

**Interfaces:**
- Consumes: nothing new.
- Produces: `Import-DFToolDb`'s signature and return shape (`[hashtable]`) are unchanged. Every
  caller (`Get-DFTool`, `Find-DFTool`, `Install-DFTool`, `Register-DFTool`, `New-DFShim`) keeps
  working exactly as today for the common case (no `-ToolsPath`); this only changes behavior when a
  caller supplies `-ToolsPath` explicitly.

**Background:** `Get-DFCategoryDb` already solves this exact bug shape correctly: it only reads
from (and only writes to) its singleton cache when the caller did **not** supply its path-override
parameter (`-Path`). `Import-DFToolDb` doesn't do this — its `$ToolsPath` parameter has a default
value, so today it can't tell "caller explicitly named a directory" from "caller used the default,"
and a single un-keyed `$script:DFToolDb` is shared across both. In production this is latent (almost
everything calls it with no `-ToolsPath`), but any caller (a test, a future sub-registry feature)
that does pass `-ToolsPath` can get a stale result, or worse, silently poison the cache for every
subsequent default-path caller in the session.

**Note before starting:** the existing test `'returns cached result on second call without -Force'`
currently encodes the *buggy* behavior as expected (two calls with the *same* explicit `-ToolsPath`
expecting the second to ignore a file added in between). Step 1 replaces it with the corrected
expectation rather than leaving it in place alongside a contradictory new test.

- [ ] **Step 1: Update the tests first**

Open `tests/Import-DFToolDb.Tests.ps1`. Find:

```powershell
    It 'returns cached result on second call without -Force' {
        $db1 = Import-DFToolDb -ToolsPath $script:TmpTools
        # Modify the tools dir — second call should NOT pick this up
        '{ "name": "extra", "executable": "extra.exe" }' |
            Set-Content (Join-Path $script:TmpTools 'extra.json')
        $db2 = Import-DFToolDb -ToolsPath $script:TmpTools
        $db2.ContainsKey('extra') | Should -BeFalse
    }
```

Replace with:

```powershell
    It 'always does a fresh read when -ToolsPath is given explicitly, even without -Force' {
        # An explicit -ToolsPath must never trust the shared cache -- a caller
        # who names their own directory (tests, a future sub-registry) always
        # sees that directory's current contents.
        $db1 = Import-DFToolDb -ToolsPath $script:TmpTools
        '{ "name": "extra", "executable": "extra.exe" }' |
            Set-Content (Join-Path $script:TmpTools 'extra.json')
        $db2 = Import-DFToolDb -ToolsPath $script:TmpTools
        $db2.ContainsKey('extra') | Should -BeTrue
    }

    It 'caches the default-location result across calls with no -ToolsPath' {
        # Seed the shared cache with a sentinel and call with NO -ToolsPath at
        # all -- if the default-location branch is really cache-backed, the
        # sentinel comes back untouched (no directory is ever scanned).
        $script:DFToolDb = @{ sentinel = $true }
        $db = Import-DFToolDb
        $db.ContainsKey('sentinel') | Should -BeTrue
    }

    It 'never overwrites the shared cache when -ToolsPath is given explicitly' {
        $script:DFToolDb = @{ sentinel = $true }
        Import-DFToolDb -ToolsPath $script:TmpTools | Out-Null
        $script:DFToolDb.ContainsKey('sentinel') | Should -BeTrue
    }
```

- [ ] **Step 2: Run the tests to verify the new/changed ones fail**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Import-DFToolDb.Tests.ps1 -Output Detailed"`
Expected: FAIL — `'always does a fresh read when -ToolsPath is given explicitly...'` fails (current
code returns the stale cached db1), and `'never overwrites the shared cache...'` fails (current code
overwrites `$script:DFToolDb` unconditionally). The sentinel-caching test passes already (current
code already returns the cache when no `-ToolsPath` and no `-Force` are given).

- [ ] **Step 3: Fix `Private/Import-DFToolDb.ps1`**

Find:

```powershell
    .PARAMETER ToolsPath
        Path to the tools directory. Defaults to the module's Tools/ folder.
        Pass an explicit path in tests to control which JSON files are loaded.
    .PARAMETER Force
        Clears the cache and reloads from disk.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$ToolsPath = (Join-Path $PSScriptRoot '../Tools'),
        [switch]$Force
    )

    if ($script:DFToolDb -and -not $Force) { return $script:DFToolDb }
```

Replace with:

```powershell
    .PARAMETER ToolsPath
        Path to the tools directory. Defaults to the module's Tools/ folder.
        Pass an explicit path in tests to control which JSON files are loaded.
        Supplying this parameter always forces a fresh, uncached read and never
        populates the shared cache -- only calls using the default location
        participate in caching, so a caller with its own directory never sees
        (or clobbers) another caller's registry.
    .PARAMETER Force
        Clears the cache and reloads from disk.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$ToolsPath = (Join-Path $PSScriptRoot '../Tools'),
        [switch]$Force
    )

    $explicitToolsPath = $PSBoundParameters.ContainsKey('ToolsPath')

    if (-not $explicitToolsPath -and -not $Force -and $script:DFToolDb) { return $script:DFToolDb }
```

Then find the end of the function:

```powershell
    $script:DFToolDb = $db
    return $db
}
```

Replace with:

```powershell
    if (-not $explicitToolsPath) { $script:DFToolDb = $db }
    return $db
}
```

- [ ] **Step 4: Run the tests to verify everything passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Import-DFToolDb.Tests.ps1 -Output Detailed"`
Expected: PASS, 0 failures — all 7 tests (the 4 pre-existing untouched ones plus the 3 from Step 1).

- [ ] **Step 5: Run the full suite once to catch any caller that relied on the old behavior**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/ -Output Detailed"`
Expected: PASS, 0 failures. (`Get-DFTool`, `Find-DFTool`, `Install-DFTool`, `New-DFShim`, and
`Register-DFTool` tests all pass `-ToolsPath` explicitly pointing at their own fixture directories —
under the new behavior those calls simply always re-read that fixture directory fresh, which is what
each of those tests already assumes since none of them rely on cross-call caching of a custom path.)

- [ ] **Step 6: Commit**

```bash
git add Private/Import-DFToolDb.ps1 tests/Import-DFToolDb.Tests.ps1
git commit -m "$(cat <<'EOF'
fix(Import-DFToolDb): never cache or trust the cache for an explicit -ToolsPath

The single $script:DFToolDb cache couldn't tell "caller passed
-ToolsPath" from "caller used the default", since the parameter always
has a value. A caller naming its own directory could get a stale
result, or silently overwrite the cache for every later default-path
caller in the session. Mirrors the guard Get-DFCategoryDb already uses
for its own -Path override.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KjTXV8CBbqnMmRTZspmhfs
EOF
)"
```

---

### Task 3: `Resolve-DFPackageManager` — an explicit `-Priority` must never read or write the shared cache

**Files:**
- Modify: `Private/Resolve-DFPackageManager.ps1`
- Test: `tests/Resolve-DFPackageManager.Tests.ps1`

**Interfaces:**
- Consumes: nothing new.
- Produces: `Resolve-DFPackageManager`'s signature and return shape (`[string[]]`) are unchanged.

**Background:** Same bug shape as Task 2, different function. `$script:DFPackageManagers` is cached
regardless of whether `-Priority` was explicitly passed, so a call with a custom order (`Install-DFTool
-PackageManager` doesn't use this path, but `Install-DFTool` without `-PackageManager` and a
`$DFConfig['PackageManagerOrder']` override, or any future caller passing `-Priority` directly,
would) can read a stale default-priority result, or overwrite the cache with its one-off order for
every later default-priority caller in the session.

- [ ] **Step 1: Write the failing test**

Open `tests/Resolve-DFPackageManager.Tests.ps1` and add this test immediately after the existing
`'respects custom -Priority order'` test (inside the same `Describe` block):

```powershell
    It 'does not let a call with a custom -Priority read or overwrite the cached default-priority result' {
        Mock Get-Command { [PSCustomObject]@{ Name = $Name } }
        $default = Resolve-DFPackageManager   # caches the default order: scoop, winget, choco
        $custom  = Resolve-DFPackageManager -Priority @('winget', 'scoop')
        @($custom)[0] | Should -Be 'winget'
        @($custom)[1] | Should -Be 'scoop'
        # cache must still reflect the default-priority result, not the custom one
        $cachedAgain = Resolve-DFPackageManager
        @($cachedAgain)[0] | Should -Be $default[0]
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Resolve-DFPackageManager.Tests.ps1 -Output Detailed"`
Expected: FAIL — the current code caches whatever the *first* call computed regardless of
`-Priority`, so `$cachedAgain` here comes back as the custom `('winget', 'scoop')` order instead of
the default order, and the third assertion fails.

- [ ] **Step 3: Fix `Private/Resolve-DFPackageManager.ps1`**

Find:

```powershell
    .PARAMETER Priority
        Ordered list of package manager names to check.
        Defaults to scoop, winget, choco.
    .PARAMETER Force
        Clear cache and re-detect.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [string[]]$Priority = @('scoop', 'winget', 'choco'),
        [switch]$Force
    )

    if ($script:DFPackageManagers -and -not $Force) { return $script:DFPackageManagers }

    $available = $Priority | Where-Object { Get-Command $_ -ErrorAction Ignore }
    $script:DFPackageManagers = @($available)
    return $script:DFPackageManagers
}
```

Replace with:

```powershell
    .PARAMETER Priority
        Ordered list of package manager names to check.
        Defaults to scoop, winget, choco. Supplying this parameter always
        forces a fresh, uncached probe and never populates the shared cache --
        only calls using the default priority order participate in caching, so
        a one-off custom-priority call never overwrites the cached default
        result for later default-priority callers.
    .PARAMETER Force
        Clear cache and re-detect.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [string[]]$Priority = @('scoop', 'winget', 'choco'),
        [switch]$Force
    )

    $explicitPriority = $PSBoundParameters.ContainsKey('Priority')

    if (-not $explicitPriority -and -not $Force -and $script:DFPackageManagers) {
        return $script:DFPackageManagers
    }

    $available = @($Priority | Where-Object { Get-Command $_ -ErrorAction Ignore })
    if (-not $explicitPriority) { $script:DFPackageManagers = $available }
    return $available
}
```

- [ ] **Step 4: Run the tests to verify everything passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Resolve-DFPackageManager.Tests.ps1 -Output Detailed"`
Expected: PASS, 0 failures — all 6 tests (the 4 pre-existing untouched ones, unaffected since none of
them interleave default- and custom-priority calls within one test, plus the new one from Step 1).

- [ ] **Step 5: Commit**

```bash
git add Private/Resolve-DFPackageManager.ps1 tests/Resolve-DFPackageManager.Tests.ps1
git commit -m "$(cat <<'EOF'
fix(Resolve-DFPackageManager): never cache or trust the cache for an explicit -Priority

Same bug shape as Import-DFToolDb: the single $script:DFPackageManagers
cache couldn't tell "caller passed -Priority" from "caller used the
default", so a one-off custom-priority call could read a stale default
result or silently overwrite the cache for every later default-priority
caller in the session.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KjTXV8CBbqnMmRTZspmhfs
EOF
)"
```

---

## Phase 2 — Speed

### Task 4: Add a `Measure-Command` baseline for `Register-DFTool -All`

**Files:**
- Create: `build/Measure-DFStartup.ps1`

**Interfaces:**
- Consumes: the public `DotForge.psd1` module surface (`Initialize-DFEnvironment`,
  `Register-DFTool`) — nothing internal.
- Produces: nothing later tasks depend on programmatically; this is a manual dev instrument whose
  *output numbers* are what Task 5 compares against.

**Background:** Before optimizing `Register-DFTool -All`'s per-tool availability probe (Task 5), get
a real number on this machine so the fix's effect is measured, not assumed. This is a manual
developer script, not a Pester test — timing depends on what's actually installed and on this
machine's disk, so it isn't something CI should gate on.

- [ ] **Step 1: Create the script**

```powershell
#Requires -Version 7.0
<#
.SYNOPSIS
    Manual dev tool: measures the wall-clock cost of Register-DFTool -All on
    this machine, to compare before/after a performance change.
.DESCRIPTION
    Imports a fresh copy of the DotForge module, runs Initialize-DFEnvironment
    once (untimed setup), then times several consecutive Register-DFTool -All
    calls and reports min/mean/max in milliseconds. Not run in CI: timings
    depend on which tools are actually installed and on this machine's disk,
    so there is no meaningful pass/fail threshold to assert.
.PARAMETER Iterations
    How many timed Register-DFTool -All calls to run. Defaults to 5.
.EXAMPLE
    pwsh -NoProfile -File build/Measure-DFStartup.ps1
    Prints a min/mean/max report to the host.
.EXAMPLE
    pwsh -NoProfile -File build/Measure-DFStartup.ps1 -Iterations 10
    Runs 10 timed iterations instead of the default 5.
#>
[CmdletBinding()]
param([int]$Iterations = 5)

Import-Module (Join-Path $PSScriptRoot '../DotForge.psd1') -Force
Initialize-DFEnvironment | Out-Null

$timings = 1..$Iterations | ForEach-Object {
    (Measure-Command { Register-DFTool -All }).TotalMilliseconds
}

[pscustomobject]@{
    Iterations = $Iterations
    MinMs      = [math]::Round(($timings | Measure-Object -Minimum).Minimum, 1)
    MeanMs     = [math]::Round(($timings | Measure-Object -Average).Average, 1)
    MaxMs      = [math]::Round(($timings | Measure-Object -Maximum).Maximum, 1)
} | Format-List
```

Save as `build/Measure-DFStartup.ps1`.

- [ ] **Step 2: Run it and record the "before" numbers**

Run: `pwsh -NoProfile -File build/Measure-DFStartup.ps1`
Expected: prints `Iterations`/`MinMs`/`MeanMs`/`MaxMs`. Write the `MeanMs` value down (paste it into
the chat/PR description when this plan is executed) — Task 5's last step compares against it.

- [ ] **Step 3: Commit**

```bash
git add build/Measure-DFStartup.ps1
git commit -m "$(cat <<'EOF'
build: add a manual Register-DFTool -All timing baseline script

A dev-only instrument (not run in CI -- timings depend on which tools
are installed on this machine) so the next performance change to
Register-DFTool has a real before/after number instead of "feels
faster".

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KjTXV8CBbqnMmRTZspmhfs
EOF
)"
```

---

### Task 5: Memoize tool-availability probes so each tool is checked at most once per session

**Files:**
- Create: `Private/Test-DFToolAvailable.ps1`
- Test: `tests/Test-DFToolAvailable.Tests.ps1`
- Modify: `Public/Register-DFTool.ps1`
- Modify: `tests/Register-DFTool.Tests.ps1`

**Interfaces:**
- Consumes: nothing new.
- Produces: `Test-DFToolAvailable -Executable <string> [-Type exe|module] [-Force]` → `[bool]`. Task
  scope note: only `Register-DFTool`'s two existing probe sites (role-winner resolution, main
  per-tool loop) are wired to it in this task — `Install-DFTool`'s separate package-manager-binary
  probes are a different concern and out of scope.

**Background:** `Get-Command $tool.executable -ErrorAction Ignore` (and the `Get-Module` equivalent
for module-type tools) is not free — PowerShell doesn't cache a *failed* lookup, so every tool that
isn't installed re-walks `PATH` on every probe. `Register-DFTool -All` already probes each tool once
in its main loop, but any tool referenced as a `$DFConfig.Defaults` role winner is probed a *second*
time in the role-resolution block first — and a user who runs `Register-DFTool -Name X` again after
`-All` (common while tweaking a profile) re-probes every one of those tools from scratch. A small
memoized wrapper removes all of this redundancy without reimplementing PATH/PATHEXT resolution
(which `Get-Command` already does correctly) — it only caches the yes/no answer per `(type,
executable)` for the session.

- [ ] **Step 1: Write the failing tests**

Create `tests/Test-DFToolAvailable.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/../Private/Test-DFToolAvailable.ps1"
}

Describe 'Test-DFToolAvailable' {
    BeforeEach { $script:DFToolAvailability = @{} }

    It 'returns $true when Get-Command finds the executable' {
        Mock Get-Command { [PSCustomObject]@{ Name = 'ripgrep.exe' } }
        Test-DFToolAvailable -Executable 'ripgrep.exe' | Should -BeTrue
    }

    It 'returns $false when Get-Command does not find the executable' {
        Mock Get-Command { $null }
        Test-DFToolAvailable -Executable 'ripgrep.exe' | Should -BeFalse
    }

    It 'checks Get-Module instead of Get-Command for -Type module' {
        Mock Get-Command { throw 'Get-Command should not be called for module-type tools' }
        Mock Get-Module { [PSCustomObject]@{ Name = 'PSFzf' } }
        Test-DFToolAvailable -Executable 'PSFzf' -Type 'module' | Should -BeTrue
    }

    It 'memoizes the result -- a second call does not re-invoke Get-Command' {
        Mock Get-Command { [PSCustomObject]@{ Name = 'ripgrep.exe' } } -Verifiable
        Test-DFToolAvailable -Executable 'ripgrep.exe' | Out-Null
        Test-DFToolAvailable -Executable 'ripgrep.exe' | Out-Null
        Should -Invoke Get-Command -Times 1 -Exactly
    }

    It 'memoizes exe and module availability separately for the same name' {
        Mock Get-Command { [PSCustomObject]@{ Name = 'foo' } }
        Mock Get-Module { $null }
        Test-DFToolAvailable -Executable 'foo' -Type 'exe' | Should -BeTrue
        Test-DFToolAvailable -Executable 'foo' -Type 'module' | Should -BeFalse
    }

    It 're-probes when -Force is specified' {
        Mock Get-Command { $null }
        Test-DFToolAvailable -Executable 'ripgrep.exe' | Should -BeFalse
        Mock Get-Command { [PSCustomObject]@{ Name = 'ripgrep.exe' } }
        Test-DFToolAvailable -Executable 'ripgrep.exe' -Force | Should -BeTrue
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Test-DFToolAvailable.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Private/Test-DFToolAvailable.ps1` does not exist yet, so dot-sourcing it in
`BeforeAll` throws and every test errors.

- [ ] **Step 3: Create `Private/Test-DFToolAvailable.ps1`**

```powershell
#Requires -Version 7.0

$script:DFToolAvailability = @{}

function script:Test-DFToolAvailable {
    <#
    .SYNOPSIS
        Checks whether a tool's executable or module is available, memoized
        per (type, name) for the session.
    .DESCRIPTION
        Wraps Get-Command (exe-type tools) / Get-Module -ListAvailable
        (module-type tools) with a session-scoped cache keyed by type and
        name, so a given tool is probed at most once regardless of how many
        times Register-DFTool runs or how many role-resolution checks
        reference it. Semantics are identical to calling Get-Command/
        Get-Module directly -- this only removes redundant repeat probes.
    .PARAMETER Executable
        The executable name (exe-type tools) or module name (module-type
        tools) to check.
    .PARAMETER Type
        'exe' or 'module'. Defaults to 'exe'.
    .PARAMETER Force
        Bypass the cache and re-probe.
    .EXAMPLE
        Test-DFToolAvailable -Executable 'ripgrep.exe'
        Returns $true if ripgrep.exe is on PATH.
    .EXAMPLE
        Test-DFToolAvailable -Executable 'PSFzf' -Type 'module'
        Returns $true if the PSFzf module is installed.
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Executable,

        [ValidateSet('exe', 'module')]
        [string]$Type = 'exe',

        [switch]$Force
    )

    $key = "$Type|$Executable"
    if (-not $Force -and $script:DFToolAvailability.ContainsKey($key)) {
        return $script:DFToolAvailability[$key]
    }

    $available = [bool](if ($Type -eq 'module') {
        Get-Module -Name $Executable -ListAvailable -ErrorAction Ignore
    } else {
        Get-Command $Executable -ErrorAction Ignore
    })

    $script:DFToolAvailability[$key] = $available
    return $available
}
```

- [ ] **Step 4: Run it to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Test-DFToolAvailable.Tests.ps1 -Output Detailed"`
Expected: PASS, 0 failures, all 6 tests green.

- [ ] **Step 5: Wire it into `Public/Register-DFTool.ps1`**

Find the role-winner availability check:

```powershell
            $winnerType = $winnerTool.PSObject.Properties['type']?.Value ?? 'exe'
            $winnerAvailable = if ($winnerType -eq 'module') {
                Get-Module -Name $winnerTool.executable -ListAvailable -ErrorAction Ignore
            } else {
                Get-Command $winnerTool.executable -ErrorAction Ignore
            }
            if (-not $winnerAvailable) { continue }
```

Replace with:

```powershell
            $winnerType = $winnerTool.PSObject.Properties['type']?.Value ?? 'exe'
            if (-not (Test-DFToolAvailable -Executable $winnerTool.executable -Type $winnerType)) { continue }
```

Then find the main per-tool availability guard:

```powershell
        # ── Guard: skip if not available ──────────────────────────────────
        $toolType = $tool.PSObject.Properties['type']?.Value ?? 'exe'
        $isAvailable = if ($toolType -eq 'module') {
            Get-Module -Name $tool.executable -ListAvailable -ErrorAction Ignore
        } else {
            Get-Command $tool.executable -ErrorAction Ignore
        }
        if (-not $isAvailable) {
            Write-Verbose "DotForge: '$($tool.executable)' not available — skipping $($tool.name)"
            continue
        }
```

Replace with:

```powershell
        # ── Guard: skip if not available ──────────────────────────────────
        $toolType = $tool.PSObject.Properties['type']?.Value ?? 'exe'
        if (-not (Test-DFToolAvailable -Executable $tool.executable -Type $toolType)) {
            Write-Verbose "DotForge: '$($tool.executable)' not available — skipping $($tool.name)"
            continue
        }
```

- [ ] **Step 6: Update `tests/Register-DFTool.Tests.ps1` for the new dependency**

The memoization cache is a `$script:` variable, so — exactly like `$script:DFToolDb` already is —
it must be reset between tests, or one test's `Mock Get-Command` result will leak into the next
test's assertions via the cache.

Find the `BeforeAll` block:

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
    # Register-DFTool calls Get-DFCommandConflict for its shadowed-command warning.
    . "$PSScriptRoot/../Private/Get-DFCoreutilsShadowSet.ps1"
    . "$PSScriptRoot/../Public/Get-DFCommandConflict.ps1"
    . "$PSScriptRoot/../Private/Get-DFToolSetupState.ps1"
    . "$PSScriptRoot/../Public/Complete-DFToolSetup.ps1"
    . "$PSScriptRoot/../Public/Register-DFTool.ps1"
    . "$PSScriptRoot/../Private/Initialize-DFCompletionStack.ps1"
}
```

Replace with (one new dot-source line added):

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
    . "$PSScriptRoot/../Private/Test-DFToolAvailable.ps1"
    . "$PSScriptRoot/../Public/Get-DFTool.ps1"
    . "$PSScriptRoot/../Public/Find-DFTool.ps1"
    # Register-DFTool calls Get-DFCommandConflict for its shadowed-command warning.
    . "$PSScriptRoot/../Private/Get-DFCoreutilsShadowSet.ps1"
    . "$PSScriptRoot/../Public/Get-DFCommandConflict.ps1"
    . "$PSScriptRoot/../Private/Get-DFToolSetupState.ps1"
    . "$PSScriptRoot/../Public/Complete-DFToolSetup.ps1"
    . "$PSScriptRoot/../Public/Register-DFTool.ps1"
    . "$PSScriptRoot/../Private/Initialize-DFCompletionStack.ps1"
}
```

Then find the `BeforeEach` block's cache reset line:

```powershell
    BeforeEach {
        $script:DFToolDb = $null
        $script:SavedConfigHome = $Env:XDG_CONFIG_HOME
```

Replace with:

```powershell
    BeforeEach {
        $script:DFToolDb = $null
        $script:DFToolAvailability = @{}
        $script:SavedConfigHome = $Env:XDG_CONFIG_HOME
```

- [ ] **Step 7: Run the full test suite**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/ -Output Detailed"`
Expected: PASS, 0 failures. (Every existing `Register-DFTool` test mocks `Get-Command`/`Get-Module`
fresh inside its own `It` block; resetting `$script:DFToolAvailability` in `BeforeEach` means each
test's mock is consulted exactly as before — the memoization only spans calls *within* a single
`It`/a single real session, never across the reset boundary.)

- [ ] **Step 8: Re-run the startup baseline and compare**

Run: `pwsh -NoProfile -File build/Measure-DFStartup.ps1`
Compare `MeanMs` against the number recorded in Task 4, Step 2. On a machine where several
`$DFConfig.Defaults` role winners are installed (each previously double-probed), expect a visible
drop; on a machine with none configured, expect roughly the same number (there was nothing to
de-duplicate) — either outcome is consistent with the fix, since this task removes *redundant*
probes, not the one probe every tool still needs at least once.

- [ ] **Step 9: Commit**

```bash
git add Private/Test-DFToolAvailable.ps1 tests/Test-DFToolAvailable.Tests.ps1 \
        Public/Register-DFTool.ps1 tests/Register-DFTool.Tests.ps1
git commit -m "$(cat <<'EOF'
perf(Register-DFTool): memoize tool-availability probes per session

Get-Command doesn't cache a failed lookup, so every tool that isn't
installed re-walked PATH on every probe -- and a role-winner tool was
probed twice per Register-DFTool call (once during role resolution,
once in the main loop), with the whole set re-probed again on any
later Register-DFTool -Name call in the same session. Test-DFToolAvailable
wraps Get-Command/Get-Module with a session-scoped cache keyed by
(type, executable), so each tool is probed at most once per session.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KjTXV8CBbqnMmRTZspmhfs
EOF
)"
```

---

## Future phases (not in this plan)

These `audit.claude.md` findings are real but each needs its own design/plan pass rather than being
folded in here — per the Scope Check, a plan should cover one coherent slice of work, not every
open finding at once:

- **Split `Register-DFTool` into private phase functions** (readability/testability, audit §1.2) —
  a bigger, higher-risk refactor of the function this plan's Task 5 already touches; better done as
  its own reviewed change once Task 5 has landed and settled, not stacked underneath it.
- **`fzf.json` theme hardcoding** (audit §3.4) — closing this properly needs a real per-theme color
  table for fzf (delta's mechanism only resolves a *name*, not hex color values), which is a small
  design decision, not a mechanical fix; not included here to avoid scope creep into Phase 1/2.
- **`Invoke-DFSqliteQuery` parameter binding** (audit §3.3) — explicitly lower priority per the
  audit (hardening an already-correct call site, not fixing an active bug).
- Code-reuse items (a `Get-DFPropertyValue` helper, the catalog-provider factory, the
  `Invoke-DFPackageManagerPicker` consolidation) and idiom cleanup (`script:` prefix consistency,
  `Test-DFToolSchema`'s local `PSProp` helper) — all genuine improvements, none urgent, safe to pick
  up opportunistically or in a dedicated cleanup plan.
