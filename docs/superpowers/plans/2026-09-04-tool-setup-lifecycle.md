# Tool Setup Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give any tool a way to make a persistent, user-visible change exactly once, ever — never re-applied, never silently re-added after the user removes it. Adds a `Tools/<name>.setup.ps1` companion convention, a small persisted state store, and `Register-DFTool` integration.

**Architecture:** Two new functions (`Private/Get-DFToolSetupState.ps1`, `Public/Complete-DFToolSetup.ps1`) manage a JSON state file at `$XDG_STATE_HOME/dotforge/setup-state.json`, keyed by tool name. `Register-DFTool` gains a `$DFConfig['SkipSetup']` opt-out (mirroring the existing `SkipTools`) and a new block, after its existing companion-`.ps1` handling, that dot-sources `Tools/<name>.setup.ps1` at most once ever per tool — the setup script itself calls `Complete-DFToolSetup` as its own last line, only once its work has actually succeeded, so a thrown error never gets recorded as done and retries on the next call.

**Tech Stack:** PowerShell 7+, Pester 5/6.

**Spec:** `docs/superpowers/specs/2026-09-04-tool-setup-lifecycle-design.md`

## Global Constraints

- No `$ErrorActionPreference = 'Stop'` in any module file.
- All directory creation goes through `New-DFDirectory`, never raw `New-Item` (except inside test fixtures/`BeforeEach`, which use `New-Item` directly to build TestDrive scaffolding, matching existing test-file precedent).
- **Private function declaration:** `function script:<Name>` — matches `Private/Get-DFConfiguredTheme.ps1` and `Private/Expand-DFXdgPath.ps1`. **Public function declaration:** plain `function <Name>`, with complete comment-based help (`.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER` for each parameter, at least one `.EXAMPLE`, `.OUTPUTS`) — required before committing per `CLAUDE.md`; verify by running `Get-Help <Name> -Full` and confirming every section renders.
- New Public functions go in `DotForge.psd1`'s `FunctionsToExport`. Private functions do not.
- **Never index `$Global:DFConfig` with the `?[` null-conditional operator.** Use the exact guard already in `Public/Register-DFTool.ps1:60-62`: `@(if ($null -ne $Global:DFConfig) { $Global:DFConfig['Key'] })`. (`?.` member access, e.g. `.PSObject.Properties['x']?.Value`, is fine and used throughout — the avoidance is specific to indexing `$DFConfig` itself.)
- **Atomic JSON writes:** write to `"$Path.tmp.$PID"` then `Move-Item -Force` to the real path — matches `Private/DFCatalog.ps1:190-196`. Never `Set-Content` directly over a shared state file.
- `ConvertFrom-Json` can auto-convert an ISO-8601-looking string into a `[datetime]` object with unpredictable `Kind` (see `Private/DFCatalog.ps1:223` comment) — never assert an exact string equality or regex match against a round-tripped timestamp field in a test; cast with `[datetime]` and compare via `.ToUniversalTime()` instead.
- Before running Task 1 Step 1, run `pwsh -NoProfile -Command "Invoke-Pester tests/ -Output None"` once and note the pass/fail counts as this plan's baseline. Every later full-suite run in this plan must be compared against that baseline, not against a number from an earlier, unrelated session.
- Before committing any task with a user-visible change: update `README.md` and `CHANGELOG.md`'s `[Unreleased]` section (project convention, enforced by a pre-commit hook reminder).

---

### Task 1: State store — `Get-DFToolSetupState` / `Complete-DFToolSetup`

**Files:**
- Create: `Private/Get-DFToolSetupState.ps1`
- Create: `Public/Complete-DFToolSetup.ps1`
- Test: `tests/Get-DFToolSetupState.Tests.ps1`
- Test: `tests/Complete-DFToolSetup.Tests.ps1`
- Modify: `DotForge.psd1`

**Interfaces:**
- Produces: `Get-DFToolSetupState` (Private, no parameters) → `[PSCustomObject]`. Reads `$Env:XDG_STATE_HOME/dotforge/setup-state.json`; returns `[PSCustomObject]@{}` when the file is missing, unreadable, or `$Env:XDG_STATE_HOME` itself is unset — never throws.
- Produces: `Complete-DFToolSetup -Name <string> [-Actions <object[]>]` (Public). No return value. Reads current state via `Get-DFToolSetupState`, sets/overwrites the entry for `-Name` with `ranAt` (UTC, ISO-8601) and `-Actions` (default `@()`), writes back atomically.

