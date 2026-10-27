# Claude Code and Script Installers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `script` install source (T-84) and a `claude-code` record that installs Claude Code natively, keeps its config in XDG, prefers PowerShell, follows DotForge's theme through the claude-themes plugin, and adds `cc`/`ccc`/`ccr`.

**Architecture:** The script source is an ordinary manager record (`Tools/script.json`) whose functions (`Tools/script.manage.ps1`) look the rest of a tool's `packages.script` entry up by its URL, so core stays free of manager names. Claude-specific behavior lives in `Tools/claude-code.json`, its companion and setup script; every call to the real `claude` and every download/process goes through a private seam tests replace. One small core extension: an alias may declare `ifFree`.

**Tech Stack:** PowerShell 7.2+, Pester 6.

**Spec:** `docs/superpowers/specs/2026-10-27-claude-code-design.md`

## Global Constraints

- Only an https URL written in a tool record is ever downloaded and run; never http, never a local path.
- Removal deletes only the record's declared paths, and never a path outside `$HOME`.
- `settings.json`: add only missing keys; never change a key the user set.
- Theme order: marketplace known → plugin installed and enabled → only then the `theme` key.
- No test downloads, runs an installer, or runs the real `claude`.
- Plugin rule: no tool or manager names in core code.

## Review Focus

1. `Install-DFTool claude-code -Confirm:$false` (the restore) never stops for the script prompt; without it, the prompt names the URL.
2. A `packages.script.remove` path with `..` or a `${HOME}`-relative path that resolves outside `$HOME` is refused, nothing deleted.
3. Theme switch while offline / Claude Code not installed: `theme` key unchanged, status says why, no throw.
4. `settings.json` that isn't valid JSON (or has a BOM / comments): left untouched, setup note.
5. `ccr <id>` passes the id through (`claude --resume <id>`); an alias with `ifFree` is skipped when a program of that name is on PATH, with a status note.

---

### Task 1: `ifFree` aliases (core extension)

**Files:** `Shared/Test-DFToolSchema.ps1` (aliases checker), `Shared/Import-DFToolDb.ps1` (`ConvertTo-DFAliasMap`), `Private/Register-DFToolAliases.ps1`; Test `tests/Register-DFToolAliases.Tests.ps1` (or the existing alias test file).

**Produces:** alias entries normalize to `{ command; args[]; ifFree [bool] }`.

- [ ] **Step 1: Failing tests**
  - `an ifFree alias is skipped when a program of that name exists, with a status note` — record alias `dfxnote = { command: 'Get-Date', ifFree: true }`; `Mock Test-DFCommandExists { $true }` (the seam in Step 3) → no alias or function `dfxnote`; `Get-DFToolNote` matches `dfxnote`.
  - `an ifFree alias is created when the name is free` — seam returns `$false` → alias/wrapper exists.
  - `ifFree must be a boolean` — schema error matching `ifFree`.
  - `an alias without ifFree is created even when a program has that name` — unchanged behavior.
- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement**: `ConvertTo-DFAliasMap` keeps `ifFree` (default `$false`); schema accepts a boolean; `Register-DFToolAliases` checks `Test-DFCommandExists -Name` (new private one-liner: any `Application` or `ExternalScript` of that name, so a seam) and skips with `Add-DFToolNote -Tool <name> -Note "<alias> isn't defined: a <alias> command already exists"`.
- [ ] **Step 4: Run** — PASS. Regenerate bundle.

### Task 2: the script-installer source (T-84)

**Files:** Create `Tools/script.json`, `Tools/script.manage.ps1`; Test `tests/Script.Manage.Tests.ps1`, `tests/ScriptPackages.Tests.ps1`.

**Produces (in `Tools/script.manage.ps1`):**
- `Find-DFScriptPackage -Url <string>` → the tool record and its `packages.script` object whose `id` equals the URL (from `Import-DFToolDb`), or throws.
- `Invoke-DFScriptDownload -Url <string>` → script text (seam: `Invoke-RestMethod`).
- `Invoke-DFScriptProcess -Path <string>` → exit code (seam: `pwsh -NoProfile -File <path>` as a child process; the install environment is already in the process, piece 3).
- `Install-DFScriptPackage -Id <string[]>` (`SupportsShouldProcess`, `ConfirmImpact = 'High'`): per URL, refuse non-https; `ShouldProcess(<tool>, "Download and run <url>")`; download to a temp file, run, delete; throw on non-zero exit.
- `Update-DFScriptPackage -Id <string[]>`: runs `update` argv, or writes "<tool> updates itself".
- `Remove-DFScriptPackage -Id <string[]>`: expands each `remove` template (`Expand-DFXdgPath`, `${HOME}`), canonical (`ConvertTo-DFPath`), refuses any not under `$HOME`; deletes files/folders that exist.
- `Get-DFScriptInstalled -Manager` → `{ Id = <url>; Installed = 'installed'; Available = $null }` for each record whose `installed` path exists.
- `Tools/script.json`: `executable: pwsh.exe`, `installs: { from: script, function: Install-DFScriptPackage, args: { Id: '{id}' }, update: { function: Update-DFScriptPackage, args: { Id: '{id}' } }, remove: { function: Remove-DFScriptPackage, args: { Id: '{id}' } }, list: Get-DFScriptInstalled, batch: false }`.

