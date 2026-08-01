# Profile-to-DotForge Fold-in Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move approved reusable profile setup to DotForge while retaining personal and host-specific behavior.

**Architecture:** Tool JSON records set static XDG-derived values. Same-basename companion scripts handle only initialization hooks, dynamic executable-directory discovery, and PowerShell feedback configuration. The profile invokes `Initialize-DFEnvironment` before its remaining personal modules and calls `Register-DFTool -All` once per startup branch.

**Tech Stack:** PowerShell 7.2+, Pester 5, PowerShell experimental features.

## Global Constraints

- Use four-space PowerShell indentation. Do not set `$ErrorActionPreference = 'Stop'` in module files.
- Use `New-DFDirectory` and `Add-DFToPath` for all DotForge-owned directory/PATH changes.
- Registration is conditional and never installs tools or the optional WinGet module.
- Run tests with `pwsh -NoProfile`.
- The external profile needs elevated filesystem access.

---

### Task 1: Bootstrap XDG bin and explicit hook order

**Files:**

- Modify: `Public/Initialize-DFEnvironment.ps1`, `Tools/zoxide.json`
- Modify: `tests/Initialize-DFEnvironment.Tests.ps1`, `tests/Register-DFTool.Tests.ps1`

**Interfaces:**

- Produces: `Initialize-DFEnvironment` creates the five XDG directories and keeps `XDG_BIN_HOME` in PATH exactly once.
- Produces: `oh-my-posh → zoxide → fnm` whenever all are registered.

- [ ] **Step 1: Add failing tests**

Import `Add-DFToPath.ps1` in the initialization test. Save and restore `PATH` and `XDG_BIN_HOME`. Add:

```powershell
It 'adds XDG_BIN_HOME to PATH exactly once' {
    $Env:XDG_BIN_HOME = Join-Path $TestDrive 'bin'
    $Env:Path = 'C:\Windows\System32'
    Mock Get-Command { $null }

    Initialize-DFEnvironment
    Initialize-DFEnvironment

    @($Env:Path -split [IO.Path]::PathSeparator |
        Where-Object { $_ -ieq $Env:XDG_BIN_HOME }).Count | Should -Be 1
}
```

In the registry test, use three temporary JSON fixtures with companions adding their names to `$global:RegistrationOrder`, then assert:

```powershell
$global:RegistrationOrder | Should -Be @('oh-my-posh', 'zoxide', 'fnm')
```

- [ ] **Step 2: Verify red**

```powershell
pwsh -NoProfile -Command "Invoke-Pester tests/Initialize-DFEnvironment.Tests.ps1,tests/Register-DFTool.Tests.ps1 -Output Detailed"
```

Expected: FAIL for the new assertions.

- [ ] **Step 3: Implement minimum behavior**

After the existing XDG directory pipeline in `Initialize-DFEnvironment`, add:

```powershell
Add-DFToPath $Env:XDG_BIN_HOME
```

Add `"dependsOn": ["oh-my-posh"]` to `Tools/zoxide.json`. Keep fnm’s dependency on zoxide unchanged.

- [ ] **Step 4: Verify green and commit**

Run the Step 2 command; expected PASS.

```powershell
git add Public/Initialize-DFEnvironment.ps1 Tools/zoxide.json tests/Initialize-DFEnvironment.Tests.ps1 tests/Register-DFTool.Tests.ps1
git commit -m "feat: centralize XDG bin and prompt ordering"
```

### Task 2: Add tool records and companions

**Files:**

- Create: `Tools/direnv.json`, `Tools/direnv.ps1`, `Tools/python.json`, `Tools/python.ps1`, `Tools/pipx.json`, `Tools/gpg.json`, `Tools/rustup.ps1`
- Modify: `Tools/rustup.json`, `tests/Test-DFToolSchema.Tests.ps1`, `tests/Register-DFTool.Tests.ps1`

**Interfaces:**

- Produces: direnv’s `LocationChangedAction` hook; Python scripts and Cargo bin PATH entries; pipx bin set to `XDG_BIN_HOME`; XDG Rust and GnuPG homes.

- [ ] **Step 1: Add failing tests**