- [ ] **Step 1: Write the failing tests for `Get-DFToolSetupState`**

Create `tests/Get-DFToolSetupState.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/../Private/Get-DFToolSetupState.ps1"
}

Describe 'Get-DFToolSetupState' {
    BeforeEach {
        $script:SavedStateHome = $Env:XDG_STATE_HOME
        $Env:XDG_STATE_HOME = Join-Path $TestDrive 'state'
    }

    AfterEach {
        $Env:XDG_STATE_HOME = $script:SavedStateHome
    }

    It 'returns an empty object when the state file does not exist' {
        $state = Get-DFToolSetupState
        @($state.PSObject.Properties).Count | Should -Be 0
    }

    It 'returns an empty object when $Env:XDG_STATE_HOME is not set' {
        $Env:XDG_STATE_HOME = $null
        { Get-DFToolSetupState } | Should -Not -Throw
        $state = Get-DFToolSetupState
        @($state.PSObject.Properties).Count | Should -Be 0
    }

    It 'returns an empty object when the state file is corrupt JSON' {
        $stateDir = Join-Path $Env:XDG_STATE_HOME 'dotforge'
        New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
        Set-Content -Path (Join-Path $stateDir 'setup-state.json') -Value '{ not valid json' -Encoding UTF8

        $state = Get-DFToolSetupState
        @($state.PSObject.Properties).Count | Should -Be 0
    }

    It 'parses an existing state file' {
        $stateDir = Join-Path $Env:XDG_STATE_HOME 'dotforge'
        New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
        @'
{ "delta": { "ranAt": "2026-09-04T10:22:00Z", "actions": [] } }
'@ | Set-Content -Path (Join-Path $stateDir 'setup-state.json') -Encoding UTF8

        $state = Get-DFToolSetupState
        $state.PSObject.Properties['delta'] | Should -Not -BeNullOrEmpty
        [datetime]$state.delta.ranAt | Should -Be ([datetime]'2026-09-04T10:22:00Z')
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Get-DFToolSetupState.Tests.ps1 -Output Detailed"`

