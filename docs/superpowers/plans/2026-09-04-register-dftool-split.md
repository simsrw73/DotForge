# Register-DFTool Split Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract `Register-DFTool`'s four independent per-tool responsibilities (XDG config, aliases,
picker codegen, companion dot-sourcing) into their own private functions, with zero behavior change,
so each becomes independently unit-testable instead of only reachable by driving the whole 339-line
function end-to-end.

**Architecture:** Pure extraction, not redesign. Each extracted function's body is the corresponding
block from `Register-DFTool.ps1` today, with local variables renamed to parameters and nothing else
changed — same string literals, same warnings, same edge-case handling, same order of operations.
`Register-DFTool` becomes a thin orchestrator: resolve tools → topo-sort → role resolution →
`foreach ($tool in $tools) { <availability guard>, <five short calls> }` → completion stack →
conflict check.

**Tech Stack:** PowerShell 7+, Pester 5/6 (dual-compatible per project convention).

## Global Constraints

- No `$ErrorActionPreference = 'Stop'` in any module file.
- Every extracted function gets full comment-based help (`.SYNOPSIS`/`.DESCRIPTION`/`.PARAMETER`
  for each param/`.OUTPUTS`) even though all four are private — matching the codebase's existing
  private-function convention (`Import-DFToolDb`, `Get-DFCategoryDb`, `Test-DFToolAvailable` all
  have it).
- StrictMode-safe optional-property access (`$obj.PSObject.Properties['x']?.Value`) is preserved
  verbatim from the original code — this plan does not change how any field is read.
- Tests pass under both Pester 5.8 and 6.0.1 — `Should -Invoke ... -Times N -Exactly`, never
  `Assert-MockCalled`.
- Never use `git add -A`/`git add .` — each task's commit contains only its intended files.
- **No CHANGELOG.md entry for this plan.** Every task here is a documented zero-behavior-change
  extraction verified against the full existing test suite; `CHANGELOG.md`'s `[Unreleased]` section
  logs user-visible fixes/features/changes (confirmed by reading its history), and an internal
  refactor with no external effect doesn't fit any of its three subsections. If any task turns out
  to change observable behavior, stop and treat that as a bug in the extraction, not a changelog-
  worthy feature.
- **After each task, run the full suite** (`pwsh -NoProfile -Command "Invoke-Pester tests/ -Output
  Detailed"`), not just the focused test files. `Register-DFTool` is exercised end-to-end by many
  other test files (`bat`, `delta`, `glow`, `mdcat`, `mdv`, `psreadline`, `vivid`,
  `DefaultToolRoles`, `XdgSplit`, and `Register-DFTool` itself) using real `Tools/*.json`/`.ps1`
  companions — that breadth is the actual regression safety net for a refactor of this shared
  function, more so than any single new unit test. Expect exactly **1028 passed, 10 failed** (the
  10 are `Get-DFCategoryDb.Tests.ps1`'s pre-existing fixture-isolation bug, tracked in `TODO.md`
  since 2026-09-03, unrelated to this plan). A different count or different failing tests means stop
  and report BLOCKED, not "probably fine."

---

## Task 1: Extract `Set-DFToolXdgConfig`

**Files:**
- Create: `Private/Set-DFToolXdgConfig.ps1`
- Test: `tests/Set-DFToolXdgConfig.Tests.ps1`
- Modify: `Public/Register-DFTool.ps1`

**Interfaces:**
- Consumes: `Expand-DFXdgPath`, `New-DFDirectory` (both already private/public functions this file
  can call — no new dot-sourcing needed inside the real module; test files must dot-source both).
- Produces: `Set-DFToolXdgConfig -Tool <PSCustomObject>` → `[void]`, called once per tool from
  `Register-DFTool`'s main loop.

**Background:** `Register-DFTool.ps1` currently has this block inline (lines 121-164 today):

```powershell
        # ── XDG configuration ──────────────────────────────────────────────
        $xdgProp   = $tool.PSObject.Properties['xdg']
        $xdgMethod = if ($xdgProp) { $xdgProp.Value.PSObject.Properties['method']?.Value } else { $null }
        switch ($xdgMethod) {
            'env' {
                $xdg  = $tool.xdg
                $vars = $xdg.PSObject.Properties['vars']?.Value
                if ($vars) {
                    $vars.PSObject.Properties | ForEach-Object {
                        [System.Environment]::SetEnvironmentVariable(
                            $_.Name,
                            (Expand-DFXdgPath $_.Value),
                            'Process'
                        )
                    }
                }
                $dirs = $xdg.PSObject.Properties['dirs']?.Value
                if ($dirs) {
                    @($dirs) | Where-Object { $_ } |
                        ForEach-Object { New-DFDirectory (Expand-DFXdgPath $_) }
                }
            }
            'manual' {
                $instr = if ($xdgProp) { $xdgProp.Value.PSObject.Properties['instructions']?.Value } else { $null }
                Write-Warning "DotForge: $($tool.name) requires manual XDG configuration.$(if ($instr) { " $instr" })"
            }
            'config' {
                $xdg = $tool.xdg
                $rawConfigPath    = $xdg.PSObject.Properties['config_path']?.Value
                $rawConfigContent = $xdg.PSObject.Properties['config_content']?.Value
                if ($rawConfigPath) {
                    $expandedPath = Expand-DFXdgPath $rawConfigPath
                    New-DFDirectory (Split-Path $expandedPath)
                    if (-not (Test-Path $expandedPath) -and $rawConfigContent) {
                        Set-Content -Path $expandedPath -Value $rawConfigContent -Encoding UTF8
                        Write-Verbose "DotForge: Created default config at $expandedPath"
                    }
                }
            }
            'wrapper' {
                Write-Verbose "DotForge: $($tool.name) xdg.method 'wrapper' — handled by companion .ps1"
            }
            'default' { } # tool already follows XDG natively — no env config needed
        }
```

This task moves it verbatim into its own function (renaming `$tool` → `$Tool` throughout — the only
change), and replaces it in `Register-DFTool.ps1` with a one-line call.

- [ ] **Step 1: Write the failing tests**

