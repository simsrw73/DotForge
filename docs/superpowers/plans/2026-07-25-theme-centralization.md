# Theme Centralization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace hardcoded per-sidecar theme family→dialect mapping with a per-tool `themeMap` block resolved by a tiny `Resolve-DFThemeName`, and make delta respond to `$DFConfig.Theme`.

**Architecture:** Each themed tool optionally declares `themeMap` (canonical family → its dialect) in its own JSON; the pure `Resolve-DFThemeName -Name -ThemeMap` translates using the *target tool's* map (read from `$DFCurrentTool`), passing through anything not a canonical key. No central file, no startup file-read. Governed by `docs/plugin-architecture.md`.

**Tech Stack:** PowerShell 7+, Pester 5/6 (suite passes under both).

## Global Constraints

Copied from `docs/superpowers/specs/2026-07-25-theme-centralization-design.md`:

- **Config vocabulary:** `$DFConfig.Theme` (shared) is canonical-only (`catppuccin-mocha`). `$DFConfig.<Tool>Theme` accepts canonical OR that tool's own native names. The canonical is the ONLY value that triggers translation; everything else passes through to the tool's own built-in validation.
- **`Resolve-DFThemeName` is a pure translator:** `themeMap` key match (case-insensitive) → dialect; else pass through `$Name` unchanged. `$null`/absent map → pass-through. No file I/O, no validation, no fallback (those stay in sidecars). StrictMode-safe reads.
- **Only mdv needs a `themeMap`** (native `catppuccin` ≠ canonical). glow/psreadline/mdcat/delta call the family `catppuccin-mocha` natively — no `themeMap`; the canonical passes through their existing logic.
- **Retire the bare `catppuccin` alias.** All tool defaults are canonical `catppuccin-mocha`. Tests exercising the `catppuccin` alias as a shared `Theme` move to `catppuccin-mocha`.
- **Plugin invariant:** adding a themed tool must require only its own files. No `switch ($tool.name)` in core.
- Sidecars call `Resolve-DFThemeName` in their **body** (where `$DFCurrentTool` exists), not inside the global functions (which run later for pickers).
- Tests pass under Pester 5.8.0 AND 6.0.1; no `Assert-MockCalled`. Run `pwsh -NoProfile -Command 'Invoke-Pester tests/ -Output Detailed'`.

## File Structure

**Create:**
- `Private/Resolve-DFThemeName.ps1` — the resolver.
- `tests/Resolve-DFThemeName.Tests.ps1` — resolver unit tests.
- `Tools/delta.ps1` — delta theming sidecar.
- `tests/delta.Tests.ps1` — delta sidecar tests.

**Modify:**
- `Tools/glow.ps1`, `Tools/psreadline.ps1`, `Tools/mdcat.ps1`, `Tools/mdv.ps1` — use the resolver; drop hardcoded mapping.
- `Tools/mdv.json` — add `themeMap`; `settings.theme` → canonical.
- `Tools/delta.json` — remove `DELTA_FEATURES` from `env`.
- `tests/glow.Tests.ps1`, `tests/psreadline.Tests.ps1`, `tests/mdcat.Tests.ps1`, `tests/mdv.Tests.ps1` — alias→canonical; dot-source the resolver.
- `tests/XdgSplit.Tests.ps1` — drop the `env.DELTA_FEATURES` assertion.
- `ToolAcquisitionSpec.md`, `CLAUDE.md`, `docs/external-dependencies.md`, `CHANGELOG.md`, `README.md`.

---

### Task 1: The `Resolve-DFThemeName` resolver

**Files:**
- Create: `Private/Resolve-DFThemeName.ps1`
- Test: `tests/Resolve-DFThemeName.Tests.ps1`

**Interfaces:**
- Produces: `Resolve-DFThemeName -Name <string> -ThemeMap <pscustomobject>` → `[string]`. Canonical key in map (case-insensitive) → dialect value; else `$Name` unchanged; `$null`/empty map → `$Name`.