Add `direnv`, `python`, `pipx`, `gpg`, and `powershell` to the expected tool names. Add temporary tool/sidecar fixtures proving a companion can append Cargo bin and prepend Python’s mocked `sysconfig.get_path('scripts')` result:

```powershell
$Env:Path -split [IO.Path]::PathSeparator | Should -Contain "$Env:CARGO_HOME\bin"
```

Mock direnv to emit `$global:DirenvHookLoaded = $true` and assert the sidecar evaluates it.

- [ ] **Step 2: Verify red**

```powershell
pwsh -NoProfile -Command "Invoke-Pester tests/Test-DFToolSchema.Tests.ps1,tests/Register-DFTool.Tests.ps1 -Output Detailed"
```

Expected: FAIL because the records are absent.

- [ ] **Step 3: Implement records and companions**

Create the direnv record (`direnv.exe`, Scoop `direnv`, Winget `direnv.direnv`) and sidecar:

```powershell
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingInvokeExpression', '')]
param()

Invoke-Expression (direnv hook pwsh | Out-String)
```

Create Python record variables for `PYTHONPYCACHEPREFIX`, `PYTHONUSERBASE`, and `PYTHONIOENCODING`; use this companion:

```powershell
param()

$_scripts = python -c "import sysconfig; print(sysconfig.get_path('scripts'))" 2>$null
if ($LASTEXITCODE -eq 0 -and $_scripts) {
    Add-DFToPath $_scripts.Trim() -Prepend
}
```

Create pipx variables `PIPX_HOME`, `PIPX_BIN_DIR`, and `PIPX_MAN_DIR` under XDG data/bin locations—do not retain `PIP_BIN_DIR`. Create gpg with `GNUPGHOME` under XDG config. Change rustup to XDG env mode for `RUSTUP_HOME` and `CARGO_HOME`; use:

```powershell
param()

Add-DFToPath (Join-Path $Env:CARGO_HOME 'bin')
```

- [ ] **Step 4: Verify green and commit**

Run the Step 2 command; expected PASS.

```powershell
git add Tools tests/Test-DFToolSchema.Tests.ps1 tests/Register-DFTool.Tests.ps1
git commit -m "feat: fold profile tool environment into registry"
```

### Task 3: Configure PowerShell feedback and WinGet suggestions

**Files:**

- Create: `Tools/powershell.json`, `Tools/powershell.ps1`, `tests/powershell.Tests.ps1`
- Modify: `README.md`, `docs/external-dependencies.md`

**Interfaces:**

- Produces: only a listed, disabled `PSFeedbackProvider` is enabled at CurrentUser scope; a missing feature is treated as mainstream; WinGet suggestions load only if its module is installed.

- [ ] **Step 1: Add failing tests**

Mock a disabled feature and assert:

```powershell
Should -Invoke Enable-ExperimentalFeature -Times 1 -ParameterFilter {
    $Name -eq 'PSFeedbackProvider' -and $Scope -eq 'CurrentUser'
}
```

Mock no feature and assert zero enables. Mock an available `Microsoft.WinGet.CommandNotFound` module and assert one import; mock no module and assert zero imports.

- [ ] **Step 2: Verify red**

```powershell
pwsh -NoProfile -Command "Invoke-Pester tests/powershell.Tests.ps1 -Output Detailed"
```

Expected: FAIL because the sidecar is absent.

- [ ] **Step 3: Implement conditional configuration and docs**

Create a `powershell` record for `pwsh.exe`. Implement:

```powershell
param()

$_feedback = Get-ExperimentalFeature -Name PSFeedbackProvider -ErrorAction Ignore
if ($_feedback -and -not $_feedback.Enabled) {
    try {
        Enable-ExperimentalFeature -Name PSFeedbackProvider -Scope CurrentUser -ErrorAction Stop
        Write-Warning 'DotForge: enabled PSFeedbackProvider; restart PowerShell for it to take effect.'
    } catch {
        Write-Warning "DotForge: could not enable PSFeedbackProvider: $($_.Exception.Message)"
    }
}

if (Get-Module -ListAvailable -Name Microsoft.WinGet.CommandNotFound -ErrorAction Ignore) {
    Import-Module -Name Microsoft.WinGet.CommandNotFound -ErrorAction SilentlyContinue
}
```