Create `tests/Set-DFToolXdgConfig.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/../Private/ConvertTo-DFPath.ps1"
    . "$PSScriptRoot/../Private/Expand-DFXdgPath.ps1"
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/Set-DFToolXdgConfig.ps1"
}

Describe 'Set-DFToolXdgConfig' {
    BeforeEach {
        $script:SavedConfigHome = $Env:XDG_CONFIG_HOME
        $script:SavedStateHome  = $Env:XDG_STATE_HOME
        $Env:XDG_CONFIG_HOME = Join-Path $TestDrive 'config'
        $Env:XDG_STATE_HOME  = Join-Path $TestDrive 'state'
        Remove-Item Env:\TESTXDG_CONFIG -ErrorAction Ignore
        Remove-Item Env:\TESTXDG_HIST -ErrorAction Ignore
    }
    AfterEach {
        $Env:XDG_CONFIG_HOME = $script:SavedConfigHome
        $Env:XDG_STATE_HOME  = $script:SavedStateHome
        Remove-Item Env:\TESTXDG_CONFIG -ErrorAction Ignore
        Remove-Item Env:\TESTXDG_HIST -ErrorAction Ignore
    }

    It 'method env: sets env vars and creates directories' {
        $tool = @'
{
  "name": "envtool",
  "xdg": {
    "method": "env",
    "vars": { "TESTXDG_CONFIG": "${XDG_CONFIG_HOME}/envtool/config.conf" },
    "dirs": ["${XDG_CONFIG_HOME}/envtool"]
  }
}
'@ | ConvertFrom-Json
        Set-DFToolXdgConfig -Tool $tool
        $Env:TESTXDG_CONFIG | Should -Be (Join-Path $Env:XDG_CONFIG_HOME 'envtool' 'config.conf')
        Test-Path (Join-Path $Env:XDG_CONFIG_HOME 'envtool') | Should -BeTrue
    }

    It 'method manual: warns, including instructions when present' {
        $tool = @'
{
  "name": "manualtool",
  "xdg": { "method": "manual", "instructions": "See docs/manualtool.md" }
}
'@ | ConvertFrom-Json
        Set-DFToolXdgConfig -Tool $tool -WarningVariable warns 3>$null
        $warns | Where-Object { $_ -match 'manualtool requires manual XDG configuration' -and $_ -match 'See docs/manualtool.md' } |
            Should -Not -BeNullOrEmpty
    }

    It 'method config: seeds default content only when the file is absent' {
        $tool = @'
{
  "name": "configtool",
  "xdg": {
    "method": "config",
    "config_path": "${XDG_CONFIG_HOME}/configtool/configtool.conf",
    "config_content": "default = true"
  }
}
'@ | ConvertFrom-Json
        Set-DFToolXdgConfig -Tool $tool
        $expected = Join-Path $Env:XDG_CONFIG_HOME 'configtool' 'configtool.conf'
        Get-Content $expected -Raw | Should -Be "default = true"

        Set-Content -Path $expected -Value 'user edited this' -NoNewline
        Set-DFToolXdgConfig -Tool $tool
        Get-Content $expected -Raw | Should -Be 'user edited this'
    }

    It 'method wrapper: no env/dir side effects (handled by companion)' {
        $tool = @'
{ "name": "wrappertool", "xdg": { "method": "wrapper" } }
'@ | ConvertFrom-Json
        { Set-DFToolXdgConfig -Tool $tool -Verbose } | Should -Not -Throw
    }

    It 'method default: no-op' {
        $tool = @'
{ "name": "defaulttool", "xdg": { "method": "default" } }
'@ | ConvertFrom-Json
        { Set-DFToolXdgConfig -Tool $tool } | Should -Not -Throw
    }

    It 'no xdg property at all: no-op, does not throw' {
        $tool = '{ "name": "noxdgtool" }' | ConvertFrom-Json
        { Set-DFToolXdgConfig -Tool $tool } | Should -Not -Throw
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Set-DFToolXdgConfig.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Private/Set-DFToolXdgConfig.ps1` does not exist yet, so the `BeforeAll` dot-source
throws and every test errors.

- [ ] **Step 3: Create `Private/Set-DFToolXdgConfig.ps1`**

```powershell
#Requires -Version 7.0

function Set-DFToolXdgConfig {
    <#
    .SYNOPSIS
        Applies one tool's xdg.method configuration: env vars, directories,
        a seeded config file, or a manual-instructions warning.
    .DESCRIPTION
        Reads $Tool.xdg.method and dispatches accordingly: 'env' sets env
        vars from xdg.vars and creates xdg.dirs; 'config' seeds a default
        config file only when absent (never overwrites a user's edits);
        'manual' warns with any instructions; 'wrapper' and 'default' are
        no-ops here (handled by a companion .ps1, or not needed at all).
        Extracted verbatim from Register-DFTool's per-tool loop -- no
        behavior change from the prior inline version.
    .PARAMETER Tool
        The tool record (from the tool JSON database) to configure.
    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Tool
    )

    $xdgProp   = $Tool.PSObject.Properties['xdg']
    $xdgMethod = if ($xdgProp) { $xdgProp.Value.PSObject.Properties['method']?.Value } else { $null }
    switch ($xdgMethod) {
        'env' {
            $xdg  = $Tool.xdg
            $vars = $xdg.PSObject.Properties['vars']?.Value
            if ($vars) {
                $vars.PSObject.Properties | ForEach-Object {
                    [System.Environment]::SetEnvironmentVariable(
                        $_.Name,
                        (Expand-DFXdgPath $_.Value),
                        'Process'
                    )
                }
            }
            $dirs = $xdg.PSObject.Properties['dirs']?.Value
            if ($dirs) {
                @($dirs) | Where-Object { $_ } |
                    ForEach-Object { New-DFDirectory (Expand-DFXdgPath $_) }
            }
        }
        'manual' {
            $instr = if ($xdgProp) { $xdgProp.Value.PSObject.Properties['instructions']?.Value } else { $null }
            Write-Warning "DotForge: $($Tool.name) requires manual XDG configuration.$(if ($instr) { " $instr" })"
        }
        'config' {
            $xdg = $Tool.xdg
            $rawConfigPath    = $xdg.PSObject.Properties['config_path']?.Value
            $rawConfigContent = $xdg.PSObject.Properties['config_content']?.Value
            if ($rawConfigPath) {
                $expandedPath = Expand-DFXdgPath $rawConfigPath
                New-DFDirectory (Split-Path $expandedPath)
                if (-not (Test-Path $expandedPath) -and $rawConfigContent) {
                    Set-Content -Path $expandedPath -Value $rawConfigContent -Encoding UTF8
                    Write-Verbose "DotForge: Created default config at $expandedPath"
                }
            }
        }
        'wrapper' {
            Write-Verbose "DotForge: $($Tool.name) xdg.method 'wrapper' — handled by companion .ps1"
        }
        'default' { } # tool already follows XDG natively — no env config needed
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Set-DFToolXdgConfig.Tests.ps1 -Output Detailed"`
Expected: PASS, 0 failures, all 6 tests green.