- [ ] **Step 1: Write the failing test**

Create `tests/Resolve-DFThemeName.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/../Private/Resolve-DFThemeName.ps1"
}

Describe 'Resolve-DFThemeName' {
    It 'translates a canonical family key to the tool dialect' {
        $map = [pscustomobject]@{ 'catppuccin-mocha' = 'catppuccin' }
        Resolve-DFThemeName -Name 'catppuccin-mocha' -ThemeMap $map | Should -Be 'catppuccin'
    }
    It 'matches the canonical key case-insensitively' {
        $map = [pscustomobject]@{ 'catppuccin-mocha' = 'catppuccin' }
        Resolve-DFThemeName -Name 'Catppuccin-Mocha' -ThemeMap $map | Should -Be 'catppuccin'
    }
    It 'passes a name that is not a canonical key straight through' {
        $map = [pscustomobject]@{ 'catppuccin-mocha' = 'catppuccin' }
        Resolve-DFThemeName -Name 'dracula' -ThemeMap $map | Should -Be 'dracula'
    }
    It 'passes through when the map is $null (tool has no themeMap)' {
        Resolve-DFThemeName -Name 'catppuccin-mocha' -ThemeMap $null | Should -Be 'catppuccin-mocha'
    }
    It 'passes through when the map is an empty object' {
        Resolve-DFThemeName -Name 'catppuccin-mocha' -ThemeMap ([pscustomobject]@{}) |
            Should -Be 'catppuccin-mocha'
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `pwsh -NoProfile -Command 'Invoke-Pester tests/Resolve-DFThemeName.Tests.ps1 -Output Detailed'`
Expected: FAIL — `Resolve-DFThemeName` not defined.

- [ ] **Step 3: Implement the resolver**

Create `Private/Resolve-DFThemeName.ps1`:

```powershell
#Requires -Version 7.0

