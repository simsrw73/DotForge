# XDG Model Split Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move non-XDG environment settings out of `xdg.vars` into a dedicated top-level `env` block, reducing `xdg.vars` to path-templates-only, migrating fzf/delta/less/mdcat behavior-preservingly.

**Architecture:** A new top-level `env` object (`env-var → value`) in the tool JSON, applied unconditionally by `Register-DFTool` via the existing `Expand-DFXdgPath` (flag strings pass through; `${XDG_*}` still expands). Four tool JSONs migrate; the standard is amended so `xdg.vars` holds only `${XDG_*}` path templates.

**Tech Stack:** PowerShell 7+, Pester 5/6 (suite passes under both).

## Global Constraints

Copied verbatim from `docs/superpowers/specs/2026-07-25-xdg-model-split-design.md`:

- **Target invariant:** after this work, `xdg.vars` contains ONLY `${XDG_*}` path templates. Every non-path env var lives in the top-level `env` block. No exceptions (theme vars `DELTA_FEATURES`/`MDCAT_THEME` move now too).
- **Behavior-preserving:** the exact env vars set today must still be set to the same values after migration. This is a pure relocation, not a policy change. Clobber semantics unchanged (`SetEnvironmentVariable(..., 'Process')`).
- **`env` applies unconditionally** (independent of `xdg.method`), through `Expand-DFXdgPath` (reused unchanged).
- **`method`/`compliance` are distinct:** `method` = dispatch key (what `Register-DFTool` does); `compliance` = documentation. fzf/delta → `method: default` + `compliance: none`; mdcat → `method: default` + `compliance: full`.
- **Ordering:** the `env` block is applied right after the `xdg` switch (`Public/Register-DFTool.ps1` ~line 135), which is BEFORE the companion `.ps1` dot-source (~line 235). mdcat's sidecar must still override the env default when `$DFConfig` specifies a theme.
- No new `xdg.method` value; no change to the `Register-DFTool` `switch`.
- Tests pass under Pester 5.8.0 AND 6.0.1; run `pwsh -NoProfile -Command 'Invoke-Pester tests/ -Output Detailed'`.

## File Structure

**Modify:**
- `Public/Register-DFTool.ps1` — apply the `env` block after the `xdg` switch.
- `Tools/fzf.json`, `Tools/delta.json`, `Tools/less.json`, `Tools/mdcat.json` — migrate.
- `tests/Register-DFTool.Tests.ps1` — `env`-block application tests.
- `tests/mdcat.Tests.ps1` — update two data assertions to the new location.
- `tests/Test-DFToolSchema.Tests.ps1` — add `mdcat` to the seed-file list.
- `ToolAcquisitionSpec.md`, `CLAUDE.md`, `docs/external-dependencies.md`, `CHANGELOG.md`, `README.md`.

**Create:**
- `tests/XdgSplit.Tests.ps1` — behavior-preservation + invariant tests for the four migrated tools.

---

### Task 1: Apply the `env` block in `Register-DFTool`

**Files:**
- Modify: `Public/Register-DFTool.ps1` (after the `xdg` switch, ~line 135)
- Test: `tests/Register-DFTool.Tests.ps1`

**Interfaces:**
- Consumes: `Expand-DFXdgPath -Template <string>` (existing), the tool record's optional `env` property.
- Produces: env-block application — for each `env` entry, `[System.Environment]::SetEnvironmentVariable($name, (Expand-DFXdgPath $value), 'Process')`. Applied to every tool regardless of `xdg.method`.

- [ ] **Step 1: Write the failing test**

Add to `tests/Register-DFTool.Tests.ps1`, inside the `Describe 'Register-DFTool'` block (after the existing `'sets XDG env vars when method is env'` test):

