# Project-Environment Tools Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make ps-dotenv, mise and direnv work as zero-config `project-env` role members, with a declarative `scoopBucket` field so `Install-DFTool` can install ps-dotenv from its third-party bucket.

**Architecture:** One generic core addition, the `scoopBucket` field, which `Install-DFTool` reads. Everything else lives in tool plugins: each tool's JSON joins `project-env` with a priority, and its companion's `Initialize-DFRoleProjectEnv` hook does the activation, which DotForge calls only for the winner. mise also adds its shims folder to PATH from its companion body, so its tools work even when it loses the role.

**Tech Stack:** PowerShell 7+, Pester 6.

**Spec:** `docs/superpowers/specs/2026-10-05-project-env-tools-design.md`. Read it first, especially "Verified facts".

## Global Constraints

- Follow CLAUDE.md: `DF` prefix; `Get-DFConfig` for `$DFConfig`; `Get-DFXdgPath` for XDG folders; `ConvertTo-DFPath` for every path; `Add-DFToPath` for PATH; no `$ErrorActionPreference = 'Stop'`.
- Plugin invariant: core never names a tool. The roles contract (`tests/Roles.Contract.Tests.ps1`) must pass. `project-env` reserves `Invoke-Expression`, `iex` and `LocationChangedAction` for code inside the hook.
- Tests isolate every XDG folder they can write to, restore `LocationChangedAction` and any env var they set, and remove globals with `Remove-DFTestGlobal`.
- Run Pester as `pwsh -NoProfile -NonInteractive`. Run the full suite alone; parallel runs share process state.
- Every new global function a companion defines needs complete comment-based help. Hooks and companion-local helpers are not global.
- Commits are GPG-signed and batched into one commit at the end.
- Never write the user's `direnv.toml`, and never install software without asking.

## Review Focus

1. **Re-registering in the same session (`. $PROFILE`):** ps-dotenv must not chain `Update-Dotenv` onto `LocationChangedAction` a second time. (Task 3 test.)
2. **Approved folder given as `~\projects`:** must expand through `ConvertTo-DFPath`; a bad entry warns and the rest still apply. (Task 3 test.)
3. **Bucket already added under the same name:** no second `bucket add`; install is still bucket-qualified. (Task 1 test.)
4. **`DIRENV_BASH` already set by the user:** left alone. (Task 2 test.)
5. **mise not winning `project-env`:** its shims are still on PATH, and its activation never runs. (Task 4 test.)

---

### Task 1: `scoopBucket` field and bucket-aware scoop install

**Files:**
- Modify: `Private/Import-DFToolDb.ps1` (`ConvertTo-DFToolRecord`: `scoopBucket` defaults to `$null`)
- Modify: `Private/Test-DFToolSchema.ps1`
- Create: `Private/Invoke-DFScoopInstall.ps1`
- Modify: `Public/Install-DFTool.ps1`
- Test: `tests/Install-DFTool.Tests.ps1`, `tests/Test-DFToolSchema.Tests.ps1`, `tests/ConvertTo-DFToolRecord.Tests.ps1`

**Interfaces:**
- Produces: `Invoke-DFScoopInstall -Id <string> [-Bucket <pscustomobject>]`. It sets `$global:LASTEXITCODE` (0 = installed) like the other manager branches. A missing bucket is added first (printing `DotForge: added scoop bucket '<name>' (<url>)`) and the install is bucket-qualified, `<name>/<id>`. A failed add warns and sets `LASTEXITCODE` 1.
- Produces: every normalized tool record has `scoopBucket` (`$null`, or `{ name; url }`).

- [ ] **Step 1: Failing tests.** Add to `tests/Install-DFTool.Tests.ps1`, dot-sourcing `Private/Invoke-DFScoopInstall.ps1` in `BeforeAll`:

```powershell
Describe 'Install-DFTool with a scoop bucket' {
    BeforeEach {
        $script:DFToolDb = $null
        $script:DFToolAvailability = @{}
        $script:TmpTools = Join-Path $TestDrive "tools-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Force -Path $script:TmpTools | Out-Null
        @'
{ "name": "bucktool", "executable": "bucktool.exe", "packages": { "scoop": "bucktool" },
  "scoopBucket": { "name": "testbucket", "url": "https://example.invalid/bucket" } }
'@ | Set-Content (Join-Path $script:TmpTools 'bucktool.json')
        $script:ScoopCalls = [System.Collections.Generic.List[string]]::new()
        $script:Buckets = @('main')
        $script:BucketAddExit = 0
        function script:scoop {
            $script:ScoopCalls.Add(($args -join ' '))
            if ($args[0] -eq 'bucket' -and $args[1] -eq 'list') { $script:Buckets | ForEach-Object { [pscustomobject]@{ Name = $_ } }; $global:LASTEXITCODE = 0; return }
            if ($args[0] -eq 'bucket' -and $args[1] -eq 'add') { $global:LASTEXITCODE = $script:BucketAddExit; return }
            $global:LASTEXITCODE = 0
        }
        Mock Get-Command { [PSCustomObject]@{ Name = $Name } }
        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
    }
    AfterEach { Remove-Item function:scoop -ErrorAction Ignore }

    It 'adds a missing bucket, then installs the bucket-qualified package' {
        Install-DFTool -Name bucktool -PackageManager scoop -ToolsPath $script:TmpTools 6>$null
        $script:ScoopCalls | Should -Contain 'bucket add testbucket https://example.invalid/bucket'
        $script:ScoopCalls | Should -Contain 'install testbucket/bucktool'
    }

    It 'skips the add when the bucket is already there' {
        $script:Buckets = @('main', 'testbucket')
        Install-DFTool -Name bucktool -PackageManager scoop -ToolsPath $script:TmpTools 6>$null
        @($script:ScoopCalls | Where-Object { $_ -like 'bucket add*' }).Count | Should -Be 0
        $script:ScoopCalls | Should -Contain 'install testbucket/bucktool'
    }

    It 'warns and does not install when the bucket cannot be added' {
        $script:BucketAddExit = 1
        Install-DFTool -Name bucktool -PackageManager scoop -ToolsPath $script:TmpTools -WarningVariable w -WarningAction SilentlyContinue 6>$null
        "$w" | Should -Match "testbucket"
        @($script:ScoopCalls | Where-Object { $_ -like 'install*' }).Count | Should -Be 0
    }

    It 'installs an unqualified id when the tool declares no bucket' {
        '{ "name": "plain", "executable": "plain.exe", "packages": { "scoop": "plain" } }' | Set-Content (Join-Path $script:TmpTools 'plain.json')
        Install-DFTool -Name plain -PackageManager scoop -ToolsPath $script:TmpTools 6>$null
        $script:ScoopCalls | Should -Contain 'install plain'
        @($script:ScoopCalls | Where-Object { $_ -like 'bucket*' }).Count | Should -Be 0
    }
}
```

`tests/Test-DFToolSchema.Tests.ps1`:

```powershell
        It 'rejects a scoopBucket without both name and url' {
            $t = '{ "name": "t", "executable": "t.exe", "scoopBucket": { "name": "x" } }' | ConvertFrom-Json
            $errs = @()
            Test-DFToolSchema -Tool $t -Errors ([ref]$errs) | Should -BeFalse
            "$errs" | Should -Match 'scoopBucket'
        }
```

`tests/ConvertTo-DFToolRecord.Tests.ps1`: add `'scoopBucket'` to the "every field, with defaults" loop list and to the StrictMode field list.

- [ ] **Step 2: Run and confirm red.** `pwsh -NoProfile -NonInteractive -c "Invoke-Pester tests/Install-DFTool.Tests.ps1, tests/Test-DFToolSchema.Tests.ps1, tests/ConvertTo-DFToolRecord.Tests.ps1 -Output Detailed"`. Expected: the new tests fail.

- [ ] **Step 3: Implement.**

`Private/Invoke-DFScoopInstall.ps1`:

```powershell
#Requires -Version 7.0

function Invoke-DFScoopInstall {
    <#
    .SYNOPSIS
        Installs a scoop package, first adding the tool's third-party bucket when it declares one.
    .DESCRIPTION
        With -Bucket ({ name; url } from the tool's scoopBucket field): adds the
        bucket when scoop bucket list doesn't show it, printing what it added,
        then installs <name>/<id> so a same-named package in another bucket
        can't win. A failed add warns and installs nothing. Sets
        $global:LASTEXITCODE (0 = installed) like Install-DFTool's other
        manager branches.
    .PARAMETER Id
        The package id (packages.scoop).
    .PARAMETER Bucket
        The tool's scoopBucket object, or $null.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [AllowNull()][object]$Bucket
    )
    if ($Bucket) {
        $listed = @(scoop bucket list 2>$null | ForEach-Object { if ($_ -is [string]) { ($_ -split '\s+')[0] } else { $_.Name } })
        if ($Bucket.name -notin $listed) {
            $null = scoop bucket add $Bucket.name $Bucket.url 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "DotForge: could not add scoop bucket '$($Bucket.name)' ($($Bucket.url))."
                $global:LASTEXITCODE = 1
                return
            }
            Write-Host "DotForge: added scoop bucket '$($Bucket.name)' ($($Bucket.url))"
        }
        $Id = "$($Bucket.name)/$Id"
    }
    $null = scoop install $Id 2>&1
}
```

`Public/Install-DFTool.ps1`: replace `'scoop'      { scoop  install $pkgId 2>&1 }` with `'scoop'      { Invoke-DFScoopInstall -Id $pkgId -Bucket $tool.scoopBucket }`. In the help, change the `scoop` row to `scoop install <id>, or <bucket>/<id> after adding the tool's scoopBucket` and mention it in `.DESCRIPTION`.

`ConvertTo-DFToolRecord`: add `scoopBucket = & $get $Tool 'scoopBucket' $null` to `$record`, and `scoopBucket` to the help's defaults list.

`Test-DFToolSchema`, before the roles block:

```powershell
    $bucket = PSProp $Tool 'scoopBucket'
    if ($null -ne $bucket -and (-not (PSProp $bucket 'name') -or -not (PSProp $bucket 'url'))) {
        $errs.Add('scoopBucket must be an object with non-empty name and url')
    }
```

- [ ] **Step 4: Run and confirm green.** Same command as Step 2, plus `tests/Get-DFTool.Tests.ps1`. Expected: PASS.

---

### Task 2: direnv — bash path and the version warning

**Files:**
- Modify: `Tools/direnv.ps1`
- Test: `tests/direnv.Tests.ps1`

**Interfaces:**
- Companion-local helpers, not global:
  - `Find-DFGitBash [-GitPath <string>]` returns the first `<ancestor>\bin\bash.exe` that exists, walking up from git's folder, or nothing. It never returns a path under `$Env:WINDIR`.
  - `Test-DFDirenvBuggyVersion -VersionText <string>` returns `$true` when the leading `x.y.z` parses and is `<= 2.37.1`.

- [ ] **Step 1: Failing tests** (add to `tests/direnv.Tests.ps1`; dot-source `tests/TestSupport.ps1`):

```powershell
Describe 'direnv companion helpers' {
    BeforeAll { . $script:CompanionPath }

    It 'finds Git bash from <Layout>' -ForEach @(
        @{ Layout = 'mingw64\bin\git.exe'; Git = 'Git\mingw64\bin\git.exe' }
        @{ Layout = 'cmd\git.exe';         Git = 'Git\cmd\git.exe' }
    ) {
        $root = Join-Path $TestDrive "g-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Force (Join-Path $root 'Git\bin'), (Split-Path (Join-Path $root $Git)) | Out-Null
        New-Item -ItemType File (Join-Path $root 'Git\bin\bash.exe'), (Join-Path $root $Git) | Out-Null
        Find-DFGitBash -GitPath (Join-Path $root $Git) | Should -Be (Join-Path $root 'Git\bin\bash.exe')
    }

    It 'returns nothing when no bin\bash.exe sits above git' {
        $git = Join-Path $TestDrive 'nobash\git.exe'
        New-Item -ItemType Directory -Force (Split-Path $git) | Out-Null
        New-Item -ItemType File $git | Out-Null
        Find-DFGitBash -GitPath $git | Should -BeNullOrEmpty
    }

    It 'flags <Text> as buggy: <Buggy>' -ForEach @(
        @{ Text = "2.37.1`n"; Buggy = $true }
        @{ Text = '2.36.0';   Buggy = $true }
        @{ Text = '2.38.0';   Buggy = $false }
        @{ Text = 'garbage';  Buggy = $false }
    ) {
        Test-DFDirenvBuggyVersion -VersionText $Text | Should -Be $Buggy
    }
}