- [ ] **Step 5: Wire into `Public/Register-DFTool.ps1`**

Find:

```powershell
        # ── XDG configuration ──────────────────────────────────────────────
        $xdgProp   = $tool.PSObject.Properties['xdg']
        $xdgMethod = if ($xdgProp) { $xdgProp.Value.PSObject.Properties['method']?.Value } else { $null }
        switch ($xdgMethod) {
            'env' {
                $xdg  = $tool.xdg
                $vars = $xdg.PSObject.Properties['vars']?.Value
                if ($vars) {
                    $vars.PSObject.Properties | ForEach-Object {
                        [System.Environment]::SetEnvironmentVariable(
                            $_.Name,
                            (Expand-DFXdgPath $_.Value),
                            'Process'
                        )
                    }
                }
                $dirs = $xdg.PSObject.Properties['dirs']?.Value
                if ($dirs) {
                    @($dirs) | Where-Object { $_ } |
                        ForEach-Object { New-DFDirectory (Expand-DFXdgPath $_) }
                }
            }
            'manual' {
                $instr = if ($xdgProp) { $xdgProp.Value.PSObject.Properties['instructions']?.Value } else { $null }
                Write-Warning "DotForge: $($tool.name) requires manual XDG configuration.$(if ($instr) { " $instr" })"
            }
            'config' {
                $xdg = $tool.xdg
                $rawConfigPath    = $xdg.PSObject.Properties['config_path']?.Value
                $rawConfigContent = $xdg.PSObject.Properties['config_content']?.Value
                if ($rawConfigPath) {
                    $expandedPath = Expand-DFXdgPath $rawConfigPath
                    New-DFDirectory (Split-Path $expandedPath)
                    if (-not (Test-Path $expandedPath) -and $rawConfigContent) {
                        Set-Content -Path $expandedPath -Value $rawConfigContent -Encoding UTF8
                        Write-Verbose "DotForge: Created default config at $expandedPath"
                    }
                }
            }
            'wrapper' {
                Write-Verbose "DotForge: $($tool.name) xdg.method 'wrapper' — handled by companion .ps1"
            }
            'default' { } # tool already follows XDG natively — no env config needed
        }
```

Replace with:

```powershell
        # ── XDG configuration ──────────────────────────────────────────────
        Set-DFToolXdgConfig -Tool $tool
```

- [ ] **Step 6: Run `Register-DFTool.Tests.ps1`, then the full suite**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Register-DFTool.Tests.ps1 -Output Detailed"`
Expected: PASS, unchanged from before this task (same test count, same result).

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/ -Output Detailed"`
Expected: **1028 passed, 10 failed** (the pre-existing, unrelated `Get-DFCategoryDb` failures — see
Global Constraints). If this differs, stop and report BLOCKED.

- [ ] **Step 7: Commit**

```bash
git add Private/Set-DFToolXdgConfig.ps1 tests/Set-DFToolXdgConfig.Tests.ps1 Public/Register-DFTool.ps1
git commit -m "$(cat <<'EOF'
refactor(Register-DFTool): extract Set-DFToolXdgConfig

Pure extraction of the xdg.method switch block into its own private
function, independently unit-testable without driving the whole
Register-DFTool pipeline. No behavior change -- verified against the
full test suite (1028/10, matching the pre-existing baseline exactly).

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KjTXV8CBbqnMmRTZspmhfs
EOF
)"
```

---

## Task 2: Extract `Register-DFToolAliases`

**Files:**
- Create: `Private/Register-DFToolAliases.ps1`
- Test: `tests/Register-DFToolAliases.Tests.ps1`
- Modify: `Public/Register-DFTool.ps1`

**Interfaces:**
- Consumes: nothing new (only built-in cmdlets: `Set-Alias`, `Set-Item`, `Remove-Item`, `Test-Path`).
- Produces: `Register-DFToolAliases -Tool <PSCustomObject> -RoleWinner <object>` → `[void]`.
  `-RoleWinner` is `$null` or a hashtable shaped `@{ WinnerName = <string>; AliasKeys = <string[]> }`
  — the exact shape `Register-DFTool`'s `$activeRoleWinners[$roleName]` already produces today.

**Background:** Currently inline in `Register-DFTool.ps1` (today's lines 181-219, run *after* Task 1
lands and shifts line numbers — locate by content, not line number):

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

                if ($aliasArgs.Count -eq 0) {
                    Set-Alias -Name $aliasName -Value $aliasCmd -Scope Global -Force
                } else {
                    # A built-in alias (e.g. ls -> Get-ChildItem) outranks a
                    # function of the same name in command resolution
                    # (Alias > Function), so it would shadow the wrapper
                    # function below. Remove the colliding global alias first.
                    # -Force clears ReadOnly built-ins (cd, cp, rm, ...).
                    if (Test-Path "Alias:\$aliasName") {
                        Remove-Item "Alias:\$aliasName" -Force -ErrorAction SilentlyContinue
                    }
                    $capturedCmd  = $aliasCmd
                    $capturedArgs = $aliasArgs
                    Set-Item -Path "function:global:$aliasName" -Value {
                        & $capturedCmd @capturedArgs @args
                    }.GetNewClosure()
                }
            }
        }
```

The role-winner *lookup* (`$toolRole`/`$roleWinner` from `$activeRoleWinners`) stays in the main loop
— it depends on that loop's local `$activeRoleWinners`, which is a small, self-contained two-line
snippet not worth threading through a parameter. Only the alias-creation logic (everything from
`$aliases = ...` onward) moves into the new function, taking the already-resolved `$roleWinner` as a
parameter.

- [ ] **Step 1: Write the failing tests**

Create `tests/Register-DFToolAliases.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/../Private/Register-DFToolAliases.ps1"
}

