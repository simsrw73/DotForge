# Pager Tools Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add moor and ov to the `pager` role, make less resolve to the native Windows build, and take bat out of the role.

**Architecture:** One generic core addition: an `executableExclude` tool field and a `${DF_TOOL_EXE}` token in role `env` values, resolved by a new `Resolve-DFToolExecutable`. `Invoke-DFPagerExe` learns quoted program paths. Everything else lives in tool plugins.

**Tech Stack:** PowerShell 7+, Pester 6.

**Spec:** `docs/superpowers/specs/2026-10-05-pager-tools-design.md`.

## Global Constraints

- Follow CLAUDE.md: `DF` prefix, `Get-DFConfig`, `ConvertTo-DFPath`, no tool names in core, contract test passes.
- `Resolve-DFToolExecutable` runs at registration only for a won role whose `env` uses the token. No extra startup work otherwise.
- Tests isolate XDG folders and restore any env var they set. Run Pester with `pwsh -NoProfile -NonInteractive`; run the full suite alone.
- One signed commit at the end. Never install software or change PATH/`TERM` on the machine.

## Review Focus

1. **Only Git's MSYS less installed:** `PAGER` must be the bare `less`, with no warning. (Task 1 test.)
2. **A resolved path with spaces** (`C:/Program Files/...`) must be quoted, and DotForge's own pager must still run it. (Tasks 1–2 tests.)
3. **User already set `MOOR`:** left untouched. (Task 3 test.)
4. **Re-registration:** `${DF_TOOL_EXE}` expands to the same value, so `Set-DFRoleEnv` treats it as DotForge's own and doesn't warn. (Covered by the precedence tests; check the real-machine run shows no conflict warning.)
5. **bat with no pager role:** the bat records and tests still pass, and the contract test is green.

---

### Task 1: `executableExclude`, `Resolve-DFToolExecutable`, `${DF_TOOL_EXE}`

**Files:** Modify `Private/Import-DFToolDb.ps1` (record default `executableExclude = @()`), `Private/Test-DFToolSchema.ps1`, `Private/Register-DFToolSteps.ps1` (`Invoke-DFToolRegistration`). Create `Private/Resolve-DFToolExecutable.ps1`. Test: `tests/Resolve-DFToolExecutable.Tests.ps1`, `tests/Roles.Registration.Tests.ps1`, `tests/Test-DFToolSchema.Tests.ps1`, `tests/ConvertTo-DFToolRecord.Tests.ps1`. Add the new private file to the `BeforeAll` dot-sources of every test that dot-sources `Register-DFToolSteps.ps1`.

**Interfaces:**
- `Resolve-DFToolExecutable -Tool <pscustomobject>` → `[string]` full path, or `$null`.
- `ConvertTo-DFToolExePathToken -Tool <pscustomobject>` → `[string]` value for `${DF_TOOL_EXE}`: forward-slashed path, double-quoted when it contains a space, or the executable name without `.exe` when the resolver returns `$null`.