Expected: FAIL — `Get-DFToolSetupState` is not defined (the file doesn't exist yet).

- [ ] **Step 3: Create `Private/Get-DFToolSetupState.ps1`**

```powershell
#Requires -Version 7.0

function script:Get-DFToolSetupState {
    <#
    .SYNOPSIS
        Reads the persisted one-time tool-setup state, keyed by tool name.
    .DESCRIPTION
        Backs Register-DFTool's "has this tool's Tools/<name>.setup.ps1 already
        run?" check and Complete-DFToolSetup's read-modify-write. Never throws:
        a missing file, an unset $Env:XDG_STATE_HOME, or corrupt JSON all
        return an empty object, treated the same as "no tool has ever run
        setup" -- see docs/superpowers/specs/2026-09-04-tool-setup-lifecycle-design.md.
    .OUTPUTS
        [PSCustomObject] keyed by tool name; each value has .ranAt (string)
        and .actions (object[]). Empty object ([PSCustomObject]@{}) if no
        state has ever been recorded.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    if (-not $Env:XDG_STATE_HOME) {
        return [PSCustomObject]@{}
    }

    $stateFile = Join-Path $Env:XDG_STATE_HOME 'dotforge' 'setup-state.json'
    if (-not (Test-Path $stateFile -PathType Leaf)) {
        return [PSCustomObject]@{}
    }

    try {
        Get-Content -Path $stateFile -Raw | ConvertFrom-Json
    } catch {
        [PSCustomObject]@{}
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Get-DFToolSetupState.Tests.ps1 -Output Detailed"`

Expected: PASS — all 4 tests green.

- [ ] **Step 5: Write the failing tests for `Complete-DFToolSetup`**

Create `tests/Complete-DFToolSetup.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/ConvertTo-DFPath.ps1"
    . "$PSScriptRoot/../Private/Get-DFToolSetupState.ps1"
    . "$PSScriptRoot/../Public/Complete-DFToolSetup.ps1"
}

Describe 'Complete-DFToolSetup' {
    BeforeEach {
        $script:SavedStateHome = $Env:XDG_STATE_HOME
        $Env:XDG_STATE_HOME = Join-Path $TestDrive 'state'
    }

    AfterEach {
        $Env:XDG_STATE_HOME = $script:SavedStateHome
    }

    It 'creates the state file and records actions for a new tool' {
        Complete-DFToolSetup -Name 'delta' -Actions @(
            @{ type = 'gitConfigInclude'; path = 'C:\fake\catppuccin.gitconfig' }
        )

        $stateFile = Join-Path $Env:XDG_STATE_HOME 'dotforge' 'setup-state.json'
        Test-Path $stateFile -PathType Leaf | Should -BeTrue

        $state = Get-DFToolSetupState
        $state.delta.actions[0].type | Should -Be 'gitConfigInclude'
        $state.delta.actions[0].path | Should -Be 'C:\fake\catppuccin.gitconfig'
    }

    It 'defaults Actions to an empty array when omitted' {
        Complete-DFToolSetup -Name 'mdv'
        $state = Get-DFToolSetupState
        @($state.mdv.actions).Count | Should -Be 0
    }

    It 'overwrites an existing entry for the same tool without touching others' {
        Complete-DFToolSetup -Name 'delta' -Actions @(@{ type = 'first' })
        Complete-DFToolSetup -Name 'mdv'    -Actions @()
        Complete-DFToolSetup -Name 'delta' -Actions @(@{ type = 'second' })

        $state = Get-DFToolSetupState
        @($state.delta.actions).Count | Should -Be 1
        $state.delta.actions[0].type  | Should -Be 'second'
        $state.PSObject.Properties['mdv'] | Should -Not -BeNullOrEmpty
    }

    It 'records ranAt as a recent, valid UTC timestamp' {
        Complete-DFToolSetup -Name 'delta'
        $state = Get-DFToolSetupState
        # ConvertFrom-Json may auto-parse the ISO-8601 string to [datetime] with
        # an unpredictable Kind -- cast (a no-op if already [datetime]) then
        # normalize to UTC before comparing, per this plan's Global Constraints.
        $ranAtUtc = ([datetime]$state.delta.ranAt).ToUniversalTime()
        $ranAtUtc | Should -BeGreaterThan ([datetime]::UtcNow.AddMinutes(-5))
        $ranAtUtc | Should -BeLessThan ([datetime]::UtcNow.AddMinutes(1))
    }

    It 'warns and no-ops when $Env:XDG_STATE_HOME is not set' {
        $Env:XDG_STATE_HOME = $null
        $warnings = Complete-DFToolSetup -Name 'delta' 3>&1 |
            Where-Object { $_ -is [System.Management.Automation.WarningRecord] }
        $warnings | Where-Object { $_ -match 'XDG_STATE_HOME' } | Should -Not -BeNullOrEmpty
    }
}
```

- [ ] **Step 6: Run the test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Complete-DFToolSetup.Tests.ps1 -Output Detailed"`

Expected: FAIL — `Complete-DFToolSetup` is not defined.

- [ ] **Step 7: Create `Public/Complete-DFToolSetup.ps1`**

```powershell
#Requires -Version 7.0

function Complete-DFToolSetup {
    <#
    .SYNOPSIS
        Records that a tool's one-time setup has completed successfully.
    .DESCRIPTION
        Call this from a Tools/<name>.setup.ps1 companion as its own last
        line, only once the script's work has actually succeeded. Merges an
        entry for -Name into the persisted state file at
        $XDG_STATE_HOME/dotforge/setup-state.json, recording the UTC time it
        ran and an opaque -Actions record whose shape the calling tool
        defines -- DotForge core never interprets it.

        Register-DFTool checks this state before dot-sourcing a tool's
        Tools/<name>.setup.ps1 again, so once an entry exists for a tool, its
        setup script is skipped on every future Register-DFTool call --
        forever, until the state file is deleted or the entry is removed. See
        docs/superpowers/specs/2026-09-04-tool-setup-lifecycle-design.md.
    .PARAMETER Name
        The tool name this setup record belongs to (matches the "name" field
        in the tool's Tools/<name>.json).
    .PARAMETER Actions
        Free-form objects describing what the setup did, e.g.
        @{ type = 'gitConfigInclude'; path = '...' }. Opaque to DotForge
        core -- recorded verbatim for a future teardown command to read
        back. Defaults to an empty array.
    .EXAMPLE
        Complete-DFToolSetup -Name 'delta' -Actions @(
            @{ type = 'gitConfigInclude'; path = $resolvedIncludePath }
        )
        Records that delta's setup ran, and what it changed.
    .EXAMPLE
        Complete-DFToolSetup -Name 'mdv'
        Records that mdv's setup ran, with no actions to report.
    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [object[]]$Actions = @()
    )

    if (-not $Env:XDG_STATE_HOME) {
        Write-Warning 'DotForge: $Env:XDG_STATE_HOME is not set. Call Initialize-DFEnvironment first.'
        return
    }

    $state = Get-DFToolSetupState
    $entry = [PSCustomObject]@{
        ranAt   = (Get-Date).ToUniversalTime().ToString('o')
        actions = @($Actions)
    }
    $state | Add-Member -MemberType NoteProperty -Name $Name -Value $entry -Force

    $stateDir  = Join-Path $Env:XDG_STATE_HOME 'dotforge'
    $stateFile = Join-Path $stateDir 'setup-state.json'
    New-DFDirectory $stateDir

    $tmp = "$stateFile.tmp.$PID"
    $state | ConvertTo-Json -Depth 10 | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Path $tmp -Destination $stateFile -Force
}
```

- [ ] **Step 8: Run the test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Complete-DFToolSetup.Tests.ps1 -Output Detailed"`

Expected: PASS — all 5 tests green.

- [ ] **Step 9: Verify comment-based help renders completely**

Run:

```powershell
pwsh -NoProfile -Command "Import-Module ./DotForge.psd1 -Force; Get-Help Complete-DFToolSetup -Full"
```

Expected: `SYNOPSIS`, `SYNTAX`, `DESCRIPTION`, both `PARAMETERS` (`-Name`, `-Actions`), both `EXAMPLES`, and `OUTPUTS` all render — no missing sections, no raw comment-block text leaking through unparsed.

- [ ] **Step 10: Add `Complete-DFToolSetup` to the manifest**

In `DotForge.psd1`, find:

```powershell
        # Layer 2 — Tool Registry
        'Get-DFTool',
        'Find-DFTool',
        'Register-DFTool',
```

Replace with:

```powershell
        # Layer 2 — Tool Registry
        'Get-DFTool',
        'Find-DFTool',
        'Register-DFTool',
        'Complete-DFToolSetup',
```

- [ ] **Step 11: Run the full suite to check for regressions**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/ -Output None"`

Expected: no new failures beyond this plan's recorded baseline.

- [ ] **Step 12: Commit**

```bash
git add Private/Get-DFToolSetupState.ps1 Public/Complete-DFToolSetup.ps1 tests/Get-DFToolSetupState.Tests.ps1 tests/Complete-DFToolSetup.Tests.ps1 DotForge.psd1
git commit -m "$(cat <<'EOF'
feat: add tool-setup-lifecycle state store

Get-DFToolSetupState (Private) reads $XDG_STATE_HOME/dotforge/setup-state.json,
never throwing (missing file, unset XDG_STATE_HOME, and corrupt JSON all
resolve to an empty object). Complete-DFToolSetup (Public) is the write side:
a tool's Tools/<name>.setup.ps1 calls it as its own last line, once its work
has actually succeeded, recording when it ran and an opaque per-tool
actions record. Writes are atomic (temp file + Move-Item -Force) since this
is a single shared state file for every tool.

Not yet wired into Register-DFTool -- that's the next task.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KjTXV8CBbqnMmRTZspmhfs
EOF
)"
```

---

### Task 2: `Register-DFTool` integration

**Files:**
- Modify: `Public/Register-DFTool.ps1:60-62` (add `$skipSetup`), `Public/Register-DFTool.ps1:291-297` (add the one-time-setup block)
- Modify: `tests/Register-DFTool.Tests.ps1`
- Modify: `CLAUDE.md` (Key Design Decisions)
- Modify: `README.md` (`$DFConfig` example block)
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes (Task 1): `Get-DFToolSetupState` (Private), `Complete-DFToolSetup -Name <string> [-Actions <object[]>]` (Public).
- Produces: `$DFConfig['SkipSetup']` — a new, generic user-facing config key (array of tool names). `Tools/<name>.setup.ps1` — a new companion-file convention any tool may add.

- [ ] **Step 1: Write the failing tests**

In `tests/Register-DFTool.Tests.ps1`'s `BeforeAll` (top of file), add the two new dependencies:

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

(Only the two new lines, `Get-DFToolSetupState.ps1` and `Complete-DFToolSetup.ps1`, are additions — placed right before `Register-DFTool.ps1` since it now depends on both, matching how `Get-DFConfiguredTheme`/`Resolve-DFThemeName` are ordered relative to `Register-DFTool.ps1` in the vivid/bat test files.)

The file has two top-level `Describe` blocks: `Describe 'Register-DFTool'` closes at line 515, then `Describe 'Invoke-DFTopoSort'` starts at line 517 and runs to the end of the file (line 575). Insert a new `Describe` block **between them** — after line 515's closing brace, before line 517's `Describe 'Invoke-DFTopoSort' {`:

```powershell
Describe 'Register-DFTool one-time setup' {
    BeforeEach {
        $script:DFToolDb = $null
        $script:SavedConfigHome = $Env:XDG_CONFIG_HOME
        $script:SavedCacheHome  = $Env:XDG_CACHE_HOME
        $script:SavedStateHome  = $Env:XDG_STATE_HOME
        $script:SavedWinDir     = $Env:WINDIR
        $Env:XDG_CONFIG_HOME = Join-Path $TestDrive 'config'
        $Env:XDG_CACHE_HOME  = Join-Path $TestDrive 'cache'
        $Env:XDG_STATE_HOME  = Join-Path $TestDrive 'state'
        $Env:WINDIR = 'C:\Windows'
        $Global:__DFTestSetupRunCount = 0

        $script:TmpTools = Join-Path $TestDrive 'setup-tools'
        New-Item -ItemType Directory -Force -Path $script:TmpTools | Out-Null

        @'
{
  "name": "testsetup",
  "executable": "testsetup.exe",
  "xdg": { "compliance": "none", "method": "default" }
}
'@ | Set-Content (Join-Path $script:TmpTools 'testsetup.json')

        @'
$Global:__DFTestSetupRunCount++
Complete-DFToolSetup -Name 'testsetup' -Actions @(@{ type = 'marker'; value = 'ran' })
'@ | Set-Content (Join-Path $script:TmpTools 'testsetup.setup.ps1')

        @'
{
  "name": "testsetupfail",
  "executable": "testsetupfail.exe",
  "xdg": { "compliance": "none", "method": "default" },
  "aliases": { "tsf": { "command": "testsetupfail", "args": [] } }
}
'@ | Set-Content (Join-Path $script:TmpTools 'testsetupfail.json')

        @'
throw 'boom: setup deliberately fails'
'@ | Set-Content (Join-Path $script:TmpTools 'testsetupfail.setup.ps1')
    }

    AfterEach {
        $Env:XDG_CONFIG_HOME = $script:SavedConfigHome
        $Env:XDG_CACHE_HOME  = $script:SavedCacheHome
        $Env:XDG_STATE_HOME  = $script:SavedStateHome
        $Env:WINDIR          = $script:SavedWinDir
        Remove-Variable __DFTestSetupRunCount -Scope Global -ErrorAction Ignore
        Remove-Alias tsf -Force -Scope Global -ErrorAction Ignore
    }

    It 'dot-sources <name>.setup.ps1 on first registration and records state' {
        Mock Get-Command { [PSCustomObject]@{ Path = 'C:\fake\testsetup.exe' } }
        Register-DFTool -Name 'testsetup' -ToolsPath $script:TmpTools

        $Global:__DFTestSetupRunCount | Should -Be 1
        $state = Get-DFToolSetupState
        $state.PSObject.Properties['testsetup'] | Should -Not -BeNullOrEmpty
        $state.testsetup.actions[0].type | Should -Be 'marker'
    }

    It 'does not run setup.ps1 again on a second registration' {
        Mock Get-Command { [PSCustomObject]@{ Path = 'C:\fake\testsetup.exe' } }
        Register-DFTool -Name 'testsetup' -ToolsPath $script:TmpTools
        Register-DFTool -Name 'testsetup' -ToolsPath $script:TmpTools

        $Global:__DFTestSetupRunCount | Should -Be 1
    }

    It 'runs setup.ps1 again if the state file is deleted' {
        Mock Get-Command { [PSCustomObject]@{ Path = 'C:\fake\testsetup.exe' } }
        Register-DFTool -Name 'testsetup' -ToolsPath $script:TmpTools
        $Global:__DFTestSetupRunCount | Should -Be 1

        Remove-Item (Join-Path $Env:XDG_STATE_HOME 'dotforge' 'setup-state.json') -Force
        Register-DFTool -Name 'testsetup' -ToolsPath $script:TmpTools

        $Global:__DFTestSetupRunCount | Should -Be 2
    }

    It 'never dot-sources setup.ps1 when the tool is in $DFConfig.SkipSetup' {
        Mock Get-Command { [PSCustomObject]@{ Path = 'C:\fake\testsetup.exe' } }
        $Global:DFConfig = @{ SkipSetup = @('testsetup') }
        Register-DFTool -Name 'testsetup' -ToolsPath $script:TmpTools

        $Global:__DFTestSetupRunCount | Should -Be 0
        (Get-DFToolSetupState).PSObject.Properties['testsetup'] | Should -BeNullOrEmpty
    }

    It 'warns and records no state when setup.ps1 throws, but still finishes registering the tool normally' {
        Mock Get-Command { [PSCustomObject]@{ Path = 'C:\fake\testsetupfail.exe' } }
        $warnings = Register-DFTool -Name 'testsetupfail' -ToolsPath $script:TmpTools 3>&1 |
            Where-Object { $_ -is [System.Management.Automation.WarningRecord] }

        $warnings | Where-Object { $_ -match 'testsetupfail' } | Should -Not -BeNullOrEmpty
        (Get-DFToolSetupState).PSObject.Properties['testsetupfail'] | Should -BeNullOrEmpty
        # The tool's own declared alias still gets set -- one tool's setup
        # failure must not break the rest of its own registration.
        Get-Alias tsf -ErrorAction Ignore | Should -Not -BeNullOrEmpty
    }

    It 'never dot-sources setup.ps1 for a tool not found on PATH' {
        Mock Get-Command { $null }
        Register-DFTool -Name 'testsetup' -ToolsPath $script:TmpTools

        $Global:__DFTestSetupRunCount | Should -Be 0
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Register-DFTool.Tests.ps1 -Output Detailed"`

Expected: FAIL — the new `Describe 'Register-DFTool one-time setup'` block's tests all fail (`.setup.ps1` is never dot-sourced yet, `$DFConfig['SkipSetup']` doesn't exist yet). The pre-existing `Describe 'Register-DFTool'` tests still pass.