Describe 'Register-DFToolAliases' {
    AfterEach {
        Remove-Alias testalias -Force -Scope Global -ErrorAction Ignore
        Remove-Item 'function:global:testalias-v' -ErrorAction Ignore
        Remove-Alias ls -Force -Scope Global -ErrorAction Ignore
        Remove-Item 'function:global:ls' -ErrorAction Ignore
    }

    It 'creates a zero-arg alias with Set-Alias' {
        $tool = '{ "name": "t", "aliases": { "testalias": { "command": "notepad", "args": [] } } }' | ConvertFrom-Json
        Register-DFToolAliases -Tool $tool -RoleWinner $null
        (Get-Alias testalias).Definition | Should -Be 'notepad'
    }

    It 'creates a wrapper function for an alias with args, removing a colliding builtin alias first' {
        $tool = '{ "name": "t", "aliases": { "ls": { "command": "eza", "args": ["--icons"] } } }' | ConvertFrom-Json
        Register-DFToolAliases -Tool $tool -RoleWinner $null
        Test-Path 'Alias:\ls' | Should -BeFalse
        Get-Command 'function:global:ls' | Should -Not -BeNullOrEmpty
    }

    It 'skips an alias whose key is suppressed by a different role winner' {
        $tool = '{ "name": "lsd", "role": "listing", "aliases": { "ls": { "command": "lsd", "args": [] } } }' | ConvertFrom-Json
        $roleWinner = @{ WinnerName = 'eza'; AliasKeys = @('ls') }
        Register-DFToolAliases -Tool $tool -RoleWinner $roleWinner
        (Get-Alias ls -ErrorAction Ignore) | Should -BeNullOrEmpty
    }

    It 'still applies the role winner''s own aliases (WinnerName matches Tool.name)' {
        $tool = '{ "name": "eza", "role": "listing", "aliases": { "ls": { "command": "eza", "args": [] } } }' | ConvertFrom-Json
        $roleWinner = @{ WinnerName = 'eza'; AliasKeys = @('ls') }
        Register-DFToolAliases -Tool $tool -RoleWinner $roleWinner
        (Get-Alias ls).Definition | Should -Be 'eza'
    }

    It 'does nothing when Tool has no aliases property' {
        $tool = '{ "name": "noaliastool" }' | ConvertFrom-Json
        { Register-DFToolAliases -Tool $tool -RoleWinner $null } | Should -Not -Throw
    }

    It 'skips an alias entry with no command' {
        $tool = '{ "name": "t", "aliases": { "testalias": { "args": [] } } }' | ConvertFrom-Json
        { Register-DFToolAliases -Tool $tool -RoleWinner $null } | Should -Not -Throw
        (Get-Alias testalias -ErrorAction Ignore) | Should -BeNullOrEmpty
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Register-DFToolAliases.Tests.ps1 -Output Detailed"`
Expected: FAIL — the function doesn't exist yet.

- [ ] **Step 3: Create `Private/Register-DFToolAliases.ps1`**

```powershell
#Requires -Version 7.0

function Register-DFToolAliases {
    <#
    .SYNOPSIS
        Creates one tool's declared aliases (or wrapper functions, for
        aliases that carry arguments), honoring role-loser alias suppression.
    .DESCRIPTION
        For each alias in $Tool.aliases: if $RoleWinner names a different
        tool that won this alias's role, the alias is skipped (Write-Verbose
        only -- every other alias, XDG config, and picker $Tool declares
        still applies elsewhere in Register-DFTool). Otherwise, a zero-
        argument alias becomes a plain Set-Alias; an alias with args becomes
        a global wrapper function, removing any colliding built-in alias
        first (Alias outranks Function in command resolution, so a built-in
        like `cd` would otherwise shadow the wrapper). Extracted verbatim
        from Register-DFTool's per-tool loop -- no behavior change from the
        prior inline version.
    .PARAMETER Tool
        The tool record declaring the aliases.
    .PARAMETER RoleWinner
        $null, or a hashtable @{ WinnerName; AliasKeys } naming the tool that
        won $Tool's role and which of its own alias keys are suppressed on
        every other tool sharing that role.
    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Tool,

        [object]$RoleWinner
    )

    $aliases = $Tool.PSObject.Properties['aliases']?.Value
    if (-not $aliases) { return }

    $aliases.PSObject.Properties | ForEach-Object {
        $aliasName = $_.Name

        if ($RoleWinner -and $RoleWinner.WinnerName -ne $Tool.name -and $aliasName -in $RoleWinner.AliasKeys) {
            Write-Verbose "DotForge: $($Tool.name) alias '$aliasName' suppressed — '$($RoleWinner.WinnerName)' won role '$($Tool.PSObject.Properties['role']?.Value)'"
            return
        }

        $aliasCmd  = $_.Value.PSObject.Properties['command']?.Value
        $rawArgs   = $_.Value.PSObject.Properties['args']?.Value
        $aliasArgs = [object[]]@($rawArgs)

        if (-not $aliasCmd) { return }

        if ($aliasArgs.Count -eq 0) {
            Set-Alias -Name $aliasName -Value $aliasCmd -Scope Global -Force
        } else {
            # A built-in alias (e.g. ls -> Get-ChildItem) outranks a
            # function of the same name in command resolution
            # (Alias > Function), so it would shadow the wrapper
            # function below. Remove the colliding global alias first.
            # -Force clears ReadOnly built-ins (cd, cp, rm, ...).
            if (Test-Path "Alias:\$aliasName") {
                Remove-Item "Alias:\$aliasName" -Force -ErrorAction SilentlyContinue
            }
            $capturedCmd  = $aliasCmd
            $capturedArgs = $aliasArgs
            Set-Item -Path "function:global:$aliasName" -Value {
                & $capturedCmd @capturedArgs @args
            }.GetNewClosure()
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Register-DFToolAliases.Tests.ps1 -Output Detailed"`
Expected: PASS, 0 failures, all 6 tests green.

- [ ] **Step 5: Wire into `Public/Register-DFTool.ps1`**

Find:

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

                if ($aliasArgs.Count -eq 0) {
                    Set-Alias -Name $aliasName -Value $aliasCmd -Scope Global -Force
                } else {
                    # A built-in alias (e.g. ls -> Get-ChildItem) outranks a
                    # function of the same name in command resolution
                    # (Alias > Function), so it would shadow the wrapper
                    # function below. Remove the colliding global alias first.
                    # -Force clears ReadOnly built-ins (cd, cp, rm, ...).
                    if (Test-Path "Alias:\$aliasName") {
                        Remove-Item "Alias:\$aliasName" -Force -ErrorAction SilentlyContinue
                    }
                    $capturedCmd  = $aliasCmd
                    $capturedArgs = $aliasArgs
                    Set-Item -Path "function:global:$aliasName" -Value {
                        & $capturedCmd @capturedArgs @args
                    }.GetNewClosure()
                }
            }
        }