- [ ] **Step 1: Failing tests** (mock the two seams; no network, no process)
  - `installs by downloading and running the record's script, then deleting it` (seams invoked once; temp file gone).
  - `refuses a non-https URL without downloading`.
  - `asks before running, naming the URL; -Confirm:$false doesn't ask` (**RF1**: `$ConfirmPreference='None'` → no prompt; with `-WhatIf` nothing downloaded).
  - `throws when the script exits non-zero`.
  - `removes exactly the declared paths` and `refuses a path outside $HOME, deleting nothing` (**RF2**: `${HOME}/../x`).
  - `update runs the declared command / says a self-updating tool updates itself`.
  - `lists a tool whose installed path exists`.
  - `ScriptPackages.Tests`: every `Tools/*.json` `packages.script` has an https `id`, an `installed` path template, and `remove` templates rooted at `${HOME}` or `${XDG_*}`.
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** **Step 4: Run** — PASS. Regenerate registry.

### Task 3: the claude-code record

**Files:** Create `Tools/claude-code.json`; Test `tests/claude-code.Tests.ps1`.

- [ ] **Step 1: Failing tests** (record shape)
  - packages: `script` = `{ id: 'https://claude.ai/install.ps1', installed: '${HOME}/.local/bin/claude.exe', update: ['claude','update'], remove: ['${HOME}/.local/bin/claude.exe', '${XDG_DATA_HOME}/claude'] }`, `winget: 'Anthropic.ClaudeCode'`, `npm: '@anthropic-ai/claude-code'`; `install.prefer = ['script']`.
  - `xdg.vars.CLAUDE_CONFIG_DIR = '${XDG_CONFIG_HOME}/claude'`; native `CLAUDE_CONFIG_DIR = ['${HOME}/.claude']`, `'${XDG_CONFIG_HOME}/claude/.claude.json' = ['${HOME}/.claude.json']`; `desktop = ['CLAUDE_CONFIG_DIR']`.
  - aliases: `cc → claude`, `ccc → claude --continue`, `ccr → claude --resume`, each `ifFree: true`; and `ccr abc` calls `claude --resume abc` (**RF5**: stub `function global:claude { $args }`, removed with `Remove-DFTestGlobal`).
  - `New-DFInstallPlan` for claude-code with sources allowed picks `script` (plan test with mocks, as `tests/New-DFInstallPlan.Tests.ps1` does).
- [ ] **Steps 2–4**: RED, write the record, GREEN; regenerate registry; `ToolNative.Coverage` passes.

### Task 4: theme steps and Git Bash finder (companion)

**Files:** Create `Tools/claude-code.ps1`; Test `tests/claude-code.Tests.ps1`.

**Produces:** `Invoke-DFClaudeCli -Arguments <string[]>` → `{ ExitCode; Output }` (the one seam for the real `claude`); `Set-DFClaudeTheme -Name <string>` (global, the record's `theme.apply`); `Find-DFGitBash` → path or `$null`; `Get-DFClaudeSettingsPath` → `$CLAUDE_CONFIG_DIR\settings.json` (via the session's value, else `Get-DFXdgPath Config`\claude).

Record `theme`: `key: ClaudeTheme`, `default: catppuccin-mocha`, `map` for `catppuccin-mocha|-frappe|-latte|-macchiato` → `custom:catppuccin:<same>`, `apply: Set-DFClaudeTheme`. `Set-DFClaudeTheme` accepts a `custom:<plugin>:<id>` value as is.

- [ ] **Step 1: Failing tests** (mock `Invoke-DFClaudeCli`; settings file under TestDrive)
  - `adds the marketplace, then installs the plugin, then sets theme — in that order` (record call order; final file `theme = custom:catppuccin:catppuccin-mocha`).
  - `skips marketplace add and install when both are present` (`marketplace list --json` returns `claude-themes`; `plugin list --json` returns `catppuccin@claude-themes` enabled).
  - `enables an installed but disabled plugin before setting the theme`.
  - `leaves theme unchanged and notes why when a step fails` (**RF3**: install returns exit 1; key unchanged; `Get-DFToolNote claude-code` matches the failure; no throw).
  - `leaves settings.json alone when it isn't valid JSON` (**RF4**).
  - `Find-DFGitBash` prefers a scoop `current` folder: mocked `git --exec-path` = `…\apps\git\2.56.0.2\ucrt64\libexec\git-core` with `…\apps\git\current\bin\bash.exe` present → returns the `current` path; none → `$null`.
- [ ] **Steps 2–4**: RED, implement (JSON read/write with `ConvertFrom-Json -AsHashtable` / `ConvertTo-Json -Depth 20`, two-space indent), GREEN.

### Task 5: one-time settings merge (setup script)

**Files:** Create `Tools/claude-code.setup.ps1`; Test `tests/claude-code.Tests.ps1`.

- [ ] **Step 1: Failing tests**
  - `creates settings.json with defaultShell, the PowerShell tool and Git Bash path on a fresh machine` (`defaultShell = 'powershell'`, `env.CLAUDE_CODE_USE_POWERSHELL_TOOL = '1'`, `env.CLAUDE_CODE_GIT_BASH_PATH = <Find-DFGitBash>`).
  - `adds only missing keys, never changing yours` (existing `defaultShell = 'bash'` and `env.FOO` kept).
  - `leaves out the Git Bash key when there's no git`.
  - `sets the theme through Set-DFClaudeTheme` (invoked once with the session theme).
  - `records completion only after it succeeds` (`Complete-DFToolSetup` last; a throw records nothing).
- [ ] **Steps 2–4**: RED, implement, GREEN.

### Task 6: docs, close T-84

`docs/guide/tools.md` (claude-code; script installers and how to move from winget), `docs/guide/writing-a-tool.md` (`packages.script`, alias `ifFree`), `docs/guide/configuration.md` (install sources list includes `script`), CLAUDE.md (`packages` and aliases lines), CHANGELOG, restore notes (piece 9), TODO (delete T-84). Regenerate registry, bundle, reference; categories/identities entries for `claude-code` and `script` by hand (T-87). Full gate. One signed commit, `Closes T-84`.