```powershell
    It 'applies the top-level env block independently of xdg.method' {
        Mock Get-Command { [PSCustomObject]@{ Path = 'C:\fake\envtool.exe' } }
        @'
{
  "name": "envtool",
  "executable": "envtool.exe",
  "xdg": { "compliance": "none", "method": "default" },
  "env": {
    "ENVTOOL_OPTS": "--layout=reverse\n--border",
    "ENVTOOL_XDGREF": "${XDG_CONFIG_HOME}/envtool"
  }
}
'@ | Set-Content (Join-Path $script:TmpTools 'envtool.json')
        try {
            Register-DFTool -Name 'envtool' -ToolsPath $script:TmpTools
            # Flag string preserved byte-for-byte (including the newline)
            $Env:ENVTOOL_OPTS   | Should -Be "--layout=reverse`n--border"
            # ${XDG_*} inside an env value still expands
            $Env:ENVTOOL_XDGREF | Should -Be (Join-Path $Env:XDG_CONFIG_HOME 'envtool')
        } finally {
            Remove-Item Env:\ENVTOOL_OPTS, Env:\ENVTOOL_XDGREF -ErrorAction Ignore
        }
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `pwsh -NoProfile -Command 'Invoke-Pester tests/Register-DFTool.Tests.ps1 -Output Detailed'`
Expected: FAIL — `$Env:ENVTOOL_OPTS` is empty (the `env` block is not yet applied).

- [ ] **Step 3: Implement the env-block application**

In `Public/Register-DFTool.ps1`, immediately after the `xdg` switch closes, add the block. Find:

```powershell
            'default' { } # tool already follows XDG natively — no env config needed
        }
```

and insert directly after that closing `}`:

```powershell

        # ── Non-XDG environment settings ───────────────────────────────────
        # Applied unconditionally (env vars are not tied to xdg.method). Values
        # go through Expand-DFXdgPath so ${XDG_*} still expands while flag
        # strings pass through byte-for-byte.
        $envBlock = $tool.PSObject.Properties['env']?.Value
        if ($envBlock) {
            $envBlock.PSObject.Properties | ForEach-Object {
                [System.Environment]::SetEnvironmentVariable(
                    $_.Name,
                    (Expand-DFXdgPath $_.Value),
                    'Process'
                )
            }
        }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `pwsh -NoProfile -Command 'Invoke-Pester tests/Register-DFTool.Tests.ps1 -Output Detailed'`
Expected: PASS (the new test and all existing Register-DFTool tests).

- [ ] **Step 5: Commit**

```bash
git add Public/Register-DFTool.ps1 tests/Register-DFTool.Tests.ps1
git commit -m "feat(tools): apply top-level env block in Register-DFTool"
```

---

### Task 2: Migrate the four tool JSONs + update tests

**Files:**
- Modify: `Tools/fzf.json`, `Tools/delta.json`, `Tools/less.json`, `Tools/mdcat.json`
- Modify: `tests/mdcat.Tests.ps1`, `tests/Test-DFToolSchema.Tests.ps1`
- Create: `tests/XdgSplit.Tests.ps1`

**Interfaces:**
- Consumes: the `env`-block application from Task 1.
- Produces: migrated tool records whose `xdg.vars` is path-only and whose non-XDG vars live under `env`.

- [ ] **Step 1: Write the failing behavior-preservation tests**

Create `tests/XdgSplit.Tests.ps1`:

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
    . "$PSScriptRoot/../Private/Get-DFCoreutilsShadowSet.ps1"
    . "$PSScriptRoot/../Public/Get-DFCommandConflict.ps1"
    . "$PSScriptRoot/../Private/Initialize-DFCompletionStack.ps1"
    . "$PSScriptRoot/../Private/Get-DFConfiguredTheme.ps1"
    . "$PSScriptRoot/../Public/Register-DFTool.ps1"
    $script:RealTools = Join-Path $PSScriptRoot '../Tools'
}

Describe 'xdg.vars is path-templates-only after the split' {
    It 'tool <Name> has no non-XDG value in xdg.vars' -ForEach @(
        @{ Name = 'fzf' }, @{ Name = 'delta' }, @{ Name = 'less' }, @{ Name = 'mdcat' }
    ) {
        $j = Get-Content (Join-Path $script:RealTools "$Name.json") -Raw | ConvertFrom-Json
        $vars = $j.xdg.PSObject.Properties['vars']?.Value
        if ($vars) {
            foreach ($p in $vars.PSObject.Properties) {
                $p.Value | Should -Match '\$\{XDG_(CONFIG|DATA|STATE|CACHE)_HOME\}' `
                    -Because "$Name xdg.vars['$($p.Name)'] must be an XDG path template"
            }
        }
    }
}