```

Replace with:

```powershell
        # ── Aliases ─────────────────────────────────────────────────────────
        $toolRole   = $tool.PSObject.Properties['role']?.Value
        $roleWinner = if ($toolRole) { $activeRoleWinners[$toolRole] } else { $null }
        Register-DFToolAliases -Tool $tool -RoleWinner $roleWinner
```

- [ ] **Step 6: Run `Register-DFTool.Tests.ps1`, then the full suite**

Same two commands and expected results as Task 1, Step 6.

- [ ] **Step 7: Commit**

```bash
git add Private/Register-DFToolAliases.ps1 tests/Register-DFToolAliases.Tests.ps1 Public/Register-DFTool.ps1
git commit -m "$(cat <<'EOF'
refactor(Register-DFTool): extract Register-DFToolAliases

Pure extraction of the alias/wrapper-function creation block into its
own private function. No behavior change -- verified against the full
test suite (1028/10, matching the pre-existing baseline exactly).

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KjTXV8CBbqnMmRTZspmhfs
EOF
)"
```

---

## Task 3: Extract `New-DFToolPickerFunction`

**Files:**
- Create: `Private/New-DFToolPickerFunction.ps1`
- Test: `tests/New-DFToolPickerFunction.Tests.ps1`
- Modify: `Public/Register-DFTool.ps1`

**Interfaces:**
- Consumes: `Invoke-DFPicker` (public function; must be dot-sourced in tests, already loaded in the
  real module).
- Produces: `New-DFToolPickerFunction -Tool <PSCustomObject>` → `[void]`. Installs a global function
  (named `$Tool.picker.function`) and, if declared, a global alias pointing at it.

**Background:** This is the densest block (today's lines 222-282) and the one the audit flagged as
having the thinnest test coverage relative to its complexity — extraction makes it possible to test
picker codegen directly against picker declarations, without needing a real `Tools/` directory or a
real `Get-Command` probe.

Currently inline:

```powershell
        # ── Declarative picker ──────────────────────────────────────────────
        $picker = $tool.PSObject.Properties['picker']?.Value
        if ($picker -and $picker -is [PSCustomObject]) {
            $pAlias    = $picker.PSObject.Properties['alias']?.Value
            $pFunction = $picker.PSObject.Properties['function']?.Value
            $pList     = $picker.PSObject.Properties['list']?.Value
            $pPreview  = $picker.PSObject.Properties['preview']?.Value ?? ''
            $pWindow   = $picker.PSObject.Properties['preview_window']?.Value ?? 'right:60%'
            $pAnsi     = [bool]($picker.PSObject.Properties['ansi']?.Value)
            $pHeader   = $picker.PSObject.Properties['header']?.Value ?? ''
            $pAction   = $picker.PSObject.Properties['action']?.Value
            $pParse    = $picker.PSObject.Properties['parse']?.Value
            $pAccPath  = [bool]($picker.PSObject.Properties['list_accepts_path']?.Value)

            if ($pFunction -and $pList) {
                $capturedList    = $pList
                $capturedPreview = $pPreview
                $capturedWindow  = $pWindow
                $capturedAnsi    = $pAnsi
                $capturedHeader  = $pHeader
                $capturedAction  = if ($pAction -and $pAction -ne 'output') {
                    [scriptblock]::Create("param(`$v) " + $pAction.Replace('{}', '$v'))
                } else { $null }
                $capturedParse   = if ($pParse) {
                    [scriptblock]::Create($pParse)
                } else { $null }

                $fn = if ($pAccPath) {
                    $capturedParts = @($capturedList -split '\s+')
                    {
                        [CmdletBinding()]
                        param([string]$Path = '.')
                        Invoke-DFPicker `
                            -List          { & $capturedParts[0] @($capturedParts[1..($capturedParts.Count - 1)]) $Path } `
                            -Preview       $capturedPreview `
                            -PreviewWindow $capturedWindow `
                            -Ansi:$capturedAnsi `
                            -Header        $capturedHeader `
                            -Parse         $capturedParse `
                            -Action        $capturedAction
                    }.GetNewClosure()
                } else {
                    {
                        [CmdletBinding()]
                        param()
                        Invoke-DFPicker `
                            -List          ([scriptblock]::Create($capturedList)) `
                            -Preview       $capturedPreview `
                            -PreviewWindow $capturedWindow `
                            -Ansi:$capturedAnsi `
                            -Header        $capturedHeader `
                            -Parse         $capturedParse `
                            -Action        $capturedAction
                    }.GetNewClosure()
                }

                Set-Item -Path "function:global:$pFunction" -Value $fn
                if ($pAlias) {
                    Set-Alias -Name $pAlias -Value $pFunction -Scope Global -Force
                }
            }
        }
```

- [ ] **Step 1: Write the failing tests**

Create `tests/New-DFToolPickerFunction.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/../Private/Invoke-DFFzf.ps1"
    . "$PSScriptRoot/../Public/Invoke-DFPicker.ps1"
    . "$PSScriptRoot/../Private/New-DFToolPickerFunction.ps1"
}