- [ ] **Step 3: Add `$skipSetup` next to the existing `$skipTools` computation**

In `Public/Register-DFTool.ps1`, find:

```powershell
    # Test the value, not just the variable's existence: `$DFConfig = $null` leaves
    # the variable defined, and indexing into it throws "Cannot index into a null array".
    $skipTools = @(if ($null -ne $Global:DFConfig) {
        $Global:DFConfig['SkipTools']
    })
```

Replace with:

```powershell
    # Test the value, not just the variable's existence: `$DFConfig = $null` leaves
    # the variable defined, and indexing into it throws "Cannot index into a null array".
    $skipTools = @(if ($null -ne $Global:DFConfig) {
        $Global:DFConfig['SkipTools']
    })
    $skipSetup = @(if ($null -ne $Global:DFConfig) {
        $Global:DFConfig['SkipSetup']
    })
```

- [ ] **Step 4: Add the one-time-setup block after the companion `.ps1` block**

In `Public/Register-DFTool.ps1`, find:

```powershell
        # ── Companion .ps1 ──────────────────────────────────────────────────
        $companion = Join-Path $resolvedToolsPath "$($tool.name).ps1"
        if (Test-Path $companion -PathType Leaf) {
            $DFCurrentTool = $tool
            . ($companion)
            Remove-Variable -Name DFCurrentTool -ErrorAction Ignore
        }

        Write-Verbose "DotForge: $($tool.name) registered"
        $registeredTools.Add($tool.name)
```