Describe 'direnv project-env hook' {
    BeforeEach {
        $script:SavedBash = $Env:DIRENV_BASH
        $script:SavedLca = $ExecutionContext.SessionState.InvokeCommand.LocationChangedAction
        . $script:CompanionPath
        Mock Get-DFCachedCommandOutput { '' } -ParameterFilter { $Name -eq 'direnv-hook' }
        Mock Get-DFCachedCommandOutput { $script:VersionText } -ParameterFilter { $Name -eq 'direnv-version' }
        $script:VersionText = '2.37.1'
    }
    AfterEach {
        if ($null -eq $script:SavedBash) { Remove-Item Env:DIRENV_BASH -ErrorAction Ignore } else { $Env:DIRENV_BASH = $script:SavedBash }
        $ExecutionContext.SessionState.InvokeCommand.LocationChangedAction = $script:SavedLca
    }

    It 'leaves a DIRENV_BASH the user set alone' {
        $Env:DIRENV_BASH = 'C:\mine\bash.exe'
        . Initialize-DFRoleProjectEnv -Role project-env -WarningAction SilentlyContinue
        $Env:DIRENV_BASH | Should -Be 'C:\mine\bash.exe'
    }

    It 'sets DIRENV_BASH from Git bash when unset' {
        Remove-Item Env:DIRENV_BASH -ErrorAction Ignore
        Mock Find-DFGitBash { 'C:\Git\bin\bash.exe' }
        . Initialize-DFRoleProjectEnv -Role project-env -WarningAction SilentlyContinue
        $Env:DIRENV_BASH | Should -Be 'C:\Git\bin\bash.exe'
    }

    It 'warns when no Git bash is found' {
        Remove-Item Env:DIRENV_BASH -ErrorAction Ignore
        Mock Find-DFGitBash { }
        . Initialize-DFRoleProjectEnv -Role project-env -WarningVariable w -WarningAction SilentlyContinue
        "$w" | Should -Match "needs Git for Windows' bash"
    }

    It 'warns about the Windows bug for 2.37.1, and not for 2.38.0' {
        $Env:DIRENV_BASH = 'C:\x\bash.exe'
        . Initialize-DFRoleProjectEnv -Role project-env -WarningVariable w1 -WarningAction SilentlyContinue
        "$w1" | Should -Match 'direnv#1488'
        $script:VersionText = '2.38.0'
        . Initialize-DFRoleProjectEnv -Role project-env -WarningVariable w2 -WarningAction SilentlyContinue
        "$w2" | Should -Not -Match 'direnv#1488'
    }
}
```

If a mock of a companion-local function (`Find-DFGitBash`) proves unreliable because the companion re-defines it on dot-source, dot-source the companion in `BeforeAll` instead and keep `Mock` in the `It`. Ledger the change.

- [ ] **Step 2: Run and confirm red.** `pwsh -NoProfile -NonInteractive -c "Invoke-Pester tests/direnv.Tests.ps1 -Output Detailed"`.

- [ ] **Step 3: Implement** in `Tools/direnv.ps1`. Add the two helpers above the hook, with short `<# .SYNOPSIS #>` help, and extend the hook:

```powershell
# Last direnv release with the Windows variable-unloading bug (direnv#1488); see
# docs/external-dependencies.md. Raise it if a release still has the bug.
$DFDirenvLastBuggyVersion = [version]'2.37.1'

function Find-DFGitBash {
    <#
    .SYNOPSIS
        Returns Git for Windows' bash.exe: the first <ancestor>\bin\bash.exe above git.exe, never one under Windows.
    #>
    param([string]$GitPath = (Get-Command git.exe -CommandType Application -ErrorAction Ignore | Select-Object -First 1).Source)
    if (-not $GitPath) { return }
    $dir = Split-Path $GitPath -Parent
    while ($dir) {
        $bash = Join-Path $dir 'bin\bash.exe'
        if ((Test-Path -LiteralPath $bash -PathType Leaf) -and -not ($Env:WINDIR -and $bash -like "$Env:WINDIR\*")) { return $bash }
        $parent = Split-Path $dir -Parent
        if (-not $parent -or $parent -eq $dir) { return }
        $dir = $parent
    }
}

function Test-DFDirenvBuggyVersion {
    <#
    .SYNOPSIS
        True when direnv's version text is at or below the last release with the Windows unloading bug.
    #>
    param([AllowEmptyString()][string]$VersionText)
    if ($VersionText -notmatch '(\d+\.\d+\.\d+)') { return $false }
    [version]$Matches[1] -le $DFDirenvLastBuggyVersion
}
```

At the start of `Initialize-DFRoleProjectEnv`:

```powershell
    # direnv.toml's bash_path, when set, still wins over DIRENV_BASH (direnv's own
    # precedence), and DotForge never writes direnv.toml.
    if (-not $Env:DIRENV_BASH) {
        $gitBash = Find-DFGitBash
        if ($gitBash) { $Env:DIRENV_BASH = $gitBash }
        else { Write-Warning "DotForge: direnv needs Git for Windows' bash; set bash_path in direnv.toml or DIRENV_BASH." }
    }
    $direnvVersion = Get-DFCachedCommandOutput -Name 'direnv-version' -Executable 'direnv' -Generate { direnv version | Out-String }
    if (Test-DFDirenvBuggyVersion -VersionText $direnvVersion) {
        Write-Warning ("DotForge: direnv $($direnvVersion.Trim()) on Windows unloads environment variables it didn't set (direnv#1488). " +
            "Consider ps-dotenv: `$DFConfig.Defaults = @{ 'project-env' = 'ps-dotenv' }")
    }
```

Then the existing 7.2 guard and hook follow, unchanged. Update the file's header comment for the bash path and the warning.

- [ ] **Step 4: Run and confirm green.** Same command, plus `tests/Roles.Contract.Tests.ps1`.

---

### Task 3: ps-dotenv

**Files:**
- Create: `Tools/ps-dotenv.json`, `Tools/ps-dotenv.ps1`
- Test: `tests/ps-dotenv.Tests.ps1`

**Interfaces:**
- Hook `Initialize-DFRoleProjectEnv`, per spec §2. Marks its chained handler in `$global:DFDotenvLocationHook`, so a re-registration doesn't chain again.
- `$DFConfig` keys: `DotenvSafeMode` (bool, default `$true`), `DotenvApprovedDirs` (string[]).

- [ ] **Step 1: Failing tests** (`tests/ps-dotenv.Tests.ps1`). A fake `Dotenv` module stands in for the real one:

```powershell
BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    . "$PSScriptRoot/../Private/ConvertTo-DFPath.ps1"
    . "$PSScriptRoot/../Private/Get-DFConfiguredTheme.ps1"
    $script:CompanionPath = Join-Path $PSScriptRoot '../Tools/ps-dotenv.ps1'
    $fakeDir = Join-Path $TestDrive 'fake\Dotenv'
    New-Item -ItemType Directory -Force $fakeDir | Out-Null
    $script:FakeModule = Join-Path $fakeDir 'Dotenv.psm1'
    @'
$Dotenv = [pscustomobject]@{ Enabled = $false; SafeMode = $false; Async = $true }
function Enable-Dotenv { $Dotenv.Enabled = $true }
function Approve-DotenvDir { param([Parameter(Mandatory)][string]$Path) if ($Path -like '*bad*') { throw 'nope' }; $global:FakeDotenvCalls += "approve:$Path" }
function Update-Dotenv { $global:FakeDotenvCalls += 'update' }
Export-ModuleMember -Function * -Variable Dotenv
'@ | Set-Content $script:FakeModule
}