Document in README: conditional enablement, restart requirement, and optional existing-module import. Document the PowerShell lifecycle and module import in external dependencies.

- [ ] **Step 4: Verify green and commit**

Run the Step 2 command; expected PASS.

```powershell
git add Tools/powershell.json Tools/powershell.ps1 tests/powershell.Tests.ps1 README.md docs/external-dependencies.md
git commit -m "feat: configure PowerShell feedback providers"
```

### Task 4: Simplify the external profile

**Files:**

- Modify: `C:\Users\simsr\OneDrive\Documents\PowerShell\profile.ps1`
- Modify: `C:\Users\simsr\OneDrive\Documents\PowerShell\ProfileModules\Env.ps1`, `Aliases.ps1`, `Functions.ps1`
- Delete: external `PSReadline.ps1`, `PSReadLine-Theme.ps1`

**Interfaces:**

- Consumes: `Import-Module DotForge`, `Initialize-DFEnvironment`, `Register-DFTool -All`.
- Produces: one DotForge bootstrap per host branch; only personal/host integration remains.

- [ ] **Step 1: Add a failing profile-content check**

```powershell
$profileText = Get-Content 'C:\Users\simsr\OneDrive\Documents\PowerShell\profile.ps1' -Raw
foreach ($pattern in 'scoop-search --hook', 'direnv hook pwsh', 'DockerCompletion', 'PowerType', 'PSFeedbackProvider', 'Microsoft.WinGet.CommandNotFound') {
    if ($profileText -match [regex]::Escape($pattern)) { throw "Retired profile code remains: $pattern" }
}
```

- [ ] **Step 2: Verify red**

Run the Step 1 script with `pwsh -NoProfile`; expected FAIL.

- [ ] **Step 3: Apply approved cleanup**

In both paths, invoke `Initialize-DFEnvironment` after importing DotForge and before sourcing `Env.ps1`. Keep `DFConfig` and `POSH_THEME`. Remove direct Scoop, direnv, PSReadLine, DockerCompletion, PowerType, feedback-provider, and WinGet setup.

Remove local PATH/XDG/Rust/Python/pipx/GnuPG code and `PIP_BIN_DIR` from Env; retain editor, terminal, Bun, Claude, Pulsar, pager, vivid, and Komorebi settings, replacing remaining personal PATH calls with `Add-DFToPath`. Remove superseded aliases/functions (`printenv`, `printpath`, `touch`, `rp`, `Show-Environment`, `Show-Path`, `New-File`, `Reload-Profile`, `cd...`, `cd....`). Keep destructive, SSH, maintenance, measurement, public-IP, and Claude helpers. Do not alter `cli_tools_config.ps1`.

- [ ] **Step 4: Verify green and commit if appropriate**

```powershell
pwsh -NoProfile -Command ". 'C:\Users\simsr\OneDrive\Documents\PowerShell\profile.ps1'; Get-Alias touch,env,path,reload -ErrorAction SilentlyContinue | Select-Object Name,Definition"
git -C 'C:\Users\simsr\OneDrive\Documents\PowerShell' rev-parse --is-inside-work-tree
```

Expected: no duplicate-hook errors and DotForge aliases work. Commit only if the external directory already reports `true`; otherwise report the external changes without creating a repository.

### Task 5: Complete verification

- [ ] **Step 1: Validate schemas and complete suite**

```powershell
pwsh -NoProfile -Command "Invoke-Pester tests/Test-DFToolSchema.Tests.ps1 -Output Detailed"
pwsh -NoProfile -Command "Invoke-Pester tests/ -Output Detailed"
```

Expected: PASS.

- [ ] **Step 2: Inspect final state**

```powershell
git diff --check
git status --short
git log --oneline -5
```

Expected: no whitespace errors and only intentional changes.

- [ ] **Step 3: Commit only a needed verification correction**

If a test exposed a defect, commit the focused fix as `fix: verify profile fold-in`; otherwise create no no-op commit.