Replace with:

```powershell
        # ── Companion .ps1 ──────────────────────────────────────────────────
        $companion = Join-Path $resolvedToolsPath "$($tool.name).ps1"
        if (Test-Path $companion -PathType Leaf) {
            $DFCurrentTool = $tool
            . ($companion)
            Remove-Variable -Name DFCurrentTool -ErrorAction Ignore
        }

        # ── One-time setup ──────────────────────────────────────────────────
        # Tools/<name>.setup.ps1 runs at most once ever per tool: it is
        # responsible for calling Complete-DFToolSetup itself, as its own
        # last line, only once its work has actually succeeded. If it throws
        # first, nothing gets recorded, so the next Register-DFTool call
        # retries from the top -- see
        # docs/superpowers/specs/2026-09-04-tool-setup-lifecycle-design.md.
        $setupCompanion = Join-Path $resolvedToolsPath "$($tool.name).setup.ps1"
        if ((Test-Path $setupCompanion -PathType Leaf) -and
            $tool.name -notin $skipSetup -and
            -not (Get-DFToolSetupState).PSObject.Properties[$tool.name]) {
            $DFCurrentTool = $tool
            try {
                . ($setupCompanion)
            } catch {
                Write-Warning "DotForge: $($tool.name) one-time setup failed: $($_.Exception.Message)"
            }
            Remove-Variable -Name DFCurrentTool -ErrorAction Ignore
        }

        Write-Verbose "DotForge: $($tool.name) registered"
        $registeredTools.Add($tool.name)
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Register-DFTool.Tests.ps1 -Output Detailed"`