Describe 'New-DFToolPickerFunction' {
    AfterEach {
        Remove-Item 'function:global:Select-TestThing' -ErrorAction Ignore
        Remove-Alias ftt -Force -Scope Global -ErrorAction Ignore
        Remove-Item 'function:global:Select-TestPathThing' -ErrorAction Ignore
    }

    It 'installs a global function and alias for a simple picker' {
        $tool = @'
{
  "name": "t",
  "picker": {
    "alias": "ftt",
    "function": "Select-TestThing",
    "list": "echo one",
    "header": "pick one",
    "action": "output"
  }
}
'@ | ConvertFrom-Json
        New-DFToolPickerFunction -Tool $tool
        Get-Command 'function:global:Select-TestThing' | Should -Not -BeNullOrEmpty
        (Get-Alias ftt).Definition | Should -Be 'Select-TestThing'
    }

    It 'does not create an alias when picker.alias is absent' {
        $tool = @'
{ "name": "t", "picker": { "function": "Select-TestThing", "list": "echo one" } }
'@ | ConvertFrom-Json
        New-DFToolPickerFunction -Tool $tool
        Get-Command 'function:global:Select-TestThing' | Should -Not -BeNullOrEmpty
    }

    It 'does nothing when Tool has no picker' {
        $tool = '{ "name": "nopicker" }' | ConvertFrom-Json
        { New-DFToolPickerFunction -Tool $tool } | Should -Not -Throw
    }

    It 'does nothing when picker is explicitly null' {
        $tool = '{ "name": "nullpicker", "picker": null }' | ConvertFrom-Json
        { New-DFToolPickerFunction -Tool $tool } | Should -Not -Throw
    }

    It 'does nothing when picker lacks function or list' {
        $tool = '{ "name": "t", "picker": { "alias": "ftt" } }' | ConvertFrom-Json
        New-DFToolPickerFunction -Tool $tool
        (Get-Alias ftt -ErrorAction Ignore) | Should -BeNullOrEmpty
    }

    It 'generates a -Path-accepting function when list_accepts_path is true' {
        $tool = @'
{
  "name": "t",
  "picker": {
    "function": "Select-TestPathThing",
    "list": "eza --icons -1",
    "list_accepts_path": true,
    "action": "output"
  }
}
'@ | ConvertFrom-Json
        New-DFToolPickerFunction -Tool $tool
        $cmd = Get-Command 'function:global:Select-TestPathThing'
        $cmd.Parameters.ContainsKey('Path') | Should -BeTrue
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/New-DFToolPickerFunction.Tests.ps1 -Output Detailed"`
Expected: FAIL — the function doesn't exist yet.

- [ ] **Step 3: Create `Private/New-DFToolPickerFunction.ps1`**

```powershell
#Requires -Version 7.0

function New-DFToolPickerFunction {
    <#
    .SYNOPSIS
        Builds and installs one tool's declarative fzf picker as a global
        function (and alias, if declared).
    .DESCRIPTION
        Reads $Tool.picker (list/preview/header/action/parse/etc., all plain
        strings per the JSON schema) and assembles an Invoke-DFPicker call as
        a global function via [scriptblock]::Create and .GetNewClosure(). When
        picker.list_accepts_path is true, the generated function instead
        takes a -Path parameter and splits the list command on whitespace to
        append it (existing behavior, including its known limitation with
        quoted arguments -- unchanged by this extraction; see TODO.md). No-ops
        when $Tool has no picker, or the picker lacks a function/list pair.
        Extracted verbatim from Register-DFTool's per-tool loop -- no
        behavior change from the prior inline version.
    .PARAMETER Tool
        The tool record declaring the picker.
    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Tool
    )

    $picker = $Tool.PSObject.Properties['picker']?.Value
    if (-not $picker -or $picker -isnot [PSCustomObject]) { return }

    $pAlias    = $picker.PSObject.Properties['alias']?.Value
    $pFunction = $picker.PSObject.Properties['function']?.Value
    $pList     = $picker.PSObject.Properties['list']?.Value
    $pPreview  = $picker.PSObject.Properties['preview']?.Value ?? ''
    $pWindow   = $picker.PSObject.Properties['preview_window']?.Value ?? 'right:60%'
    $pAnsi     = [bool]($picker.PSObject.Properties['ansi']?.Value)
    $pHeader   = $picker.PSObject.Properties['header']?.Value ?? ''
    $pAction   = $picker.PSObject.Properties['action']?.Value
    $pParse    = $picker.PSObject.Properties['parse']?.Value
    $pAccPath  = [bool]($picker.PSObject.Properties['list_accepts_path']?.Value)

    if (-not ($pFunction -and $pList)) { return }

    $capturedList    = $pList
    $capturedPreview = $pPreview
    $capturedWindow  = $pWindow
    $capturedAnsi    = $pAnsi
    $capturedHeader  = $pHeader
    $capturedAction  = if ($pAction -and $pAction -ne 'output') {
        [scriptblock]::Create("param(`$v) " + $pAction.Replace('{}', '$v'))
    } else { $null }
    $capturedParse   = if ($pParse) {
        [scriptblock]::Create($pParse)
    } else { $null }

    $fn = if ($pAccPath) {
        $capturedParts = @($capturedList -split '\s+')
        {
            [CmdletBinding()]
            param([string]$Path = '.')
            Invoke-DFPicker `
                -List          { & $capturedParts[0] @($capturedParts[1..($capturedParts.Count - 1)]) $Path } `
                -Preview       $capturedPreview `
                -PreviewWindow $capturedWindow `
                -Ansi:$capturedAnsi `
                -Header        $capturedHeader `
                -Parse         $capturedParse `
                -Action        $capturedAction
        }.GetNewClosure()
    } else {
        {
            [CmdletBinding()]
            param()
            Invoke-DFPicker `
                -List          ([scriptblock]::Create($capturedList)) `
                -Preview       $capturedPreview `
                -PreviewWindow $capturedWindow `
                -Ansi:$capturedAnsi `
                -Header        $capturedHeader `
                -Parse         $capturedParse `
                -Action        $capturedAction
        }.GetNewClosure()
    }

    Set-Item -Path "function:global:$pFunction" -Value $fn
    if ($pAlias) {
        Set-Alias -Name $pAlias -Value $pFunction -Scope Global -Force
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/New-DFToolPickerFunction.Tests.ps1 -Output Detailed"`
Expected: PASS, 0 failures, all 6 tests green.

- [ ] **Step 5: Wire into `Public/Register-DFTool.ps1`**

Find the entire block shown in this task's Background section (from `# ── Declarative picker
──...` through the closing `}` of the outer `if ($picker -and $picker -is [PSCustomObject])`).
Replace with:

```powershell
        # ── Declarative picker ──────────────────────────────────────────────
        New-DFToolPickerFunction -Tool $tool
```

- [ ] **Step 6: Run `Register-DFTool.Tests.ps1`, then the full suite**

Same two commands and expected results as Task 1, Step 6.

- [ ] **Step 7: Commit**

```bash
git add Private/New-DFToolPickerFunction.ps1 tests/New-DFToolPickerFunction.Tests.ps1 Public/Register-DFTool.ps1
git commit -m "$(cat <<'EOF'
refactor(Register-DFTool): extract New-DFToolPickerFunction

Pure extraction of the picker-codegen block into its own private
function, now unit-testable directly against a picker declaration
without a real Tools/ directory or Get-Command probe. No behavior
change -- verified against the full test suite (1028/10, matching the
pre-existing baseline exactly).

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KjTXV8CBbqnMmRTZspmhfs
EOF
)"
```

---

## Task 4: Extract `Invoke-DFToolCompanion`

**Files:**
- Create: `Private/Invoke-DFToolCompanion.ps1`
- Test: `tests/Invoke-DFToolCompanion.Tests.ps1`
- Modify: `Public/Register-DFTool.ps1`

**Interfaces:**
- Consumes: `Get-DFToolSetupState` (existing private function, already loaded module-wide; test
  file must dot-source it).
- Produces: `Invoke-DFToolCompanion -Tool <PSCustomObject> -ToolsPath <string> [-SkipSetup
  <string[]>]` → `[void]`. Sets `$DFCurrentTool` around each dot-source, exactly as
  `Register-DFTool` does today.

**Background:** Currently inline (today's lines 284-310):

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
```

