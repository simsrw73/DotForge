# Alias Ownership Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make all 27 general-helper aliases genuinely module-owned by dropping `-Scope Global -Force` from their `Set-Alias` call sites; rename `copy`→`yank` (the one builtin collision that made this impossible for that alias); formalize dynamic tool/picker aliases as intentionally registry-owned; add a consistency guard against future drift.

**Architecture:** No new abstractions — a mechanical, verified fix applied uniformly to 27 existing `Set-Alias` call sites across 11 `Public/*.ps1` files. The manifest's `AliasesToExport` already lists the correct names; dropping `-Scope Global` lets a bare `Set-Alias` land in the module's own scope, where the manifest makes it a genuine export (verified empirically in the design phase — no `[Alias()]` attributes or `Export-ModuleMember` calls needed).

**Tech Stack:** PowerShell 7+, Pester 5/6 (suite passes under both).

## Global Constraints

Copied from `docs/superpowers/specs/2026-07-26-alias-ownership-design.md`:

- **The fix is `Set-Alias -Name <n> -Value <Function>`** — drop `-Scope Global`, `-Force`, and (for the renamed `yank` alias only) `-Option AllScope`. No other restructuring.
- **`copy` → `yank`.** Verified: `yank` has no PowerShell builtin collision. This is the ONLY name-change in this workstream — all 26 other aliases keep their existing names.
- **Real module ownership does NOT change import-time clobbering behavior** (verified empirically: silent overwrite either way, no warning). Do not add any clobber-detection/guard logic — that is explicitly out of scope (see spec).
- **Dynamic tool/picker aliases are unaffected** — `Register-DFTool.ps1`'s two `Set-Alias ... -Scope Global -Force` call sites (tool aliases, picker aliases) are NOT touched by this workstream; they are deliberately dynamic and stay exactly as they are.
- **Historical dated docs are not touched** — `docs/superpowers/{plans,specs}/2026-05-08-*.md` reference the old `copy` name; these are point-in-time records, left as-is.
- `docs/builtin-safety-policy.md`, the `CLAUDE.md` pointer, and the `TODO.md` future-idea entry are **already committed** (prior to this plan) — no task here re-creates them.
- Tests pass under Pester 5.8.0 AND 6.0.1; no `Assert-MockCalled`. Run `pwsh -NoProfile -Command 'Invoke-Pester tests/ -Output Detailed'`.

## File Structure

**Modify:**
- `Public/DFHelpers.Clipboard.ps1` — rename `copy`→`yank`, drop scope/force/option.
- `Public/DFHelpers.Environment.ps1`, `Public/DFHelpers.FileSystem.ps1`, `Public/DFHelpers.Help.ps1`, `Public/DFHelpers.Navigation.ps1`, `Public/DFHelpers.Pager.ps1`, `Public/DFHelpers.Process.ps1`, `Public/DFHelpers.Utility.ps1`, `Public/Find-DFPackage.ps1`, `Public/Get-DFCategoryList.ps1`, `Public/Select-DFPackage.ps1` — drop `-Scope Global -Force`.
- `DotForge.psd1` — `AliasesToExport`: `'copy'` → `'yank'`.
- `tests/DFHelpers.Clipboard.Tests.ps1` — the alias name + a NEW real assertion (previously impossible — see Task 1).
- `README.md`, `ToolAcquisitionSpec.md`, `docs/external-dependencies.md`, `CHANGELOG.md`, `TODO.md`.

**Create:**
- `tests/AliasOwnership.Tests.ps1` — real-import ownership test (Task 2) + manifest/tool-alias consistency guard (Task 3).

---

### Task 1: Rename `copy` → `yank`

**Files:**
- Modify: `Public/DFHelpers.Clipboard.ps1`, `DotForge.psd1`, `tests/DFHelpers.Clipboard.Tests.ps1`, `README.md`

**Interfaces:**
- Produces: the `yank` alias for `Copy-DFToClipboard`, created via a bare `Set-Alias` (module-scope, genuinely exportable) — no builtin collision, so (unlike `copy`) it is now verifiable directly in Pester.

- [ ] **Step 1: Write the failing test**