Expected: PASS — every test in the file green, including both `Describe` blocks.

- [ ] **Step 6: Run the full suite to check for regressions**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/ -Output None"`

Expected: no new failures beyond this plan's recorded baseline.

- [ ] **Step 7: Document the mechanism in `CLAUDE.md`**

In `CLAUDE.md`, find:

```markdown
- **`$DFCurrentTool` sidecar contract**: `Register-DFTool` sets `$DFCurrentTool = $tool` immediately before dot-sourcing a companion `.ps1` and clears it after. Sidecars may read `$DFCurrentTool.settings` and other fields. Existing sidecars that do not reference `$DFCurrentTool` are unaffected. Sidecars needing their own subdirectory use `$PSScriptRoot`, which resolves to `Tools/` at dot-source time.
```

Replace with:

```markdown
- **`$DFCurrentTool` sidecar contract**: `Register-DFTool` sets `$DFCurrentTool = $tool` immediately before dot-sourcing a companion `.ps1` and clears it after. Sidecars may read `$DFCurrentTool.settings` and other fields. Existing sidecars that do not reference `$DFCurrentTool` are unaffected. Sidecars needing their own subdirectory use `$PSScriptRoot`, which resolves to `Tools/` at dot-source time.
- **Tool setup lifecycle**: an optional `Tools/<name>.setup.ps1`, parallel to the regular `.ps1`, runs at most once ever per tool (tracked in `$XDG_STATE_HOME/dotforge/setup-state.json`, checked/updated via `Private/Get-DFToolSetupState.ps1`/`Public/Complete-DFToolSetup.ps1`) — for setup that makes a persistent, user-visible change (e.g. an `[include]` line in the user's real git config) that must never be silently reasserted after the user edits or removes it. The script owns its own success: it must call `Complete-DFToolSetup -Name <tool> [-Actions <object[]>]` itself, as its own last line, only once its work has actually succeeded — a thrown error records nothing, so the next `Register-DFTool` call retries from the top. `$DFConfig['SkipSetup']` (array of tool names) opts a tool's setup script out entirely, mirroring `SkipTools`. Full design: `docs/superpowers/specs/2026-09-04-tool-setup-lifecycle-design.md`.
```