function script:Resolve-DFThemeName {
    <#
    .SYNOPSIS
        Translates a canonical theme family name to a tool's native dialect
        using that tool's own themeMap. A pure, file-free translator.
    .DESCRIPTION
        If $ThemeMap contains a key equal to $Name (case-insensitive), returns
        the mapped dialect. Otherwise returns $Name unchanged — so a per-tool
        override that is the tool's own native name, or any non-canonical value,
        passes through to the sidecar's own built-in validation. A $null or
        empty map always passes through. The resolver never validates or falls
        back; that stays in the sidecars.
    .PARAMETER Name
        The configured theme name (from Get-DFConfiguredTheme's chain).
    .PARAMETER ThemeMap
        The target tool's themeMap object (canonical -> dialect), typically
        $DFCurrentTool.themeMap. May be $null.
    .OUTPUTS
        [string] the tool's dialect, or $Name unchanged.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Name,
        [pscustomobject]$ThemeMap
    )

    if ($null -ne $ThemeMap) {
        $prop = $ThemeMap.PSObject.Properties | Where-Object { $_.Name -ieq $Name } | Select-Object -First 1
        if ($prop) { return [string]$prop.Value }
    }
    $Name
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `pwsh -NoProfile -Command 'Invoke-Pester tests/Resolve-DFThemeName.Tests.ps1 -Output Detailed'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Private/Resolve-DFThemeName.ps1 tests/Resolve-DFThemeName.Tests.ps1
git commit -m "feat(theme): Resolve-DFThemeName — per-tool themeMap translator"
```

---

### Task 2: Refactor glow, psreadline, mdcat sidecars (no themeMap)

**Files:**
- Modify: `Tools/glow.ps1`, `Tools/psreadline.ps1`, `Tools/mdcat.ps1`
- Test: `tests/glow.Tests.ps1`, `tests/psreadline.Tests.ps1`, `tests/mdcat.Tests.ps1`

**Interfaces:**
- Consumes: `Resolve-DFThemeName` (Task 1). These three tools have native == canonical, so they declare no `themeMap`; the resolver call passes the canonical through unchanged, and removing the hardcoded `catppuccin` alias is the behavior change.

- [ ] **Step 1: Update the tests first (they encode the new behavior)**

In `tests/glow.Tests.ps1`: add the resolver to `BeforeAll` (alongside the existing `Get-DFConfiguredTheme` dot-source):

```powershell
    . "$PSScriptRoot/../Private/Resolve-DFThemeName.ps1"
```

Then change the two `catppuccin`-alias uses to the canonical. Line ~126–129:

```powershell
    It 'follows the shared $DFConfig[Theme] key (catppuccin-mocha -> bundled mocha)' {
        $Global:DFConfig = @{ Theme = 'catppuccin-mocha' }
```

Line ~134:

```powershell
        $Global:DFConfig = @{ Theme = 'catppuccin-mocha'; GlowTheme = 'dracula' }
```

In `tests/psreadline.Tests.ps1`: add the resolver dot-source to `BeforeAll`, then line ~82–84:

```powershell
    It 'follows the shared $DFConfig[Theme] key (catppuccin-mocha -> mocha)' {
        ...
        $Global:DFConfig = @{ Theme = 'catppuccin-mocha' }
```

Line ~93:

```powershell
        $Global:DFConfig = @{ Theme = 'catppuccin-mocha'; PSReadLineTheme = 'light' }
```

In `tests/mdcat.Tests.ps1`: add the resolver dot-source to `BeforeAll`, then line ~59–60:

```powershell
    It 'maps the shared catppuccin-mocha family to catppuccin-mocha' {
        $Global:DFConfig = @{ Theme = 'catppuccin-mocha' }
```

Also add a **discriminating negative test** to `tests/glow.Tests.ps1` (in the same `Describe` as the other theme tests) that proves the `catppuccin` alias is retired — it maps under the old code and must fall back under the new:

```powershell
    It 'no longer treats the bare "catppuccin" alias as the mocha family (retired)' {
        $Global:DFConfig = @{ Theme = 'catppuccin' }
        Register-DFTool -Name 'glow' -ToolsPath $script:RealTools
        # Old code mapped 'catppuccin' -> catppuccin-mocha.json; new code passes it
        # through and glow, not recognizing it, falls back to 'auto'.
        $global:DFGlowStyle | Should -Be 'auto'
    }
```

(Match the registration/setup idiom already used by the other glow theme tests — same `Register-DFTool -Name 'glow' -ToolsPath $script:RealTools` call and any `$DFConfig`/`$DFGlowStyle` cleanup those tests use.)

- [ ] **Step 2: Run to verify the negative test FAILS against the current sidecars**

Run: `pwsh -NoProfile -Command 'Invoke-Pester tests/glow.Tests.ps1, tests/psreadline.Tests.ps1, tests/mdcat.Tests.ps1 -Output Detailed'`
Expected: the new "retired alias" glow test **FAILS** (current glow maps `catppuccin` → `catppuccin-mocha.json`, so `$DFGlowStyle` is the bundled path, not `auto`). The canonical-updated tests PASS (the canonical already resolves via each tool's existing file/built-in logic). This is the RED that proves the alias removal is real.

- [ ] **Step 3: Remove the hardcoded mapping and add the resolver call**

**`Tools/glow.ps1`** — after the `$_theme = Get-DFConfiguredTheme -ToolKey 'GlowTheme' -Default $_default` line (~line 17), insert:

```powershell
$_theme = Resolve-DFThemeName -Name $_theme -ThemeMap ($DFCurrentTool.PSObject.Properties['themeMap']?.Value)
```

and DELETE the family-alias line inside `Resolve-DFGlowStyle` (~line 36–37):

```powershell
    # Family alias: the shared 'catppuccin' key means glow's bundled mocha flavour.
    if ($Name -eq 'catppuccin') { $Name = 'catppuccin-mocha' }
```

**`Tools/psreadline.ps1`** — change the apply block (~line 109–110) to resolve first:

```powershell
$_themeSetting = Get-DFConfiguredTheme -ToolKey 'PSReadLineTheme' -Default 'dark'
$_themeSetting = Resolve-DFThemeName -Name $_themeSetting -ThemeMap ($DFCurrentTool.PSObject.Properties['themeMap']?.Value)
Invoke-DFApplyPSReadLineTheme -Name $_themeSetting
```

and DELETE the family-alias line inside `Invoke-DFApplyPSReadLineTheme` (~line 65–66):

```powershell
    # Family alias: the shared 'catppuccin' key means the bundled mocha flavour.
    if ($Name -eq 'catppuccin') { $Name = 'catppuccin-mocha' }
```

**`Tools/mdcat.ps1`** — change the theme block (~line 11–14). Replace:

```powershell
$_name = Get-DFConfiguredTheme -ToolKey 'MdcatTheme'
if ($_name) {
    # Family alias: bare 'catppuccin' -> mdcat's default flavour.
    if ($_name -eq 'catppuccin') { $_name = 'catppuccin-mocha' }
```

with:

```powershell
$_name = Get-DFConfiguredTheme -ToolKey 'MdcatTheme'
if ($_name) {
    $_name = Resolve-DFThemeName -Name $_name -ThemeMap ($DFCurrentTool.PSObject.Properties['themeMap']?.Value)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pwsh -NoProfile -Command 'Invoke-Pester tests/glow.Tests.ps1, tests/psreadline.Tests.ps1, tests/mdcat.Tests.ps1 -Output Detailed'`
Expected: PASS — including the "retired alias" test, which now goes GREEN (`catppuccin` passes through the resolver and glow falls back to `auto`). The canonical `catppuccin-mocha` still resolves through each tool's existing logic; the deleted alias lines are no longer needed.

- [ ] **Step 5: Full suite + commit**

Run: `pwsh -NoProfile -Command 'Invoke-Pester tests/ -Output Detailed'`
Expected: PASS.

```bash
git add Tools/glow.ps1 Tools/psreadline.ps1 Tools/mdcat.ps1 tests/glow.Tests.ps1 tests/psreadline.Tests.ps1 tests/mdcat.Tests.ps1
git commit -m "refactor(theme): glow/psreadline/mdcat resolve via Resolve-DFThemeName; retire catppuccin alias"
```

---

### Task 3: Refactor mdv sidecar + add `themeMap`

**Files:**
- Modify: `Tools/mdv.ps1`, `Tools/mdv.json`, `tests/mdv.Tests.ps1`

**Interfaces:**
- Consumes: `Resolve-DFThemeName` (Task 1). mdv is the one tool whose native (`catppuccin`) differs from canonical, so it declares `themeMap` and proves the translation.

- [ ] **Step 1: Update the tests first**

In `tests/mdv.Tests.ps1`: add `. "$PSScriptRoot/../Private/Resolve-DFThemeName.ps1"` to `BeforeAll`. Change the seed-theme assertion (~line 28–29) to the canonical default and add a `themeMap` assertion:

```powershell
    It 'names catppuccin-mocha as the default theme' {
        $script:MdvJson.settings.theme | Should -Be 'catppuccin-mocha'
    }
    It 'declares a themeMap translating the canonical family to catppuccin' {
        $script:MdvJson.themeMap.'catppuccin-mocha' | Should -Be 'catppuccin'
    }
```

The existing "maps the catppuccin family down to mdv's catppuccin theme" test (~line 80–84, already `Theme = 'catppuccin-mocha'`) stays — it now proves the `themeMap` path end to end. The "seeds config.yaml with the catppuccin theme when absent" test (~line 64–68, expects `theme: "catppuccin"`) stays unchanged — mdv's seeded native value is still `catppuccin`.

- [ ] **Step 2: Run to verify the new assertions FAIL**

Run: `pwsh -NoProfile -Command 'Invoke-Pester tests/mdv.Tests.ps1 -Output Detailed'`
Expected: FAIL — `settings.theme` is still `catppuccin`, and `themeMap` doesn't exist yet.

- [ ] **Step 3: Add `themeMap` and canonical default to `Tools/mdv.json`**

Change the `settings` block and add `themeMap` (place `themeMap` as a top-level sibling of `settings`):

```json
  "settings": {
    "theme": "catppuccin-mocha"
  },
  "themeMap": {
    "catppuccin-mocha": "catppuccin"
  },
```

- [ ] **Step 4: Refactor `Tools/mdv.ps1`**

Change the theme block (~line 10–14). Replace:

```powershell
$_default  = $_settings.PSObject.Properties['theme']?.Value ?? 'catppuccin'
$_name     = Get-DFConfiguredTheme -ToolKey 'MdvTheme' -Default $_default

# Family alias: mdv ships one catppuccin flavour, so any catppuccin-* -> catppuccin.
if ($_name -like 'catppuccin-*') { $_name = 'catppuccin' }
```

with:

```powershell
$_default  = $_settings.PSObject.Properties['theme']?.Value ?? 'catppuccin-mocha'
$_name     = Get-DFConfiguredTheme -ToolKey 'MdvTheme' -Default $_default
$_name     = Resolve-DFThemeName -Name $_name -ThemeMap ($DFCurrentTool.PSObject.Properties['themeMap']?.Value)
```

- [ ] **Step 5: Run mdv tests + full suite**

Run: `pwsh -NoProfile -Command 'Invoke-Pester tests/mdv.Tests.ps1 -Output Detailed'`
Expected: PASS — `settings.theme` is canonical, `themeMap` present, and `Theme = 'catppuccin-mocha'` resolves to mdv's `catppuccin` (seeded in config.yaml).

Run: `pwsh -NoProfile -Command 'Invoke-Pester tests/ -Output Detailed'`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Tools/mdv.ps1 Tools/mdv.json tests/mdv.Tests.ps1
git commit -m "refactor(theme): mdv declares themeMap; resolves canonical -> catppuccin"
```

---

### Task 4: New delta sidecar; delta responds to `$DFConfig.Theme`

**Files:**
- Create: `Tools/delta.ps1`, `tests/delta.Tests.ps1`
- Modify: `Tools/delta.json`, `tests/XdgSplit.Tests.ps1`

**Interfaces:**
- Consumes: `Resolve-DFThemeName`, `Get-DFConfiguredTheme`. delta's native == canonical → no `themeMap`; the sidecar sets `DELTA_FEATURES` from the resolved theme.

- [ ] **Step 1: Write the failing test**

Create `tests/delta.Tests.ps1`:

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
    . "$PSScriptRoot/../Private/Resolve-DFThemeName.ps1"
    . "$PSScriptRoot/../Public/Register-DFTool.ps1"
    $script:RealTools = Join-Path $PSScriptRoot '../Tools'
}

Describe 'Tools/delta.json' {
    It 'no longer carries DELTA_FEATURES in its env block' {
        $j = Get-Content (Join-Path $script:RealTools 'delta.json') -Raw | ConvertFrom-Json
        $j.env.PSObject.Properties['DELTA_FEATURES'] | Should -BeNullOrEmpty
        $j.env.GIT_PAGER | Should -Be 'delta'
    }
}

Describe 'delta tool sidecar' {
    BeforeEach {
        $script:DFToolDb   = $null
        $script:SavedFeat  = $Env:DELTA_FEATURES
        $Env:DELTA_FEATURES = $null
        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
        Mock Get-Command { [PSCustomObject]@{ Path = 'C:\fake\delta.exe' } }
    }
    AfterEach {
        $Env:DELTA_FEATURES = $script:SavedFeat
        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
    }

    It 'sets DELTA_FEATURES to the canonical default when no theme is configured' {
        Register-DFTool -Name 'delta' -ToolsPath $script:RealTools
        $Env:DELTA_FEATURES | Should -Be 'catppuccin-mocha'
    }
    It 'follows the shared $DFConfig[Theme]' {
        $Global:DFConfig = @{ Theme = 'catppuccin-mocha' }
        Register-DFTool -Name 'delta' -ToolsPath $script:RealTools
        $Env:DELTA_FEATURES | Should -Be 'catppuccin-mocha'
    }
    It 'lets $DFConfig[DeltaTheme] override with a verbatim (non-canonical) name' {
        $Global:DFConfig = @{ DeltaTheme = 'my-custom-feature' }
        Register-DFTool -Name 'delta' -ToolsPath $script:RealTools
        $Env:DELTA_FEATURES | Should -Be 'my-custom-feature'
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `pwsh -NoProfile -Command 'Invoke-Pester tests/delta.Tests.ps1 -Output Detailed'`
Expected: FAIL — `delta.json` still has `DELTA_FEATURES` in `env`; no `delta.ps1` sets it from the theme.

- [ ] **Step 3: Create `Tools/delta.ps1`**

```powershell
# Companion for delta — set DELTA_FEATURES from the configured theme so it tracks
# $DFConfig.Theme. delta features are user-defined config names, so there is no
# built-in list to validate against; an unknown feature is silently ignored by
# delta. Rendering catppuccin requires a delta config defining that feature —
# out of DotForge's scope. See docs/external-dependencies.md.

$_theme  = Get-DFConfiguredTheme -ToolKey 'DeltaTheme' -Default 'catppuccin-mocha'
$_native = Resolve-DFThemeName -Name $_theme -ThemeMap ($DFCurrentTool.PSObject.Properties['themeMap']?.Value)
[System.Environment]::SetEnvironmentVariable('DELTA_FEATURES', $_native, 'Process')
```

- [ ] **Step 4: Remove `DELTA_FEATURES` from `Tools/delta.json`**

The `env` block becomes:

```json
  "env": {
    "GIT_PAGER": "delta"
  },
```

- [ ] **Step 5: Update `tests/XdgSplit.Tests.ps1`**

In the "delta env carries GIT_PAGER and DELTA_FEATURES" test (~line 44–48), drop the `DELTA_FEATURES` assertion and rename:

```powershell
    It 'delta env carries GIT_PAGER (DELTA_FEATURES moved to the sidecar)' {
        $j = Get-Content (Join-Path $script:RealTools 'delta.json') -Raw | ConvertFrom-Json
        $j.env.GIT_PAGER | Should -Be 'delta'
        $j.env.PSObject.Properties['DELTA_FEATURES'] | Should -BeNullOrEmpty
    }
```

- [ ] **Step 6: Run delta + XdgSplit + full suite**

Run: `pwsh -NoProfile -Command 'Invoke-Pester tests/delta.Tests.ps1, tests/XdgSplit.Tests.ps1 -Output Detailed'`
Expected: PASS.

Run: `pwsh -NoProfile -Command 'Invoke-Pester tests/ -Output Detailed'`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Tools/delta.ps1 Tools/delta.json tests/delta.Tests.ps1 tests/XdgSplit.Tests.ps1
git commit -m "feat(theme): delta.ps1 sets DELTA_FEATURES from the resolved theme"
```

---

### Task 5: Amend the standard and docs

**Files:** Modify `ToolAcquisitionSpec.md`, `CLAUDE.md`, `docs/external-dependencies.md`, `CHANGELOG.md`, `README.md`.

**Interfaces:** none (documentation only).

- [ ] **Step 1: `ToolAcquisitionSpec.md` §6.2**

Replace the central-`theme-aliases.json` example and the "accept alias or native" resolver text with the per-tool model: each themed tool optionally declares a `themeMap` (canonical → its dialect) in its own JSON; `Resolve-DFThemeName` translates using the target tool's map; shared `Theme` is canonical-only; per-tool overrides accept canonical or that tool's own native; the canonical is the only translation trigger; there are no aliases. Cross-reference `docs/plugin-architecture.md`. Example:

```jsonc
// Tools/mdv.json — only tools whose dialect differs from the canonical need this
"themeMap": { "catppuccin-mocha": "catppuccin" }
```

- [ ] **Step 2: `CLAUDE.md` — Tool JSON Schema**

Add an entry:

```markdown
- `themeMap` (optional): a map of canonical theme family → this tool's native
  dialect (e.g. `{ "catppuccin-mocha": "catppuccin" }`). Only needed when the
  tool's native name differs from the canonical. Sidecars resolve the configured
  theme with `Get-DFConfiguredTheme` (chain) then `Resolve-DFThemeName` (translate
  via this map), then validate against their own built-in list. Shared
  `$DFConfig.Theme` is canonical-only; per-tool `<Tool>Theme` accepts the
  canonical or the tool's own native names.
```

- [ ] **Step 3: `docs/external-dependencies.md`**

Add/adjust a delta entry: DotForge sets `DELTA_FEATURES` from the resolved theme (`Tools/delta.ps1`); delta actually rendering catppuccin requires a delta config defining that feature — out of DotForge's scope; an undefined feature is silently ignored (degrade, never fail).

- [ ] **Step 4: `CHANGELOG.md` `[Unreleased]` → `### Changed`**

```markdown
- **Theme family→dialect mapping moved from hardcoded sidecar rules into an
  optional per-tool `themeMap`**, resolved by `Resolve-DFThemeName` from each
  tool's own declaration (no central registry). The bare `catppuccin` alias is
  retired in favor of the canonical `catppuccin-mocha`; shared `$DFConfig.Theme`
  is canonical-only. `delta` now themes via `Tools/delta.ps1` — `DELTA_FEATURES`
  tracks `$DFConfig.Theme` instead of being a static value.
```

- [ ] **Step 5: `README.md`**

Grep for `$DFConfig` theme documentation:

Run: `pwsh -NoProfile -Command 'Select-String -Path README.md -Pattern "Theme|GlowTheme|MdvTheme|catppuccin" '`

If the README documents `$DFConfig` theme keys, note the canonical-only shared `Theme` rule and the per-tool override rule. If nothing relevant, make no change and say so in the commit body.

- [ ] **Step 6: Commit**

```bash
git add ToolAcquisitionSpec.md CLAUDE.md docs/external-dependencies.md CHANGELOG.md README.md
git commit -m "docs: per-tool themeMap theme resolution; delta theming; retire catppuccin alias"
```

---

## Self-Review checklist (author ran before finalizing)

- **Spec coverage:** resolver (T1) ✓; glow/psreadline/mdcat refactor + alias retirement (T2) ✓; mdv `themeMap` (T3) ✓; delta sidecar + `env` change + XdgSplit update (T4) ✓; standard §6.2 + CLAUDE/external-deps/CHANGELOG/README (T5) ✓.
- **Type/name consistency:** `Resolve-DFThemeName -Name -ThemeMap`, `$DFCurrentTool.PSObject.Properties['themeMap']?.Value`, and the canonical `catppuccin-mocha` are used identically across all sidecars and tests.
- **Behavior-change safety:** all tool *defaults* are canonical (glow/psreadline unchanged defaults; mdcat env-block default; mdv `settings.theme` → canonical; delta default canonical), so out-of-the-box rendering is unchanged. The only break is the retired `catppuccin` alias, and every test that used it as a shared `Theme` is updated to the canonical in the same task.
- **Plugin invariant:** no core file changes to add a themed tool; the resolver reads the tool's own `themeMap`; no `switch ($tool.name)`.
