# Declarative Tool Effects Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tools declare their theme, executable wrapper and env values in JSON; the core applies them with one precedence rule (T-21, closing T-28 and T-29).

**Architecture:** Phase 1 generalizes the role-env ledger (`Set-DFRoleEnv`) into `Set-DFEnv`, used by every DotForge env write, and makes status `Detail` a list. Phase 2 adds a normalized `theme` block, `Get-DFToolTheme`/`Resolve-DFToolTheme`, `Set-DFToolThemeEnv` (applied during registration) and a public `Set-DFToolTheme`, then migrates nine tools. Phase 3 adds a `wrapper` block and `New-DFToolWrapper`, then migrates glow and fastfetch and adds lsd.

**Tech Stack:** PowerShell 7.2+, Pester 6.

**Spec:** `docs/superpowers/specs/2026-10-12-declarative-tool-effects-design.md`

## Global Constraints

- Work in a worktree: `git worktree add ../DotForge-tool-effects -b tool-effects` from `main`; every path below is relative to it.
- Core code never names a tool (`docs/plugin-architecture.md`); new behavior is an optional field the core no-ops on when absent.
- Tests: `. "$PSScriptRoot/TestSupport.ps1"` then `foreach ($f in Get-DFTestModuleFile) { . $f }`; Pester 6 syntax only (`Should -Invoke`, never `Assert-MockCalled`); XDG isolation with `Set-DFTestXdg`/`Restore-DFTestXdg`; config with `Set-DFTestConfig`; session state with `Reset-DFTestSession`; globals removed with `Remove-DFTestGlobal`.
- Run a task's tests with `pwsh -NoProfile -File build/Test-DFFull.ps1 -Path <test files>`; the whole suite with `pwsh -NoProfile -File build/Test-DFFull.ps1`.
- After changing `Shared/`, `Private/` or `Public/`: `pwsh -NoProfile -File build/Build-DFCoreBundle.ps1`. After changing `Tools/*.json`: `pwsh -NoProfile -File build/Build-DFToolRegistry.ps1`. After changing help or tool JSON: `pwsh -NoProfile -File build/Build-DFReferenceDocs.ps1`. Commit the regenerated files with the change.
- Every public function and every global function a companion defines has complete comment-based help (`.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER` each, `.EXAMPLE` code + blank line + prose, `.OUTPUTS`).
- No `$ErrorActionPreference = 'Stop'` in module files; paths through `ConvertTo-DFPath`/`Expand-DFXdgPath`; folders through `New-DFDirectory`.
- Commits are GPG-signed. On `gpg: signing failed: Timeout`, stop and ask the user to run `! 'unlock' | gpg --clearsign | Out-Null`; never bypass signing.
- Commit messages end with:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01XaRtQPwDUByTipgRdGiuKv
  ```

## Review Focus

1. A theme value with a space (`Catppuccin Mocha`) reaching a wrapper must stay one argument → Task 9 test "keeps a theme value with spaces as one argument".
2. A theme rejected by `valid` with no `fallback` must not write an empty env value (which deletes the variable) → Task 5 test "writes nothing when the theme resolves to no value".
3. Piped input through a generated wrapper whose `ifFile` is missing must not hang and must pass no `{file}` group → Task 9 test "passes piped input through without the missing file's group".
4. `Set-DFToolTheme` with an unknown theme warns and falls back instead of failing, and on an inactive tool errors without terminating → Task 6 tests.
5. A user who changes a variable after DotForge set it, then re-registers, keeps their value → Task 1 test "treats a value the user changed after DotForge set it as outside DotForge".

---

## Phase 1 — One env precedence rule

### Task 1: `Set-DFEnv` replaces `Set-DFRoleEnv`

**Files:**
- Rename: `Private/Set-DFRoleEnv.ps1` → `Private/Set-DFEnv.ps1` (rewrite)
- Rename: `tests/Set-DFRoleEnv.Tests.ps1` → `tests/Set-DFEnv.Tests.ps1` (rewrite)
- Modify: `Private/Register-DFToolSteps.ps1:227` (help text) and `:286-292` (role env loop)
- Modify: `Public/Get-DFRole.ps1:71`
- Modify: `tests/TestSupport.ps1` (`Reset-DFTestSession`)

**Interfaces:**
- Produces: `Get-DFEnvState` → `@{ Written = @{}; Warned = @{}; Kept = @{} }` (session global `$global:DFEnvState`); `Set-DFEnv -Name <string> -Value <string> -Tool <string> [-ExplicitReason <string>]` → nothing; `Get-DFEnvKeptNote -Tool <string>` → `string[]`; `Clear-DFEnvKeptNote -Tool <string>`; `Format-DFEnvValue -Value <string>` → `string`.

- [ ] **Step 1: Move the files**

```powershell
git mv Private/Set-DFRoleEnv.ps1 Private/Set-DFEnv.ps1
git mv tests/Set-DFRoleEnv.Tests.ps1 tests/Set-DFEnv.Tests.ps1
```

`Get-DFTestModuleFile` and the module loader load every `Private/*.ps1`, so the rename needs no list edit. Confirm with `rg -n "Set-DFRoleEnv" DotForge.psm1 build tests/TestSupport.ps1` (expect no hits).

- [ ] **Step 2: Write the failing tests** — replace `tests/Set-DFEnv.Tests.ps1` with:

```powershell
BeforeAll { . "$PSScriptRoot/../Private/Set-DFEnv.ps1" }

Describe 'Set-DFEnv' {
    BeforeEach {
        $global:DFEnvState = $null
        $script:Saved = $Env:DF_TEST_PAGER
        Remove-Item Env:DF_TEST_PAGER -ErrorAction Ignore
        $script:Common = @{ Name = 'DF_TEST_PAGER'; Tool = 'moar' }
        $script:Defaults = "`$DFConfig.Defaults.pager is 'moar'; using moar"
    }
    AfterEach {
        Remove-Variable DFEnvState -Scope Global -ErrorAction Ignore
        if ($null -eq $script:Saved) { Remove-Item Env:DF_TEST_PAGER -ErrorAction Ignore } else { $Env:DF_TEST_PAGER = $script:Saved }
    }

    It 'sets an unset variable' {
        Set-DFEnv @script:Common -Value 'moar'
        $Env:DF_TEST_PAGER | Should -Be 'moar'
    }

    It 'keeps a value set outside DotForge when the choice is not explicit, silently' {
        $Env:DF_TEST_PAGER = 'less'
        Set-DFEnv @script:Common -Value 'moar' -WarningVariable w
        $Env:DF_TEST_PAGER | Should -Be 'less'
        $w | Should -BeNullOrEmpty
    }

    It 'notes the kept value for the tool' {
        $Env:DF_TEST_PAGER = 'less'
        Set-DFEnv @script:Common -Value 'moar'
        Get-DFEnvKeptNote -Tool 'moar' | Should -Be "DF_TEST_PAGER kept as set outside DotForge ('less'); DotForge wanted 'moar'"
    }

    It 'drops the note once the variable is written' {
        $Env:DF_TEST_PAGER = 'less'
        Set-DFEnv @script:Common -Value 'moar'
        Remove-Item Env:DF_TEST_PAGER
        Set-DFEnv @script:Common -Value 'moar'
        Get-DFEnvKeptNote -Tool 'moar' | Should -BeNullOrEmpty
    }

    It 'clears a tool''s notes' {
        $Env:DF_TEST_PAGER = 'less'
        Set-DFEnv @script:Common -Value 'moar'
        Clear-DFEnvKeptNote -Tool 'moar'
        Get-DFEnvKeptNote -Tool 'moar' | Should -BeNullOrEmpty
    }

    It 'shortens long values in notes' {
        $Env:DF_TEST_PAGER = 'x' * 100
        Set-DFEnv @script:Common -Value 'moar'
        Get-DFEnvKeptNote -Tool 'moar' | Should -Match "\('x{57}\.\.\.'\)"
    }

    It 'replaces a value set outside DotForge for an explicit choice, and warns with both settings' {
        $Env:DF_TEST_PAGER = 'less'
        Set-DFEnv @script:Common -Value 'moar' -ExplicitReason $script:Defaults -WarningVariable w -WarningAction SilentlyContinue
        $Env:DF_TEST_PAGER | Should -Be 'moar'
        "$w" | Should -Match "DF_TEST_PAGER was 'less' but \`$DFConfig.Defaults.pager is 'moar'; using moar"
        "$w" | Should -Match 'Remove one of the two settings'
    }

    It 'does not warn when the outside value already equals the new value' {
        $Env:DF_TEST_PAGER = 'moar'
        Set-DFEnv @script:Common -Value 'moar' -ExplicitReason $script:Defaults -WarningVariable w
        $w | Should -BeNullOrEmpty
    }

    It 'replaces a value DotForge set earlier' {
        Set-DFEnv @script:Common -Value 'less'
        Set-DFEnv @script:Common -Value 'moar'
        $Env:DF_TEST_PAGER | Should -Be 'moar'
    }

    It 'does not warn again on a second registration in the same session' {
        $Env:DF_TEST_PAGER = 'less'
        Set-DFEnv @script:Common -Value 'moar' -ExplicitReason $script:Defaults -WarningAction SilentlyContinue
        Set-DFEnv @script:Common -Value 'moar' -ExplicitReason $script:Defaults -WarningVariable w
        $w | Should -BeNullOrEmpty
    }

    It 'treats a value the user changed after DotForge set it as outside DotForge' {
        Set-DFEnv @script:Common -Value 'moar'
        $Env:DF_TEST_PAGER = 'less'
        Set-DFEnv @script:Common -Value 'moar'
        $Env:DF_TEST_PAGER | Should -Be 'less'
    }

    It 'warns about one conflict once per session, even when the profile re-sets the variable' {
        $Env:DF_TEST_PAGER = 'less'
        Set-DFEnv @script:Common -Value 'moar' -ExplicitReason $script:Defaults -WarningAction SilentlyContinue
        $Env:DF_TEST_PAGER = 'less'   # `. $PROFILE` runs the profile's own assignment again
        Set-DFEnv @script:Common -Value 'moar' -ExplicitReason $script:Defaults -WarningVariable w
        $w | Should -BeNullOrEmpty
        $Env:DF_TEST_PAGER | Should -Be 'moar'
    }

    It 'still warns about a different conflict in the same session' {
        $Env:DF_TEST_PAGER = 'less'
        Set-DFEnv @script:Common -Value 'moar' -ExplicitReason $script:Defaults -WarningAction SilentlyContinue
        $Env:DF_TEST_PAGER = 'more'
        Set-DFEnv @script:Common -Value 'moar' -ExplicitReason $script:Defaults -WarningVariable w -WarningAction SilentlyContinue
        "$w" | Should -Match "was 'more'"
    }

    It 'remembers what DotForge wrote across a module reload' {
        Set-DFEnv @script:Common -Value 'less'
        . "$PSScriptRoot/../Private/Set-DFEnv.ps1"   # Import-Module -Force re-runs the file; the global survives
        Set-DFEnv @script:Common -Value 'moar'
        $Env:DF_TEST_PAGER | Should -Be 'moar'
    }
}
```

- [ ] **Step 3: Run it to see it fail**

Run: `pwsh -NoProfile -File build/Test-DFFull.ps1 -Path tests/Set-DFEnv.Tests.ps1`
Expected: FAIL, `The term 'Set-DFEnv' is not recognized`.

- [ ] **Step 4: Implement** — replace `Private/Set-DFEnv.ps1` with:

```powershell
#Requires -Version 7.2

function Get-DFEnvState {
    <#
    .SYNOPSIS
        Returns this session's record of the environment variables DotForge wrote, warned about and kept.
    .DESCRIPTION
        Kept in a session global, not a $script: variable, so Import-Module
        DotForge -Force doesn't forget which values DotForge itself wrote.
        Written maps variable -> the value DotForge last wrote: a current value
        that differs was set outside DotForge (profile, parent shell, system
        environment). Warned holds the conflicts already reported this session.
        Kept maps tool -> variable -> a note naming the outside value kept over
        what the tool wanted (Get-DFEnvKeptNote).
    .OUTPUTS
        System.Collections.Hashtable. @{ Written = @{}; Warned = @{}; Kept = @{} }.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    if ($global:DFEnvState -isnot [hashtable]) {
        $global:DFEnvState = @{ Written = @{}; Warned = @{}; Kept = @{} }
    }
    $global:DFEnvState
}

function Set-DFEnv {
    <#
    .SYNOPSIS
        Sets an environment variable for a tool, without overriding a value the user set outside DotForge.
    .DESCRIPTION
        The one precedence rule for every variable DotForge writes (xdg.vars,
        env, theme.env, role env, theme apply functions):
          1. The current value already equals -Value: nothing to do.
          2. The variable is unset, or still holds what DotForge last wrote: write it.
          3. It was set outside DotForge: keep it and note that for -Tool's
             status, unless -ExplicitReason says the user chose this value in
             DotForge's config (or by running a command). Then overwrite it and
             warn, once per session for each conflict, naming both settings.
        Writing or matching a variable drops the tool's kept note for it.
    .PARAMETER Name
        The variable.
    .PARAMETER Value
        The value to write (already expanded).
    .PARAMETER Tool
        The tool the value belongs to; a kept value is noted against it.
    .PARAMETER ExplicitReason
        Set when the user chose the value explicitly, e.g.
        "`$DFConfig.Defaults.pager is 'moar'; using moar". It completes the
        warning "<Name> was '<current>' but <reason>."
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][string]$Tool,
        [string]$ExplicitReason
    )
    $state = Get-DFEnvState
    $current = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if ($current -ceq $Value) {
        $state.Written[$Name] = $Value
        if ($state.Kept[$Tool]) { $state.Kept[$Tool].Remove($Name) }
        return
    }
    $setOutside = $current -and $state.Written[$Name] -cne $current
    if ($setOutside) {
        if (-not $ExplicitReason) {
            Write-Verbose "DotForge: keeping $Name='$current' (set outside DotForge) over $Tool's '$Value'."
            if (-not $state.Kept[$Tool]) { $state.Kept[$Tool] = [ordered]@{} }
            $state.Kept[$Tool][$Name] = "$Name kept as set outside DotForge ('$(Format-DFEnvValue $current)'); DotForge wanted '$(Format-DFEnvValue $Value)'"
            return
        }
        # Once per session: `. $PROFILE` re-runs the profile's own assignment,
        # and the same contradiction needs reporting only once.
        $conflict = "$Name|$current|$ExplicitReason"
        if (-not $state.Warned.ContainsKey($conflict)) {
            $state.Warned[$conflict] = $true
            Write-Warning ("DotForge: $Name was '$(Format-DFEnvValue $current)' but $ExplicitReason.`n" +
                '  Remove one of the two settings to silence this.')
        }
    }
    [Environment]::SetEnvironmentVariable($Name, $Value, 'Process')
    $state.Written[$Name] = $Value
    if ($state.Kept[$Tool]) { $state.Kept[$Tool].Remove($Name) }
}

function Get-DFEnvKeptNote {
    <#
    .SYNOPSIS
        Returns the notes for variables kept over what a tool wanted, in the order they were kept.
    .PARAMETER Tool
        The tool name.
    .OUTPUTS
        System.String[].
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$Tool)
    $notes = (Get-DFEnvState).Kept[$Tool]
    if ($notes) { [string[]]@($notes.Values) }
}

function Clear-DFEnvKeptNote {
    <#
    .SYNOPSIS
        Forgets a tool's kept-variable notes; each registration of the tool starts with this.
    .PARAMETER Tool
        The tool name.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Tool)
    (Get-DFEnvState).Kept.Remove($Tool)
}

function Format-DFEnvValue {
    <#
    .SYNOPSIS
        Shortens a variable's value for a message: over 60 characters keeps the first 57 and adds "...".
    .PARAMETER Value
        The value.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][AllowNull()][string]$Value)
    if ($Value.Length -gt 60) { $Value.Substring(0, 57) + '...' } else { $Value }
}
```

- [ ] **Step 5: Switch the callers**

In `Private/Register-DFToolSteps.ps1`, the role env loop (around line 286) becomes:

```powershell
        if ($block.env) {
            # An explicit Defaults choice overrides a value set outside DotForge; an auto-pick doesn't.
            $explicit = if ($won.Reason -eq 'Defaults') { "`$DFConfig.Defaults.$roleName is '$($won.Winner)'; using $($won.Winner)" }
            foreach ($var in $block.env.PSObject.Properties) {
                # ${DF_TOOL_EXE}: the winner's own executable path (see Resolve-DFToolExecutable).
                $value = [string]$var.Value
                if ($value.Contains('${DF_TOOL_EXE}')) { $value = $value.Replace('${DF_TOOL_EXE}', (ConvertTo-DFToolExePathToken -Tool $Tool)) }
                Set-DFEnv -Name $var.Name -Value (Expand-DFXdgPath $value) -Tool $Tool.name -ExplicitReason $explicit
            }
        }
```

and in its help (line 227) replace `(through Set-DFRoleEnv)` with `(through Set-DFEnv)`. In `Public/Get-DFRole.ps1:71` replace `(Get-DFRoleEnvState).Written` with `(Get-DFEnvState).Written`. In `tests/TestSupport.ps1`'s `Reset-DFTestSession`, add after `$script:DFSessionStarted = $false`:

```powershell
    $global:DFEnvState = $null
```

and add to its `.DESCRIPTION`: "Also forgets which environment values DotForge wrote (Get-DFEnvState)."

- [ ] **Step 6: Run the tests**

Run: `pwsh -NoProfile -File build/Test-DFFull.ps1 -Path tests/Set-DFEnv.Tests.ps1, tests/Get-DFRole.Tests.ps1, tests/Roles.Contract.Tests.ps1, tests/Register-DFTool.Tests.ps1, tests/Start-DFSession.Tests.ps1`
Expected: PASS. Then `rg -n "Set-DFRoleEnv|Get-DFRoleEnvState|DFRoleEnvState" --glob '!docs/superpowers/**' --glob '!CHANGELOG.md' --glob '!Bundle/**'` must print nothing (fix any doc or test reference it finds).

- [ ] **Step 7: Rebuild the bundle and commit**

```powershell
pwsh -NoProfile -File build/Build-DFCoreBundle.ps1
git add -A Private/Set-DFEnv.ps1 tests/Set-DFEnv.Tests.ps1 Private/Register-DFToolSteps.ps1 Public/Get-DFRole.ps1 tests/TestSupport.ps1 Bundle/DotForge.Core.ps1
git commit -m "refactor: Set-DFEnv, one precedence rule for env writes (from Set-DFRoleEnv)"
```

---

### Task 2: Status `Detail` is a list (Closes T-28)

**Files:**
- Modify: `Private/Invoke-DFSessionActivation.ps1` (`New-DFToolStatus` ~285-312, `Add-DFRoleOutcomeStatus` ~273, `Get-DFActivationBlocker` ~213-252, `Add-DFInstallHint` ~665-669)
- Create: `tests/New-DFToolStatus.Tests.ps1`
- Modify: `TODO.md` (delete T-28)

**Interfaces:**
- Produces: `New-DFToolStatus -Name -State [-RequestedBy] [-Detail <string[]>]` → `DotForge.ToolStatus` with `DetailItems` (`List[string]`) and read-only `Detail` (`string`, items joined by `; `; `''` when none); `Add-DFToolStatusDetail -Status <pscustomobject> -Text <string>`; `Get-DFActivationBlocker` returns `string[]` (empty when nothing blocks).

- [ ] **Step 1: Write the failing tests** — `tests/New-DFToolStatus.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
}

Describe 'New-DFToolStatus' {
    It 'joins detail lines with "; "' {
        (New-DFToolStatus -Name a -State Missing -Detail 'one', 'two').Detail | Should -Be 'one; two'
    }
    It 'has an empty Detail when given none' {
        (New-DFToolStatus -Name a -State Active).Detail | Should -Be ''
    }
    It 'skips empty lines' {
        (New-DFToolStatus -Name a -State Missing -Detail '', 'two').Detail | Should -Be 'two'
    }
    It 'appends a line with Add-DFToolStatusDetail' {
        $status = New-DFToolStatus -Name a -State Missing -Detail 'one'
        Add-DFToolStatusDetail -Status $status -Text 'more'
        $status.Detail | Should -Be 'one; more'
    }
    It 'shows Detail, not DetailItems, by default' {
        $status = New-DFToolStatus -Name a -State Active
        $status.PSStandardMembers.DefaultDisplayPropertySet.ReferencedPropertyNames |
            Should -Be @('Name', 'State', 'RequestedBy', 'Roles', 'Detail')
    }
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `pwsh -NoProfile -File build/Test-DFFull.ps1 -Path tests/New-DFToolStatus.Tests.ps1`
Expected: FAIL (`'one two'` vs `'one; two'`, and `Add-DFToolStatusDetail` not recognized).

- [ ] **Step 3: Implement**

Replace `New-DFToolStatus`'s `-Detail` parameter doc with "Lines explaining the state (failure message, what blocks it, values kept over the tool's own). Joined with '; ' in Detail." and its body with:

```powershell
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Active', 'Missing', 'Blocked', 'Failed', 'Excluded', 'Conflict')][string]$State,
        [string]$RequestedBy,
        [AllowEmptyCollection()][AllowEmptyString()][string[]]$Detail = @()
    )
    $status = [pscustomobject]@{
        PSTypeName  = 'DotForge.ToolStatus'
        Name        = $Name
        State       = $State
        RequestedBy = $RequestedBy
        Roles       = [string[]]@()
        DetailItems = [System.Collections.Generic.List[string]]::new()
    }
    foreach ($line in $Detail) { if ($line) { $status.DetailItems.Add($line) } }
    # One place renders the lines, so no producer joins strings itself (T-28).
    $status | Add-Member -MemberType ScriptProperty -Name Detail -Value { $this.DetailItems -join '; ' }
    $display = [System.Management.Automation.PSPropertySet]::new('DefaultDisplayPropertySet', [string[]]@('Name', 'State', 'RequestedBy', 'Roles', 'Detail'))
    $status | Add-Member -MemberType MemberSet -Name PSStandardMembers -Value ([System.Management.Automation.PSMemberInfo[]]@($display))
    $status
```

Add next to it:

```powershell
function Add-DFToolStatusDetail {
    <#
    .SYNOPSIS
        Appends a line to a tool status's Detail.
    .PARAMETER Status
        A DotForge.ToolStatus record.
    .PARAMETER Text
        The line; empty text is ignored.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Status, [AllowEmptyString()][string]$Text)
    if ($Text) { $Status.DetailItems.Add($Text) }
}
```

Replace the three string joins:

```powershell
# Add-DFRoleOutcomeStatus (was: $preferred.Detail = "$($preferred.Detail); using ...")
            Add-DFToolStatusDetail -Status $preferred -Text "using $($roleOutcome.Winner) instead ($($roleOutcome.Role))"

# Add-DFInstallHint (two places)
            Add-DFToolStatusDetail -Status $st -Text "Install-DFTool -Missing will install it $how"
            if ($st -and $st -in $todo) { Add-DFToolStatusDetail -Status $st -Text "can't install yet: $($g.Reason)" }
```

`Get-DFActivationBlocker`: change `[OutputType([string])]` to `[OutputType([string[]])]`, its `.OUTPUTS` to "System.String[]: the reasons, empty when nothing blocks it.", its synopsis to "...or returns nothing when nothing blocks it.", and replace the lines from `if (Test-DFToolAvailable -Executable $Tool.executable -Type $Tool.type) { return '' }` to the final `$detail`:

```powershell
    if (Test-DFToolAvailable -Executable $Tool.executable -Type $Tool.type) { return }
    $pathArgs = if ($ToolsPath) { @{ ToolsPath = $ToolsPath } } else { @{} }
    "'$($Tool.executable)' is not installed"
    if ($Requirements.RoleHint.ContainsKey($Tool.name)) {
        Get-DFRoleRequirementHint -Role $Requirements.RoleHint[$Tool.name] @pathArgs
    }
```

and its caller (around line 87): `$blocker = @(Get-DFActivationBlocker -Tool $tool -Requirements $requirements @pathArgs)`, keeping `if ($blocker)` and `-Detail $blocker`.

Also `rg -n "Get-DFActivationBlocker" tests` and update any assertion that compared its result to `''` (expect `@()`/`BeNullOrEmpty`).

- [ ] **Step 4: Run the tests**

Run: `pwsh -NoProfile -File build/Test-DFFull.ps1 -Path tests/New-DFToolStatus.Tests.ps1, tests/Start-DFSession.Tests.ps1, tests/Requires.Tests.ps1, tests/Activation.Ownership.Tests.ps1, tests/Register-DFTool.Tests.ps1, tests/Remove-DFTool.Tests.ps1`
Expected: PASS (existing `-Match` assertions read `Detail`, still a string).

- [ ] **Step 5: Close T-28 and commit**

Delete the `T-28` line from `TODO.md`.

```powershell
pwsh -NoProfile -File build/Build-DFCoreBundle.ps1
git add Private/Invoke-DFSessionActivation.ps1 tests/New-DFToolStatus.Tests.ps1 TODO.md Bundle/DotForge.Core.ps1
git commit -m "refactor: tool status Detail is a list rendered once

Closes T-28"
```

---

### Task 3: Route `xdg.vars`, `env`, fzf and vivid through `Set-DFEnv`

**Files:**
- Modify: `Private/Set-DFToolXdgConfig.ps1:9-12,29-48`
- Modify: `Private/Register-DFToolSteps.ps1:246-257` (`Invoke-DFToolRegistration` start and env loop)
- Modify: `Private/Invoke-DFSessionActivation.ps1:102` (Active status)
- Modify: `Tools/fzf.ps1` (`Invoke-DFApplyFzfTheme`, bottom call), `Tools/vivid.ps1` (`Invoke-DFApplyLSColorsTheme`, bottom call)
- Test: `tests/Register-DFTool.Tests.ps1`, `tests/fzf.Tests.ps1`, `tests/vivid.Tests.ps1`
- Docs: `docs/guide/configuration.md` (or the guide page that explains `env`; find it with `rg -n "env" docs/guide/writing-a-tool.md docs/guide/configuration.md`), `CHANGELOG.md`

**Interfaces:**
- Consumes: `Set-DFEnv`, `Get-DFEnvKeptNote`, `Clear-DFEnvKeptNote` (Task 1); `New-DFToolStatus -Detail <string[]>` (Task 2).
- Produces: `Invoke-DFApplyFzfTheme -Name <string> [-Implicit]`, `Invoke-DFApplyLSColorsTheme -Name <string> [-Force] [-Implicit]`.

- [ ] **Step 1: Write the failing tests** — add to `tests/Register-DFTool.Tests.ps1` inside `Describe 'Register-DFTool'` (its `BeforeEach` already creates `$script:TmpTools` and mocks the availability probes):

```powershell
    Context 'env precedence' {
        BeforeEach {
            Mock Get-Command { [PSCustomObject]@{ Path = 'C:\fake\envkeep.exe' } }
            @'
{
  "name": "envkeep",
  "executable": "envkeep.exe",
  "xdg": { "compliance": "partial", "method": "env", "vars": { "ENVKEEP_CONFIG": "${XDG_CONFIG_HOME}/envkeep" } },
  "env": { "ENVKEEP_OPTS": "--dotforge" }
}
'@ | Set-Content (Join-Path $script:TmpTools 'envkeep.json')
        }
        AfterEach { Remove-Item Env:ENVKEEP_OPTS, Env:ENVKEEP_CONFIG -ErrorAction Ignore }

        It 'keeps an env value set outside DotForge, and says so in the status' {
            $Env:ENVKEEP_OPTS = '--mine'
            Register-DFTool -Name 'envkeep' -ToolsPath $script:TmpTools
            $Env:ENVKEEP_OPTS | Should -Be '--mine'
            (Get-DFToolStatus -Name 'envkeep').Detail | Should -Match "ENVKEEP_OPTS kept as set outside DotForge \('--mine'\); DotForge wanted '--dotforge'"
        }

        It 'keeps an xdg.vars value set outside DotForge' {
            $Env:ENVKEEP_CONFIG = 'C:\mine'
            Register-DFTool -Name 'envkeep' -ToolsPath $script:TmpTools
            $Env:ENVKEEP_CONFIG | Should -Be 'C:\mine'
        }

        It 'rewrites a value DotForge wrote on re-registration' {
            Register-DFTool -Name 'envkeep' -ToolsPath $script:TmpTools
            Set-Content (Join-Path $script:TmpTools 'envkeep.json') ((Get-Content (Join-Path $script:TmpTools 'envkeep.json') -Raw).Replace('--dotforge', '--changed'))
            Reset-DFTestSession
            $global:DFEnvState = @{ Written = @{ ENVKEEP_OPTS = '--dotforge' }; Warned = @{}; Kept = @{} }   # the ledger survives a session reset
            Register-DFTool -Name 'envkeep' -ToolsPath $script:TmpTools
            $Env:ENVKEEP_OPTS | Should -Be '--changed'
        }

        It 'has no kept note once the value is DotForge''s again' {
            $Env:ENVKEEP_OPTS = '--mine'
            Register-DFTool -Name 'envkeep' -ToolsPath $script:TmpTools
            Remove-Item Env:ENVKEEP_OPTS
            Reset-DFTestSession
            Register-DFTool -Name 'envkeep' -ToolsPath $script:TmpTools
            (Get-DFToolStatus -Name 'envkeep').Detail | Should -Be ''
        }
    }
```

Add to `tests/fzf.Tests.ps1` (in the Describe that dot-sources the companion; reuse its setup that saves/clears `FZF_DEFAULT_OPTS`):

```powershell
    It 'keeps an FZF_DEFAULT_OPTS set outside DotForge when the theme is not explicit' {
        $Env:FZF_DEFAULT_OPTS = '--mine'
        Invoke-DFApplyFzfTheme -Name catppuccin-mocha -Implicit
        $Env:FZF_DEFAULT_OPTS | Should -Be '--mine'
    }

    It 'appends the theme to an outside FZF_DEFAULT_OPTS when called by hand' {
        $Env:FZF_DEFAULT_OPTS = '--mine'
        Invoke-DFApplyFzfTheme -Name catppuccin-mocha -WarningAction SilentlyContinue
        $Env:FZF_DEFAULT_OPTS | Should -Match '^--mine\r?\n--color=.*bg\+:#313244'
    }
```

Add to `tests/vivid.Tests.ps1` (in its registration Describe; it already clears `LS_COLORS` in `AfterEach`):

```powershell
    It 'keeps an LS_COLORS set outside DotForge when VividTheme is not set' {
        [System.Environment]::SetEnvironmentVariable('LS_COLORS', 'di=01;34', 'Process')
        Register-DFTool -Name 'vivid' -ToolsPath $script:RealTools
        $Env:LS_COLORS | Should -Be 'di=01;34'
    }
```

(Use the same `-ToolsPath` variable the surrounding vivid tests use.)

- [ ] **Step 2: Run them to see them fail**

Run: `pwsh -NoProfile -File build/Test-DFFull.ps1 -Path tests/Register-DFTool.Tests.ps1, tests/fzf.Tests.ps1, tests/vivid.Tests.ps1`
Expected: FAIL — env overwritten with `--dotforge`; `-Implicit` not a parameter.

- [ ] **Step 3: Implement the core changes**

`Private/Set-DFToolXdgConfig.ps1`, the `'env'` branch body becomes:

```powershell
        'env' {
            # A tool's vars are defaults: a variable the user set outside DotForge
            # (profile, system) is kept, one DotForge wrote is updated (Set-DFEnv).
            foreach ($var in @($xdg.vars?.PSObject.Properties)) {
                if ($var) { Set-DFEnv -Name $var.Name -Value (Expand-DFXdgPath $var.Value) -Tool $Tool.name }
            }
            $xdg.dirs | Where-Object { $_ } |
                ForEach-Object { New-DFDirectory (Expand-DFXdgPath $_) }
        }
```

and its `.DESCRIPTION` first sentence becomes "'env' sets env vars from xdg.vars through Set-DFEnv (a value set outside DotForge is kept) and creates xdg.dirs;".

`Private/Register-DFToolSteps.ps1`, in `Invoke-DFToolRegistration` right after `$RoleDb = $Context.RoleDb`:

```powershell
    # Notes about values kept over this tool's own are rebuilt by every registration.
    Clear-DFEnvKeptNote -Tool $Tool.name
```

and the env loop:

```powershell
    # Non-XDG settings apply regardless of xdg.method. Expand-DFXdgPath expands
    # ${XDG_*} and passes flag strings through byte-for-byte.
    if ($Tool.env) {
        foreach ($var in $Tool.env.PSObject.Properties) {
            Set-DFEnv -Name $var.Name -Value (Expand-DFXdgPath $var.Value) -Tool $Tool.name
        }
    }
```

`Private/Invoke-DFSessionActivation.ps1:102`:

```powershell
                $status[$tool.name] = New-DFToolStatus -Name $tool.name -State Active -RequestedBy $requestedBy[$tool.name] -Detail @(Get-DFEnvKeptNote -Tool $tool.name)
```

- [ ] **Step 4: Implement the fzf and vivid changes**

`Tools/fzf.ps1`: after `$_resolveThemeFile = ${function:Resolve-DFThemeFile}` add `$_setEnv = ${function:Set-DFEnv}`. In `Invoke-DFApplyFzfTheme`'s help add:

```
    .PARAMETER Implicit
        Used by the companion at startup when the theme came from $DFConfig.Theme
        or the default: an FZF_DEFAULT_OPTS you set outside DotForge is then kept
        as is. Without it (calling the function yourself, or an explicit
        FzfTheme), the colors are appended to it.
```

change its `param` to `param([Parameter(Mandatory)][string]$Name, [switch]$Implicit)`, and replace its last two lines (`$existing = ...` / `$Env:FZF_DEFAULT_OPTS = ...`) with:

```powershell
    $existing = [string]$Env:FZF_DEFAULT_OPTS
    $value = if ($existing) { "$existing`n$colorArg" } else { $colorArg }
    $explicit = if (-not $Implicit) { "fzf theme '$Name' was applied" }
    & $_setEnv -Name 'FZF_DEFAULT_OPTS' -Value $value -Tool 'fzf' -ExplicitReason $explicit
```

and the bottom call becomes:

```powershell
Invoke-DFApplyFzfTheme -Name $_themeSetting -Implicit:(-not (Get-DFConfig FzfTheme))
```

`Tools/vivid.ps1`: after `$_fingerprintCache = ...` add `$_setEnv = ${function:Set-DFEnv}`. In `Invoke-DFApplyLSColorsTheme` add the help entry

```
    .PARAMETER Implicit
        Used by the companion at startup when the theme came from $DFConfig.Theme
        or the default: an LS_COLORS you set outside DotForge is then kept.
```

the parameter `[switch]$Implicit`, and replace `[System.Environment]::SetEnvironmentVariable('LS_COLORS', $value, 'Process')` with:

```powershell
    $explicit = if (-not $Implicit) { "vivid theme '$Name' was applied" }
    & $_setEnv -Name 'LS_COLORS' -Value $value -Tool 'vivid' -ExplicitReason $explicit
```

The bottom call becomes `Invoke-DFApplyLSColorsTheme -Name $_theme -Implicit:(-not (Get-DFConfig VividTheme))`.

- [ ] **Step 5: Run the tests**

Run: `pwsh -NoProfile -File build/Test-DFFull.ps1 -Path tests/Register-DFTool.Tests.ps1, tests/fzf.Tests.ps1, tests/vivid.Tests.ps1, tests/Set-DFToolXdgConfig.Tests.ps1, tests/Start-DFSession.Tests.ps1, tests/bat.Tests.ps1, tests/mdcat.Tests.ps1`
Expected: PASS. If a pre-existing test set a variable before registering and expected DotForge's value, it encoded the old always-overwrite rule: change it to clear the variable first, and keep a separate assertion for the new keep rule only where Step 1 doesn't already cover it.

- [ ] **Step 6: Docs**

In the guide page that documents `env`/`xdg.vars` for users, add a short section:

```markdown
### Your own environment values win

If you set one of the variables a tool configures (in your profile, or system-wide) before DotForge
loads, DotForge keeps your value and `Get-DFToolStatus <tool>` says so, e.g.
`BAT_THEME kept as set outside DotForge ('Dracula'); DotForge wanted 'Catppuccin Mocha'`.
A choice you make in DotForge's own config overrides it (a `Defaults` role pick, a per-tool theme key
such as `BatTheme`, or a command like `Invoke-DFApplyFzfTheme`), with a one-time warning naming both.
```

In `CHANGELOG.md` under `## [Unreleased]` → `### Changed` add:

```markdown
- **Your own environment values win.** A variable a tool's `env` or `xdg.vars` sets (`LESS`, `FZF_*`,
  `BAT_THEME`, `LS_COLORS`, …) that you already set outside DotForge is now kept, and
  `Get-DFToolStatus` says so; before, DotForge overwrote most of them. A value DotForge wrote itself is
  still updated when a tool re-registers.
```

- [ ] **Step 7: Rebuild and commit**

```powershell
pwsh -NoProfile -File build/Build-DFCoreBundle.ps1
pwsh -NoProfile -File build/Build-DFReferenceDocs.ps1
git add Private/Set-DFToolXdgConfig.ps1 Private/Register-DFToolSteps.ps1 Private/Invoke-DFSessionActivation.ps1 Tools/fzf.ps1 Tools/vivid.ps1 tests/Register-DFTool.Tests.ps1 tests/fzf.Tests.ps1 tests/vivid.Tests.ps1 docs CHANGELOG.md Bundle/DotForge.Core.ps1
git commit -m "feat: env values set outside DotForge are kept and reported"
```

---

## Phase 2 — Declarative theme

### Task 4: `theme` schema and normalization

**Files:**
- Modify: `Shared/Import-DFToolDb.ps1` (add `ConvertTo-DFThemeBlock`; `ConvertTo-DFToolRecord` field list and help)
- Modify: `Shared/Test-DFToolSchema.ps1` (add `Get-DFThemeSchemaError`; call it in `Test-DFToolSchema`; `$known` gains `theme`)
- Test: `tests/ConvertTo-DFToolRecord.Tests.ps1`, `tests/Test-DFToolSchema.Tests.ps1`

**Interfaces:**
- Produces: record field `theme` = `$null` or `[pscustomobject]@{ key; default; map; files; valid ([string[]]); fallback; env; command }`; `map` falls back to the record's legacy top-level `themeMap`.

- [ ] **Step 1: Write the failing tests**

`tests/ConvertTo-DFToolRecord.Tests.ps1`: add `'theme'` to the list of fields asserted present (line 16 loop) and to the list at line 132. Add:

```powershell
    Context 'theme' {
        It 'is $null when absent' {
            (ConvertTo-DFToolRecord ([pscustomobject]@{ name = 'x'; executable = 'x.exe' })).theme | Should -BeNullOrEmpty
        }
        It 'fills every field' {
            $theme = (ConvertTo-DFToolRecord ([pscustomobject]@{ name = 'x'; executable = 'x.exe'; theme = [pscustomobject]@{ key = 'XTheme' } })).theme
            $theme.key | Should -Be 'XTheme'
            foreach ($f in 'default', 'map', 'files', 'fallback', 'env', 'command') { $theme.PSObject.Properties[$f] | Should -Not -BeNullOrEmpty }
            , $theme.valid | Should -BeOfType [string[]]
        }
        It 'takes map from the legacy top-level themeMap when theme.map is absent' {
            $legacy = [pscustomobject]@{ 'catppuccin-mocha' = 'Catppuccin Mocha' }
            $theme = (ConvertTo-DFToolRecord ([pscustomobject]@{ name = 'x'; executable = 'x.exe'; themeMap = $legacy; theme = [pscustomobject]@{ key = 'XTheme' } })).theme
            $theme.map.'catppuccin-mocha' | Should -Be 'Catppuccin Mocha'
        }
    }
```

`tests/Test-DFToolSchema.Tests.ps1` (it has a `Get-SchemaErrors` helper taking a hashtable of extra fields):

```powershell
    Context 'theme' {
        It 'accepts a full theme block' {
            Get-SchemaErrors @{ theme = [pscustomobject]@{ key = 'XTheme'; default = 'a'; map = [pscustomobject]@{ a = 'A' }; files = 'x'
                valid = @('A'); fallback = 'A'; env = [pscustomobject]@{ X_THEME = '{theme}' }; command = 'Select-XTheme' } } | Should -BeNullOrEmpty
        }
        It 'requires key to name a *Theme config key' {
            Get-SchemaErrors @{ theme = [pscustomobject]@{ key = 'x' } } | Should -Match 'theme.key'
        }
        It 'rejects a non-object theme' {
            Get-SchemaErrors @{ theme = 'dracula' } | Should -Match 'theme must be an object'
        }
        It 'requires valid to be strings' {
            Get-SchemaErrors @{ theme = [pscustomobject]@{ key = 'XTheme'; valid = @(1) } } | Should -Match 'theme.valid'
        }
        It 'requires env values to be strings' {
            Get-SchemaErrors @{ theme = [pscustomobject]@{ key = 'XTheme'; env = [pscustomobject]@{ X = 1 } } } | Should -Match 'theme.env.X'
        }
        It 'warns about a misspelled theme field' {
            (Test-DFToolSchema -Tool ([pscustomobject]@{ name = 'x'; executable = 'x.exe'; theme = [pscustomobject]@{ key = 'XTheme'; defualt = 'a' } })).Warnings |
                Should -Match "theme.defualt.*theme.default"
        }
    }
```

- [ ] **Step 2: Run to see them fail**

Run: `pwsh -NoProfile -File build/Test-DFFull.ps1 -Path tests/ConvertTo-DFToolRecord.Tests.ps1, tests/Test-DFToolSchema.Tests.ps1`
Expected: FAIL.

- [ ] **Step 3: Implement normalization** — in `Shared/Import-DFToolDb.ps1`, before `ConvertTo-DFToolRecord`:

```powershell
function ConvertTo-DFThemeBlock {
    <#
    .SYNOPSIS
        Normalizes a tool's theme block: every field present, valid a string array, map defaulting to the legacy top-level themeMap.
    .PARAMETER RawTheme
        The parsed theme object, or $null.
    .PARAMETER LegacyMap
        The tool's top-level themeMap, or $null.
    .OUTPUTS
        PSCustomObject, or $null when there is no theme block.
    #>
    [CmdletBinding()]
    param([AllowNull()][object]$RawTheme, [AllowNull()][object]$LegacyMap)
    if ($null -eq $RawTheme) { return $null }
    [pscustomobject]@{
        key      = Get-DFToolRecordProperty $RawTheme 'key' $null
        default  = Get-DFToolRecordProperty $RawTheme 'default' $null
        map      = Get-DFToolRecordProperty $RawTheme 'map' $LegacyMap
        files    = Get-DFToolRecordProperty $RawTheme 'files' $null
        valid    = [string[]]@(Get-DFToolRecordProperty $RawTheme 'valid' @())
        fallback = Get-DFToolRecordProperty $RawTheme 'fallback' $null
        env      = Get-DFToolRecordProperty $RawTheme 'env' $null
        command  = Get-DFToolRecordProperty $RawTheme 'command' $null
    }
}
```

In `ConvertTo-DFToolRecord` add after the `themeMap` line:

```powershell
        theme             = ConvertTo-DFThemeBlock (Get-DFToolRecordProperty $Tool 'theme' $null) (Get-DFToolRecordProperty $Tool 'themeMap' $null)
```

and in its `.DESCRIPTION` add `theme` to the `$null` defaults list plus: "theme, when present, has key, default, map (falling back to the legacy top-level themeMap), files, valid (string[]), fallback, env and command."

- [ ] **Step 4: Implement validation** — in `Shared/Test-DFToolSchema.ps1` add:

```powershell
function Get-DFThemeSchemaError ([PSCustomObject]$Tool) {
    <#
    .SYNOPSIS
        Schema errors in theme: key names a *Theme config key; default, files, fallback and command are strings; valid is strings; map and env map names to strings.
    #>
    $theme = Get-DFSchemaProperty $Tool 'theme'
    if ($null -eq $theme) { return }
    if ($theme -isnot [pscustomobject]) { return 'theme must be an object' }
    $key = Get-DFSchemaProperty $theme 'key'
    if ($key -isnot [string] -or $key -cnotmatch '^[A-Z][A-Za-z0-9]*Theme$') { "theme.key must name the tool's config key, e.g. 'BatTheme'" }
    foreach ($field in 'default', 'files', 'fallback', 'command') {
        $v = Get-DFSchemaProperty $theme $field
        if ($null -ne $v -and ($v -isnot [string] -or -not $v)) { "theme.$field must be a non-empty string" }
    }
    $valid = $theme.PSObject.Properties['valid']?.Value   # read directly: a helper would unroll ["x"]
    if ($null -ne $valid -and ($valid -isnot [array] -or @($valid | Where-Object { $_ -isnot [string] }).Count)) { 'theme.valid must be an array of strings' }
    $v = Get-DFSchemaProperty $theme 'map'; if ($null -ne $v) { Get-DFMapSchemaError $v 'theme.map' -StringsOnly }
    $v = Get-DFSchemaProperty $theme 'env'; if ($null -ne $v) { Get-DFMapSchemaError $v 'theme.env' -StringsOnly }
}
```

Call it in `Test-DFToolSchema`'s `$errs` list after `Get-DFAliasAndMapSchemaError $Tool`. In `Get-DFFieldTypoWarning`: add `'theme'` to `$known['']`, add `theme = 'key', 'default', 'map', 'files', 'valid', 'fallback', 'env', 'command'`, and after the `$bannerObj` section:

```powershell
    $themeObj = Get-DFSchemaProperty $Tool 'theme'
    if ($themeObj -is [pscustomobject]) { $sections.Add(@('theme', $themeObj, 'theme.')) }
```

Update `Test-DFToolSchema`'s `.DESCRIPTION` shape list to include `theme`.

- [ ] **Step 5: Run the tests**

Run: `pwsh -NoProfile -File build/Test-DFFull.ps1 -Path tests/ConvertTo-DFToolRecord.Tests.ps1, tests/Test-DFToolSchema.Tests.ps1, tests/ToolRegistry.Tests.ps1`
Expected: the first two PASS; `ToolRegistry` fails as stale — run `pwsh -NoProfile -File build/Build-DFToolRegistry.ps1` and rerun it to PASS.

- [ ] **Step 6: Commit**

```powershell
pwsh -NoProfile -File build/Build-DFCoreBundle.ps1
git add Shared tests/ConvertTo-DFToolRecord.Tests.ps1 tests/Test-DFToolSchema.Tests.ps1 data/tool-registry.json Bundle/DotForge.Core.ps1
git commit -m "feat: theme block in the tool schema"
```

---

### Task 5: Resolve and apply a tool's theme during registration

**Files:**
- Create: `Private/Get-DFToolTheme.ps1`
- Modify: `Private/Register-DFToolSteps.ps1` (`Invoke-DFToolRegistration`: after the env loop)
- Modify: `tests/TestSupport.ps1` (`Reset-DFTestSession`; new `Get-DFTestToolRecord`)
- Create: `tests/Get-DFToolTheme.Tests.ps1`

**Interfaces:**
- Consumes: record `theme` (Task 4); `Set-DFEnv` (Task 1); existing `Get-DFConfig`, `Get-DFConfiguredTheme`, `Resolve-DFThemeName`, `Resolve-DFThemeFile`, `Get-DFToolFolder`, `Expand-DFXdgPath`.
- Produces:
  - `Resolve-DFToolTheme -Tool <record> [-Name <string>]` → `$null` (no theme block) or `[pscustomobject]@{ Name; Native; Value; Explicit }` (fresh resolution; warns on rejection).
  - `Get-DFToolTheme -Tool <record>` → same object, cached per session in `$script:DFSessionThemes[<tool>]`.
  - `Get-DFSessionThemeValue -Name <tool>` → `string` or `$null` (the session's `Value`).
  - `Set-DFToolThemeEnv -Tool <record> -Theme <object> [-ExplicitReason <string>]` → nothing.
  - Test helper `Get-DFTestToolRecord -Name <tool>` → normalized record of `Tools/<name>.json` with `folder` set.

- [ ] **Step 1: Add the test helper** — in `tests/TestSupport.ps1`, add `$script:DFSessionThemes = @{}` to `Reset-DFTestSession` (and "and the resolved themes" to its description), and:

```powershell
function Get-DFTestToolRecord {
    <#
    .SYNOPSIS
        Loads Tools/<Name>.json as a normalized tool record, with its folder set to Tools/.
    .PARAMETER Name
        The tool name.
    .OUTPUTS
        PSCustomObject. The record ConvertTo-DFToolRecord returns.
    #>
    param([Parameter(Mandatory)][string]$Name)
    $toolsDir = Join-Path $PSScriptRoot '..' 'Tools'
    $record = ConvertTo-DFToolRecord (Get-Content (Join-Path $toolsDir "$Name.json") -Raw | ConvertFrom-Json)
    $record.folder = (Resolve-Path $toolsDir).Path
    $record
}
```

- [ ] **Step 2: Write the failing tests** — `tests/Get-DFToolTheme.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    function New-ThemedTool([hashtable]$Theme, [string]$Folder) {
        $record = ConvertTo-DFToolRecord ([pscustomobject]@{ name = 'themed'; executable = 'themed.exe'; theme = [pscustomobject]$Theme })
        $record.folder = $Folder
        $record
    }
}

Describe 'Resolve-DFToolTheme' {
    BeforeEach { Reset-DFTestSession; Set-DFTestXdg; Set-DFTestConfig $null }
    AfterEach { Set-DFTestConfig $null; Restore-DFTestXdg }

    It 'returns $null for a tool without a theme block' {
        $plain = ConvertTo-DFToolRecord ([pscustomobject]@{ name = 'plain'; executable = 'plain.exe' })
        Resolve-DFToolTheme -Tool $plain | Should -BeNullOrEmpty
    }
    It 'uses the per-tool key first, and marks it explicit' {
        Set-DFTestConfig @{ ThemedTheme = 'nord'; Theme = 'dracula' }
        $t = Resolve-DFToolTheme -Tool (New-ThemedTool @{ key = 'ThemedTheme'; default = 'auto' })
        $t.Name | Should -Be 'nord'; $t.Explicit | Should -BeTrue
    }
    It 'then the shared Theme, not explicit' {
        Set-DFTestConfig @{ Theme = 'dracula' }
        $t = Resolve-DFToolTheme -Tool (New-ThemedTool @{ key = 'ThemedTheme'; default = 'auto' })
        $t.Name | Should -Be 'dracula'; $t.Explicit | Should -BeFalse
    }
    It 'then the default' {
        (Resolve-DFToolTheme -Tool (New-ThemedTool @{ key = 'ThemedTheme'; default = 'auto' })).Value | Should -Be 'auto'
    }
    It 'treats -Name as explicit' {
        $t = Resolve-DFToolTheme -Tool (New-ThemedTool @{ key = 'ThemedTheme'; default = 'auto' }) -Name 'nord'
        $t.Value | Should -Be 'nord'; $t.Explicit | Should -BeTrue
    }
    It 'translates through map' {
        $t = Resolve-DFToolTheme -Tool (New-ThemedTool @{ key = 'ThemedTheme'; default = 'catppuccin-mocha'; map = [pscustomobject]@{ 'catppuccin-mocha' = 'Catppuccin Mocha' } })
        $t.Native | Should -Be 'Catppuccin Mocha'; $t.Value | Should -Be 'Catppuccin Mocha'
    }
    It 'falls back with a warning when valid rejects the name' {
        $tool = New-ThemedTool @{ key = 'ThemedTheme'; default = 'bogus'; valid = @('auto', 'dark'); fallback = 'auto' }
        $t = Resolve-DFToolTheme -Tool $tool -WarningVariable w -WarningAction SilentlyContinue
        $t.Value | Should -Be 'auto'
        "$w" | Should -Match "themed theme 'bogus' not recognized — falling back to 'auto'"
    }
    It 'resolves files from the bundled folder' {
        New-Item -ItemType Directory -Path (Join-Path $TestDrive 'tools' 'themed') -Force | Out-Null
        Set-Content (Join-Path $TestDrive 'tools' 'themed' 'nord.json') '{}'
        $t = Resolve-DFToolTheme -Tool (New-ThemedTool @{ key = 'ThemedTheme'; default = 'nord'; files = 'themed' } (Join-Path $TestDrive 'tools'))
        $t.Value | Should -Be (Join-Path $TestDrive 'tools' 'themed' 'nord.json')
    }
    It 'prefers the user''s themes folder over the bundled one' {
        New-Item -ItemType Directory -Path (Join-Path $Env:XDG_CONFIG_HOME 'themed' 'themes') -Force | Out-Null
        Set-Content (Join-Path $Env:XDG_CONFIG_HOME 'themed' 'themes' 'nord.json') '{}'
        $t = Resolve-DFToolTheme -Tool (New-ThemedTool @{ key = 'ThemedTheme'; default = 'nord'; files = 'themed' } (Join-Path $TestDrive 'tools'))
        $t.Value | Should -Be (Join-Path $Env:XDG_CONFIG_HOME 'themed' 'themes' 'nord.json')
    }
    It 'uses a valid built-in name when no file matches' {
        $t = Resolve-DFToolTheme -Tool (New-ThemedTool @{ key = 'ThemedTheme'; default = 'dark'; files = 'themed'; valid = @('dark'); fallback = 'auto' } (Join-Path $TestDrive 'tools'))
        $t.Value | Should -Be 'dark'
    }
}

Describe 'Set-DFToolThemeEnv' {
    BeforeEach { Reset-DFTestSession; Remove-Item Env:THEMED_THEME -ErrorAction Ignore }
    AfterEach { Remove-Item Env:THEMED_THEME -ErrorAction Ignore }

    It 'writes each env template with {theme} replaced' {
        $tool = New-ThemedTool @{ key = 'ThemedTheme'; default = 'nord'; env = [pscustomobject]@{ THEMED_THEME = '+{theme}' } }
        Set-DFToolThemeEnv -Tool $tool -Theme (Resolve-DFToolTheme -Tool $tool)
        $Env:THEMED_THEME | Should -Be '+nord'
    }
    It 'writes nothing when the theme resolves to no value' {
        $Env:THEMED_THEME = 'keep'
        $tool = New-ThemedTool @{ key = 'ThemedTheme'; default = 'bogus'; valid = @('a'); env = [pscustomobject]@{ THEMED_THEME = '{theme}' } }
        Set-DFToolThemeEnv -Tool $tool -Theme (Resolve-DFToolTheme -Tool $tool 3>$null)
        $Env:THEMED_THEME | Should -Be 'keep'
    }
    It 'keeps an outside value for an implicit theme' {
        $Env:THEMED_THEME = 'mine'
        $tool = New-ThemedTool @{ key = 'ThemedTheme'; default = 'nord'; env = [pscustomobject]@{ THEMED_THEME = '{theme}' } }
        Set-DFToolThemeEnv -Tool $tool -Theme (Resolve-DFToolTheme -Tool $tool)
        $Env:THEMED_THEME | Should -Be 'mine'
    }
    It 'overrides an outside value for an explicit theme, naming the config key' {
        $Env:THEMED_THEME = 'mine'
        Set-DFTestConfig @{ ThemedTheme = 'nord' }
        $tool = New-ThemedTool @{ key = 'ThemedTheme'; env = [pscustomobject]@{ THEMED_THEME = '{theme}' } }
        Set-DFToolThemeEnv -Tool $tool -Theme (Resolve-DFToolTheme -Tool $tool) -WarningVariable w -WarningAction SilentlyContinue
        $Env:THEMED_THEME | Should -Be 'nord'
        "$w" | Should -Match "THEMED_THEME was 'mine' but \`$DFConfig.ThemedTheme is 'nord'"
        Set-DFTestConfig $null
    }
}

Describe 'theme during registration' {
    BeforeEach {
        Reset-DFTestSession; Set-DFTestXdg; Set-DFTestConfig $null
        Mock Test-DFExecutableOnPath { $true }
        $script:DFToolAvailability = @{}
        $script:Tools = Join-Path $TestDrive 'regtools'
        New-Item -ItemType Directory -Path $script:Tools -Force | Out-Null
        '{ "name": "themed", "executable": "themed.exe", "theme": { "key": "ThemedTheme", "default": "nord", "env": { "THEMED_THEME": "{theme}" } } }' |
            Set-Content (Join-Path $script:Tools 'themed.json')
        Remove-Item Env:THEMED_THEME -ErrorAction Ignore
    }
    AfterEach { Remove-Item Env:THEMED_THEME -ErrorAction Ignore; Set-DFTestConfig $null; Restore-DFTestXdg }

    It 'applies theme.env and caches the theme for the session' {
        Register-DFTool -Name 'themed' -ToolsPath $script:Tools
        $Env:THEMED_THEME | Should -Be 'nord'
        Get-DFSessionThemeValue -Name 'themed' | Should -Be 'nord'
    }
    It 're-resolves on re-registration' {
        Register-DFTool -Name 'themed' -ToolsPath $script:Tools
        Set-DFTestConfig @{ ThemedTheme = 'dracula' }
        Reset-DFTestSession
        $global:DFEnvState = @{ Written = @{ THEMED_THEME = 'nord' }; Warned = @{}; Kept = @{} }
        Register-DFTool -Name 'themed' -ToolsPath $script:Tools
        $Env:THEMED_THEME | Should -Be 'dracula'
    }
}
```

- [ ] **Step 3: Run to see them fail**

Run: `pwsh -NoProfile -File build/Test-DFFull.ps1 -Path tests/Get-DFToolTheme.Tests.ps1`
Expected: FAIL, `Resolve-DFToolTheme` not recognized.

- [ ] **Step 4: Implement** — `Private/Get-DFToolTheme.ps1`:

```powershell
#Requires -Version 7.2

# Each tool's resolved theme this session: tool name -> Resolve-DFToolTheme result.
# Set by registration and Set-DFToolTheme; read by wrappers at call time.

function Resolve-DFToolTheme {
    <#
    .SYNOPSIS
        Resolves a tool's theme from its theme block: the name, its native spelling, and the value the tool is given.
    .DESCRIPTION
        Name: -Name, else the tool's per-tool key (theme.key), else the shared
        Theme key, else theme.default (Get-DFConfiguredTheme). Explicit is true
        for -Name and the per-tool key: the user chose this theme for this tool.
        Native: Name translated through theme.map (Resolve-DFThemeName).
        Value: with theme.files, a theme file found by Resolve-DFThemeFile (an
        absolute path, then <XDG config>\<files>\themes, then <tool folder>\<files>);
        otherwise, or when no file matches, Native when theme.valid is empty or
        lists it; otherwise theme.fallback with a warning ($null without one).
    .PARAMETER Tool
        A normalized tool record.
    .PARAMETER Name
        A theme to use instead of the configured one.
    .OUTPUTS
        PSCustomObject: Name, Native, Value, Explicit. $null when the tool has no theme block.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][pscustomobject]$Tool, [string]$Name)
    $theme = $Tool.theme
    if (-not $theme) { return $null }
    $explicit = [bool]$Name
    if (-not $Name) {
        $explicit = [bool](Get-DFConfig $theme.key)
        $Name = Get-DFConfiguredTheme -ToolKey $theme.key -Default $theme.default
    }
    if (-not $Name) { return [pscustomobject]@{ Name = $null; Native = $null; Value = $null; Explicit = $false } }
    $native = Resolve-DFThemeName -Name $Name -ThemeMap $theme.map
    $value = $null
    if ($theme.files) {
        $bundled = Join-Path (Get-DFToolFolder -Tool $Tool -Default (Join-Path $PSScriptRoot '..' 'Tools')) $theme.files
        $value = Resolve-DFThemeFile -Tool $theme.files -Name $native -BundledDir $bundled
    }
    if (-not $value) {
        if (-not $theme.valid -or $native -in $theme.valid) {
            $value = $native
        } else {
            $value = $theme.fallback
            $instead = if ($value) { "falling back to '$value'" } else { 'leaving it unset' }
            Write-Warning "DotForge: $($Tool.name) theme '$native' not recognized — $instead"
        }
    }
    [pscustomobject]@{ Name = $Name; Native = $native; Value = $value; Explicit = $explicit }
}

function Get-DFToolTheme {
    <#
    .SYNOPSIS
        Returns a tool's theme for this session, resolving it once.
    .DESCRIPTION
        Companions call this instead of resolving the theme themselves; the
        first call (registration) resolves and caches it, later calls reuse it
        (so a rejected name warns once). Set-DFToolTheme replaces it.
    .PARAMETER Tool
        A normalized tool record.
    .OUTPUTS
        PSCustomObject: Name, Native, Value, Explicit; $null for a tool without a theme block.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][pscustomobject]$Tool)
    if (-not $Tool.theme) { return $null }
    if ($script:DFSessionThemes -isnot [hashtable]) { $script:DFSessionThemes = @{} }
    if (-not $script:DFSessionThemes.ContainsKey($Tool.name)) {
        $script:DFSessionThemes[$Tool.name] = Resolve-DFToolTheme -Tool $Tool
    }
    $script:DFSessionThemes[$Tool.name]
}

function Get-DFSessionThemeValue {
    <#
    .SYNOPSIS
        Returns the value of a tool's theme this session, or $null; wrappers call it on every run.
    .PARAMETER Name
        The tool name.
    .OUTPUTS
        System.String, or $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name)
    if ($script:DFSessionThemes -is [hashtable] -and $script:DFSessionThemes.ContainsKey($Name)) {
        $script:DFSessionThemes[$Name].Value
    }
}

function Set-DFToolThemeEnv {
    <#
    .SYNOPSIS
        Writes a tool's theme.env variables for a resolved theme, through Set-DFEnv.
    .DESCRIPTION
        Each theme.env template has {theme} replaced by the theme's Value, then
        ${XDG_*} expanded. Nothing is written when the theme has no Value. An
        explicit theme (the per-tool key) overrides a value set outside
        DotForge, naming the key; -ExplicitReason gives another reason.
    .PARAMETER Tool
        A normalized tool record.
    .PARAMETER Theme
        A Resolve-DFToolTheme result.
    .PARAMETER ExplicitReason
        Why the value overrides one set outside DotForge (Set-DFToolTheme passes its own).
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Tool,
        [AllowNull()][pscustomobject]$Theme,
        [string]$ExplicitReason
    )
    if (-not $Theme -or -not $Theme.Value -or -not $Tool.theme.env) { return }
    if (-not $ExplicitReason -and $Theme.Explicit) { $ExplicitReason = "`$DFConfig.$($Tool.theme.key) is '$($Theme.Name)'" }
    foreach ($var in $Tool.theme.env.PSObject.Properties) {
        $value = Expand-DFXdgPath ([string]$var.Value).Replace('{theme}', $Theme.Value)
        Set-DFEnv -Name $var.Name -Value $value -Tool $Tool.name -ExplicitReason $ExplicitReason
    }
}
```

In `Invoke-DFToolRegistration`, after the `env` loop:

```powershell
    # A declared theme is resolved afresh on each registration (the config may
    # have changed), applied to theme.env, and cached for the companion and wrappers.
    if ($Tool.theme) {
        if ($script:DFSessionThemes -is [hashtable]) { $script:DFSessionThemes.Remove($Tool.name) }
        Set-DFToolThemeEnv -Tool $Tool -Theme (Get-DFToolTheme -Tool $Tool)
    }
```

and mention "the declared theme" in its synopsis list.

- [ ] **Step 5: Run the tests**

Run: `pwsh -NoProfile -File build/Test-DFFull.ps1 -Path tests/Get-DFToolTheme.Tests.ps1, tests/Register-DFTool.Tests.ps1`
Expected: PASS.

- [ ] **Step 6: Commit**

```powershell
pwsh -NoProfile -File build/Build-DFCoreBundle.ps1
git add Private/Get-DFToolTheme.ps1 Private/Register-DFToolSteps.ps1 tests/TestSupport.ps1 tests/Get-DFToolTheme.Tests.ps1 Bundle/DotForge.Core.ps1
git commit -m "feat: resolve and apply a tool's declared theme during registration"
```

---

### Task 6: `Set-DFToolTheme`

**Files:**
- Create: `Public/Set-DFToolTheme.ps1`
- Modify: `DotForge.psd1` (`FunctionsToExport`)
- Create: `tests/Set-DFToolTheme.Tests.ps1`
- Docs: `docs/guide/configuration.md` (theme section; find with `rg -n "Theme" docs/guide/configuration.md`)

**Interfaces:**
- Consumes: `Resolve-DFToolTheme`, `Set-DFToolThemeEnv`, `$script:DFSessionThemes` (Task 5); `Test-DFToolActive`, `$script:DFSessionToolDb`.
- Produces: `Set-DFToolTheme -Name <string> -Theme <string>` → the `Resolve-DFToolTheme` object. Task 9 extends its "can switch live" check to wrappers.

- [ ] **Step 1: Write the failing tests** — `tests/Set-DFToolTheme.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
}

Describe 'Set-DFToolTheme' {
    BeforeEach {
        Reset-DFTestSession; Set-DFTestXdg; Set-DFTestConfig $null
        Mock Test-DFExecutableOnPath { $true }
        $script:DFToolAvailability = @{}
        $script:Tools = Join-Path $TestDrive 'settools'
        New-Item -ItemType Directory -Path $script:Tools -Force | Out-Null
        '{ "name": "themed", "executable": "themed.exe", "theme": { "key": "ThemedTheme", "default": "nord", "valid": ["nord", "dark", "auto"], "fallback": "auto", "env": { "THEMED_THEME": "{theme}" } } }' |
            Set-Content (Join-Path $script:Tools 'themed.json')
        '{ "name": "coded", "executable": "coded.exe", "theme": { "key": "CodedTheme", "default": "nord", "command": "Select-CodedTheme" } }' |
            Set-Content (Join-Path $script:Tools 'coded.json')
        '{ "name": "seeded", "executable": "seeded.exe", "theme": { "key": "SeededTheme", "default": "nord" } }' |
            Set-Content (Join-Path $script:Tools 'seeded.json')
        Remove-Item Env:THEMED_THEME -ErrorAction Ignore
    }
    AfterEach { Remove-Item Env:THEMED_THEME -ErrorAction Ignore; Set-DFTestConfig $null; Restore-DFTestXdg }

    It 'switches the theme and re-applies theme.env' {
        Register-DFTool -Name 'themed' -ToolsPath $script:Tools
        (Set-DFToolTheme -Name 'themed' -Theme 'dark').Value | Should -Be 'dark'
        $Env:THEMED_THEME | Should -Be 'dark'
        Get-DFSessionThemeValue -Name 'themed' | Should -Be 'dark'
    }
    It 'overrides a value set outside DotForge' {
        Register-DFTool -Name 'themed' -ToolsPath $script:Tools
        $Env:THEMED_THEME = 'mine'
        Set-DFToolTheme -Name 'themed' -Theme 'dark' -WarningAction SilentlyContinue | Out-Null
        $Env:THEMED_THEME | Should -Be 'dark'
    }
    It 'falls back with a warning for an unknown theme' {
        Register-DFTool -Name 'themed' -ToolsPath $script:Tools
        (Set-DFToolTheme -Name 'themed' -Theme 'bogus' -WarningAction SilentlyContinue).Value | Should -Be 'auto'
        $Env:THEMED_THEME | Should -Be 'auto'
    }
    It 'errors, without throwing, for a tool that is not active' {
        { Set-DFToolTheme -Name 'themed' -Theme 'dark' -ErrorAction SilentlyContinue -ErrorVariable e } | Should -Not -Throw
        Set-DFToolTheme -Name 'themed' -Theme 'dark' -ErrorAction SilentlyContinue -ErrorVariable e
        "$e" | Should -Match "themed isn't active"
    }
    It 'points at the companion''s command for a code-applied theme' {
        Register-DFTool -Name 'coded' -ToolsPath $script:Tools
        Set-DFToolTheme -Name 'coded' -Theme 'dark' -ErrorAction SilentlyContinue -ErrorVariable e
        "$e" | Should -Match 'Select-CodedTheme'
    }
    It 'says a setup-only theme cannot be switched live' {
        Register-DFTool -Name 'seeded' -ToolsPath $script:Tools
        Set-DFToolTheme -Name 'seeded' -Theme 'dark' -ErrorAction SilentlyContinue -ErrorVariable e
        "$e" | Should -Match "can't be switched live"
    }
}
```

- [ ] **Step 2: Run to see them fail**

Run: `pwsh -NoProfile -File build/Test-DFFull.ps1 -Path tests/Set-DFToolTheme.Tests.ps1`
Expected: FAIL, `Set-DFToolTheme` not recognized.

- [ ] **Step 3: Implement** — `Public/Set-DFToolTheme.ps1`:

```powershell
#Requires -Version 7.2

function Set-DFToolTheme {
    <#
    .SYNOPSIS
        Switches an active tool's theme for the rest of this session.
    .DESCRIPTION
        For a tool whose theme block DotForge applies itself: resolves -Theme
        like the configured one (theme map, theme files, built-in names, with a
        warning and the tool's fallback for a name it doesn't know), re-applies
        the theme's environment variables, and makes the tool's wrapper use it
        from the next call. The choice is explicit, so it replaces a value you
        set outside DotForge.

        It lasts for this session; to keep it, set the tool's theme key (for
        example $DFConfig GlowTheme) in your profile. A tool whose theme is
        applied by its companion names its own command instead, and a theme
        written to a config file once, at setup, can't be switched here.
    .PARAMETER Name
        The tool, e.g. glow. Tab completion lists active tools with a theme.
    .PARAMETER Theme
        A theme name, or the full path to a theme file for tools that read theme files.
    .EXAMPLE
        Set-DFToolTheme glow dracula

        Renders Markdown with glow's dracula style for the rest of the session.
    .EXAMPLE
        Set-DFToolTheme bat 'Monokai Extended'

        Switches bat's BAT_THEME.
    .OUTPUTS
        PSCustomObject: Name, Native, Value (what the tool is given) and Explicit.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/configuration.md
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete)
            foreach ($toolName in @($script:DFSessionToolDb.Keys | Sort-Object)) {
                if ($toolName -like "$wordToComplete*" -and $script:DFSessionToolDb[$toolName].theme -and (Test-DFToolActive $toolName)) { $toolName }
            }
        })]
        [string]$Name,
        [Parameter(Mandatory, Position = 1)][string]$Theme
    )
    $tool = if ($script:DFSessionToolDb) { $script:DFSessionToolDb[$Name] }
    if (-not $tool -or -not (Test-DFToolActive $Name)) { Write-Error "DotForge: $Name isn't active in this session."; return }
    if (-not $tool.theme) { Write-Error "DotForge: $Name has no theme to switch."; return }
    if ($tool.theme.command) { Write-Error "DotForge: $Name's theme is applied by its companion; use $($tool.theme.command)."; return }
    if (-not (Test-DFThemeSwitchable -Tool $tool)) {
        Write-Error "DotForge: $Name's theme is written to its config once, at setup, so it can't be switched live; edit its config file."
        return
    }
    $resolved = Resolve-DFToolTheme -Tool $tool -Name $Theme
    if ($script:DFSessionThemes -isnot [hashtable]) { $script:DFSessionThemes = @{} }
    $script:DFSessionThemes[$Name] = $resolved
    Set-DFToolThemeEnv -Tool $tool -Theme $resolved -ExplicitReason "Set-DFToolTheme chose '$Theme'"
    $resolved
}
```

and in `Private/Get-DFToolTheme.ps1`:

```powershell
function Test-DFThemeSwitchable {
    <#
    .SYNOPSIS
        True when DotForge itself applies a tool's theme at run time (theme.env), so Set-DFToolTheme can switch it.
    .PARAMETER Tool
        A normalized tool record with a theme block.
    .OUTPUTS
        System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][pscustomobject]$Tool)
    [bool]$Tool.theme.env -and @($Tool.theme.env.PSObject.Properties).Count -gt 0
}
```

Add `'Set-DFToolTheme'` to `FunctionsToExport` in `DotForge.psd1` (keep the list's order).

- [ ] **Step 4: Run the tests**

Run: `pwsh -NoProfile -File build/Test-DFFull.ps1 -Path tests/Set-DFToolTheme.Tests.ps1, tests/ModuleSplit.Tests.ps1, tests/Docs.Help.Tests.ps1`
Expected: PASS. Also `pwsh -NoProfile -c "Import-Module ./DotForge.psd1 -Force; Get-Help Set-DFToolTheme -Full"` renders every section.

- [ ] **Step 5: Docs** — in the guide's theme section add:

```markdown
To switch a tool's theme for the rest of the session, use `Set-DFToolTheme`:

<!-- system -->
```powershell
Set-DFToolTheme bat 'Monokai Extended'
```

It works for tools whose theme DotForge applies itself (bat, mdcat, moor, delta, glow). fzf, PSReadLine
and vivid have their own commands (`Invoke-DFApplyFzfTheme`, `Select-PSReadLineTheme`,
`Select-LSColorsTheme`). To keep a theme, set the tool's key (`BatTheme`, …) in your config.
```

- [ ] **Step 6: Commit**

```powershell
pwsh -NoProfile -File build/Build-DFCoreBundle.ps1
pwsh -NoProfile -File build/Build-DFReferenceDocs.ps1
git add Public/Set-DFToolTheme.ps1 Private/Get-DFToolTheme.ps1 DotForge.psd1 tests/Set-DFToolTheme.Tests.ps1 docs Bundle/DotForge.Core.ps1
git commit -m "feat: Set-DFToolTheme switches a tool's declared theme live"
```

---

### Task 7: Migrate bat, mdcat, moor and delta to `theme`

**Files:**
- Modify: `Tools/bat.json`, `Tools/mdcat.json`, `Tools/moor.json`, `Tools/delta.json`
- Delete: `Tools/bat.ps1`, `Tools/moor.ps1`
- Modify: `Tools/mdcat.ps1` (drop section 1), `Tools/delta.ps1` (drop the theme lines)
- Modify: `tests/bat.Tests.ps1`, `tests/moor.Tests.ps1`, `tests/mdcat.Tests.ps1`, `tests/delta.Tests.ps1`, `tests/DFSessionConfig.Tests.ps1`

**Interfaces:**
- Consumes: `Resolve-DFToolTheme`, `Set-DFToolThemeEnv` (Task 5); `Get-DFTestToolRecord` (Task 5).

- [ ] **Step 1: Write the failing tests**

Add a shared check to `tests/DFSessionConfig.Tests.ps1`'s `known-key list` context:

```powershell
        It 'lists every theme.key a tool record declares' {
            $root = Split-Path $PSScriptRoot -Parent
            $keys = foreach ($json in Get-ChildItem (Join-Path $root 'Tools') -Filter '*.json') {
                (Get-Content $json -Raw | ConvertFrom-Json).PSObject.Properties['theme']?.Value?.key
            }
            @($keys | Where-Object { $_ -and -not $script:DFConfigKeys.Contains($_) }) | Should -BeNullOrEmpty
        }
```

Replace `tests/bat.Tests.ps1` with:

```powershell
BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
}

Describe 'bat theme' {
    BeforeEach { Reset-DFTestSession; Set-DFTestConfig $null; Remove-Item Env:BAT_THEME -ErrorAction Ignore; $script:Bat = Get-DFTestToolRecord bat }
    AfterEach { Remove-Item Env:BAT_THEME -ErrorAction Ignore; Set-DFTestConfig $null }

    It 'has no companion and no top-level BAT_THEME' {
        Test-Path "$PSScriptRoot/../Tools/bat.ps1" | Should -BeFalse
        $script:Bat.env | Should -BeNullOrEmpty
    }
    It 'sets BAT_THEME to Catppuccin Mocha by default' {
        Set-DFToolThemeEnv -Tool $script:Bat -Theme (Resolve-DFToolTheme -Tool $script:Bat)
        $Env:BAT_THEME | Should -Be 'Catppuccin Mocha'
    }
    It 'follows the shared Theme key, translating to the native name' {
        Set-DFTestConfig @{ Theme = 'catppuccin-mocha' }
        Set-DFToolThemeEnv -Tool $script:Bat -Theme (Resolve-DFToolTheme -Tool $script:Bat)
        $Env:BAT_THEME | Should -Be 'Catppuccin Mocha'
    }
    It 'lets BatTheme override the shared Theme with a native name' {
        Set-DFTestConfig @{ Theme = 'catppuccin-mocha'; BatTheme = 'Dracula' }
        Set-DFToolThemeEnv -Tool $script:Bat -Theme (Resolve-DFToolTheme -Tool $script:Bat)
        $Env:BAT_THEME | Should -Be 'Dracula'
    }
    It 'keeps a BAT_THEME set outside DotForge unless BatTheme is set' {
        $Env:BAT_THEME = 'Nord'
        Set-DFToolThemeEnv -Tool $script:Bat -Theme (Resolve-DFToolTheme -Tool $script:Bat)
        $Env:BAT_THEME | Should -Be 'Nord'
    }
}
```

Replace `tests/moor.Tests.ps1` with:

```powershell
BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
}

Describe 'moor theme' {
    BeforeEach {
        Reset-DFTestSession; Set-DFTestConfig $null
        $script:SavedMoor = $Env:MOOR; Remove-Item Env:MOOR -ErrorAction Ignore
        $script:Moor = Get-DFTestToolRecord moor
    }
    AfterEach {
        if ($null -eq $script:SavedMoor) { Remove-Item Env:MOOR -ErrorAction Ignore } else { $Env:MOOR = $script:SavedMoor }
        Set-DFTestConfig $null
    }

    It 'sets MOOR to the configured style and quit-if-one-screen when unset' {
        Set-DFTestConfig @{ Theme = 'catppuccin-mocha' }
        Set-DFToolThemeEnv -Tool $script:Moor -Theme (Resolve-DFToolTheme -Tool $script:Moor)
        $Env:MOOR | Should -Be '-style catppuccin-mocha -quit-if-one-screen'
    }
    It 'lets MoorTheme override the shared theme' {
        Set-DFTestConfig @{ Theme = 'catppuccin-mocha'; MoorTheme = 'dracula' }
        Set-DFToolThemeEnv -Tool $script:Moor -Theme (Resolve-DFToolTheme -Tool $script:Moor) -WarningAction SilentlyContinue
        $Env:MOOR | Should -Be '-style dracula -quit-if-one-screen'
    }
    It 'leaves a MOOR the user set alone' {
        $Env:MOOR = '-no-linenumbers'
        Set-DFToolThemeEnv -Tool $script:Moor -Theme (Resolve-DFToolTheme -Tool $script:Moor)
        $Env:MOOR | Should -Be '-no-linenumbers'
    }
}
```

In `tests/mdcat.Tests.ps1`: change `'sets a catppuccin MDCAT_THEME default in the env block'` to assert `$json.theme.default | Should -Be 'catppuccin-mocha'` and `$json.theme.env.MDCAT_THEME | Should -Be '{theme}'`; replace the theme `It`s at lines 56-79 ('sets MDCAT_THEME to the JSON default…' through 'tolerates $DFConfig being set to $null') with a `Describe 'mdcat theme'` built like bat's above (record `Get-DFTestToolRecord mdcat`, variable `MDCAT_THEME`), covering: default → `catppuccin-mocha`; `MdcatTheme = 'nord'` → `nord`; `Theme = 'catppuccin-mocha'` → `catppuccin-mocha`; `MdcatTheme = 'bogus'` → `auto` with a warning matching `"mdcat theme 'bogus' not recognized — falling back to 'auto'"`; `Set-DFTestConfig $null` → `catppuccin-mocha`. Keep the completion-cache test.

In `tests/delta.Tests.ps1`: keep line 9's test (no top-level env). Replace the three DELTA_FEATURES `It`s (lines 59-73) with a `Describe 'delta theme'` built like bat's above (record `Get-DFTestToolRecord delta`, variable `DELTA_FEATURES`): default → `+catppuccin-mocha`; `Theme = 'catppuccin-mocha'` → `+catppuccin-mocha`; `DeltaTheme = 'my-feature'` → `+my-feature`.

- [ ] **Step 2: Run to see them fail**

Run: `pwsh -NoProfile -File build/Test-DFFull.ps1 -Path tests/bat.Tests.ps1, tests/moor.Tests.ps1, tests/mdcat.Tests.ps1, tests/delta.Tests.ps1, tests/DFSessionConfig.Tests.ps1`
Expected: FAIL (records have no theme block yet).

- [ ] **Step 3: Migrate the records**

`Tools/bat.json`: delete the `env` and `themeMap` blocks; add after `xdg`:

```json
  "theme": {
    "key": "BatTheme",
    "default": "catppuccin-mocha",
    "map": { "catppuccin-mocha": "Catppuccin Mocha" },
    "env": { "BAT_THEME": "{theme}" }
  },
```

`Tools/moor.json`: add `"theme": { "key": "MoorTheme", "default": "catppuccin-mocha", "env": { "MOOR": "-style {theme} -quit-if-one-screen" } },` (moor's `-style` names include the canonical names; it falls back to its default for one it doesn't know).

`Tools/mdcat.json`: delete `env`; add:

```json
  "theme": {
    "key": "MdcatTheme",
    "default": "catppuccin-mocha",
    "valid": ["auto", "dark", "light", "catppuccin-mocha", "catppuccin-latte", "gruvbox-dark", "gruvbox-light", "dracula", "nord", "solarized-dark", "solarized-light"],
    "fallback": "auto",
    "env": { "MDCAT_THEME": "{theme}" }
  },
```

`Tools/delta.json`: add `"theme": { "key": "DeltaTheme", "default": "catppuccin-mocha", "env": { "DELTA_FEATURES": "+{theme}" } },`. delta features are user-defined config names, so there's no `valid`; the leading `+` makes them additive (see `docs/superpowers/specs/2026-09-04-delta-catppuccin-design.md`).

Delete `Tools/bat.ps1` and `Tools/moor.ps1` (`git rm`). In `Tools/mdcat.ps1` delete section 1 (the theme block), renumber section 2 as the only step, and change the header to "Companion for mdcat — registers mdcat's own PowerShell completions. Its theme is declared in Tools/mdcat.json (theme block)." In `Tools/delta.ps1` delete the `$_theme`/`$_native`/`SetEnvironmentVariable` lines with their comment, and change the header's first paragraph and its "Reads:/Sets:" lines to: "Companion for delta — deploys the bundled catppuccin/delta theme file so the feature named by DELTA_FEATURES (set from the theme block in Tools/delta.json) resolves to a real [delta \"...\"] block." / "Writes: $XDG_CONFIG_HOME\delta\catppuccin.gitconfig …" (keep the rest).

- [ ] **Step 4: Run the tests**

Run: `pwsh -NoProfile -File build/Build-DFToolRegistry.ps1` then
`pwsh -NoProfile -File build/Test-DFFull.ps1 -Path tests/bat.Tests.ps1, tests/moor.Tests.ps1, tests/mdcat.Tests.ps1, tests/delta.Tests.ps1, tests/DFSessionConfig.Tests.ps1, tests/ToolRegistry.Tests.ps1, tests/Test-DFToolSchema.Tests.ps1, tests/Roles.Contract.Tests.ps1, tests/Docs.Help.Tests.ps1`
Expected: PASS. (`Roles.Contract` confirms `MOOR` isn't a role-reserved variable; if it is, keep moor's theme env and report it.)

- [ ] **Step 5: Commit**

```powershell
pwsh -NoProfile -File build/Build-DFReferenceDocs.ps1
git add -A Tools/bat.json Tools/bat.ps1 Tools/moor.json Tools/moor.ps1 Tools/mdcat.json Tools/mdcat.ps1 Tools/delta.json Tools/delta.ps1 tests/bat.Tests.ps1 tests/moor.Tests.ps1 tests/mdcat.Tests.ps1 tests/delta.Tests.ps1 tests/DFSessionConfig.Tests.ps1 data/tool-registry.json docs/reference.md
git commit -m "feat: bat, mdcat, moor and delta declare their themes"
```

---

### Task 8: fzf, psreadline, vivid and mdv read `Get-DFToolTheme`

**Files:**
- Modify: `Tools/fzf.json`, `Tools/psreadline.json`, `Tools/vivid.json`, `Tools/mdv.json`
- Modify: `Tools/fzf.ps1` (bottom), `Tools/psreadline.ps1` (section 5), `Tools/vivid.ps1` (resolve block), `Tools/mdv.setup.ps1`
- Modify: `tests/mdv.Tests.ps1`, `tests/vivid.Tests.ps1`, `tests/fzf.Tests.ps1`, `tests/psreadline.Tests.ps1` (only where they read `settings.theme`, `themeMap` or construct `$DFCurrentTool` without `theme`)

**Interfaces:**
- Consumes: `Get-DFToolTheme` (Task 5); `-Implicit` on the apply functions (Task 3).

- [ ] **Step 1: Write the failing tests**

`tests/mdv.Tests.ps1` line 19 test becomes:

```powershell
    It 'declares a theme map translating the canonical family to catppuccin' {
        $script:MdvJson.theme.map.'catppuccin-mocha' | Should -Be 'catppuccin'
        $script:MdvJson.theme.fallback | Should -Be 'terminal'
    }
```

Add to `tests/Get-DFToolTheme.Tests.ps1`:

```powershell
Describe 'code-applied themes' {
    It '<_> declares its theme with a command and no env' -ForEach @('fzf', 'psreadline', 'vivid') {
        $record = Get-DFTestToolRecord $_
        $record.theme.command | Should -Not -BeNullOrEmpty
        $record.theme.env | Should -BeNullOrEmpty
    }
    It '<_> companion no longer resolves the theme chain itself' -ForEach @('fzf', 'psreadline', 'vivid', 'mdv.setup') {
        Get-Content "$PSScriptRoot/../Tools/$_.ps1" -Raw | Should -Not -Match 'Get-DFConfiguredTheme|Resolve-DFThemeName'
    }
}
```

- [ ] **Step 2: Run to see them fail**

Run: `pwsh -NoProfile -File build/Test-DFFull.ps1 -Path tests/Get-DFToolTheme.Tests.ps1, tests/mdv.Tests.ps1`
Expected: FAIL.

- [ ] **Step 3: Migrate**

Records:
- `Tools/fzf.json`: `"theme": { "key": "FzfTheme", "default": "catppuccin-mocha", "command": "Invoke-DFApplyFzfTheme" },`
- `Tools/psreadline.json`: `"theme": { "key": "PSReadLineTheme", "default": "catppuccin-mocha", "command": "Select-PSReadLineTheme" },`
- `Tools/vivid.json`: `"theme": { "key": "VividTheme", "default": "catppuccin-mocha", "command": "Select-LSColorsTheme" },` and delete `settings.theme` (delete `settings` if it becomes empty).
- `Tools/mdv.json`: move `settings.theme` to `theme.default` and `themeMap` to `theme.map`; add `"key": "MdvTheme"`, `"valid": ["terminal", "solarized-dark", "nord", "tokyonight", "kanagawa", "gruvbox", "monokai", "material-ocean", "catppuccin"]`, `"fallback": "terminal"`. Delete `settings` if empty.

Companions:

```powershell
# Tools/fzf.ps1, replacing the three lines after "# Apply initial theme":
# Apply the session theme (Tools/fzf.json theme block: FzfTheme -> Theme -> default).
$_theme = Get-DFToolTheme -Tool $DFCurrentTool
Invoke-DFApplyFzfTheme -Name $_theme.Native -Implicit:(-not $_theme.Explicit)
```

```powershell
# Tools/psreadline.ps1, section 5:
# 5. Apply the session theme (Tools/psreadline.json theme block: PSReadLineTheme -> Theme -> default).
Invoke-DFApplyPSReadLineTheme -Name (Get-DFToolTheme -Tool $DFCurrentTool).Native
```

```powershell
# Tools/vivid.ps1, replacing the "# Resolve:" block and the call after it:
# Apply the session theme (Tools/vivid.json theme block: VividTheme -> Theme -> default).
$_theme = Get-DFToolTheme -Tool $DFCurrentTool
Invoke-DFApplyLSColorsTheme -Name $_theme.Native -Implicit:(-not $_theme.Explicit)
```

```powershell
# Tools/mdv.setup.ps1, replacing $_settings ... through the $_valid check:
# The theme block in Tools/mdv.json resolves MdvTheme -> Theme -> default, maps
# the canonical name and falls back to 'terminal' for a name mdv doesn't know.
$_name = (Get-DFToolTheme -Tool $DFCurrentTool).Value
```

Update the companions' header comments: "Reads: $DFConfig.XTheme, then …" becomes "Theme: the theme block in Tools/<tool>.json (Get-DFToolTheme)". In each, the help text that says "calls it at startup with $DFConfig.XTheme, then $DFConfig.Theme, then catppuccin-mocha" stays true; leave it.

Tests that dot-source these companions with a hand-built `$DFCurrentTool` (e.g. `[pscustomobject]@{ themeMap = $null }`) must use `Get-DFTestToolRecord <tool>` instead; tests reading `settings.theme` read `theme.default`.

- [ ] **Step 4: Run the tests**

Run: `pwsh -NoProfile -File build/Build-DFToolRegistry.ps1` then
`pwsh -NoProfile -File build/Test-DFFull.ps1 -Path tests/Get-DFToolTheme.Tests.ps1, tests/mdv.Tests.ps1, tests/fzf.Tests.ps1, tests/psreadline.Tests.ps1, tests/PSReadLine.Completion.Tests.ps1, tests/vivid.Tests.ps1, tests/ToolRegistry.Tests.ps1, tests/DFSessionConfig.Tests.ps1, tests/Docs.Help.Tests.ps1`
Expected: PASS.

- [ ] **Step 5: Commit**

```powershell
pwsh -NoProfile -File build/Build-DFReferenceDocs.ps1
git add Tools/fzf.json Tools/fzf.ps1 Tools/psreadline.json Tools/psreadline.ps1 Tools/vivid.json Tools/vivid.ps1 Tools/mdv.json Tools/mdv.setup.ps1 tests data/tool-registry.json docs/reference.md
git commit -m "refactor: fzf, psreadline, vivid and mdv read their declared theme"
```

---

## Phase 3 — Declarative executable wrapper

### Task 9: `wrapper` schema, normalization and `New-DFToolWrapper`

**Files:**
- Modify: `Shared/Import-DFToolDb.ps1` (add `ConvertTo-DFWrapperBlock`; record field `wrapper`)
- Modify: `Shared/Test-DFToolSchema.ps1` (add `Get-DFWrapperSchemaError`; typo names)
- Create: `Private/New-DFToolWrapper.ps1`
- Modify: `Private/Register-DFToolSteps.ps1` (after the theme step); `Private/Get-DFToolTheme.ps1` (`Test-DFThemeSwitchable`)
- Modify: `build/Build-DFReferenceDocs.ps1` (`Get-ToolMarkdown`: Theme and Wraps rows)
- Create: `tests/New-DFToolWrapper.Tests.ps1`; modify `tests/Test-DFToolSchema.Tests.ps1`, `tests/ConvertTo-DFToolRecord.Tests.ps1`

**Interfaces:**
- Consumes: `Get-DFSessionThemeValue` (Task 5).
- Produces:
  - record field `wrapper` = `$null` or `[pscustomobject]@{ args = [object[]] of [pscustomobject]@{ ifFile = <string or $null>; args = [string[]] }; custom = [bool] }` (each plain string in the JSON becomes its own group with `ifFile = $null`).
  - `Expand-DFToolToken -Tool <record> -Text <string>` → `string` (`{settings.<name>}` replaced, then `Expand-DFXdgPath`).
  - `New-DFToolWrapper -Tool <record> [-Invoke <scriptblock>] [-Description <string>]`: defines `function:global:<executable basename>`. `-Invoke` is called as `& $Invoke <exe> <string[] declared> <object[] userArgs> <InvocationInfo>`.

- [ ] **Step 1: Write the failing tests** — `tests/New-DFToolWrapper.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    function New-WrappedTool([object[]]$WrapperArgs, [hashtable]$Theme, [hashtable]$Settings) {
        $raw = [ordered]@{ name = 'wrapped'; executable = 'dfwrapped.exe'; wrapper = [pscustomobject]@{ args = $WrapperArgs } }
        if ($Theme) { $raw.theme = [pscustomobject]$Theme }
        if ($Settings) { $raw.settings = [pscustomobject]$Settings }
        ConvertTo-DFToolRecord ([pscustomobject]$raw)
    }
}

Describe 'New-DFToolWrapper' {
    BeforeEach {
        Reset-DFTestSession; Set-DFTestXdg
        # The "executable": a global function named like the exe; the wrapper calls it by that name.
        Set-Item function:global:dfwrapped.exe -Value {
            $piped = @($input)
            "args=$($args -join '|')"
            if ($piped) { "input=$($piped -join '|')" }
        }
    }
    AfterEach { Remove-DFTestGlobal -Function 'dfwrapped.exe', 'dfwrapped'; Restore-DFTestXdg }

    It 'defines a global function named after the executable, passing declared then user args' {
        New-DFToolWrapper -Tool (New-WrappedTool @('--a', '--b'))
        dfwrapped --mine | Should -Be 'args=--a|--b|--mine'
    }
    It 'passes an ifFile group only while the file exists, reading {file}' {
        $cfg = Join-Path $TestDrive 'w.conf'
        New-DFToolWrapper -Tool (New-WrappedTool @([pscustomobject]@{ ifFile = $cfg; args = @('--config', '{file}') }))
        dfwrapped | Should -Be 'args='
        Set-Content $cfg 'x'
        dfwrapped | Should -Be "args=--config|$cfg"
    }
    It 'expands ${XDG_*} and {settings.<name>} in ifFile' {
        $tool = New-WrappedTool @([pscustomobject]@{ ifFile = '{settings.cfg}'; args = @('-c', '{file}') }) -Settings @{ cfg = '${XDG_CONFIG_HOME}/w.conf' }
        New-Item -ItemType File -Path (Join-Path $Env:XDG_CONFIG_HOME 'w.conf') -Force | Out-Null
        New-DFToolWrapper -Tool $tool
        dfwrapped | Should -Be "args=-c|$(Join-Path $Env:XDG_CONFIG_HOME 'w.conf')"
    }
    It 'reads {theme} from the session on every call' {
        $tool = New-WrappedTool @('-s', '{theme}') -Theme @{ key = 'WrappedTheme'; default = 'nord' }
        $script:DFSessionThemes = @{ wrapped = [pscustomobject]@{ Value = 'nord' } }
        New-DFToolWrapper -Tool $tool
        dfwrapped | Should -Be 'args=-s|nord'
        $script:DFSessionThemes.wrapped = [pscustomobject]@{ Value = 'dracula' }
        dfwrapped | Should -Be 'args=-s|dracula'
    }
    It 'keeps a theme value with spaces as one argument' {
        $tool = New-WrappedTool @('-s', '{theme}') -Theme @{ key = 'WrappedTheme' }
        $script:DFSessionThemes = @{ wrapped = [pscustomobject]@{ Value = 'Catppuccin Mocha' } }
        Set-Item function:global:dfwrapped.exe -Value { "count=$($args.Count) last=$($args[-1])" }
        New-DFToolWrapper -Tool $tool
        dfwrapped | Should -Be 'count=2 last=Catppuccin Mocha'
    }
    It 'passes piped input through without the missing file''s group' {
        New-DFToolWrapper -Tool (New-WrappedTool @([pscustomobject]@{ ifFile = (Join-Path $TestDrive 'none'); args = @('--config', '{file}') }))
        'one', 'two' | dfwrapped | Should -Be @('args=', 'input=one|two')
    }
    It 'hands the call to -Invoke with the declared and user arguments' {
        New-DFToolWrapper -Tool (New-WrappedTool @('--a')) -Invoke { param($exe, $declared, $userArgs, $invocation) "$exe;$($declared -join ',');$($userArgs -join ',')" }
        dfwrapped --x | Should -Be 'dfwrapped.exe;--a;--x'
    }
    It 'gives the wrapper complete help' {
        New-DFToolWrapper -Tool (New-WrappedTool @('--a'))
        $help = Get-Help dfwrapped -Full
        $help.Synopsis | Should -Match 'Runs dfwrapped.exe'
        ($help.description | Out-String) | Should -Match '--a'
        @($help.examples.example).Count | Should -BeGreaterThan 0
        ($help.returnValues | Out-String) | Should -Match 'String'
    }
}

Describe 'wrapper during registration' {
    BeforeEach {
        Reset-DFTestSession; Set-DFTestXdg
        Mock Test-DFExecutableOnPath { $true }
        $script:DFToolAvailability = @{}
        $script:Tools = Join-Path $TestDrive 'wraptools'
        New-Item -ItemType Directory -Path $script:Tools -Force | Out-Null
        '{ "name": "wrapped", "executable": "dfwrapped.exe", "theme": { "key": "WrappedTheme", "default": "nord" }, "wrapper": { "args": ["-s", "{theme}"] } }' |
            Set-Content (Join-Path $script:Tools 'wrapped.json')
        Set-Item function:global:dfwrapped.exe -Value { "args=$($args -join '|')" }
    }
    AfterEach { Remove-DFTestGlobal -Function 'dfwrapped.exe', 'dfwrapped'; Restore-DFTestXdg }

    It 'builds the wrapper with the session theme' {
        Register-DFTool -Name 'wrapped' -ToolsPath $script:Tools
        dfwrapped | Should -Be 'args=-s|nord'
    }
    It 'follows Set-DFToolTheme' {
        Register-DFTool -Name 'wrapped' -ToolsPath $script:Tools
        Set-DFToolTheme wrapped dracula | Out-Null
        dfwrapped | Should -Be 'args=-s|dracula'
    }
    It 'leaves a custom wrapper to the companion' {
        '{ "name": "wrapped", "executable": "dfwrapped.exe", "wrapper": { "custom": true, "args": ["--a"] } }' | Set-Content (Join-Path $script:Tools 'wrapped.json')
        Register-DFTool -Name 'wrapped' -ToolsPath $script:Tools
        Test-Path function:global:dfwrapped | Should -BeFalse
    }
}

Describe 'declared wrappers' {
    It '<_> does not shadow a PowerShell builtin' -ForEach @(Get-ChildItem "$PSScriptRoot/../Tools" -Filter '*.json' | ForEach-Object {
            $json = Get-Content $_ -Raw | ConvertFrom-Json
            if ($json.PSObject.Properties['wrapper']) { [System.IO.Path]::GetFileNameWithoutExtension($json.executable) } }) {
        $builtin = pwsh -NoProfile -NoLogo -c "Get-Command -Name '$_' -CommandType Cmdlet, Alias, Function -ErrorAction Ignore | ForEach-Object Name"
        $builtin | Should -BeNullOrEmpty
    }
    It '<_> companion builds its custom wrapper' -ForEach @(Get-ChildItem "$PSScriptRoot/../Tools" -Filter '*.json' | ForEach-Object {
            $json = Get-Content $_ -Raw | ConvertFrom-Json
            if ($json.PSObject.Properties['wrapper']?.Value.PSObject.Properties['custom']?.Value) { $json.name } }) {
        Get-Content "$PSScriptRoot/../Tools/$_.ps1" -Raw | Should -Match 'New-DFToolWrapper'
    }
}
```

(Until Tasks 10-12 add wrappers, the two `-ForEach` lists are empty and Pester skips them; that's expected.)

Add to `tests/Test-DFToolSchema.Tests.ps1`:

```powershell
    Context 'wrapper' {
        It 'accepts strings and ifFile groups' {
            Get-SchemaErrors @{ wrapper = [pscustomobject]@{ args = @('-x', [pscustomobject]@{ ifFile = '${XDG_CONFIG_HOME}/x'; args = @('--config', '{file}') }) } } | Should -BeNullOrEmpty
        }
        It 'requires args to be an array' {
            Get-SchemaErrors @{ wrapper = [pscustomobject]@{ args = '-x' } } | Should -Match 'wrapper.args must be an array'
        }
        It 'rejects a malformed group' {
            Get-SchemaErrors @{ wrapper = [pscustomobject]@{ args = @([pscustomobject]@{ args = @('-x') }) } } | Should -Match 'wrapper.args\[0\]'
        }
        It 'rejects {theme} without a theme block' {
            Get-SchemaErrors @{ wrapper = [pscustomobject]@{ args = @('-s', '{theme}') } } | Should -Match 'no theme block'
        }
        It 'rejects {theme} when valid can reject and there is no fallback' {
            Get-SchemaErrors @{ theme = [pscustomobject]@{ key = 'XTheme'; valid = @('a') }; wrapper = [pscustomobject]@{ args = @('-s', '{theme}') } } | Should -Match 'needs a fallback'
        }
        It 'requires custom to be a boolean' {
            Get-SchemaErrors @{ wrapper = [pscustomobject]@{ custom = 'yes'; args = @() } } | Should -Match 'wrapper.custom'
        }
    }
```

In `tests/ConvertTo-DFToolRecord.Tests.ps1` add `'wrapper'` to the two field lists and:

```powershell
    It 'normalizes wrapper args into groups' {
        $w = (ConvertTo-DFToolRecord ([pscustomobject]@{ name = 'x'; executable = 'x.exe'; wrapper = [pscustomobject]@{ args = @('-s', [pscustomobject]@{ ifFile = 'f'; args = @('-c', '{file}') }) } })).wrapper
        $w.custom | Should -BeFalse
        $w.args.Count | Should -Be 2
        $w.args[0].ifFile | Should -BeNullOrEmpty
        $w.args[0].args | Should -Be @('-s')
        $w.args[1].ifFile | Should -Be 'f'
        $w.args[1].args | Should -Be @('-c', '{file}')
    }
```

- [ ] **Step 2: Run to see them fail**

Run: `pwsh -NoProfile -File build/Test-DFFull.ps1 -Path tests/New-DFToolWrapper.Tests.ps1, tests/Test-DFToolSchema.Tests.ps1, tests/ConvertTo-DFToolRecord.Tests.ps1`
Expected: FAIL.

- [ ] **Step 3: Normalization and schema**

`Shared/Import-DFToolDb.ps1`:

```powershell
function ConvertTo-DFWrapperBlock {
    <#
    .SYNOPSIS
        Normalizes a tool's wrapper block: args becomes a list of { ifFile; args } groups, custom a boolean.
    .PARAMETER RawWrapper
        The parsed wrapper object, or $null.
    .OUTPUTS
        PSCustomObject, or $null when there is no wrapper block.
    #>
    [CmdletBinding()]
    param([AllowNull()][object]$RawWrapper)
    if ($null -eq $RawWrapper) { return $null }
    $groups = foreach ($entry in @($RawWrapper.PSObject.Properties['args']?.Value)) {
        if ($null -eq $entry) { continue }
        if ($entry -is [string]) { [pscustomobject]@{ ifFile = $null; args = [string[]]@($entry) }; continue }
        [pscustomobject]@{
            ifFile = Get-DFToolRecordProperty $entry 'ifFile' $null
            args   = [string[]]@($entry.PSObject.Properties['args']?.Value)
        }
    }
    [pscustomobject]@{ args = [object[]]@($groups); custom = [bool](Get-DFToolRecordProperty $RawWrapper 'custom' $false) }
}
```

In `ConvertTo-DFToolRecord` add `wrapper = ConvertTo-DFWrapperBlock (Get-DFToolRecordProperty $Tool 'wrapper' $null)` after `theme`, and to its description: "wrapper, when present, has args (a list of { ifFile; args } groups; a plain string is its own group) and custom."

`Shared/Test-DFToolSchema.ps1`:

```powershell
function Get-DFWrapperSchemaError ([PSCustomObject]$Tool) {
    <#
    .SYNOPSIS
        Schema errors in wrapper: args is an array of strings and { ifFile, args } groups; {theme} needs a theme that always has a value.
    #>
    $wrapper = Get-DFSchemaProperty $Tool 'wrapper'
    if ($null -eq $wrapper) { return }
    if ($wrapper -isnot [pscustomobject]) { return 'wrapper must be an object' }
    $custom = Get-DFSchemaProperty $wrapper 'custom'
    if ($null -ne $custom -and $custom -isnot [bool]) { 'wrapper.custom must be true or false' }
    $entries = $wrapper.PSObject.Properties['args']?.Value   # read directly: a helper would unroll ["x"]
    if ($entries -isnot [array]) { return 'wrapper.args must be an array' }
    $usesTheme = $false
    for ($n = 0; $n -lt $entries.Count; $n++) {
        $entry = $entries[$n]
        if ($entry -is [string]) { if ($entry.Contains('{theme}')) { $usesTheme = $true }; continue }
        $inner = if ($entry -is [pscustomobject]) { $entry.PSObject.Properties['args']?.Value }
        $ifFile = if ($entry -is [pscustomobject]) { Get-DFSchemaProperty $entry 'ifFile' }
        if ($ifFile -isnot [string] -or -not $ifFile -or $inner -isnot [array] -or @($inner | Where-Object { $_ -isnot [string] }).Count) {
            "wrapper.args[$n] must be a string or { ifFile, args: [strings] }"; continue
        }
        if (@($inner | Where-Object { $_.Contains('{theme}') }).Count) { $usesTheme = $true }
    }
    if (-not $usesTheme) { return }
    $theme = Get-DFSchemaProperty $Tool 'theme'
    if ($null -eq $theme) { return 'wrapper.args uses {theme}, but the tool has no theme block' }
    $canReject = (Get-DFSchemaProperty $theme 'files') -or $theme.PSObject.Properties['valid']
    if ($canReject -and -not (Get-DFSchemaProperty $theme 'fallback')) {
        'wrapper.args uses {theme}, so theme needs a fallback (valid or files can reject a name)'
    }
}
```

Call it after `Get-DFThemeSchemaError $Tool`. In `Get-DFFieldTypoWarning`: add `'wrapper'` to `$known['']`, `wrapper = 'args', 'custom'`, and a section like theme's for `wrapper`.

- [ ] **Step 4: `New-DFToolWrapper`** — `Private/New-DFToolWrapper.ps1`:

```powershell
#Requires -Version 7.2

function Expand-DFToolToken {
    <#
    .SYNOPSIS
        Expands a tool record's template: {settings.<name>} from the tool's settings, then ${XDG_*}.
    .PARAMETER Tool
        A normalized tool record.
    .PARAMETER Text
        The template, e.g. '{settings.configPath}' or '${XDG_CONFIG_HOME}/lsd/config.yaml'.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][pscustomobject]$Tool, [Parameter(Mandatory)][string]$Text)
    $settings = $Tool.settings
    $filled = [regex]::Replace($Text, '\{settings\.(\w+)\}', {
        param($match)
        if ($settings) { [string]$settings.PSObject.Properties[$match.Groups[1].Value]?.Value } else { '' }
    })
    Expand-DFXdgPath $filled
}

function Format-DFWrapperHelp {
    <#
    .SYNOPSIS
        Returns the comment-based help block for a generated executable wrapper.
    .PARAMETER Tool
        A normalized tool record with a wrapper block.
    .PARAMETER Name
        The wrapper's command name.
    .PARAMETER Description
        Extra description from a companion that builds the wrapper itself.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][pscustomobject]$Tool, [Parameter(Mandatory)][string]$Name, [string]$Description)
    $exe = $Tool.executable
    $declared = @(foreach ($group in @($Tool.wrapper.args)) {
        $list = $group.args -join ' '
        if ($group.ifFile) { "$list (when $($group.ifFile) exists)" } else { $list }
    }) -join '; '
    $themeLine = if ($declared.Contains('{theme}')) { "`n        {theme} is the session's $($Tool.name) theme; Set-DFToolTheme switches it." } else { '' }
    $extra = if ($Description) { "`n        $Description" } else { '' }
    @"
    <#
    .SYNOPSIS
        Runs $exe with the arguments DotForge adds.
    .DESCRIPTION
        Wraps $exe and passes, before your own arguments: $declared.$themeLine$extra
        Piped input is passed through. Defined by DotForge from the wrapper block in $($Tool.name).json.
    .EXAMPLE
        $Name --help

        Runs $exe --help with DotForge's arguments.
    .OUTPUTS
        System.String. The output of $exe.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/tools.md
    #>

"@
}

function New-DFToolWrapper {
    <#
    .SYNOPSIS
        Defines a global function, named after a tool's executable, that runs it with the tool's declared wrapper arguments.
    .DESCRIPTION
        Builds the arguments on every call from wrapper.args: plain strings are
        always passed, an { ifFile, args } group only while its file exists
        ({file} is that path; ifFile may use {settings.<name>} and ${XDG_*}),
        and {theme} is the session theme's value (Get-DFSessionThemeValue), so
        Set-DFToolTheme takes effect at once. Your own arguments follow. Piped
        input is passed through (without that branch, a function with no
        process block swallows the pipeline and the tool waits on the
        console). The executable is called by its file name (glow.exe), so the
        wrapper never calls itself.
    .PARAMETER Tool
        A normalized tool record with a wrapper block.
    .PARAMETER Invoke
        Runs a non-piped call instead of the plain one, for a companion whose
        wrapper does more (fastfetch). Called as
        & $Invoke <executable> <declared args> <user args> <$MyInvocation>.
    .PARAMETER Description
        Extra text for the generated help's description.
    .OUTPUTS
        None. Defines function:global:<executable name>.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Tool,
        [scriptblock]$Invoke,
        [string]$Description
    )
    # The generated function is a closure over these $_df* variables.
    $_dfExe = $Tool.executable
    $_dfToolName = $Tool.name
    $_dfInvoke = $Invoke
    $_dfThemeOf = ${function:Get-DFSessionThemeValue}
    $_dfGroups = @(foreach ($group in @($Tool.wrapper.args)) {
        $file = if ($group.ifFile) { Expand-DFToolToken -Tool $Tool -Text $group.ifFile }
        [pscustomobject]@{
            IfFile = $file
            Args   = [string[]]@(foreach ($arg in $group.args) { if ($file) { $arg.Replace('{file}', $file) } else { $arg } })
        }
    })
    $name = [System.IO.Path]::GetFileNameWithoutExtension($_dfExe)
    $body = (Format-DFWrapperHelp -Tool $Tool -Name $name -Description $Description) + @'
    $declared = @(foreach ($group in $_dfGroups) {
        if ($group.IfFile -and -not (Test-Path -LiteralPath $group.IfFile -PathType Leaf)) { continue }
        foreach ($arg in $group.Args) { $arg.Replace('{theme}', [string](& $_dfThemeOf $_dfToolName)) }
    })
    if ($MyInvocation.ExpectingInput) { $input | & $_dfExe @declared @args; return }
    if ($_dfInvoke) { & $_dfInvoke $_dfExe $declared $args $MyInvocation; return }
    & $_dfExe @declared @args
'@
    Set-Item -Path "function:global:$name" -Value ([scriptblock]::Create($body).GetNewClosure())
}
```

In `Invoke-DFToolRegistration`, right after the theme step:

```powershell
    # A declared executable wrapper; custom ones are built by the companion (New-DFToolWrapper -Invoke).
    if ($Tool.wrapper -and -not $Tool.wrapper.custom) { New-DFToolWrapper -Tool $Tool }
```

`Test-DFThemeSwitchable` in `Private/Get-DFToolTheme.ps1` becomes:

```powershell
    $hasEnv = [bool]$Tool.theme.env -and @($Tool.theme.env.PSObject.Properties).Count -gt 0
    $inWrapper = [bool]$Tool.wrapper -and @($Tool.wrapper.args | ForEach-Object { $_.args } | Where-Object { $_.Contains('{theme}') }).Count -gt 0
    $hasEnv -or $inWrapper
```

with its synopsis "…at run time (theme.env or a wrapper's {theme})…".

- [ ] **Step 5: Reference rows** — in `build/Build-DFReferenceDocs.ps1`'s `Get-ToolMarkdown`, after the `Environment` row:

```powershell
    $theme = & $prop $Tool 'theme'
    if ($theme) {
        $themeText = "key $(& $code $theme.key)"
        if (& $prop $theme 'default') { $themeText += ", default $(& $code $theme.default)" }
        $themeEnv = & $prop $theme 'env'
        if ($themeEnv) { $themeText += '; sets ' + (($themeEnv.PSObject.Properties | ForEach-Object { "$(& $code $_.Name) = $(& $code $_.Value)" }) -join ', ') }
        if (& $prop $theme 'command') { $themeText += "; switch with $(& $code $theme.command)" }
        & $add 'Theme' $themeText
    }
    $wrapper = & $prop $Tool 'wrapper'
    if ($wrapper) {
        $wrapped = [System.IO.Path]::GetFileNameWithoutExtension($Tool.executable)
        $parts = @(foreach ($entry in @(& $prop $wrapper 'args')) {
            if ($entry -is [string]) { & $code $entry } else { "$(& $code ($entry.args -join ' ')) when $(& $code $entry.ifFile) exists" }
        })
        & $add 'Wraps' "$(& $code $wrapped) adds $($parts -join ', ')"
    }
```

- [ ] **Step 6: Run the tests**

Run: `pwsh -NoProfile -File build/Test-DFFull.ps1 -Path tests/New-DFToolWrapper.Tests.ps1, tests/Test-DFToolSchema.Tests.ps1, tests/ConvertTo-DFToolRecord.Tests.ps1, tests/Set-DFToolTheme.Tests.ps1, tests/Register-DFTool.Tests.ps1`
Expected: PASS.

- [ ] **Step 7: Commit**

```powershell
pwsh -NoProfile -File build/Build-DFCoreBundle.ps1
pwsh -NoProfile -File build/Build-DFToolRegistry.ps1
pwsh -NoProfile -File build/Build-DFReferenceDocs.ps1
git add Shared Private build/Build-DFReferenceDocs.ps1 tests Bundle/DotForge.Core.ps1 data/tool-registry.json docs/reference.md
git commit -m "feat: declarative executable wrappers (wrapper block, New-DFToolWrapper)"
```

---

### Task 10: glow declares its theme files and wrapper

**Files:**
- Modify: `Tools/glow.json`, `Tools/glow.ps1`
- Modify: `tests/glow.Tests.ps1`, `tests/Tools.CompanionPickers.Tests.ps1`
- Docs: `docs/guide/tools.md` (glow section), `CHANGELOG.md`, `docs/external-dependencies.md` (glow entry: the wrapper moved to JSON)

**Interfaces:**
- Consumes: `theme.files` (Task 5), wrapper block (Task 9), `Get-DFSessionThemeValue`.

- [ ] **Step 1: Update the tests first**

In `tests/glow.Tests.ps1`:
- `'names a theme that Resolve-DFGlowStyle can resolve without the binary'` → rename to `'defaults to a theme bundled in Tools/glow'` and read `$script:GlowJson.theme.default`; the bundled-style test reads `theme.default` too.
- Add to `Describe 'Tools/glow.json'`:

```powershell
    It 'declares its style files and the -s wrapper' {
        $script:GlowJson.theme.files | Should -Be 'glow'
        $script:GlowJson.theme.fallback | Should -Be 'auto'
        $script:GlowJson.wrapper.args | Should -Be @('-s', '{theme}')
        $script:GlowJson.PSObject.Properties['settings'] | Should -BeNullOrEmpty
    }
```

- In `Describe 'glow tool sidecar'`: delete `'registers Resolve-DFGlowStyle as a global function'`; replace every `$global:DFGlowStyle` read with `(Get-DFSessionThemeValue -Name glow)`; in `AfterEach` replace `Remove-Variable DFGlowStyle …` and `Remove-DFTestGlobal -Function 'glow', 'Resolve-DFGlowStyle'` with `Remove-DFTestGlobal -Function 'glow', 'Read-MarkdownFile'`; the unknown-theme test's expected warning becomes `"glow theme 'bogus' not recognized — falling back to 'auto'"` (use the name that test passes).

In `tests/Tools.CompanionPickers.Tests.ps1`, `Context 'fgl (glow)'`: replace `$global:DFGlowStyle = 'dracula'` with `$script:DFSessionThemes = @{ glow = [pscustomobject]@{ Value = 'dracula' } }`; drop `Resolve-DFGlowStyle` from the `Remove-DFTestGlobal` list and `DFGlowStyle` from `Remove-Variable`.

- [ ] **Step 2: Run to see them fail**

Run: `pwsh -NoProfile -File build/Test-DFFull.ps1 -Path tests/glow.Tests.ps1, tests/Tools.CompanionPickers.Tests.ps1`
Expected: FAIL.

- [ ] **Step 3: Migrate glow**

`Tools/glow.json`: delete `settings`; add after `xdg`:

```json
  "theme": {
    "key": "GlowTheme",
    "default": "catppuccin-mocha",
    "files": "glow",
    "valid": ["auto", "dark", "light", "dracula", "pink", "notty", "ascii", "tokyo-night"],
    "fallback": "auto"
  },
  "wrapper": { "args": ["-s", "{theme}"] },
```

and change `xdg.instructions`' last sentence to "Its style is passed with -s by the wrapper declared in Tools/glow.json, because GLOW_STYLE loses to glow's non-TTY downgrade."

`Tools/glow.ps1` becomes the header plus the picker:

```powershell
# Companion for glow — the fgl Markdown picker.
#
# glow's config (GLOW_CONFIG_HOME), style (theme block: GlowTheme -> Theme -> default,
# resolved to a style file in $XDG_CONFIG_HOME\glow\themes or Tools\glow, else one of
# glow's built-in names) and its -s wrapper are declared in Tools/glow.json. -s is the
# only way the style reaches glow: GLAMOUR_STYLE is never read, and GLOW_STYLE loses to
# glow's non-TTY downgrade (still true in 3.0.0). See docs/external-dependencies.md.
#
# Defines: Read-MarkdownFile (alias fgl).

# A captured scriptblock keeps its module binding, so the closure below can call it.
$_themeOf = ${function:Get-DFSessionThemeValue}
```

followed by the existing `Set-Item -Path 'function:global:Read-MarkdownFile' …` block, where `$style = if ($global:DFGlowStyle) { $global:DFGlowStyle } else { 'auto' }` becomes:

```powershell
    $style = & $_themeOf 'glow'
    if (-not $style) { $style = 'auto' }
```

and its help sentence "previews each rendered in the session's glow style ($global:DFGlowStyle)" becomes "previews each rendered in the session's glow style (Set-DFToolTheme glow <style> switches it)". Remove the old sections 1-4 entirely.

- [ ] **Step 4: Docs**

`docs/guide/tools.md`, glow block: replace `$global:DFGlowStyle = 'notty'` with `Set-DFToolTheme glow notty | Out-Null`, and note 1 with "`Set-DFToolTheme glow <style>` switches glow's style for the rest of the session." `CHANGELOG.md` `[Unreleased]` → `### Changed`:

```markdown
- **Breaking:** `Resolve-DFGlowStyle` and `$global:DFGlowStyle` are gone. Switch glow's style with
  `Set-DFToolTheme glow <style>`; the style is still set by `GlowTheme`/`Theme`.
```

Update glow's entry in `docs/external-dependencies.md` to say the `-s` wrapper is declared in `Tools/glow.json`.

- [ ] **Step 5: Run the tests**

Run: `pwsh -NoProfile -File build/Build-DFToolRegistry.ps1` then
`pwsh -NoProfile -File build/Test-DFFull.ps1 -Path tests/glow.Tests.ps1, tests/Tools.CompanionPickers.Tests.ps1, tests/New-DFToolWrapper.Tests.ps1, tests/Docs.Help.Tests.ps1, tests/Docs.Examples.Tests.ps1, tests/ToolRegistry.Tests.ps1`
Expected: PASS (the real-glow tests run only when `glow.exe` is installed).

- [ ] **Step 6: Commit**

```powershell
pwsh -NoProfile -File build/Build-DFReferenceDocs.ps1
git add Tools/glow.json Tools/glow.ps1 tests/glow.Tests.ps1 tests/Tools.CompanionPickers.Tests.ps1 docs CHANGELOG.md data/tool-registry.json
git commit -m "feat: glow declares its style files and -s wrapper"
```

---

### Task 11: fastfetch builds its wrapper through `New-DFToolWrapper`

**Files:**
- Modify: `Tools/fastfetch.json`, `Tools/fastfetch.ps1`
- Modify: `tests/fastfetch.Tests.ps1`

**Interfaces:**
- Consumes: `New-DFToolWrapper -Invoke -Description` (Task 9).

- [ ] **Step 1: Update the tests first** — add to the JSON `Describe` in `tests/fastfetch.Tests.ps1`:

```powershell
    It 'declares a custom wrapper passing --config only when the config exists' {
        $json = Get-Content "$PSScriptRoot/../Tools/fastfetch.json" -Raw | ConvertFrom-Json
        $json.wrapper.custom | Should -BeTrue
        $json.wrapper.args[0].ifFile | Should -Be '{settings.configPath}'
        $json.wrapper.args[0].args | Should -Be @('--config', '{file}')
    }
```

and a binary-free behavior test (its own `Describe`, stubbing `fastfetch.exe`):

```powershell
Describe 'fastfetch wrapper' {
    BeforeEach {
        Reset-DFTestSession; Set-DFTestXdg
        Set-Item function:global:fastfetch.exe -Value { "args=$($args -join '|')" }
        $script:Record = Get-DFTestToolRecord fastfetch
        $DFCurrentTool = $script:Record
        . "$PSScriptRoot/../Tools/fastfetch.ps1"
    }
    AfterEach { Remove-DFTestGlobal -Function 'fastfetch.exe', 'fastfetch'; Restore-DFTestXdg }

    It 'runs without --config while the config is missing' {
        fastfetch --logo none | Should -Be 'args=--logo|none'
    }
    It 'passes --config once the config exists' {
        $cfg = Join-Path $Env:XDG_CONFIG_HOME 'fastfetch' 'config.jsonc'
        New-Item -ItemType File -Path $cfg -Force | Out-Null
        fastfetch | Should -Be "args=--config|$cfg"
    }
}
```

- [ ] **Step 2: Run to see them fail**

Run: `pwsh -NoProfile -File build/Test-DFFull.ps1 -Path tests/fastfetch.Tests.ps1`
Expected: FAIL (no wrapper block).

- [ ] **Step 3: Migrate**

`Tools/fastfetch.json`, add after `settings`:

```json
  "wrapper": {
    "custom": true,
    "args": [ { "ifFile": "{settings.configPath}", "args": ["--config", "{file}"] } ]
  },
```

and change `xdg.instructions`' "Tools/fastfetch.ps1 wraps the executable" to "Its wrapper (declared in Tools/fastfetch.json, built by Tools/fastfetch.ps1) passes --config explicitly".

`Tools/fastfetch.ps1`: keep the header (update "wraps the executable so the seeded config reaches it" → "builds the fastfetch wrapper declared in Tools/fastfetch.json, adding the startup banner's placeholders"), keep `$_cfg`, `$_ffPart`, `$_ffStyleOf`, `$_ffTool`, `$_ffComplete`, and replace the whole `Set-Item -Path 'function:global:fastfetch' …` block with:

```powershell
# The --config flag comes from the wrapper block in Tools/fastfetch.json; this adds
# the banner's placeholders (@DF:publicip@, @DF:drives@), filled from the banner
# cache, and keeps colors when the output goes to the screen (fastfetch drops them
# when captured).
New-DFToolWrapper -Tool $DFCurrentTool -Description ('When the config holds @DF: placeholders (the startup banner''s ' +
    'public IP and drives), they are filled from the banner cache. If you delete the config, fastfetch runs with its own defaults.') -Invoke {
    param($exe, [string[]]$declared, [object[]]$userArgs, $invocation)
    $placeholders = $declared.Count -and (Select-String -LiteralPath $_cfg -Pattern '@DF:' -SimpleMatch -Quiet)
    if (-not $placeholders) { & $exe @declared @userArgs; return }
    $color = if ($invocation.PipelinePosition -lt $invocation.PipelineLength -or [Console]::IsOutputRedirected) { @() } else { @('--pipe', 'false') }
    $body = @(& $exe @declared @color @userArgs)
    $styleValues = try { & $_ffStyleOf ([pscustomobject]@{ Tool = $_ffTool }) } catch { @{} }
    & $_ffComplete -Body $body -StyleValues $styleValues
}.GetNewClosure()
```

- [ ] **Step 4: Run the tests**

Run: `pwsh -NoProfile -File build/Build-DFToolRegistry.ps1` then
`pwsh -NoProfile -File build/Test-DFFull.ps1 -Path tests/fastfetch.Tests.ps1, tests/fastfetch.Banner.Tests.ps1, tests/New-DFToolWrapper.Tests.ps1, tests/Docs.Help.Tests.ps1, tests/ToolRegistry.Tests.ps1`
Expected: PASS (now including the `custom` companion check from Task 9).

- [ ] **Step 5: Commit**

```powershell
pwsh -NoProfile -File build/Build-DFReferenceDocs.ps1
git add Tools/fastfetch.json Tools/fastfetch.ps1 tests/fastfetch.Tests.ps1 data/tool-registry.json docs/reference.md
git commit -m "refactor: fastfetch builds its wrapper with New-DFToolWrapper"
```

---

### Task 12: lsd gets a `--config-file` wrapper

**Files:**
- Modify: `Tools/lsd.json`, `tests/lsd.Tests.ps1`, `docs/external-dependencies.md`

- [ ] **Step 1: Probe the real lsd** (skip to Step 2 with a note in the report if `Get-Command lsd.exe` finds nothing; then leave lsd unchanged and tell the user).

Check the folders the probe could touch before and after (memory: real tools write known folders):

```powershell
$probeDir = Join-Path $Env:CLAUDE_JOB_DIR 'tmp' 'lsd-probe'
New-Item -ItemType Directory -Path $probeDir -Force | Out-Null
$before = @("$Env:APPDATA\lsd", "$HOME\.config\lsd") | ForEach-Object { "$_ exists=$(Test-Path $_)" }
lsd --version
'icons:' , '  when: never' | Set-Content (Join-Path $probeDir 'config.yaml')
New-Item -ItemType File -Path (Join-Path $probeDir 'sample.txt') -Force | Out-Null
lsd --config-file (Join-Path $probeDir 'config.yaml') $probeDir          # expect: listing, no icons
lsd --config-file (Join-Path $probeDir 'missing.yaml') $probeDir; $LASTEXITCODE   # expect: panic / non-zero (the reason for ifFile)
$after = @("$Env:APPDATA\lsd", "$HOME\.config\lsd") | ForEach-Object { "$_ exists=$(Test-Path $_)" }
Compare-Object $before $after   # must be empty; if lsd created a folder, remove only that folder
Remove-Item $probeDir -Recurse -Force
```

Record lsd's version and both results. Find lsd's own default config locations for its version from its README/`--help` (Windows: `%APPDATA%\lsd\config.yaml`; newer versions also `~/.config/lsd/config.yaml`); use what the docs for the installed version say.

- [ ] **Step 2: Write the failing test** — add to `tests/lsd.Tests.ps1`'s `Describe 'Tools/lsd.json'`:

```powershell
    It 'wraps lsd to pass --config-file only when its XDG config exists' {
        $script:LsdJson.xdg.method | Should -Be 'wrapper'
        $script:LsdJson.wrapper.args[0].ifFile | Should -Be '${XDG_CONFIG_HOME}/lsd/config.yaml'
        $script:LsdJson.wrapper.args[0].args | Should -Be @('--config-file', '{file}')
    }
```

Run: `pwsh -NoProfile -File build/Test-DFFull.ps1 -Path tests/lsd.Tests.ps1` — expected FAIL.

- [ ] **Step 3: Update `Tools/lsd.json`**

```json
  "xdg": {
    "compliance": "none",
    "method": "wrapper",
    "native": {
      "${XDG_CONFIG_HOME}/lsd/config.yaml": ["${APPDATA}/lsd/config.yaml", "${HOME}/.config/lsd/config.yaml"]
    },
    "instructions": "lsd's --config-file panics on a path that doesn't exist (verified lsd <version>), so its wrapper passes it only when $XDG_CONFIG_HOME\\lsd\\config.yaml exists."
  },
  "wrapper": {
    "args": [ { "ifFile": "${XDG_CONFIG_HOME}/lsd/config.yaml", "args": ["--config-file", "{file}"] } ]
  },
```

Fill `<version>` and the `native` list from Step 1. Add a `docs/external-dependencies.md` entry under the tools section, in the file's existing format: lsd `--config-file` panics on a missing path; DotForge's wrapper passes it only when the file exists; if lsd starts reading `XDG_CONFIG_HOME` itself, the wrapper is redundant but harmless.

- [ ] **Step 4: Run the tests**

Run: `pwsh -NoProfile -File build/Build-DFToolRegistry.ps1` then
`pwsh -NoProfile -File build/Test-DFFull.ps1 -Path tests/lsd.Tests.ps1, tests/New-DFToolWrapper.Tests.ps1, tests/ToolNative.Coverage.Tests.ps1, tests/Test-DFToolSchema.Tests.ps1, tests/ToolRegistry.Tests.ps1, tests/Activation.Ownership.Tests.ps1`
Expected: PASS (the builtin-shadow test now covers `lsd`).

- [ ] **Step 5: Commit**

```powershell
pwsh -NoProfile -File build/Build-DFReferenceDocs.ps1
git add Tools/lsd.json tests/lsd.Tests.ps1 docs/external-dependencies.md data/tool-registry.json docs/reference.md
git commit -m "feat: lsd reads its XDG config through a --config-file wrapper"
```

---

### Task 13: Docs, backlog, full run, merge

**Files:**
- Modify: `docs/guide/writing-a-tool.md`, `CLAUDE.md` (Tool JSON Schema), `TODO.md`, `CHANGELOG.md`, `docs/plugin-architecture.md` (themeMap mention, line ~117)

- [ ] **Step 1: Author docs**

`docs/guide/writing-a-tool.md` field table: replace the `themeMap` row with

```markdown
| `theme` | | The tool's theme: `{ "key": "BatTheme", "default": "catppuccin-mocha", "map": { … }, "env": { "BAT_THEME": "{theme}" } }`. Optional `files` (theme files in `Tools/<files>/` and `$XDG_CONFIG_HOME\<files>\themes`), `valid` + `fallback` (names the tool accepts, and what to use otherwise), `command` (for a theme your companion applies: the command that switches it). See below. |
| `wrapper` | | Runs the executable through a function that adds arguments: `{ "args": ["-s", "{theme}", { "ifFile": "${XDG_CONFIG_HOME}/x/config", "args": ["--config", "{file}"] }] }`. `custom: true` when your companion builds it with `New-DFToolWrapper -Invoke`. |
| `themeMap` | | Legacy: use `theme.map`. Still read when `theme.map` is absent. |
```

Under the `env` row add "A value you set outside DotForge is kept (see [Your own environment values win](configuration.md#…))" with the anchor of the section from Task 3. Replace the bullet "Read themes with `Get-DFConfiguredTheme -ToolKey …`" with:

```markdown
- Declare your theme in the record's `theme` block. If your companion applies it in code (a theme file
  it converts, an API call), read the resolved theme with `Get-DFToolTheme -Tool $DFCurrentTool`
  (`.Native` is the tool's own name, `.Value` the file or name to use) and set `theme.command`.
```

Add a `### Themes and wrappers` subsection with one bat-style and one glow-style example (copy the JSON from Tasks 7 and 10) and two sentences on precedence: per-tool key → `Theme` → `default`; an explicit per-tool key or `Set-DFToolTheme` overrides a variable set outside DotForge.

`CLAUDE.md` "Tool JSON Schema": replace the `themeMap` bullet with bullets for `theme` and `wrapper` (same content, condensed), add to the `env` bullet "written through `Set-DFEnv` (`Private/Set-DFEnv.ps1`): a value set outside DotForge is kept and noted in the tool's status; an explicit config choice overrides it with a warning", and change `xdg.method`'s `wrapper` meaning to "the `wrapper` block builds it".

`docs/plugin-architecture.md`: change the `themeMap` mention to `theme.map`.

- [ ] **Step 2: Backlog and changelog**

`TODO.md`: delete `T-21` and `T-29`; reword `T-37` to:

```markdown
- [ ] **T-37 Themes set in a tool's own config file** — a theme env var DotForge sets (`BAT_THEME`, `MDCAT_THEME`) still outranks a theme the user set in that tool's config file (bat's `config`), with no notice. Env values set outside DotForge are kept since T-21; weigh detecting the config-file case per tool.
```

`CHANGELOG.md` `[Unreleased]` → `### Added`:

```markdown
- **Declarative themes and wrappers.** A tool record can declare its theme (`theme`: config key,
  default, name map, theme files, accepted names, the variables it sets) and an executable wrapper
  (`wrapper`: arguments, ones passed only while a file exists). bat, mdcat, moor, delta and glow need
  no theme code; `Set-DFToolTheme <tool> <theme>` switches one for the session. lsd now reads
  `$XDG_CONFIG_HOME\lsd\config.yaml` when it exists.
```

- [ ] **Step 3: Regenerate and run the full gate**

```powershell
pwsh -NoProfile -File build/Build-DFCoreBundle.ps1
pwsh -NoProfile -File build/Build-DFToolRegistry.ps1
pwsh -NoProfile -File build/Build-DFReferenceDocs.ps1
pwsh -NoProfile -File build/Test-DFFull.ps1
```

Expected: exit 0, no failed containers. Fix anything red before continuing; never mark a failing test skipped to get green.

- [ ] **Step 4: Commit**

```powershell
git add -A docs CLAUDE.md TODO.md CHANGELOG.md Bundle data
git commit -m "docs: declarative tool effects (theme, wrapper, env precedence)

Closes T-21
Closes T-29"
```

- [ ] **Step 5: Merge** (standing permission after a green full run)

```powershell
git -C ../DotForge fetch
git -C ../DotForge merge --ff-only tool-effects
git -C ../DotForge push origin main
```

Then leave the worktree before removing it (`cd ../DotForge`), and remove it with `git worktree remove ../DotForge-tool-effects` and `git branch -d tool-effects` (this session created both).