- [ ] **Step 8: Update `README.md`'s `$DFConfig` example block**

In `README.md`, find:

```markdown
    PackageManagerOrder = @('scoop', 'winget')  # PM preference for Install-DFTool
    SkipTools           = @('lsd')              # excluded from Register-DFTool -All
```

Replace with:

```markdown
    PackageManagerOrder = @('scoop', 'winget')  # PM preference for Install-DFTool
    SkipTools           = @('lsd')              # excluded from Register-DFTool -All
    SkipSetup           = @('delta')            # excluded from Tools/<name>.setup.ps1's one-time run
```

- [ ] **Step 9: Update `CHANGELOG.md`**

In `CHANGELOG.md`, find:

```markdown
## [Unreleased]

### Added
```

Replace with:

```markdown
## [Unreleased]

### Added

- **Tool setup lifecycle.** A new optional `Tools/<name>.setup.ps1` companion
  runs at most once ever per tool — for setup that makes a persistent,
  user-visible change (e.g. adding an `[include]` line to the user's real git
  config) that must never be silently reasserted after the user edits or
  removes it. Tracked in `$XDG_STATE_HOME/dotforge/setup-state.json`
  (`Private/Get-DFToolSetupState.ps1`); a tool's setup script records its own
  success by calling the new `Complete-DFToolSetup -Name <tool> [-Actions
  <object[]>]`, so a script that throws before reaching that call is retried
  on the next `Register-DFTool` call rather than silently marked done. New
  `$DFConfig['SkipSetup']` opts a tool out, mirroring `SkipTools`. No
  consumer yet — `delta`'s catppuccin theming (tracked in `TODO.md`) will be
  the first.
```