Describe 'env-block relocation preserves the migrated values' {
    It 'fzf env carries the fuzzy-finder settings' {
        $j = Get-Content (Join-Path $script:RealTools 'fzf.json') -Raw | ConvertFrom-Json
        $j.env.FZF_DEFAULT_COMMAND | Should -Be 'fd --type f --hidden --follow --exclude .git'
        $j.env.FZF_DEFAULT_OPTS    | Should -Match '--layout=reverse'
        $j.env.FZF_DEFAULT_OPTS    | Should -Match '#1e1e2e'
        $j.env.FZF_CTRL_T_OPTS     | Should -Match 'bat --color=always'
    }
    It 'delta env carries GIT_PAGER and DELTA_FEATURES' {
        $j = Get-Content (Join-Path $script:RealTools 'delta.json') -Raw | ConvertFrom-Json
        $j.env.GIT_PAGER      | Should -Be 'delta'
        $j.env.DELTA_FEATURES | Should -Be 'catppuccin-mocha'
    }
    It 'less keeps its XDG paths and moves LESS to env' {
        $j = Get-Content (Join-Path $script:RealTools 'less.json') -Raw | ConvertFrom-Json
        $j.xdg.vars.LESSHISTFILE | Should -Match '\$\{XDG_STATE_HOME\}'
        $j.xdg.vars.LESSKEY      | Should -Match '\$\{XDG_CONFIG_HOME\}'
        $j.xdg.vars.PSObject.Properties['LESS'] | Should -BeNullOrEmpty
        $j.env.LESS | Should -Be '--RAW-CONTROL-CHARS --quit-if-one-screen --no-init'
    }
    It 'mdcat moves MDCAT_THEME to env and is method default' {
        $j = Get-Content (Join-Path $script:RealTools 'mdcat.json') -Raw | ConvertFrom-Json
        $j.xdg.method     | Should -Be 'default'
        $j.env.MDCAT_THEME | Should -Be 'catppuccin-mocha'
    }
}