- [ ] **Step 1: Failing tests** — `tests/Resolve-DFToolExecutable.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/../Private/ConvertTo-DFPath.ps1"
    . "$PSScriptRoot/../Private/Resolve-DFToolExecutable.ps1"
}

Describe 'Resolve-DFToolExecutable' {
    BeforeEach {
        $script:Hits = @()
        Mock Get-Command { $script:Hits | ForEach-Object { [pscustomobject]@{ Source = $_ } } }
    }

    It 'returns the first resolved path that no exclude pattern matches' {
        $script:Hits = @('C:\Program Files\Git\usr\bin\less.exe', 'C:\Users\x\scoop\shims\less.exe')
        $tool = [pscustomobject]@{ executable = 'less.exe'; executableExclude = @('*\Git\usr\bin\*') }
        Resolve-DFToolExecutable -Tool $tool | Should -Be 'C:\Users\x\scoop\shims\less.exe'
    }

    It 'matches exclude patterns case-insensitively' {
        $script:Hits = @('C:\program files\git\USR\BIN\less.exe')
        $tool = [pscustomobject]@{ executable = 'less.exe'; executableExclude = @('*\Git\usr\bin\*') }
        Resolve-DFToolExecutable -Tool $tool | Should -BeNullOrEmpty
    }

    It 'returns the first hit when the tool excludes nothing' {
        $script:Hits = @('C:\a\less.exe', 'C:\b\less.exe')
        Resolve-DFToolExecutable -Tool ([pscustomobject]@{ executable = 'less.exe'; executableExclude = @() }) | Should -Be 'C:\a\less.exe'
    }
}

Describe 'ConvertTo-DFToolExePathToken' {
    It 'uses forward slashes' {
        Mock Resolve-DFToolExecutable { 'C:\Users\x\scoop\shims\less.exe' }
        ConvertTo-DFToolExePathToken -Tool ([pscustomobject]@{ executable = 'less.exe' }) | Should -Be 'C:/Users/x/scoop/shims/less.exe'
    }

    It 'quotes a path that contains a space' {
        Mock Resolve-DFToolExecutable { 'C:\Program Files\less\less.exe' }
        ConvertTo-DFToolExePathToken -Tool ([pscustomobject]@{ executable = 'less.exe' }) | Should -Be '"C:/Program Files/less/less.exe"'
    }

    It 'falls back to the bare name when nothing qualifies' {
        Mock Resolve-DFToolExecutable { $null }
        ConvertTo-DFToolExePathToken -Tool ([pscustomobject]@{ executable = 'less.exe' }) | Should -Be 'less'
    }
}
```

Add to `tests/Roles.Registration.Tests.ps1`, inside the existing Describe:

```powershell
    It 'expands ${DF_TOOL_EXE} in a won role''s env to the resolved path' {
        Write-Tool 'exetool' '{ "name": "exetool", "executable": "exetool.exe", "roles": { "tpager": { "priority": 99, "env": { "DF_T_PAGER": "${DF_TOOL_EXE}" } } } }'
        Mock Resolve-DFToolExecutable { 'C:\Tools\exetool.exe' }
        Register-DFTool -Name exetool -ToolsPath $script:Tools
        $Env:DF_T_PAGER | Should -Be 'C:/Tools/exetool.exe'
    }
```

`tests/Test-DFToolSchema.Tests.ps1`: rejects `"executableExclude": "x"` (not an array). `tests/ConvertTo-DFToolRecord.Tests.ps1`: `executableExclude` defaults to an empty array, and joins the StrictMode field list. That test checks it's empty with `@($r.executableExclude).Count | Should -Be 0`, so add it to the explicit checks rather than the null-loop.

- [ ] **Step 2: Run and confirm red.**

- [ ] **Step 3: Implement.** `Private/Resolve-DFToolExecutable.ps1`:

```powershell
#Requires -Version 7.0

function Resolve-DFToolExecutable {
    <#
    .SYNOPSIS
        Returns the full path of a tool's executable, skipping copies its executableExclude patterns rule out.
    .DESCRIPTION
        Walks Get-Command <executable> -All (PATH order) and returns the first path
        that matches none of the tool's executableExclude globs (case-insensitive),
        or $null when none qualifies. Used only to expand ${DF_TOOL_EXE}; tool
        detection (Test-DFToolAvailable) ignores the exclusions.
    .PARAMETER Tool
        The normalized tool record.
    .OUTPUTS
        System.String, or nothing.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][pscustomobject]$Tool)
    $exclude = @($Tool.PSObject.Properties['executableExclude']?.Value)
    foreach ($cmd in @(Get-Command $Tool.executable -All -CommandType Application -ErrorAction Ignore)) {
        $path = $cmd.Source
        if (-not $path) { continue }
        $skip = $false
        foreach ($pattern in $exclude) { if ($pattern -and $path -like $pattern) { $skip = $true; break } }
        if (-not $skip) { return $path }
    }
}

function ConvertTo-DFToolExePathToken {
    <#
    .SYNOPSIS
        The value ${DF_TOOL_EXE} expands to: the tool's resolved path with forward slashes, quoted when it holds a space, else its bare name.
    .DESCRIPTION
        Forward slashes keep sh -c based callers (git's pager handling) from
        treating backslashes as escapes; Windows programs accept them. With no
        qualifying copy, the executable name without .exe, which leaves the
        choice to PATH as before.
    .PARAMETER Tool
        The normalized tool record.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][pscustomobject]$Tool)
    $path = Resolve-DFToolExecutable -Tool $Tool
    if (-not $path) { return [IO.Path]::GetFileNameWithoutExtension($Tool.executable) }
    $path = $path -replace '\\', '/'
    if ($path -match '\s') { "`"$path`"" } else { $path }
}
```

In `Invoke-DFToolRegistration`, the role-env loop:

```powershell
            foreach ($var in $block.env.PSObject.Properties) {
                $value = [string]$var.Value
                if ($value -like '*${DF_TOOL_EXE}*') { $value = $value.Replace('${DF_TOOL_EXE}', (ConvertTo-DFToolExePathToken -Tool $Tool)) }
                Set-DFRoleEnv -Name $var.Name -Value (Expand-DFXdgPath $value) -Role $roleName -Winner $won.Winner -Reason $won.Reason
            }
```

Check that `Expand-DFXdgPath` doesn't mangle a forward-slashed absolute path. It expands only `${XDG_*}`, and the token is replaced first, but confirm with the test. `ConvertTo-DFToolRecord`: add `executableExclude = [object[]]@(& $get $Tool 'executableExclude' @())`. `Test-DFToolSchema`:

```powershell
    $exclude = PSProp $Tool 'executableExclude'
    if ($null -ne $exclude -and ($exclude -isnot [array] -or @($exclude | Where-Object { $_ -isnot [string] }).Count)) {
        $errs.Add('executableExclude must be an array of strings')
    }