In `tests/DFHelpers.Clipboard.Tests.ps1`, replace the "cannot be verified" comment block (lines 35–39) with a real assertion — this is now possible because `yank` has no `AllScope` builtin to collide with (unlike `copy`, whose `AllScope` binding Pester resets in its sandboxed session state, per the removed comment):

```powershell
    It 'is aliased to yank' {
        (Get-Alias -Name yank -ErrorAction SilentlyContinue).Definition |
            Should -Be 'Copy-DFToClipboard'
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `pwsh -NoProfile -Command 'Invoke-Pester tests/DFHelpers.Clipboard.Tests.ps1 -Output Detailed'`
Expected: FAIL — the alias is still named `copy`, so `Get-Alias yank` finds nothing and `.Definition` is `$null`.

- [ ] **Step 3: Rename in `Public/DFHelpers.Clipboard.ps1`**

Change the `Set-Alias` line and the two doc-comment references. Find:

```powershell
    .EXAMPLE
        git log --oneline | copy
        Copies the git log output to the clipboard using the copy alias.
    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromPipeline)]
        [string]$InputObject
    )
    begin   { $lines = [System.Collections.Generic.List[string]]@() }
    process { if ($null -ne $InputObject) { $lines.Add($InputObject) } }
    end     { Set-Clipboard -Value ($lines -join "`n") }
}
Set-Alias -Name copy -Value Copy-DFToClipboard -Scope Global -Force -Option AllScope
```

Replace with:

```powershell
    .EXAMPLE
        git log --oneline | yank
        Copies the git log output to the clipboard using the yank alias.
    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromPipeline)]
        [string]$InputObject
    )
    begin   { $lines = [System.Collections.Generic.List[string]]@() }
    process { if ($null -ne $InputObject) { $lines.Add($InputObject) } }
    end     { Set-Clipboard -Value ($lines -join "`n") }
}
Set-Alias -Name yank -Value Copy-DFToClipboard
```

Also update the `.SYNOPSIS` line (`Copies pipeline input to the system clipboard (copy equivalent).`) — leave "copy equivalent" as descriptive prose (it correctly describes *what the alias does*, not its name) unless it reads ambiguously once you see it in context; if so, adjust to `(yank equivalent)`.

- [ ] **Step 4: Update `DotForge.psd1`**

In `AliasesToExport`, change `'copy',` to `'yank',` (keep its position in the list unchanged).

- [ ] **Step 5: Update `README.md`**

Line ~255, the alias reference table:

```markdown
| `Copy-DFToClipboard`  | `copy`  | Copy string or pipeline input to clipboard |
```

becomes:

```markdown
| `Copy-DFToClipboard`  | `yank`  | Copy string or pipeline input to clipboard |
```

(Lines ~6, ~314, ~378 use "copy" as an ordinary English verb, not the alias name — leave them unchanged; re-read each in context before deciding, don't pattern-match blindly.)

- [ ] **Step 6: Run to verify it passes**

Run: `pwsh -NoProfile -Command 'Invoke-Pester tests/DFHelpers.Clipboard.Tests.ps1 -Output Detailed'`
Expected: PASS — including the new `yank` assertion, which is now genuinely exercised (not skipped/commented).

- [ ] **Step 7: Full suite + commit**

Run: `pwsh -NoProfile -Command 'Invoke-Pester tests/ -Output Detailed'`
Expected: PASS.

```bash
git add Public/DFHelpers.Clipboard.ps1 DotForge.psd1 tests/DFHelpers.Clipboard.Tests.ps1 README.md
git commit -m "refactor(aliases): rename copy -> yank (removes the only builtin collision)"
```

---

### Task 2: Module-own the remaining 26 general-helper aliases + real-import test

**Files:**
- Modify: `Public/DFHelpers.Environment.ps1`, `Public/DFHelpers.FileSystem.ps1`, `Public/DFHelpers.Help.ps1`, `Public/DFHelpers.Navigation.ps1`, `Public/DFHelpers.Pager.ps1`, `Public/DFHelpers.Process.ps1`, `Public/DFHelpers.Utility.ps1`, `Public/Find-DFPackage.ps1`, `Public/Get-DFCategoryList.ps1`, `Public/Select-DFPackage.ps1`
- Create: `tests/AliasOwnership.Tests.ps1`

**Interfaces:**
- Consumes: `DotForge.psd1`'s `AliasesToExport` (already lists all 27 correct names as of Task 1).
- Produces: a new `Describe 'DotForge module owns its general-helper aliases'` block that does a REAL `Import-Module` of the packaged module (a first for this test suite — no existing test does this; every other test dot-sources individual files) and asserts genuine ownership.

- [ ] **Step 1: Write the failing test**

Create `tests/AliasOwnership.Tests.ps1`:

```powershell
BeforeAll {
    $script:ManifestPath = "$PSScriptRoot/../DotForge.psd1"
    $script:GeneralHelperAliases = (Import-PowerShellDataFile -Path $script:ManifestPath).AliasesToExport
}