Describe 'Register applies the migrated env settings (tools without a sidecar)' {
    BeforeEach {
        $script:SavedFzf   = $Env:FZF_DEFAULT_OPTS
        $script:SavedPager = $Env:GIT_PAGER
        $script:SavedLess  = $Env:LESS
        $script:SavedState = $Env:XDG_STATE_HOME
        $script:SavedCfg   = $Env:XDG_CONFIG_HOME
        $Env:XDG_STATE_HOME  = Join-Path $TestDrive 'state'
        $Env:XDG_CONFIG_HOME = Join-Path $TestDrive 'config'
        Mock Get-Command { [PSCustomObject]@{ Path = 'C:\fake\tool.exe' } }
    }
    AfterEach {
        $Env:FZF_DEFAULT_OPTS = $script:SavedFzf
        $Env:GIT_PAGER        = $script:SavedPager
        $Env:LESS             = $script:SavedLess
        $Env:XDG_STATE_HOME   = $script:SavedState
        $Env:XDG_CONFIG_HOME  = $script:SavedCfg
    }

    It 'sets FZF_DEFAULT_OPTS from fzf.json env' {
        Register-DFTool -Name 'fzf' -ToolsPath $script:RealTools
        $Env:FZF_DEFAULT_OPTS | Should -Match '--layout=reverse'
    }
    It 'sets GIT_PAGER from delta.json env' {
        Register-DFTool -Name 'delta' -ToolsPath $script:RealTools
        $Env:GIT_PAGER | Should -Be 'delta'
    }
    It 'sets LESS from less.json env and still sets the XDG history path' {
        Register-DFTool -Name 'less' -ToolsPath $script:RealTools
        $Env:LESS         | Should -Be '--RAW-CONTROL-CHARS --quit-if-one-screen --no-init'
        $Env:LESSHISTFILE | Should -Be (Join-Path $Env:XDG_STATE_HOME 'less' 'history')
    }
}
```

Note: `LESSHISTFILE`/`LESSKEY` are restored implicitly — add them to the save/restore set if your environment has them set; the assertions above only require `XDG_STATE_HOME`/`XDG_CONFIG_HOME` to be redirected.

- [ ] **Step 2: Run to verify it fails**

Run: `pwsh -NoProfile -Command 'Invoke-Pester tests/XdgSplit.Tests.ps1 -Output Detailed'`
Expected: FAIL — the JSONs still have the old shape (`env` blocks absent; `xdg.vars` holds non-XDG values; mdcat method is `env`).

- [ ] **Step 3: Migrate `Tools/fzf.json`**

Replace the `xdg` block and add `env`. The full file becomes:

```json
{
  "name": "fzf",
  "description": "General-purpose command-line fuzzy finder",
  "tags": [
    "fuzzy",
    "picker",
    "search"
  ],
  "executable": "fzf.exe",
  "packages": {
    "scoop": "fzf",
    "winget": "junegunn.fzf",
    "choco": "fzf"
  },
  "xdg": {
    "compliance": "none",
    "method": "default"
  },
  "env": {
    "FZF_DEFAULT_COMMAND": "fd --type f --hidden --follow --exclude .git",
    "FZF_DEFAULT_OPTS": "--color=bg+:#313244,bg:#1e1e2e,spinner:#f5e0dc,hl:#f38ba8\n--color=fg:#cdd6f4,header:#f38ba8,info:#cba6f7,pointer:#f5e0dc\n--color=marker:#f5e0dc,fg+:#cdd6f4,prompt:#cba6f7,hl+:#f38ba8\n--exact\n--no-sort\n--layout=reverse\n--border\n--cycle\n--height 50%",
    "FZF_ALT_C_COMMAND": "fd -H -L -E .git -t d",
    "FZF_ALT_C_OPTS": "--preview \"eza -a --icons --group-directories-first --color=always {}\"",
    "FZF_CTRL_T_COMMAND": "fd -H -L -E .git -t f",
    "FZF_CTRL_T_OPTS": "--preview \"bat --color=always --line-range=:500 {}\""
  },
  "aliases": {},
  "picker": null
}
```

- [ ] **Step 4: Migrate `Tools/delta.json`**

```json
{
  "name": "delta",
  "description": "Syntax-highlighting pager for git diff output",
  "tags": [
    "git",
    "diff",
    "pager"
  ],
  "executable": "delta.exe",
  "packages": {
    "scoop": "delta",
    "winget": "dandavison.delta",
    "choco": "delta"
  },
  "xdg": {
    "compliance": "none",
    "method": "default"
  },
  "env": {
    "GIT_PAGER": "delta",
    "DELTA_FEATURES": "catppuccin-mocha"
  },
  "aliases": {},
  "picker": null
}
```

- [ ] **Step 5: Migrate `Tools/less.json`** (keep XDG paths + dirs; move only `LESS`)

```json
{
  "name": "less",
  "description": "Opposite of more — terminal pager",
  "tags": [
    "pager",
    "viewer"
  ],
  "executable": "less.exe",
  "packages": {
    "scoop": "less",
    "choco": "less"
  },
  "xdg": {
    "compliance": "partial",
    "method": "env",
    "vars": {
      "LESSHISTFILE": "${XDG_STATE_HOME}/less/history",
      "LESSKEY": "${XDG_CONFIG_HOME}/less/lesskey"
    },
    "dirs": [
      "${XDG_STATE_HOME}/less",
      "${XDG_CONFIG_HOME}/less"
    ]
  },
  "env": {
    "LESS": "--RAW-CONTROL-CHARS --quit-if-one-screen --no-init"
  },
  "aliases": {},
  "picker": null
}
```

- [ ] **Step 6: Migrate `Tools/mdcat.json`** (method `env` → `default`; `MDCAT_THEME` → `env`)

```json
{
  "name": "mdcat",
  "description": "cat for markdown — render CommonMark in the terminal",
  "tags": [
    "markdown",
    "viewer",
    "text"
  ],
  "executable": "mdcat.exe",
  "packages": {
    "scoop": "mdcat",
    "cargo": "mdcat"
  },
  "xdg": {
    "compliance": "full",
    "method": "default"
  },
  "env": {
    "MDCAT_THEME": "catppuccin-mocha"
  },
  "aliases": {},
  "picker": null
}
```

- [ ] **Step 7: Update `tests/mdcat.Tests.ps1`** (the two data assertions in `Describe 'Tools/mdcat.json'`)

Replace:

```powershell
    It 'declares the env XDG method' {
        $script:McatJson.xdg.method | Should -Be 'env'
    }
    It 'sets a catppuccin MDCAT_THEME default' {
        $script:McatJson.xdg.vars.MDCAT_THEME | Should -Be 'catppuccin-mocha'
    }