```

- [ ] **Step 4: Run and confirm green**, plus `tests/ModuleState.Tests.ps1` and `tests/Register-DFTool.Tests.ps1`.

---

### Task 2: `Invoke-DFPagerExe` runs a quoted program path

**Files:** `Private/Invoke-DFPagerExe.ps1`, `tests/DFHelpers.Pager.Tests.ps1` (or wherever `Invoke-DFPagerExe` is tested; find it with `grep -l Invoke-DFPagerExe tests/*.ps1`).

- [ ] **Step 1: Failing tests.** Use a stand-in program the test can observe. Create `$TestDrive\dir with space\fakepager.cmd` that writes its arguments and stdin to a file, then:

```powershell
    It 'runs a double-quoted program path, then its arguments' {
        $dir = Join-Path $TestDrive 'dir with space'
        New-Item -ItemType Directory -Force $dir | Out-Null
        $out = Join-Path $TestDrive 'pager-out.txt'
        "@echo %* > `"$out`"`r`n@more >> `"$out`"" | Set-Content (Join-Path $dir 'fakepager.cmd') -Encoding ascii
        $pager = '"' + ((Join-Path $dir 'fakepager.cmd') -replace '\\', '/') + '" -x'
        Invoke-DFPagerExe -Lines 'hello' -Pager $pager -WarningVariable w
        $w | Should -BeNullOrEmpty
        Get-Content $out -Raw | Should -Match '-x'
        Get-Content $out -Raw | Should -Match 'hello'
    }

    It 'still warns about quotes in the arguments' {
        Mock Write-Warning { } -Verifiable
        $script:NoopPager = (Get-Command cmd.exe).Source
        Invoke-DFPagerExe -Lines 'x' -Pager "cmd.exe /c rem `"quoted`"" 3>$null
        Should -InvokeVerifiable
    }
```

- [ ] **Step 2: Run and confirm red** (the first test fails: today the quote warns and the path splits at the space).

- [ ] **Step 3: Implement:**

```powershell
    # A leading double-quoted program path (what ${DF_TOOL_EXE} produces for a
    # path with spaces) is the program; the rest splits on whitespace.
    if ($Pager -match '^\s*"([^"]+)"\s*(.*)$') {
        $program = $Matches[1]
        $rest = $Matches[2]
    } else {
        $parts = $Pager.Trim() -split '\s+', 2
        $program = $parts[0]
        $rest = if ($parts.Count -gt 1) { $parts[1] } else { '' }
    }
    if ($rest -match '["\x27]') {
        Write-Warning "DotForge: Quoted arguments in `$Env:Pager are not supported. Use --key=value form (e.g. bat --theme=Dracula)."
    }
    [string[]] $pagerArgs = if ($rest) { $rest -split '\s+' } else { @() }
    $Lines | & $program @pagerArgs
```

Update the `.PARAMETER Pager` help: "A double-quoted program path may come first."

- [ ] **Step 4: Run and confirm green.**

---

### Task 3: moor, ov, less, bat records and moor's companion

**Files:** Create `Tools/moor.json`, `Tools/moor.ps1`, `Tools/ov.json` (exactly per spec §2). Modify `Tools/less.json` and `Tools/bat.json`. Test: `tests/moor.Tests.ps1`, `tests/DefaultToolRoles.Tests.ps1`; update any test asserting bat's or less's old pager values (`grep -n "PAGER" tests/*.ps1`).

- [ ] **Step 1: Failing tests.** `tests/moor.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/../Private/Get-DFConfiguredTheme.ps1"
    . "$PSScriptRoot/../Private/Resolve-DFThemeName.ps1"
    $script:CompanionPath = Join-Path $PSScriptRoot '../Tools/moor.ps1'
}

Describe 'moor companion' {
    BeforeEach {
        $script:SavedMoor = $Env:MOOR
        Remove-Item Env:MOOR -ErrorAction Ignore
        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
        $DFCurrentTool = [pscustomobject]@{ themeMap = $null }
    }
    AfterEach {
        if ($null -eq $script:SavedMoor) { Remove-Item Env:MOOR -ErrorAction Ignore } else { $Env:MOOR = $script:SavedMoor }
        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
    }

    It 'sets MOOR to the configured style and quit-if-one-screen when unset' {
        $Global:DFConfig = @{ Theme = 'catppuccin-mocha' }
        . $script:CompanionPath
        $Env:MOOR | Should -Be '-style catppuccin-mocha -quit-if-one-screen'
    }

    It 'lets MoorTheme override the shared theme' {
        $Global:DFConfig = @{ Theme = 'catppuccin-mocha'; MoorTheme = 'dracula' }
        . $script:CompanionPath
        $Env:MOOR | Should -Be '-style dracula -quit-if-one-screen'
    }

    It 'leaves a MOOR the user set alone' {
        $Env:MOOR = '-no-linenumbers'
        . $script:CompanionPath
        $Env:MOOR | Should -Be '-no-linenumbers'
    }
}
```

In `tests/DefaultToolRoles.Tests.ps1`, a new Describe for the pager role, modeled on the project-env one. Mock `Get-Command`: `moor.exe` and `ov.exe` resolve; `less.exe` returns two hits, `C:\Program Files\Git\usr\bin\less.exe` then `C:\scoop\shims\less.exe`. That covers both the availability probe (any `-All` or plain call) and the resolver. Clear `PAGER` and `MOOR` and set `$global:DFRoleEnvState = $null`; restore them in `AfterEach`. Tests:
  - `Register-DFTool -Name moor, ov, less, bat` → `$Env:PAGER` is `moor`.
  - `Defaults = @{ pager = 'ov' }` → `ov --quit-if-one-screen`.
  - `Defaults = @{ pager = 'less' }` → `C:/scoop/shims/less.exe`.
  - `Get-DFRoleWinners` result for `pager` has no `bat` among its candidates. Or read `Tools/bat.json` and assert `$j.PSObject.Properties['roles']` lacks `pager`.

- [ ] **Step 2: Run and confirm red.**

- [ ] **Step 3: Implement.** The records per spec §2. `less.json`:
  - add `"executableExclude": ["*\\Git\\usr\\bin\\*"]`;
  - add `"winget": "jftuga.less"` to packages;
  - set roles to `{ "pager": { "priority": 10, "env": { "PAGER": "${DF_TOOL_EXE}" } } }`;
  - rename `LESSKEY` to `LESSKEYIN` in `xdg.vars`.

  `bat.json`: delete the `roles` line. `Tools/moor.ps1`:

```powershell
# Companion for moor — sets its options from DotForge's theme when you haven't.
#
# MOOR holds moor's default command-line options. Only set when empty, so a MOOR
# you set yourself always wins. moor's -style names include the canonical
# catppuccin-mocha, so no themeMap is needed; moor falls back to its default
# for a style it doesn't know.
param()

if (-not $Env:MOOR) {
    $_style = Resolve-DFThemeName -Name (Get-DFConfiguredTheme -ToolKey 'MoorTheme' -Default 'catppuccin-mocha') -ThemeMap $DFCurrentTool.themeMap
    $Env:MOOR = "-style $_style -quit-if-one-screen"
    Remove-Variable _style
}
```

- [ ] **Step 4: Run and confirm green**, plus `tests/Roles.Contract.Tests.ps1`, `tests/bat.Tests.ps1`, `tests/XdgSplit.Tests.ps1` and `tests/Test-DFToolSchema.Tests.ps1`.

---

### Task 4: Data, docs, verification, commit

- [ ] **Data:** add moor and ov entries to `build/categories/dotforge-curated.jsonc` (`"function": ["file-viewing"]`, `"worksWith": ["text"]`, `"interface": "tui"`, ids, `"relatedTo"`), run `./build/Build-DFCategoryDb.ps1`, and add curated entries to `data/tool-identities.json` (alphabetical; copy the packages). Update the `tcats` example count in `docs/guide/package-catalog.md` if it changes; run the command to read the new value.
- [ ] **Docs:**
  - `docs/guide/tools.md`: Included-tools Pager row `less, moor, ov`, plus a "Pagers" note covering who wins, the native-less preference, moor's `MOOR`, and ov's config.
  - `docs/guide/configuration.md`: the `MoorTheme` row, and add it to the per-tool theme list.
  - `docs/guide/writing-a-tool.md`: `executableExclude` row, and `${DF_TOOL_EXE}` in the "Joining a role" section.
  - `docs/external-dependencies.md`: entries for MSYS vs native less (with `LESSKEYIN`), bat's `PAGER=bat` fallback, and moor's `MOOR` and style names.
  - CHANGELOG; TODO (mark the pager line done); README count 45 → 47.
  - Regenerate the reference.
- [ ] **Full suite, alone:** expect 0 failed, 0 skipped.
- [ ] **Real machine, read-only.** In throwaway sessions with `PAGER`/`MOOR` removed first: `Register-DFTool -Name moor, ov, less, bat` for each of no Defaults / `pager = 'ov'` / `pager = 'less'`. Print `PAGER` and `MOOR`, and confirm `less` resolves to the scoop path. Then pipe `1..300` through `Invoke-DFWithPager` with `PAGER` set to the resolved less path, stdout redirected (a quick non-interactive run), and confirm no warning.
- [ ] **Ask the user** to try `pg`, `git log` and `bat <file>` interactively in their terminal with each pager.
- [ ] **Commit** (one signed commit).