**Important — the `$DFCurrentTool` sidecar contract (`CLAUDE.md`) must survive this move.**
Dot-sourcing (`. (...)`) runs the sourced script directly in the *calling function's own scope* —
it does not create a child scope. So as long as `Invoke-DFToolCompanion` itself sets
`$DFCurrentTool = $Tool` immediately before its own `. ($companion)`/`. ($setupCompanion)` calls
(exactly as `Register-DFTool` does today), any companion reading `$DFCurrentTool` sees it correctly
— the contract only ever required "set immediately before dot-sourcing, clear immediately after,"
never that it happen inside `Register-DFTool` specifically. This task also moves the
`[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments',
'DFCurrentTool')]` attribute from `Register-DFTool` (where `$DFCurrentTool` will no longer be
declared once this task lands) to `Invoke-DFToolCompanion` (where it now is).

- [ ] **Step 1: Write the failing tests**

Create `tests/Invoke-DFToolCompanion.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/../Private/Get-DFToolSetupState.ps1"
    . "$PSScriptRoot/../Public/Complete-DFToolSetup.ps1"
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/Invoke-DFToolCompanion.ps1"
}

Describe 'Invoke-DFToolCompanion' {
    BeforeEach {
        $script:TmpTools = Join-Path $TestDrive 'tools'
        New-Item -ItemType Directory -Force -Path $script:TmpTools | Out-Null
        $script:SavedStateHome = $Env:XDG_STATE_HOME
        $Env:XDG_STATE_HOME = Join-Path $TestDrive 'state'
    }
    AfterEach {
        $Env:XDG_STATE_HOME = $script:SavedStateHome
        Remove-Variable -Name CompanionSawCurrentTool -Scope Global -ErrorAction Ignore
    }

    It 'dot-sources the regular companion, exposing $DFCurrentTool to it' {
        '$global:CompanionSawCurrentTool = $DFCurrentTool.name' |
            Set-Content (Join-Path $script:TmpTools 'companiontool.ps1')
        $tool = '{ "name": "companiontool" }' | ConvertFrom-Json
        Invoke-DFToolCompanion -Tool $tool -ToolsPath $script:TmpTools
        $global:CompanionSawCurrentTool | Should -Be 'companiontool'
    }

    It 'clears $DFCurrentTool after the regular companion runs' {
        'Set-Content (Join-Path $TestDrive "marker.txt") -Value "ran"' |
            Set-Content (Join-Path $script:TmpTools 'nodfcurrenttool.ps1')
        $tool = '{ "name": "nodfcurrenttool" }' | ConvertFrom-Json
        Invoke-DFToolCompanion -Tool $tool -ToolsPath $script:TmpTools
        Get-Variable -Name DFCurrentTool -Scope Global -ErrorAction Ignore | Should -BeNullOrEmpty
    }

    It 'does nothing when no companion .ps1 exists' {
        $tool = '{ "name": "nocompaniontool" }' | ConvertFrom-Json
        { Invoke-DFToolCompanion -Tool $tool -ToolsPath $script:TmpTools } | Should -Not -Throw
    }

    It 'runs the one-time setup companion and it can call Complete-DFToolSetup' {
        'Complete-DFToolSetup -Name $DFCurrentTool.name' |
            Set-Content (Join-Path $script:TmpTools 'setuptool.setup.ps1')
        $tool = '{ "name": "setuptool" }' | ConvertFrom-Json
        Invoke-DFToolCompanion -Tool $tool -ToolsPath $script:TmpTools
        (Get-DFToolSetupState).PSObject.Properties['setuptool'] | Should -Not -BeNullOrEmpty
    }

    It 'does not re-run one-time setup on a second call' {
        $runCountFile = Join-Path $TestDrive 'runcount.txt'
        # Double-quoted here-string interpolates $runCountFile now, but the backtick
        # keeps `$DFCurrentTool` literal -- it must only be evaluated later, when
        # Invoke-DFToolCompanion dot-sources this generated file.
        @"
'x' | Add-Content -Path '$runCountFile'
Complete-DFToolSetup -Name `$DFCurrentTool.name
"@ | Set-Content (Join-Path $script:TmpTools 'oncetool.setup.ps1')
        $tool = '{ "name": "oncetool" }' | ConvertFrom-Json
        Invoke-DFToolCompanion -Tool $tool -ToolsPath $script:TmpTools
        Invoke-DFToolCompanion -Tool $tool -ToolsPath $script:TmpTools
        (Get-Content $runCountFile).Count | Should -Be 1
    }

    It 'skips one-time setup when the tool is in -SkipSetup' {
        'Complete-DFToolSetup -Name $DFCurrentTool.name' |
            Set-Content (Join-Path $script:TmpTools 'skippedtool.setup.ps1')
        $tool = '{ "name": "skippedtool" }' | ConvertFrom-Json
        Invoke-DFToolCompanion -Tool $tool -ToolsPath $script:TmpTools -SkipSetup @('skippedtool')
        (Get-DFToolSetupState).PSObject.Properties['skippedtool'] | Should -BeNullOrEmpty
    }

    It 'warns and continues when the one-time setup script throws' {
        'throw "boom"' | Set-Content (Join-Path $script:TmpTools 'throwtool.setup.ps1')
        $tool = '{ "name": "throwtool" }' | ConvertFrom-Json
        { Invoke-DFToolCompanion -Tool $tool -ToolsPath $script:TmpTools -WarningVariable warns 3>$null } |
            Should -Not -Throw
        (Get-DFToolSetupState).PSObject.Properties['throwtool'] | Should -BeNullOrEmpty
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Invoke-DFToolCompanion.Tests.ps1 -Output Detailed"`
Expected: FAIL — the function doesn't exist yet.

- [ ] **Step 3: Create `Private/Invoke-DFToolCompanion.ps1`**

```powershell
#Requires -Version 7.0

function Invoke-DFToolCompanion {
    # $DFCurrentTool is set before dot-sourcing companions so sidecars can
    # read it. PSScriptAnalyzer can't see the companion scope, so suppress
    # the false positive.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'DFCurrentTool')]
    <#
    .SYNOPSIS
        Dot-sources a tool's companion Tools/<name>.ps1 (if present) and its
        one-time Tools/<name>.setup.ps1 (if present, not yet run, and not
        skipped), setting $DFCurrentTool around each.
    .DESCRIPTION
        The regular companion runs every Register-DFTool call. The setup
        companion runs at most once ever per tool -- see
        docs/superpowers/specs/2026-09-04-tool-setup-lifecycle-design.md --
        and is responsible for calling Complete-DFToolSetup itself on
        success; a thrown error here is caught and warned so the next
        Register-DFTool call retries it. Dot-sourcing runs the companion
        directly in this function's own scope (not a child scope), so
        $DFCurrentTool set here immediately before each dot-source is what
        the companion sees -- the sidecar contract only requires "set
        immediately before, cleared immediately after," not that it happen
        inside Register-DFTool specifically. Extracted verbatim from
        Register-DFTool's per-tool loop -- no behavior change from the prior
        inline version.
    .PARAMETER Tool
        The tool record whose companion(s) to run.
    .PARAMETER ToolsPath
        The resolved Tools/ directory to look for companions in.
    .PARAMETER SkipSetup
        Tool names ($DFConfig['SkipSetup']) whose one-time setup companion
        must never run.
    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Tool,

        [Parameter(Mandatory)]
        [string]$ToolsPath,

        [string[]]$SkipSetup = @()
    )

    $companion = Join-Path $ToolsPath "$($Tool.name).ps1"
    if (Test-Path $companion -PathType Leaf) {
        $DFCurrentTool = $Tool
        . ($companion)
        Remove-Variable -Name DFCurrentTool -ErrorAction Ignore
    }

    $setupCompanion = Join-Path $ToolsPath "$($Tool.name).setup.ps1"
    if ((Test-Path $setupCompanion -PathType Leaf) -and
        $Tool.name -notin $SkipSetup -and
        -not (Get-DFToolSetupState).PSObject.Properties[$Tool.name]) {
        $DFCurrentTool = $Tool
        try {
            . ($setupCompanion)
        } catch {
            Write-Warning "DotForge: $($Tool.name) one-time setup failed: $($_.Exception.Message)"
        }
        Remove-Variable -Name DFCurrentTool -ErrorAction Ignore
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Invoke-DFToolCompanion.Tests.ps1 -Output Detailed"`
Expected: PASS, 0 failures, all 7 tests green.

- [ ] **Step 5: Wire into `Public/Register-DFTool.ps1`**

First, remove the now-unnecessary suppression attribute from `Register-DFTool` itself. Find:

```powershell
function Register-DFTool {
    # $DFCurrentTool is set before dot-sourcing companions so sidecars can read it.
    # PSScriptAnalyzer can't see the companion scope, so suppress the false positive.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'DFCurrentTool')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'DFToolDb')]
```

Replace with:

```powershell
function Register-DFTool {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'DFToolDb')]
```

Then find the companion + one-time setup block shown in this task's Background section (from
`# ── Companion .ps1 ──...` through the final `Remove-Variable -Name DFCurrentTool -ErrorAction
Ignore` of the one-time-setup block). Replace with:

```powershell
        # ── Companion .ps1 + one-time setup ─────────────────────────────────
        Invoke-DFToolCompanion -Tool $tool -ToolsPath $resolvedToolsPath -SkipSetup $skipSetup
```

- [ ] **Step 6: Run `Register-DFTool.Tests.ps1`, then the full suite**

Same two commands and expected results as Task 1, Step 6. This is the task most likely to surface a
real regression if one exists (it's the only one touching the `$DFCurrentTool` contract), so treat
any full-suite deviation here as a hard stop, not a "probably a flake."

- [ ] **Step 7: Commit**

```bash
git add Private/Invoke-DFToolCompanion.ps1 tests/Invoke-DFToolCompanion.Tests.ps1 Public/Register-DFTool.ps1
git commit -m "$(cat <<'EOF'
refactor(Register-DFTool): extract Invoke-DFToolCompanion

Pure extraction of the companion-.ps1 and one-time-setup dot-sourcing
into its own private function, which now owns the $DFCurrentTool
sidecar contract directly (dot-sourcing runs in the calling function's
own scope, so the contract only ever required "set immediately before,
clear immediately after" -- not that it happen inside Register-DFTool
specifically). No behavior change -- verified against the full test
suite (1028/10, matching the pre-existing baseline exactly).

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KjTXV8CBbqnMmRTZspmhfs
EOF
)"
```

---

## Task 5: Final verification and cleanup

**Files:**
- Modify: none (verification-only), unless Step 2 finds a real cleanup opportunity (see below)

**Interfaces:** none — this task produces no new interface, it confirms the prior four hold together.

- [ ] **Step 1: Confirm `Register-DFTool.ps1`'s shape**

Run: `wc -l Public/Register-DFTool.ps1`
Expected: roughly 170-190 lines, down from 339 before this plan (the orchestrator now holds: param
block + help, tool resolution, topo-sort, role-winner resolution, and a per-tool loop of an
availability guard plus five short calls/blocks: `Set-DFToolXdgConfig`, the small inline non-XDG
`env` block, `Register-DFToolAliases`, `New-DFToolPickerFunction`, `Invoke-DFToolCompanion`).

Read the file and confirm by eye: no leftover dead code, no orphaned variables from the extracted
blocks (e.g. `$xdgProp`, `$pAlias`, `$capturedCmd` should no longer appear anywhere in
`Register-DFTool.ps1` — they only exist inside the new private functions now).

- [ ] **Step 2: Run the full suite one final time**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/ -Output Detailed"`
Expected: **1028 passed, 10 failed** (same pre-existing, unrelated `Get-DFCategoryDb` failures).

- [ ] **Step 3: Confirm `Get-Help` still renders correctly for the public function**

Run: `pwsh -NoProfile -Command "Import-Module ./DotForge.psd1 -Force; Get-Help Register-DFTool -Full"`
Expected: renders cleanly with `.SYNOPSIS`/`.DESCRIPTION`/`.PARAMETER`/`.EXAMPLE`/`.OUTPUTS` all
present and unchanged from before this plan (this plan never touched `Register-DFTool`'s own
comment-based help block, only the code beneath it) — confirms `CLAUDE.md`'s "Before Commiting"
comment-help requirement still holds after the extraction.

- [ ] **Step 4: No commit for this task**

This task is verification-only. If Step 1 or Step 2 finds something to fix, that fix belongs in the
task whose extraction caused it (re-open that task, don't patch it here) — report back to the
controller rather than committing an ad hoc fix under this task's name.