```

with:

```powershell
    It 'declares the default XDG method (mdcat is XDG-native)' {
        $script:McatJson.xdg.method | Should -Be 'default'
    }
    It 'sets a catppuccin MDCAT_THEME default in the env block' {
        $script:McatJson.env.MDCAT_THEME | Should -Be 'catppuccin-mocha'
    }
```

(The `Describe 'mdcat tool sidecar'` tests are unchanged and must still pass — `Register-DFTool` now applies the `env` default before the sidecar overrides it.)

- [ ] **Step 8: Add `mdcat` to the schema seed list** in `tests/Test-DFToolSchema.Tests.ps1`

In the `$seedFiles` array, add `'mdcat'` (e.g. append to the line with `'bitwarden', 'npm', ...`):

```powershell
        'bitwarden', 'npm', 'fnm', 'scoop', 'winget',
        'posh-git', 'psreadline', 'PSFzf', 'Terminal-Icons', 'oh-my-posh',
        'gsudo', 'mdcat'
```

- [ ] **Step 9: Run the migration tests + affected suites**

Run: `pwsh -NoProfile -Command 'Invoke-Pester tests/XdgSplit.Tests.ps1, tests/mdcat.Tests.ps1, tests/Test-DFToolSchema.Tests.ps1 -Output Detailed'`
Expected: PASS. (mdcat sidecar tests are `-Skip` unless `mdcat.exe` is installed; the JSON-shape tests run regardless.)

- [ ] **Step 10: Run the full suite for regressions**

Run: `pwsh -NoProfile -Command 'Invoke-Pester tests/ -Output Detailed'`
Expected: PASS — no regressions.

- [ ] **Step 11: Commit**

```bash
git add Tools/fzf.json Tools/delta.json Tools/less.json Tools/mdcat.json tests/XdgSplit.Tests.ps1 tests/mdcat.Tests.ps1 tests/Test-DFToolSchema.Tests.ps1
git commit -m "refactor(tools): move non-XDG env vars from xdg.vars to env block (fzf, delta, less, mdcat)"
```

---

### Task 3: Amend the standard and docs

**Files:**
- Modify: `ToolAcquisitionSpec.md`, `CLAUDE.md`, `docs/external-dependencies.md`, `CHANGELOG.md`, `README.md`

**Interfaces:** none (documentation only).

- [ ] **Step 1: Amend `ToolAcquisitionSpec.md` §3**

Find the path-templating paragraph (the one stating `xdg.vars` values MAY also be plain strings, e.g. a `LESS` flag string). Replace that allowance with the new rule:

```markdown
Path templating: `xdg.vars`/`xdg.dirs`/`config_path` values MAY use the tokens `${XDG_CONFIG_HOME}`,
`${XDG_DATA_HOME}`, `${XDG_STATE_HOME}`, `${XDG_CACHE_HOME}`, expanded by
`Private/Expand-DFXdgPath.ps1` (case-sensitive `-creplace`; exact `${…}` form only). `XDG_BIN_HOME` is
**not** a supported token. **`xdg.vars` values are `${XDG_*}` path templates only.** Non-path
environment variables (flag strings, tool options, `GIT_PAGER`, theme names, …) belong in the
tool's top-level **`env`** block, applied unconditionally by `Register-DFTool` (also via
`Expand-DFXdgPath`, so an `env` value that references `${XDG_*}` still expands).
```

- [ ] **Step 2: Document the `env` block in `CLAUDE.md`**

In the "Tool JSON Schema" section, add an entry after the `xdg.vars` bullet:

```markdown
- `env` (optional): a top-level map of environment variable → value for **non-XDG** session
  settings (fzf options, `GIT_PAGER`, `LESS`, theme names, …). Applied unconditionally by
  `Register-DFTool` via `[Environment]::SetEnvironmentVariable(..., 'Process')` through
  `Expand-DFXdgPath` (flag strings pass through; `${XDG_*}` still expands). Keep `xdg.vars`
  for `${XDG_*}` path templates only.