Describe 'ps-dotenv project-env hook' {
    BeforeEach {
        $global:FakeDotenvCalls = @()
        $script:SavedLca = $ExecutionContext.SessionState.InvokeCommand.LocationChangedAction
        $script:SavedLoc = Get-Location
        Remove-Variable DFConfig, DFDotenvLocationHook -Scope Global -ErrorAction Ignore
        Mock Get-Module { [pscustomobject]@{ Path = $script:FakeModule } } -ParameterFilter { $ListAvailable }
        . $script:CompanionPath
    }
    AfterEach {
        $ExecutionContext.SessionState.InvokeCommand.LocationChangedAction = $script:SavedLca
        Set-Location $script:SavedLoc
        Remove-Module Dotenv -Force -ErrorAction Ignore
        Remove-Variable DFConfig, DFDotenvLocationHook, FakeDotenvCalls, Dotenv -Scope Global -ErrorAction Ignore
    }

    It 'imports by the discovered path, enables, turns safe mode on and async off, and loads the start folder' {
        . Initialize-DFRoleProjectEnv -Role project-env
        $Dotenv.Enabled | Should -BeTrue
        $Dotenv.SafeMode | Should -BeTrue
        $Dotenv.Async | Should -BeFalse
        $global:FakeDotenvCalls | Should -Contain 'update'
    }

    It 'leaves safe mode off when DotenvSafeMode is $false' {
        $Global:DFConfig = @{ DotenvSafeMode = $false }
        . Initialize-DFRoleProjectEnv -Role project-env
        $Dotenv.SafeMode | Should -BeFalse
    }

    It 'approves each listed folder, expanding ~, and warns about one that fails' {
        $Global:DFConfig = @{ DotenvApprovedDirs = @('~\projects', 'C:\bad') }
        . Initialize-DFRoleProjectEnv -Role project-env -WarningVariable w -WarningAction SilentlyContinue
        $global:FakeDotenvCalls | Should -Contain "approve:$(Join-Path $HOME 'projects')"
        "$w" | Should -Match 'C:\\bad'
    }

    It 'updates on Set-Location, keeping an existing handler' {
        $global:PrevHandlerRan = $false
        $ExecutionContext.SessionState.InvokeCommand.LocationChangedAction = [EventHandler[System.Management.Automation.LocationChangedEventArgs]] { $global:PrevHandlerRan = $true }
        . Initialize-DFRoleProjectEnv -Role project-env
        $global:FakeDotenvCalls = @()
        Set-Location $TestDrive
        $global:FakeDotenvCalls | Should -Contain 'update'
        $global:PrevHandlerRan | Should -BeTrue
        Remove-Variable PrevHandlerRan -Scope Global
    }

    It 'does not chain itself twice when registered again in the same session' {
        . Initialize-DFRoleProjectEnv -Role project-env
        . Initialize-DFRoleProjectEnv -Role project-env
        $global:FakeDotenvCalls = @()
        Set-Location $TestDrive
        @($global:FakeDotenvCalls | Where-Object { $_ -eq 'update' }).Count | Should -Be 1
    }
}
```

- [ ] **Step 2: Run and confirm red.** `pwsh -NoProfile -NonInteractive -c "Invoke-Pester tests/ps-dotenv.Tests.ps1 -Output Detailed"`. Expected: fails, because the companion is missing.

- [ ] **Step 3: Implement.** Write `Tools/ps-dotenv.json` exactly as in spec §2. `Tools/ps-dotenv.ps1`:

```powershell
# Companion for ps-dotenv — loads .env files as you change folders.
#
# Everything here runs only when ps-dotenv wins the project-env role. Dotenv is
# imported by its discovered path: scoop's install nests the manifest one level
# deeper than PowerShell expects, so `Import-Module Dotenv` by name fails
# (docs/external-dependencies.md). Update-Dotenv is chained onto
# LocationChangedAction rather than the prompt, so it needs no ordering against
# prompt engines and survives an fpot theme switch.
param()