- [ ] **Step 10: Run the full suite one more time**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/ -Output None"`

Expected: no new failures beyond this plan's recorded baseline (docs-only edits since Step 6, shouldn't change anything, but confirms no accidental breakage).

- [ ] **Step 11: Commit**

```bash
git add Public/Register-DFTool.ps1 tests/Register-DFTool.Tests.ps1 CLAUDE.md README.md CHANGELOG.md
git commit -m "$(cat <<'EOF'
feat(register-dftool): wire in the one-time tool setup lifecycle

Tools/<name>.setup.ps1, when present, is dot-sourced at most once ever
per tool -- gated on Get-DFToolSetupState and skippable via the new
$DFConfig['SkipSetup'] (mirrors SkipTools). The script records its own
success via Complete-DFToolSetup, called as its own last line; a
thrown error is caught, warned, and left unrecorded so the next
Register-DFTool call retries from the top rather than a tool getting
silently stranded half-configured.

No consumer yet -- delta's catppuccin theming (TODO.md) is next.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KjTXV8CBbqnMmRTZspmhfs
EOF
)"
```

---

## Self-Review Notes

- **Spec coverage:** File convention + `Register-DFTool` integration + `SkipSetup` → Task 2. `Get-DFToolSetupState`/`Complete-DFToolSetup` + data model → Task 1. Testing section → both tasks' test steps (unit tests in Task 1, integration tests in Task 2, covering every acceptance criterion: runs once, deleting state reruns it, a failing script never marks done and doesn't break the rest of that tool's registration, `SkipSetup` suppresses it, no `.setup.ps1` present is a zero-cost no-op — the last one is implicit: every pre-existing `Describe 'Register-DFTool'` test has no `.setup.ps1` fixture and is asserted unaffected by both full-suite regression steps). Delta/mdv migration and a teardown command are explicitly out of this spec's scope and are not tasks here, per the spec's own Scope section.
- **Placeholder scan:** none found — every step has complete, runnable code.
- **Type consistency:** `Get-DFToolSetupState` (no params, returns `[PSCustomObject]`) is defined once in Task 1 Step 3 and consumed identically — by name, no params — in `Complete-DFToolSetup` (Task 1 Step 7) and in `Register-DFTool`'s new block (Task 2 Step 4). `Complete-DFToolSetup -Name <string> [-Actions <object[]>]` is defined once in Task 1 Step 7 and called with that exact signature by the `testsetup.setup.ps1` fixture in Task 2 Step 1.