```

- [ ] **Step 3: Update `docs/external-dependencies.md`**

Find the note about `Expand-DFXdgPath` passing flag strings through un-normalized (the `LESS`/`FZF_DEFAULT_OPTS` dual-use). Re-point it from "`xdg.vars`" to "the `env` channel". If the note lives in `Private/Expand-DFXdgPath.ps1`'s comment (`# See docs/external-dependencies.md`), update the prose entry it references so it reads that token-less flag strings now arrive from the `env` block (fzf, delta, less), not `xdg.vars`.

- [ ] **Step 4: Update `CHANGELOG.md`**

Under `[Unreleased]`, add a `### Changed` entry (create the heading if absent):

```markdown
### Changed

- **Non-XDG environment variables moved out of `xdg.vars` into a dedicated top-level `env`
  block.** `xdg.vars` is now `${XDG_*}` path-templates only. Affects `fzf`, `delta`, `less`,
  and `mdcat` (fzf/delta/mdcat move to `xdg.method: default`). Behavior is unchanged — the same
  variables are set to the same values, just declared in `env`.
```

- [ ] **Step 5: Update `README.md`**

Grep for any reference to the migrated vars or to `xdg.vars` holding flag strings:

Run: `pwsh -NoProfile -Command 'Select-String -Path README.md -Pattern "xdg.vars|FZF_DEFAULT_OPTS|DELTA_FEATURES|GIT_PAGER" '`

If the README documents the tool JSON schema or lists `xdg.vars` semantics, add the `env` block there. If there are no matches, no change is needed (note that in the commit body).

- [ ] **Step 6: Commit**

```bash
git add ToolAcquisitionSpec.md CLAUDE.md docs/external-dependencies.md CHANGELOG.md README.md
git commit -m "docs: standardize the env block; xdg.vars is path-templates only"
```

---

## Self-Review checklist (author ran before finalizing)

- **Spec coverage:** `env` block (Task 1) ✓; four-tool migration + `method: default` (Task 2) ✓; behavior-preservation tests (Task 2) ✓; standard §3 amendment + CLAUDE/external-deps/CHANGELOG/README (Task 3) ✓.
- **Type/name consistency:** the `env` property name, `Expand-DFXdgPath` call, and `SetEnvironmentVariable(..., 'Process')` match across the Register change, the tests, and the docs.
- **Ordering:** the `env` block is applied after the `xdg` switch (line ~135) and before the companion dot-source (line ~235), so mdcat's sidecar override still wins — verified against `Public/Register-DFTool.ps1`.