function Initialize-DFRoleProjectEnv {
    # Called by DotForge only when ps-dotenv wins the project-env role.
    param([PSCustomObject]$Tool, [string]$Role)
    $manifest = (Get-Module -ListAvailable Dotenv | Select-Object -First 1).Path
    Import-Module $manifest -Global -ErrorAction Stop
    Enable-Dotenv
    # Set explicitly, not left to the module's shipped defaults. Async off: a
    # script doing `cd project; npm test` must see the .env already loaded.
    $Dotenv.SafeMode = [bool](Get-DFConfig DotenvSafeMode -Default $true)
    $Dotenv.Async = $false
    foreach ($dir in @(Get-DFConfig DotenvApprovedDirs)) {
        if (-not $dir) { continue }
        try {
            Approve-DotenvDir -Path (ConvertTo-DFPath $dir) -ErrorAction Stop
        } catch {
            Write-Warning "DotForge: ps-dotenv could not approve '$dir': $($_.Exception.Message)"
        }
    }
    if (-not $global:DFDotenvLocationHook) {
        $global:DFDotenvLocationHook = [EventHandler[System.Management.Automation.LocationChangedEventArgs]] { Dotenv\Update-Dotenv }
        $ExecutionContext.SessionState.InvokeCommand.LocationChangedAction =
            [Delegate]::Combine($ExecutionContext.SessionState.InvokeCommand.LocationChangedAction, $global:DFDotenvLocationHook)
    }
    Dotenv\Update-Dotenv
}
```

- [ ] **Step 4: Run and confirm green.** Same command, plus `tests/Roles.Contract.Tests.ps1`, `tests/Test-DFToolSchema.Tests.ps1` and `tests/ConvertTo-DFToolRecord.Tests.ps1`.

---

### Task 4: mise

**Files:**
- Create: `Tools/mise.json`, `Tools/mise.ps1`
- Test: `tests/mise.Tests.ps1`

- [ ] **Step 1: Failing tests:**

```powershell
BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    . "$PSScriptRoot/../Private/ConvertTo-DFPath.ps1"
    . "$PSScriptRoot/../Public/Add-DFToPath.ps1"
    $script:CompanionPath = Join-Path $PSScriptRoot '../Tools/mise.ps1'
}

Describe 'mise companion' {
    BeforeEach {
        $script:SavedPath = $Env:Path
        $script:SavedData = $Env:XDG_DATA_HOME
        $Env:XDG_DATA_HOME = Join-Path $TestDrive 'data'
    }
    AfterEach {
        $Env:Path = $script:SavedPath
        $Env:XDG_DATA_HOME = $script:SavedData
        Remove-DFTestGlobal -Function mise
        Remove-Variable MiseActivated -Scope Global -ErrorAction Ignore
    }

    It 'puts its shims on PATH from the body, without activating' {
        function global:mise { $global:MiseActivated = $true }
        . $script:CompanionPath
        ($Env:Path -split ';') | Should -Contain (Join-Path $TestDrive 'data\mise\shims')
        $global:MiseActivated | Should -BeNullOrEmpty
    }

    It 'activates through its project-env hook' {
        function global:mise { '$global:MiseActivated = $true' }
        . $script:CompanionPath
        . Initialize-DFRoleProjectEnv -Role project-env
        $global:MiseActivated | Should -BeTrue
    }
}

Describe 'Tools/mise.json' {
    It 'registers after the prompt engines, because activation wraps the prompt' {
        $j = Get-Content (Join-Path $PSScriptRoot '../Tools/mise.json') -Raw | ConvertFrom-Json
        $j.dependsOn | Should -Contain 'oh-my-posh'
        $j.dependsOn | Should -Contain 'starship'
    }
}
```

- [ ] **Step 2: Run and confirm red.**

- [ ] **Step 3: Implement** `Tools/mise.json` exactly as in spec §4. `Tools/mise.ps1`:

```powershell
# Companion for mise — dev tool versions, env vars and tasks per project.
#
# The body runs whether or not mise wins project-env: it puts mise's shims on
# PATH so tools mise installed keep working under another project-env tool.
# mise honors XDG_DATA_HOME natively, so its shims live in
# <XDG_DATA_HOME>\mise\shims. Activation runs only for the role's winner, and
# is generated live every session: its output embeds the current PATH, so a
# cached copy would restore a stale one (docs/external-dependencies.md).
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingInvokeExpression', '')]
param()

Add-DFToPath (Join-Path (Get-DFXdgPath Data) 'mise\shims')