Describe 'DotForge module owns its general-helper aliases' {
    AfterEach {
        Remove-Module DotForge -ErrorAction Ignore
    }

    It 'exports every general-helper alias from the manifest' {
        Import-Module $script:ManifestPath -Force
        $exported = (Get-Module DotForge).ExportedAliases.Keys
        foreach ($name in $script:GeneralHelperAliases) {
            $exported | Should -Contain $name -Because "AliasesToExport declares '$name'"
        }
    }

    It 'resolves each alias to a command owned by the DotForge module' {
        Import-Module $script:ManifestPath -Force
        foreach ($name in $script:GeneralHelperAliases) {
            $alias = Get-Alias -Name $name -ErrorAction SilentlyContinue
            $alias | Should -Not -BeNullOrEmpty -Because "'$name' should resolve after import"
            $alias.ModuleName | Should -Be 'DotForge' -Because "'$name' should be owned by DotForge, not created ad hoc"
        }
    }

    It 'removes every general-helper alias when the module is removed' {
        Import-Module $script:ManifestPath -Force
        Remove-Module DotForge
        foreach ($name in $script:GeneralHelperAliases) {
            Get-Alias -Name $name -ErrorAction SilentlyContinue | Should -BeNullOrEmpty -Because "'$name' should not survive Remove-Module"
        }
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `pwsh -NoProfile -Command 'Invoke-Pester tests/AliasOwnership.Tests.ps1 -Output Detailed'`
Expected: FAIL — most of the 27 aliases are still created via `-Scope Global -Force` (bypassing module scope), so `ExportedAliases` is empty and `.ModuleName` is blank for all but any already fixed in Task 1 (`yank`, which should already pass since Task 1 landed first).

- [ ] **Step 3: Apply the fix to the remaining 26 call sites**

For each of the following lines, remove ` -Scope Global -Force` (keep everything else — name and value — identical). This is the SAME mechanical edit at each site:

`Public/DFHelpers.Environment.ps1`:
```powershell
Set-Alias -Name path -Value Get-DFPath
Set-Alias -Name fenv -Value Select-DFEnvVar
Set-Alias -Name ep -Value Edit-DFProfile
Set-Alias -Name env -Value Get-DFEnv
Set-Alias -Name reload -Value Invoke-DFProfileReload
```

`Public/DFHelpers.FileSystem.ps1`:
```powershell
Set-Alias -Name touch -Value New-DFFile
Set-Alias -Name which -Value Get-DFWhich
Set-Alias -Name open -Value Open-DFItem
```

`Public/DFHelpers.Help.ps1`:
```powershell
Set-Alias -Name hm -Value Invoke-DFHelp
Set-Alias -Name fcmd -Value Select-DFCommand
Set-Alias -Name fverb -Value Select-DFVerb
Set-Alias -Name fmod -Value Select-DFModule
Set-Alias -Name fh -Value Select-DFHelpTopic
Set-Alias -Name clh -Value Show-DFCliHelp
Set-Alias -Name clhp -Value Show-DFCliHelpPaged
```

`Public/DFHelpers.Navigation.ps1`:
```powershell
Set-Alias -Name up -Value Set-DFLocationUp
Set-Alias -Name mkcd -Value New-DFDirectoryAndSet
Set-Alias -Name fcd -Value Select-DFLocation
```

`Public/DFHelpers.Pager.ps1`:
```powershell
Set-Alias -Name pg -Value Invoke-DFWithPager
```

`Public/DFHelpers.Process.ps1`:
```powershell
Set-Alias -Name fps -Value Select-DFProcess
Set-Alias -Name top -Value Get-DFTopProcess
```

`Public/DFHelpers.Utility.ps1`:
```powershell
Set-Alias -Name uuidgen -Value New-DFUuid
```

`Public/Find-DFPackage.ps1`:
```powershell
Set-Alias -Name trifle -Value Find-DFPackage
```

`Public/Get-DFCategoryList.ps1`:
```powershell
Set-Alias -Name tcats -Value Get-DFCategoryList
```

`Public/Select-DFPackage.ps1`:
```powershell
Set-Alias -Name ftrifle -Value Select-DFPackage
```

(`Public/DFHelpers.Clipboard.ps1`'s `paste` alias — `Set-Alias -Name paste -Value Get-DFFromClipboard -Scope Global -Force` — is in scope for this same fix too; it was not touched in Task 1, which only handled `copy`/`yank`. Fix it here alongside the rest.)

- [ ] **Step 4: Run to verify it passes**

Run: `pwsh -NoProfile -Command 'Invoke-Pester tests/AliasOwnership.Tests.ps1 -Output Detailed'`
Expected: PASS — all three assertions, for all 27 names.

- [ ] **Step 5: Full suite + commit**

Run: `pwsh -NoProfile -Command 'Invoke-Pester tests/ -Output Detailed'`
Expected: PASS. Pay attention to any test that assumed a general-helper alias was created via `-Scope Global` in the CURRENT PowerShell session at dot-source time (rather than via a real `Import-Module`) — since this test suite predominantly dot-sources individual `Public/*.ps1` files directly (not via `Import-Module`), dot-sourcing e.g. `Public/DFHelpers.Pager.ps1` directly in a test's `BeforeAll` will now create `pg` in THAT scope (script/global scope of the dot-sourcing context, same as before for a directly-dot-sourced file outside a module) — dropping `-Scope Global` only changes behavior when the file is loaded as part of an actual module import; direct dot-sourcing in a test file is unaffected because dot-sourcing always runs in the caller's current scope regardless of the `Set-Alias` scope parameter's default. If any existing test dot-sources one of these 10 files and asserts on the alias via `Get-Alias -Scope Global`, verify it still passes (default `Get-Alias` scope resolution should be unaffected, since dot-sourcing a test file into the test's own scope, without `-Scope Global` specified, still lands in that scope's session state which IS visible via a scopeless `Get-Alias`).

```bash
git add Public/DFHelpers.Environment.ps1 Public/DFHelpers.FileSystem.ps1 Public/DFHelpers.Help.ps1 Public/DFHelpers.Navigation.ps1 Public/DFHelpers.Pager.ps1 Public/DFHelpers.Process.ps1 Public/DFHelpers.Utility.ps1 Public/Find-DFPackage.ps1 Public/Get-DFCategoryList.ps1 Public/Select-DFPackage.ps1 Public/DFHelpers.Clipboard.ps1 tests/AliasOwnership.Tests.ps1
git commit -m "feat(aliases): make all 27 general-helper aliases genuinely module-owned"
```

---

### Task 3: Consistency guard — general-helper vs. tool/picker alias names never collide

**Files:**
- Modify: `tests/AliasOwnership.Tests.ps1`

**Interfaces:**
- Consumes: `DotForge.psd1`'s `AliasesToExport`; every `Tools/*.json`'s `aliases` keys and `picker.alias` value.
- Produces: a guard test that fails if a general-helper alias name is ever also declared as a tool/picker alias (or vice versa) — the two categories (Section 1 vs Section 2 of the design) must stay disjoint.

- [ ] **Step 1: Write the failing test (should already pass today — this locks in the invariant)**

Append to `tests/AliasOwnership.Tests.ps1`:

```powershell
Describe 'General-helper and tool/picker alias names never collide' {
    It 'no name in AliasesToExport is also declared by a Tools/*.json alias or picker' {
        $toolAliasNames = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
        Get-ChildItem "$PSScriptRoot/../Tools" -Filter '*.json' | ForEach-Object {
            $tool = Get-Content $_.FullName -Raw | ConvertFrom-Json
            $aliases = $tool.PSObject.Properties['aliases']?.Value
            if ($aliases) {
                foreach ($n in $aliases.PSObject.Properties.Name) { [void]$toolAliasNames.Add($n) }
            }
            $picker = $tool.PSObject.Properties['picker']?.Value
            if ($picker -is [PSCustomObject]) {
                $pAlias = $picker.PSObject.Properties['alias']?.Value
                if ($pAlias) { [void]$toolAliasNames.Add($pAlias) }
            }
        }

        $collisions = $script:GeneralHelperAliases | Where-Object { $toolAliasNames.Contains($_) }
        $collisions | Should -BeNullOrEmpty -Because 'a general-helper alias and a tool/picker alias must never share a name'
    }
}
```

- [ ] **Step 2: Run to verify it passes**

Run: `pwsh -NoProfile -Command 'Invoke-Pester tests/AliasOwnership.Tests.ps1 -Output Detailed'`
Expected: PASS immediately (no collision exists today — this test locks in the invariant for future tool onboarding, it is not fixing a currently-broken state).

- [ ] **Step 3: Full suite + commit**

Run: `pwsh -NoProfile -Command 'Invoke-Pester tests/ -Output Detailed'`
Expected: PASS.

```bash
git add tests/AliasOwnership.Tests.ps1
git commit -m "test(aliases): guard against general-helper/tool-alias name collisions"
```

---

### Task 4: Documentation

**Files:** Modify `ToolAcquisitionSpec.md`, `docs/external-dependencies.md`, `CHANGELOG.md`, `TODO.md`.

**Interfaces:** none (documentation only).

- [ ] **Step 1: `ToolAcquisitionSpec.md` §9 (Aliases)**

Add a subsection after the existing §9 content describing the two-category model:

```markdown
### 9.1 Two categories, two ownership models

DotForge creates two kinds of aliases, owned two different ways:

- **General-helper aliases** (the module's own commands — `pg`, `hm`, `touch`, `yank`, …) are a
  closed, static, author-time-known set. Each is created via a bare `Set-Alias -Name <n> -Value
  <Function>` (no `-Scope Global`, no `-Force`) inside the relevant `Public/*.ps1` file, landing in
  the module's own scope. `DotForge.psd1`'s `AliasesToExport` lists every one of them, and because
  they are created in module scope, the manifest makes them genuinely exported:
  `(Get-Module DotForge).ExportedAliases` reports them and `Remove-Module DotForge` cleans them up.
- **Tool and picker aliases** (`ls`, `cat`, `ff`, …, declared per-tool in `Tools/*.json` and created
  by `Register-DFTool` at runtime) are inherently dynamic — conditional on which tools are installed
  and what `$DFConfig.Defaults` selects. They can never be a static manifest list, and are
  intentionally NOT in `AliasesToExport`. `Get-DFCommandConflict` reads them directly from the tool
  database for exactly this reason. This is a design fact, not a gap.

The two categories MUST NOT share a name (guarded by `tests/AliasOwnership.Tests.ps1`). Before
adding any alias in either category, check it against a PowerShell builtin per
`docs/builtin-safety-policy.md`.
```

- [ ] **Step 2: `docs/external-dependencies.md`**

Find the "`AliasesToExport` is decorative" note (in the "Internal to DotForge" section) and replace it:

```markdown
- **`AliasesToExport` is real for general-helper aliases, intentionally absent for tool/picker
  aliases.** The module's own aliases (`pg`, `hm`, `touch`, `yank`, …) are created via a bare
  `Set-Alias` in module scope, so the manifest's `AliasesToExport` genuinely exports them —
  `(Get-Module DotForge).ExportedAliases` reports them and `Remove-Module DotForge` cleans them up.
  Tool and picker aliases (`ls`, `cat`, `ff`, …) are created dynamically by `Register-DFTool` from
  `Tools/*.json` and are NOT in the manifest — they cannot be, since their existence depends on
  which tools are installed and what `$DFConfig.Defaults` selects. `Get-DFCommandConflict` reads
  them directly from the tool database for this reason; that split is by design, not a gap.
```

- [ ] **Step 3: `CHANGELOG.md` `[Unreleased]` → `### Changed`**

```markdown
- **The `copy` alias is renamed to `yank`.** It collided with PowerShell's builtin `copy` alias
  (`Copy-Item`, `AllScope`) — the only general-helper alias that did. Anyone using `copy` for
  `Copy-DFToClipboard` needs to switch to `yank`.
- **All 27 general-helper aliases (`pg`, `hm`, `touch`, `yank`, …) are now genuinely module-owned.**
  `(Get-Module DotForge).ExportedAliases` reports them and `Remove-Module DotForge` cleans them up
  correctly — previously the manifest's `AliasesToExport` was decorative. No change to how or when
  they're created relative to a session's existing aliases (import-time collision behavior is
  unchanged; see `docs/superpowers/specs/2026-07-26-alias-ownership-design.md` for why).
```

- [ ] **Step 4: `TODO.md`**

Mark both original items resolved. Change:

```markdown
- [ ] **`AliasesToExport` is decorative** — ...
```

to:

```markdown
- [x] **`AliasesToExport` is decorative** — done 2026-07-26: all 27 general-helper aliases now
  created via a bare `Set-Alias` (module scope, no `-Force`), so the manifest's `AliasesToExport`
  is a genuine export — `(Get-Module DotForge).ExportedAliases` and `Remove-Module` both work
  correctly now. Tool/picker aliases remain intentionally outside the manifest (see
  `ToolAcquisitionSpec.md` §9.1) — that split is by design, not the gap this item described.
```

and change:

```markdown
- [ ] **Stop force-creating global aliases at import time** — ...
```

to:

```markdown
- [x] **Stop force-creating global aliases at import time** — done 2026-07-26: all 27 general-helper
  aliases drop `-Scope Global -Force`. Correction to this item's original framing: real module
  ownership does NOT change import-time clobbering behavior (verified empirically — a genuinely
  exported alias still silently overwrites a same-named pre-existing global alias, with no
  warning, identical to the old `-Force` behavior). That's normal PowerShell module behavior for
  every module, not a DotForge-specific defect, so it is not addressed. The `copy` alias — the one
  case that actually needed `-Force` to override a builtin — is renamed to `yank` instead, removing
  the need for `-Force` entirely rather than working around it.
```

- [ ] **Step 5: Full suite + commit**

Run: `pwsh -NoProfile -Command 'Invoke-Pester tests/ -Output Detailed'`
Expected: PASS.

```bash
git add ToolAcquisitionSpec.md docs/external-dependencies.md CHANGELOG.md TODO.md
git commit -m "docs: alias ownership two-category model; resolve TODO items"
```

---

## Self-Review checklist (author ran before finalizing)

- **Spec coverage:** `copy`→`yank` rename + newly-possible test (T1) ✓; remaining 26 aliases + real-import ownership test (T2) ✓; consistency guard (T3) ✓; standard/external-deps/CHANGELOG/TODO (T4) ✓.
- **Completeness check against the grounding grep:** all 27 `Set-Alias -Scope Global -Force` call sites from the design's file inventory are accounted for across T1 (1: `copy`/`yank`) and T2 (26, including `paste` which was NOT in the original per-file breakdown I front-loaded into T1 — confirmed and folded into T2's file list and edit steps).
- **Type/name consistency:** `$script:GeneralHelperAliases` (from the manifest) is defined once in `tests/AliasOwnership.Tests.ps1`'s shared `BeforeAll` and reused by both T2's and T3's `Describe` blocks without redefinition.
- **No `Register-DFTool.ps1` changes** — its two dynamic `Set-Alias -Scope Global -Force` call sites (tool aliases, picker aliases) are untouched by any task, matching the design's explicit out-of-scope note.