function Initialize-DFRoleProjectEnv {
    # Called by DotForge only when mise wins the project-env role.
    param([PSCustomObject]$Tool, [string]$Role)
    (& mise activate pwsh) | Out-String | Invoke-Expression
}
```

- [ ] **Step 4: Run and confirm green**, plus `tests/Roles.Contract.Tests.ps1`.

---

### Task 5: Real-record `project-env` registration

**Files:** Test: `tests/DefaultToolRoles.Tests.ps1`

- [ ] **Step 1: Write the test** (a new `Describe`, modeled on the prompt one). Mock `Get-Command` so `direnv.exe` and `mise.exe` resolve. Mock `Get-Module -ListAvailable` to return the fake Dotenv module path (copy the Task 3 fake module into `$TestDrive`). Stub `function global:mise { '$global:ProjectEnvInits += "mise"' }`. Mock `Get-DFCachedCommandOutput` for `direnv-hook` (`'$global:ProjectEnvInits += "direnv"'`) and `direnv-version` (`'2.38.0'`). Restore `LocationChangedAction` and PATH in `AfterEach`, remove `DFDotenvLocationHook`, and `Remove-Module Dotenv`. Two tests:
  - `Register-DFTool -Name ps-dotenv, mise, direnv` runs only the ps-dotenv hook (fake `Update-Dotenv` recorded, no `mise` and no `direnv` entries). It warns once (exclusive role, three candidates). The mise shims path is on PATH.
  - With `Defaults = @{ 'project-env' = 'mise' }`: only `mise` is recorded, and the fake `Update-Dotenv` never ran.
- [ ] **Step 2: Run** `tests/DefaultToolRoles.Tests.ps1`. The new tests should pass, since Tasks 2–4 are in place. Prove they can fail: temporarily set ps-dotenv's priority to 1 and see the first test fail, then restore.

---

### Task 6: Docs, verification, commit

- [ ] **Docs:**
  - `docs/guide/tools.md`: rows for ps-dotenv and mise; the direnv note (bash path, warning); a "Per-folder environments" paragraph covering safe mode and `DotenvApprovedDirs`.
  - `docs/guide/configuration.md`: add `DotenvSafeMode` and `DotenvApprovedDirs` to the settings table, with an example `$DFConfig = @{ DotenvApprovedDirs = @('~\projects') }` marked `<!-- system -->` if run, or with no output block.
  - `docs/guide/writing-a-tool.md`: a `scoopBucket` row in the record table.
  - `docs/external-dependencies.md`: four entries per spec §7, each with what breaks and how it degrades.
  - CHANGELOG `[Unreleased]` Added/Changed.
  - TODO: mark the per-directory-env item done, keeping the "survey other alternatives" note.
  - Regenerate `docs/reference.md`.
- [ ] **Full suite, run alone:** `pwsh -NoProfile -NonInteractive -c '$r = Invoke-Pester tests/ -PassThru -Output None; "passed $($r.PassedCount) failed $($r.FailedCount) skipped $($r.SkippedCount)"'`. Expected: 0 failed, 0 skipped.
- [ ] **Real machine, read-only:**
  - In a throwaway `pwsh -NoProfile`, `Import-Module ./DotForge.psd1; Register-DFTool -Name ps-dotenv, mise, direnv` with no `$DFConfig`. Check that ps-dotenv wins, `$Dotenv.Enabled` and `$Dotenv.SafeMode` are true, `$Dotenv.Async` is false, and mise's shims are on PATH.
  - Then, in a temp folder with an approved `.env` containing `DF_PROBE=1`, `Set-Location` there and confirm `$Env:DF_PROBE` is `1`. Approve it via `$DFConfig.DotenvApprovedDirs` set before import.
  - Then `$DFConfig = @{ Defaults = @{ 'project-env' = 'mise' } }` in a fresh session. In a temp folder holding `mise.toml` with `[env]\nDF_PROBE = "2"`, `cd` there and confirm the value is `2`. Check no warning appears beyond the expected ones.
  - Report each outcome.
- [ ] **Commit** (one signed commit, `feat(tools): ps-dotenv, mise and a working direnv for project-env`), staging only this work. If signing times out, ask the user to unlock.
