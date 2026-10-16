# Role Behaviors Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A role describes its aliases and pickers once, in behavior words; each member maps the words to its own flags, so `ls`/`ll`/`la`/`tree`/`ff` mean the same whichever listing tool wins (T-34).

**Architecture:** `data/roles.json` gains an optional `behaviors` block per role (words, aliases, pickers), normalized by `ConvertTo-DFRoleRecord`. A member's role block gains `flags` (word → args), normalized by `ConvertTo-DFRoleMap`. At registration, for each won role with behaviors, two pure functions build alias and picker objects from the winner's flags, which the existing `Register-DFToolAliases` and `Set-DFPickerFunction` apply. A missing word degrades to a status note.

**Tech Stack:** PowerShell 7.2+, Pester 6. Run tests with `pwsh -NoProfile -Command "./build/Test-DFFull.ps1 -Path <files>"`.

**Spec:** `docs/superpowers/specs/2026-10-16-role-behaviors-design.md`

## Global Constraints

- No `switch ($tool.name)` or tool-keyed table in core code; `data/roles.json` is keyed by role (docs/plugin-architecture.md).
- Startup speed: no new file reads or process spawns at registration; composing aliases is string work over loaded records.
- Every alias still goes through `Register-DFToolAliases`; every picker through `Set-DFPickerFunction`.
- Functions return result objects; they don't fill hashtables the caller passes (CLAUDE.md readability rules).
- A function past ~60 lines is split into named steps.
- Paths are canonical (`ConvertTo-DFPath`); none are introduced here.
- Pester 6 syntax only (`Should -Invoke`); a mock with only `-ParameterFilter` needs a default mock.
- Regenerate after changes: `Shared/`/`Private/`/`Public/` → `build/Build-DFCoreBundle.ps1`; `Tools/*.json` → `build/Build-DFToolRegistry.ps1`; comment help or `Tools/*.json` → `build/Build-DFReferenceDocs.ps1`.
- Commits are GPG-signed; never bypass signing. Write messages to a file and `git commit -F` (PowerShell here-strings in `-m` have failed here).
- Commit trailer:
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` and
  `Claude-Session: https://claude.ai/code/session_01PCJ8NCZhH2mTdAwuq8KLar`

**Spec correction this plan makes (Task 1, Step 1):** `Test-DFToolSchema` checks one record and cannot see `data/roles.json`, so the role-aware rules ("a member may not define a behaviors role's aliases", "every word is mapped") live in the role contract test and at runtime, not in the schema. The schema checks only the shape of `flags`.

## Review Focus

1. **A won role block that still has hand-written `aliases` for a behaviors role** (a user's own tool written the old way): expect the behavior aliases to win and the hand ones to be skipped with a verbose message, never both or an error. Test: Task 5, "ignores hand-written aliases for a behaviors role".
2. **The winner joins the role with flags but the role's words changed** (a user's tool from an older DotForge): expect aliases built from the words it has, and one status note naming the missing ones. Test: Task 4, "skips a missing word and reports it"; Task 5, "notes missing words in the tool's status".
3. **Re-registering the same tool** (`Register-DFTool -Name eza` twice in one shell): expect the same aliases, and the status note not duplicated. Test: Task 3, "starts each registration clean"; Task 5, "re-registration keeps one note".
4. **`Defaults = @{ listing = 'lsd' }` with both requested:** expect lsd's flags in every alias and in `ff`, eza's in none. Test: Task 5, "Defaults flips the winner's flags".
5. **A behaviors role whose aliases name a word missing from `words`** (a typo in roles.json): expect the role to warn and be ignored, like other invalid role records, not a half-built alias. Test: Task 1, "rejects behaviors that use an undefined word".

---

### Task 1: Role definitions read `behaviors`

**Files:**
- Modify: `docs/superpowers/specs/2026-10-16-role-behaviors-design.md` (the "When something is missing" schema bullet)
- Modify: `Private/Get-DFRoleDb.ps1` (`ConvertTo-DFRoleRecord`)
- Test: `tests/Get-DFRoleDb.Tests.ps1`

**Interfaces:**
- Produces: every role record has `behaviors` = `$null`, or `[pscustomobject]@{ words = [string[]]; aliases = [ordered] name -> [string[]]; pickers = [object[]] }` (each picker the parsed object, `list` a `[string[]]` of words). For a role with behaviors, `reserved.aliases` = alias names + each picker's `alias`, in that order.

- [ ] **Step 1: Correct the spec's schema bullet**

In the spec's "When something is missing" section, replace the **Schema** bullet with:

```markdown
- **Schema** (`Test-DFToolSchema`): `flags`, when present in a role block, must be an
  object of word → array of strings. The schema checks one record and can't see
  `data/roles.json`, so the role-aware rules (no hand-written aliases for a
  behaviors role, every word mapped) are the role contract test's, and at runtime a
  behaviors role's hand-written block aliases are skipped with a verbose message.
```

- [ ] **Step 2: Write the failing tests**

Append to `tests/Get-DFRoleDb.Tests.ps1`, inside a new `Describe`:

```powershell
Describe 'ConvertTo-DFRoleRecord behaviors' {
    BeforeAll {
        function script:ConvertFrom-RoleJson([string]$Json) { $Json | ConvertFrom-Json }
    }

    It 'reads words, aliases and pickers, and derives reserved aliases' {
        $role = ConvertFrom-RoleJson '{ "kind": "single", "hook": "Initialize-DFRoleListing",
            "behaviors": { "words": { "long": "details", "all": "hidden too" },
                           "aliases": { "ll": ["long"], "la": ["long", "all"] },
                           "pickers": [ { "alias": "ff", "function": "Select-File", "list": ["long"] } ] } }'
        $record = ConvertTo-DFRoleRecord -Name 'listing' -Role $role
        $record.behaviors.words | Should -Be @('long', 'all')
        $record.behaviors.aliases['la'] | Should -Be @('long', 'all')
        $record.behaviors.pickers[0].function | Should -Be 'Select-File'
        $record.reserved.aliases | Should -Be @('ll', 'la', 'ff')
    }

    It 'leaves behaviors null for a role without them' {
        $record = ConvertTo-DFRoleRecord -Name 'pager' -Role (ConvertFrom-RoleJson '{ "kind": "single", "hook": "Initialize-DFRolePager" }')
        $record.behaviors | Should -BeNullOrEmpty
    }

    It 'rejects behaviors that use an undefined word' {
        $role = ConvertFrom-RoleJson '{ "kind": "single", "hook": "Initialize-DFRoleListing",
            "behaviors": { "words": { "long": "details" }, "aliases": { "ll": ["long", "lnog"] } } }'
        ConvertTo-DFRoleRecord -Name 'listing' -Role $role 3>$null | Should -BeNullOrEmpty
        ConvertTo-DFRoleRecord -Name 'listing' -Role $role -WarningVariable w 3>$null | Out-Null
        "$w" | Should -Match "lnog"
    }

    It 'rejects behaviors on a category role' {
        $role = ConvertFrom-RoleJson '{ "kind": "category", "behaviors": { "words": { "a": "x" }, "aliases": { "q": ["a"] } } }'
        ConvertTo-DFRoleRecord -Name 'grep' -Role $role 3>$null | Should -BeNullOrEmpty
    }
}
```

- [ ] **Step 3: Run to verify they fail**

Run: `pwsh -NoProfile -Command "./build/Test-DFFull.ps1 -Path tests/Get-DFRoleDb.Tests.ps1"`
Expected: the four new tests FAIL (`behaviors` is not a property).

- [ ] **Step 4: Implement**

In `ConvertTo-DFRoleRecord`, after `$resProps = …`, read behaviors with a new private function in the same file, and use it:

```powershell
function ConvertTo-DFRoleBehaviors {
    <#
    .SYNOPSIS
        Normalizes a role's behaviors block: words, aliases (name -> words) and pickers (list as words).
    .DESCRIPTION
        Returns $null when the role has none. A problem (a word used but not defined)
        is returned as a string for ConvertTo-DFRoleRecord to report.
    .PARAMETER Behaviors
        The parsed behaviors object.
    .OUTPUTS
        pscustomobject { Value; Problem }.
    #>
    [CmdletBinding()]
    param([AllowNull()][object]$Behaviors)
    if ($null -eq $Behaviors) { return [pscustomobject]@{ Value = $null; Problem = $null } }
    $words = [string[]]@($Behaviors.PSObject.Properties['words']?.Value.PSObject.Properties | ForEach-Object Name)
    $aliases = [ordered]@{}
    foreach ($a in @($Behaviors.PSObject.Properties['aliases']?.Value.PSObject.Properties)) {
        if ($a) { $aliases[$a.Name] = [string[]]@($a.Value) }
    }
    $pickers = @($Behaviors.PSObject.Properties['pickers']?.Value | Where-Object { $_ })
    $used = @($aliases.Values | ForEach-Object { $_ }) + @($pickers | ForEach-Object { @($_.list) })
    $undefined = @($used | Where-Object { $_ -notin $words } | Select-Object -Unique)
    $problem = if ($undefined) { "behaviors use undefined word(s): $($undefined -join ', ')" }
    [pscustomobject]@{
        Value   = [pscustomobject]@{ words = $words; aliases = $aliases; pickers = $pickers }
        Problem = $problem
    }
}
```

In `ConvertTo-DFRoleRecord`:

```powershell
    $behaviors = ConvertTo-DFRoleBehaviors -Behaviors $props['behaviors']?.Value
    $reservedAliases = [string[]]@(if ($null -ne $resProps) { $resProps['aliases']?.Value })
    if ($behaviors.Value) {
        $reservedAliases = [string[]]@(@($behaviors.Value.aliases.Keys) + @($behaviors.Value.pickers | ForEach-Object alias | Where-Object { $_ }))
    }
```

Use `$reservedAliases` for `reserved.aliases`, add `behaviors = $behaviors.Value` to the record, and extend the problem checks:

```powershell
        'single' {
            $pascal = …   # unchanged
            if ($record.hook -cne $expected) { "hook '$($record.hook)' must be $expected" }
            elseif ($behaviors.Problem) { $behaviors.Problem }
        }
        'category' {
            if ($record.hook -or $record.emptyMembership -or $record.exclusive -or $record.behaviors -or
                $record.reserved.env.Count -or $record.reserved.aliases.Count -or $record.reserved.code.Count) {
                'a category role cannot declare a hook, exclusive, emptyMembership, behaviors or reserved names'
            }
        }
```

Update the `.DESCRIPTION` of `ConvertTo-DFRoleRecord` to mention behaviors and the derived reserved aliases.

- [ ] **Step 5: Run to verify they pass**

Run: `pwsh -NoProfile -Command "./build/Test-DFFull.ps1 -Path tests/Get-DFRoleDb.Tests.ps1, tests/Roles.Registration.Tests.ps1"`
Expected: PASS.

- [ ] **Step 6: Commit**

```powershell
git add Private/Get-DFRoleDb.ps1 tests/Get-DFRoleDb.Tests.ps1 docs/superpowers/specs/2026-10-16-role-behaviors-design.md
git commit -F <message file>   # "feat: role definitions read behaviors (words, aliases, pickers)"
```

---

### Task 2: Tool records carry a role block's `flags`

**Files:**
- Modify: `Shared/Import-DFToolDb.ps1` (`ConvertTo-DFRoleMap`)
- Modify: `Shared/Test-DFToolSchema.ps1` (role block checks, typo list)
- Test: `tests/ConvertTo-DFToolRecord.Tests.ps1`, `tests/Test-DFToolSchema.Tests.ps1`

**Interfaces:**
- Produces: every normalized role block has `flags` = `$null` or a `[pscustomobject]` word → `[string[]]`.

- [ ] **Step 1: Write the failing tests**

`tests/ConvertTo-DFToolRecord.Tests.ps1`, new `It` in the roles area:

```powershell
    It 'keeps a role block''s flags as word -> string arrays' {
        $tool = '{ "name": "t", "executable": "t.exe", "roles": { "listing": { "flags": { "long": ["--long"], "color": [] } } } }' | ConvertFrom-Json
        $record = ConvertTo-DFToolRecord $tool
        $record.roles.listing.flags.long | Should -Be @('--long')
        @($record.roles.listing.flags.color).Count | Should -Be 0
    }

    It 'gives a role block without flags a null flags field' {
        $tool = '{ "name": "t", "executable": "t.exe", "roles": { "pager": {} } }' | ConvertFrom-Json
        $record = ConvertTo-DFToolRecord $tool
        $record.roles.pager.PSObject.Properties['flags'] | Should -Not -BeNullOrEmpty
        $record.roles.pager.flags | Should -BeNullOrEmpty
    }
```

`tests/Test-DFToolSchema.Tests.ps1`:

```powershell
    It 'rejects role flags that are not word -> string arrays: <Json>' -ForEach @(
        @{ Json = '"flags": ["--long"]' }, @{ Json = '"flags": { "long": "--long" }' }, @{ Json = '"flags": { "long": [1] }' }
    ) {
        $tool = "{ ""name"": ""t"", ""executable"": ""t.exe"", ""roles"": { ""listing"": { $Json } } }" | ConvertFrom-Json
        (Test-DFToolSchema -Tool $tool).Errors -join ';' | Should -Match 'roles.listing.flags'
    }

    It 'accepts role flags of word -> string arrays' {
        $tool = '{ "name": "t", "executable": "t.exe", "roles": { "listing": { "flags": { "long": ["--long"], "color": [] } } } }' | ConvertFrom-Json
        (Test-DFToolSchema -Tool $tool).Errors | Should -BeNullOrEmpty
    }
```

Check how the existing schema tests read results (`(Test-DFToolSchema -Tool $tool).Errors` or similar) and match that call shape exactly.

- [ ] **Step 2: Run to verify they fail**

Run: `pwsh -NoProfile -Command "./build/Test-DFFull.ps1 -Path tests/ConvertTo-DFToolRecord.Tests.ps1, tests/Test-DFToolSchema.Tests.ps1"`
Expected: the new tests FAIL.

- [ ] **Step 3: Implement**

`ConvertTo-DFRoleMap`, inside the per-role object, add:

```powershell
                flags    = ConvertTo-DFRoleFlags (Get-DFToolRecordProperty $role.Value 'flags' $null)
```

and the legacy entry gets `flags = $null`. New function in the same file:

```powershell
function ConvertTo-DFRoleFlags {
    <#
    .SYNOPSIS
        Normalizes a role block's flags: word -> string array ($null when absent).
    .PARAMETER Flags
        The parsed flags object.
    .OUTPUTS
        PSCustomObject, or $null.
    #>
    [CmdletBinding()]
    param([AllowNull()][object]$Flags)
    if ($Flags -isnot [pscustomobject]) { return $null }
    $map = [ordered]@{}
    foreach ($p in $Flags.PSObject.Properties) { $map[$p.Name] = [string[]]@($p.Value) }
    [pscustomobject]$map
}
```

`Test-DFToolSchema.ps1`, in the role-block loop beside the aliases/env checks:

```powershell
            $v = Get-DFSchemaProperty $r.Value 'flags'
            if ($null -ne $v -and ($v -isnot [pscustomobject] -or @($v.PSObject.Properties | Where-Object {
                    $_.Value -isnot [array] -or @($_.Value | Where-Object { $_ -isnot [string] }).Count }).Count)) {
                "roles.$($r.Name).flags must map words to arrays of strings"
            }
```

Add `'flags'` to the `role` entry of the typo list in `Get-DFFieldTypoWarning`.

- [ ] **Step 4: Run to verify they pass**

Run the Step 2 command. Expected: PASS.

- [ ] **Step 5: Commit**

```powershell
git add Shared/Import-DFToolDb.ps1 Shared/Test-DFToolSchema.ps1 tests/ConvertTo-DFToolRecord.Tests.ps1 tests/Test-DFToolSchema.Tests.ps1
git commit -F <message file>   # "feat: role blocks carry flags (word -> args)"
```

---

### Task 3: Per-tool status notes

**Files:**
- Create: `Private/DFToolNote.ps1`
- Modify: `Private/Register-DFToolSteps.ps1` (clear at the start of registration), `Private/Invoke-DFSessionActivation.ps1` (status Detail)
- Test: `tests/DFToolNote.Tests.ps1`

**Interfaces:**
- Produces: `Add-DFToolNote -Tool <string> -Note <string>` (ignores a duplicate), `Get-DFToolNote -Tool <string>` → `[string[]]`, `Clear-DFToolNote -Tool <string>`.

- [ ] **Step 1: Write the failing tests**

```powershell
BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
}

Describe 'tool notes' {
    BeforeEach { Reset-DFTestSession; Clear-DFToolNote -Tool 'eza' }

    It 'returns notes in the order they were added, once each' {
        Add-DFToolNote -Tool 'eza' -Note 'first'
        Add-DFToolNote -Tool 'eza' -Note 'second'
        Add-DFToolNote -Tool 'eza' -Note 'first'
        Get-DFToolNote -Tool 'eza' | Should -Be @('first', 'second')
    }

    It 'starts each registration clean' {
        Add-DFToolNote -Tool 'eza' -Note 'old'
        Clear-DFToolNote -Tool 'eza'
        Get-DFToolNote -Tool 'eza' | Should -BeNullOrEmpty
    }

    It 'keeps tools apart' {
        Add-DFToolNote -Tool 'eza' -Note 'a'
        Get-DFToolNote -Tool 'lsd' | Should -BeNullOrEmpty
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `pwsh -NoProfile -Command "./build/Test-DFFull.ps1 -Path tests/DFToolNote.Tests.ps1"`
Expected: FAIL (commands not found).

- [ ] **Step 3: Implement**

`Private/DFToolNote.ps1`:

```powershell
#Requires -Version 7.2

$script:DFToolNotes = @{}

function Add-DFToolNote {
    <#
    .SYNOPSIS
        Records a note for a tool's status (e.g. a role flag it lacks); a repeated note is kept once.
    .PARAMETER Tool
        The tool name.
    .PARAMETER Note
        The note.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Tool, [Parameter(Mandatory)][string]$Note)
    if (-not $script:DFToolNotes.ContainsKey($Tool)) { $script:DFToolNotes[$Tool] = [System.Collections.Generic.List[string]]::new() }
    if (-not $script:DFToolNotes[$Tool].Contains($Note)) { $script:DFToolNotes[$Tool].Add($Note) }
}

function Get-DFToolNote {
    <#
    .SYNOPSIS
        Returns a tool's status notes, in the order they were added.
    .PARAMETER Tool
        The tool name.
    .OUTPUTS
        System.String[].
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$Tool)
    if ($script:DFToolNotes.ContainsKey($Tool)) { [string[]]@($script:DFToolNotes[$Tool]) }
}

function Clear-DFToolNote {
    <#
    .SYNOPSIS
        Forgets a tool's status notes; each registration of the tool starts with this.
    .PARAMETER Tool
        The tool name.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Tool)
    $script:DFToolNotes.Remove($Tool)
}
```

In `Invoke-DFToolRegistration` (`Private/Register-DFToolSteps.ps1`), next to `Clear-DFEnvKeptNote -Tool $Tool.name`, add `Clear-DFToolNote -Tool $Tool.name`.

In `Invoke-DFSessionActivation.ps1`, the Active status line becomes:

```powershell
                $status[$tool.name] = New-DFToolStatus -Name $tool.name -State Active -RequestedBy $requestedBy[$tool.name] -Detail @(@(Get-DFEnvKeptNote -Tool $tool.name) + @(Get-DFToolNote -Tool $tool.name))
```

In `Reset-DFTestSession` (`tests/TestSupport.ps1`), add `$script:DFToolNotes = @{}` after `$global:DFEnvState = $null`.

- [ ] **Step 4: Run to verify they pass**

Run: `pwsh -NoProfile -Command "./build/Test-DFFull.ps1 -Path tests/DFToolNote.Tests.ps1, tests/New-DFToolStatus.Tests.ps1, tests/Register-DFTool.Tests.ps1"`
Expected: PASS.

- [ ] **Step 5: Commit**

```powershell
git add Private/DFToolNote.ps1 Private/Register-DFToolSteps.ps1 Private/Invoke-DFSessionActivation.ps1 tests/DFToolNote.Tests.ps1 tests/TestSupport.ps1
git commit -F <message file>   # "feat: per-tool status notes (Add/Get/Clear-DFToolNote)"
```

---

### Task 4: Build aliases and pickers from a winner's flags

**Files:**
- Create: `Private/Get-DFRoleBehavior.ps1`
- Test: `tests/Get-DFRoleBehavior.Tests.ps1`

**Interfaces:**
- Consumes: role record `behaviors` (Task 1), role block `flags` (Task 2), `Add-DFToolNote` (Task 3).
- Produces:
  - `Get-DFRoleBehaviorAlias -RoleDefinition <role record> -Block <role block> -Tool <tool record>` → `[pscustomobject]` alias name → `{ command = <string>; args = [string[]] }` (the shape `Register-DFToolAliases` takes).
  - `Get-DFRolePicker -RoleDefinition -Block -Tool` → `[pscustomobject[]]`, each a copy of the role picker with `list` = `"<command> <args joined by spaces>"`.
  - Both call `Add-DFToolNote -Tool $Tool.name -Note "<role>: no flag for '<word>' (<names>)"` once per missing word, listing the aliases/pickers that use it.

- [ ] **Step 1: Write the failing tests**

```powershell
BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }

    $script:Role = ConvertTo-DFRoleRecord -Name 'listing' -Role ('{ "kind": "single", "hook": "Initialize-DFRoleListing",
        "behaviors": {
          "words": { "long": "d", "all": "h", "color": "c", "one-per-line": "1", "literal": "q" },
          "aliases": { "ll": ["long", "color", "literal"], "la": ["long", "all", "color", "literal"] },
          "pickers": [ { "alias": "ff", "function": "Select-File", "list": ["one-per-line", "color", "literal"],
                         "list_accepts_path": true, "preview": "bat {}", "action": "output" } ] } }' | ConvertFrom-Json)
    function script:New-Member([string]$FlagsJson) {
        ConvertTo-DFToolRecord ("{ ""name"": ""lsx"", ""executable"": ""lsx.exe"", ""roles"": { ""listing"": { ""flags"": $FlagsJson } } }" | ConvertFrom-Json)
    }
}

Describe 'Get-DFRoleBehaviorAlias' {
    BeforeEach { Clear-DFToolNote -Tool 'lsx' }

    It 'turns each alias''s words into the winner''s flags, in the role''s order' {
        $tool = New-Member '{ "long": ["--long"], "all": ["--all"], "color": ["--color=auto"], "one-per-line": ["-1"], "literal": ["--literal"] }'
        $aliases = Get-DFRoleBehaviorAlias -RoleDefinition $script:Role -Block $tool.roles.listing -Tool $tool
        $aliases.ll.command | Should -Be 'lsx'
        $aliases.ll.args | Should -Be @('--long', '--color=auto', '--literal')
        $aliases.la.args | Should -Be @('--long', '--all', '--color=auto', '--literal')
    }

    It 'adds nothing for a word mapped to []' {
        $tool = New-Member '{ "long": ["--long"], "all": ["--all"], "color": [], "one-per-line": ["-1"], "literal": [] }'
        (Get-DFRoleBehaviorAlias -RoleDefinition $script:Role -Block $tool.roles.listing -Tool $tool).ll.args | Should -Be @('--long')
    }

    It 'skips a missing word and reports it' {
        $tool = New-Member '{ "long": ["--long"], "color": [], "one-per-line": ["-1"], "literal": [] }'
        (Get-DFRoleBehaviorAlias -RoleDefinition $script:Role -Block $tool.roles.listing -Tool $tool).la.args | Should -Be @('--long')
        Get-DFToolNote -Tool 'lsx' | Should -Be @("listing: no flag for 'all' (la)")
    }
}

Describe 'Get-DFRolePicker' {
    BeforeEach { Clear-DFToolNote -Tool 'lsx' }

    It 'builds the list command from the winner''s flags and keeps the other fields' {
        $tool = New-Member '{ "long": ["--long"], "all": ["--all"], "color": ["--color=always"], "one-per-line": ["-1"], "literal": ["--literal"] }'
        $picker = @(Get-DFRolePicker -RoleDefinition $script:Role -Block $tool.roles.listing -Tool $tool)
        $picker.Count | Should -Be 1
        $picker[0].list | Should -Be 'lsx -1 --color=always --literal'
        $picker[0].alias | Should -Be 'ff'
        $picker[0].list_accepts_path | Should -BeTrue
        $picker[0].preview | Should -Be 'bat {}'
    }

    It 'does not change the role definition''s picker' {
        $tool = New-Member '{ "long": [], "all": [], "color": [], "one-per-line": ["-1"], "literal": [] }'
        Get-DFRolePicker -RoleDefinition $script:Role -Block $tool.roles.listing -Tool $tool | Out-Null
        $script:Role.behaviors.pickers[0].list | Should -Be @('one-per-line', 'color', 'literal')
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `pwsh -NoProfile -Command "./build/Test-DFFull.ps1 -Path tests/Get-DFRoleBehavior.Tests.ps1"`
Expected: FAIL (commands not found).

- [ ] **Step 3: Implement**

`Private/Get-DFRoleBehavior.ps1`:

```powershell
#Requires -Version 7.2

function Resolve-DFRoleWords {
    <#
    .SYNOPSIS
        A won role's words as the winner's arguments; missing words are returned, not thrown.
    .PARAMETER Words
        The words, in the order their flags go.
    .PARAMETER Flags
        The winner's role block flags (word -> string array).
    .OUTPUTS
        pscustomobject { Args = [string[]]; Missing = [string[]] }.
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][string[]]$Words, [AllowNull()][object]$Flags)
    $argList = [System.Collections.Generic.List[string]]::new()
    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($word in $Words) {
        $mapped = if ($Flags) { $Flags.PSObject.Properties[$word] }
        if ($mapped) { foreach ($a in @($mapped.Value)) { if ($a) { $argList.Add($a) } } } else { $missing.Add($word) }
    }
    [pscustomobject]@{ Args = [string[]]$argList.ToArray(); Missing = [string[]]$missing.ToArray() }
}

function Add-DFRoleMissingWordNote {
    <#
    .SYNOPSIS
        Notes, once per word, the role words a tool has no flag for, naming the aliases and pickers that use them.
    .PARAMETER Tool
        The tool record.
    .PARAMETER Role
        The role name.
    .PARAMETER Missing
        Word -> names of the aliases or pickers that use it.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$Tool, [Parameter(Mandatory)][string]$Role, [Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary]$Missing)
    foreach ($word in $Missing.Keys) {
        Add-DFToolNote -Tool $Tool.name -Note "$Role`: no flag for '$word' ($(@($Missing[$word]) -join ', '))"
    }
}

function Get-DFRoleBehaviorAlias {
    <#
    .SYNOPSIS
        Builds a won role's aliases from the winner's flags.
    .DESCRIPTION
        Each alias the role's behaviors define runs the winner's executable (its file
        name without extension) with each word's flags, in the role's order. A word the
        winner doesn't map is left out and noted in the tool's status.
    .PARAMETER RoleDefinition
        The role record (Get-DFRoleDb), with behaviors.
    .PARAMETER Block
        The winner's normalized block for the role (flags).
    .PARAMETER Tool
        The winner's tool record.
    .OUTPUTS
        PSCustomObject: alias name -> { command; args }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][PSCustomObject]$RoleDefinition, [Parameter(Mandatory)][PSCustomObject]$Block, [Parameter(Mandatory)][PSCustomObject]$Tool)
    $command = [IO.Path]::GetFileNameWithoutExtension([string]$Tool.executable)
    $aliases = [ordered]@{}
    $missing = [ordered]@{}
    foreach ($name in $RoleDefinition.behaviors.aliases.Keys) {
        $resolved = Resolve-DFRoleWords -Words $RoleDefinition.behaviors.aliases[$name] -Flags $Block.flags
        $aliases[$name] = [pscustomobject]@{ command = $command; args = $resolved.Args }
        foreach ($word in $resolved.Missing) { $missing[$word] = @(@($missing[$word]) + $name | Where-Object { $_ }) }
    }
    if ($missing.Count) { Add-DFRoleMissingWordNote -Tool $Tool -Role $RoleDefinition.name -Missing $missing }
    [pscustomobject]$aliases
}

function Get-DFRolePicker {
    <#
    .SYNOPSIS
        Builds a won role's pickers, with each list command made from the winner's flags.
    .DESCRIPTION
        Returns copies of the role's pickers whose list is "<executable> <flags>"; every
        other field (alias, function, preview, …) is kept. A missing word is noted as for aliases.
    .PARAMETER RoleDefinition
        The role record, with behaviors.
    .PARAMETER Block
        The winner's normalized block for the role.
    .PARAMETER Tool
        The winner's tool record.
    .OUTPUTS
        PSCustomObject[]: declarative pickers for Set-DFPickerFunction.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$RoleDefinition, [Parameter(Mandatory)][PSCustomObject]$Block, [Parameter(Mandatory)][PSCustomObject]$Tool)
    $command = [IO.Path]::GetFileNameWithoutExtension([string]$Tool.executable)
    $missing = [ordered]@{}
    $pickers = foreach ($picker in @($RoleDefinition.behaviors.pickers)) {
        $resolved = Resolve-DFRoleWords -Words @($picker.list) -Flags $Block.flags
        foreach ($word in $resolved.Missing) { $missing[$word] = @(@($missing[$word]) + $picker.alias | Where-Object { $_ }) }
        $copy = [ordered]@{}
        foreach ($p in $picker.PSObject.Properties) { $copy[$p.Name] = $p.Value }
        $copy['list'] = (@($command) + $resolved.Args) -join ' '
        [pscustomobject]$copy
    }
    if ($missing.Count) { Add-DFRoleMissingWordNote -Tool $Tool -Role $RoleDefinition.name -Missing $missing }
    @($pickers)
}
```

- [ ] **Step 4: Run to verify they pass**

Run the Step 2 command. Expected: PASS.

- [ ] **Step 5: Commit**

```powershell
git add Private/Get-DFRoleBehavior.ps1 tests/Get-DFRoleBehavior.Tests.ps1
git commit -F <message file>   # "feat: build a won role's aliases and pickers from the winner's flags"
```

---

### Task 5: Apply behaviors at registration

**Files:**
- Modify: `Private/Register-DFToolSteps.ps1` (`Invoke-DFToolRegistration`, the won-roles loop)
- Test: `tests/Roles.Registration.Tests.ps1`

**Interfaces:**
- Consumes: `Get-DFRoleBehaviorAlias`, `Get-DFRolePicker` (Task 4); `Register-DFToolAliases -Tool -Aliases`; `Set-DFPickerFunction -Picker`.

- [ ] **Step 1: Write the failing tests**

In `tests/Roles.Registration.Tests.ps1`, add a `Describe` with its own fixture (the existing `BeforeEach` pattern: XDG under `$TestDrive`, `Get-DFRoleDb -Path`, `Write-Tool`, `Mock Test-DFToolAvailable { $true }`, `Mock Write-DFConflictNotice { }`):

```powershell
Describe 'Register-DFTool role behaviors' {
    BeforeEach {
        Reset-DFTestSession
        $script:DFToolDb = $null; $script:DFToolAvailability = @{}
        Set-DFTestXdg
        Set-DFTestConfig $null
        $script:Tools = Join-Path $TestDrive "tools-$([guid]::NewGuid())"
        New-Item -ItemType Directory $script:Tools | Out-Null
        $rolesFile = Join-Path $TestDrive 'roles-behaviors.json'
        @'
{ "tlist": { "kind": "single", "hook": "Initialize-DFRoleTlist",
    "behaviors": { "words": { "long": "d", "all": "h", "one": "1" },
                   "aliases": { "tll": ["long"], "tla": ["long", "all"] },
                   "pickers": [ { "alias": "tff", "function": "Select-DFTestFile", "list": ["one"], "action": "output" } ] } } }
'@ | Set-Content $rolesFile
        $script:DFRoleDb = Get-DFRoleDb -Path $rolesFile
        '{ "name": "tlsa", "executable": "tlsa.exe", "roles": { "tlist": { "priority": 20, "flags": { "long": ["-l"], "all": ["-a"], "one": ["-1"] } } } }' |
            Set-Content (Join-Path $script:Tools 'tlsa.json')
        '{ "name": "tlsb", "executable": "tlsb.exe", "roles": { "tlist": { "priority": 10, "flags": { "long": ["--long"], "one": ["--oneline"] },
            "aliases": { "tll": { "command": "tlsb", "args": ["--hand"] } } } } }' |
            Set-Content (Join-Path $script:Tools 'tlsb.json')
        Mock Test-DFToolAvailable { $true }
        Mock Write-DFConflictNotice { }
    }
    AfterEach {
        Set-DFTestConfig $null
        Remove-DFTestGlobal -Function 'tll', 'tla', 'Select-DFTestFile'
        Remove-Alias tff -Scope Global -Force -ErrorAction Ignore
        $script:DFRoleDb = $null
        Restore-DFTestXdg
    }

    It 'gives the winner the role''s aliases and pickers from its flags' {
        Set-DFTestConfig @{ Tools = @('tlsa', 'tlsb') }
        Register-DFTool -Name 'tlsa', 'tlsb' -ToolsPath $script:Tools 3>$null 6>$null
        ${function:global:tla}.ToString() | Should -Match 'tlsa'
        ${function:global:tla}.ToString() | Should -Match '-l'
        ${function:global:tla}.ToString() | Should -Match '-a'
        ${function:global:Select-DFTestFile}.ToString() | Should -Not -BeNullOrEmpty
    }

    It 'Defaults flips the winner''s flags' {
        Set-DFTestConfig @{ Tools = @('tlsa', 'tlsb'); Defaults = @{ tlist = 'tlsb' } }
        Register-DFTool -Name 'tlsa', 'tlsb' -ToolsPath $script:Tools 3>$null 6>$null
        ${function:global:tll}.ToString() | Should -Match 'tlsb'
        ${function:global:tll}.ToString() | Should -Match '--long'
        ${function:global:tll}.ToString() | Should -Not -Match 'tlsa'
    }

    It 'ignores hand-written aliases for a behaviors role' {
        Set-DFTestConfig @{ Tools = @('tlsb') }
        Register-DFTool -Name 'tlsb' -ToolsPath $script:Tools 3>$null 6>$null
        ${function:global:tll}.ToString() | Should -Match '--long'
        ${function:global:tll}.ToString() | Should -Not -Match '--hand'
    }

    It 'notes missing words in the tool''s status' {
        Set-DFTestConfig @{ Tools = @('tlsb') }
        Register-DFTool -Name 'tlsb' -ToolsPath $script:Tools 3>$null 6>$null
        (Get-DFToolStatus -Name 'tlsb').Detail | Should -Contain "tlist: no flag for 'all' (tla)"
    }

    It 're-registration keeps one note' {
        Set-DFTestConfig @{ Tools = @('tlsb') }
        Register-DFTool -Name 'tlsb' -ToolsPath $script:Tools 3>$null 6>$null
        Register-DFTool -Name 'tlsb' -ToolsPath $script:Tools 3>$null 6>$null
        @((Get-DFToolStatus -Name 'tlsb').Detail | Where-Object { $_ -like 'tlist:*' }).Count | Should -Be 1
    }

    It 'does not warn about a missing hook for a behaviors-only membership' {
        Set-DFTestConfig @{ Tools = @('tlsa') }
        Register-DFTool -Name 'tlsa' -ToolsPath $script:Tools -WarningVariable w 6>$null
        "$w" | Should -Not -Match 'Initialize-DFRoleTlist'
    }
}
```

`Register-DFTool -Name` takes `[string[]]`. `Get-DFToolStatus -Name` returns a status whose `.Detail` is a string list (since T-28).

- [ ] **Step 2: Run to verify they fail**

Run: `pwsh -NoProfile -Command "./build/Test-DFFull.ps1 -Path tests/Roles.Registration.Tests.ps1"`
Expected: the new tests FAIL (no aliases built; hook warning).

- [ ] **Step 3: Implement**

In `Invoke-DFToolRegistration`, replace the won-role alias line and `HookRequired` with:

```powershell
        $roleDefinition = $RoleDb[$roleName]
        $behaviors = $roleDefinition.behaviors
        if ($behaviors) {
            if (Test-DFHasEntries $block.aliases) {
                Write-Verbose "DotForge: $($Tool.name)'s own aliases for '$roleName' are ignored; the role defines them (behaviors)."
            }
            Register-DFToolAliases -Tool $Tool -Aliases (Get-DFRoleBehaviorAlias -RoleDefinition $roleDefinition -Block $block -Tool $Tool)
            foreach ($picker in Get-DFRolePicker -RoleDefinition $roleDefinition -Block $block -Tool $Tool) { Set-DFPickerFunction -Picker $picker }
        } elseif ($block.aliases) {
            Register-DFToolAliases -Tool $Tool -Aliases $block.aliases
        }
        [pscustomobject]@{
            Role         = $roleName
            Hook         = $roleDefinition.hook
            # An empty {} block is still an object, so count what it holds.
            HookRequired = -not ($behaviors -or (Test-DFHasEntries $block.env) -or (Test-DFHasEntries $block.aliases) -or
                $block.legacy -or $roleDefinition.emptyMembership)
        }
```

Update the function's `.DESCRIPTION`: "For a role with behaviors, its aliases and pickers are built from the winner's flags (Get-DFRoleBehaviorAlias, Get-DFRolePicker)."

If `Invoke-DFToolRegistration` now passes ~60 lines, move the won-roles loop into `Invoke-DFWonRoles -Tool -Context` returning the won-role objects, and call it.

- [ ] **Step 4: Run to verify they pass**

Run: `pwsh -NoProfile -Command "./build/Test-DFFull.ps1 -Path tests/Roles.Registration.Tests.ps1, tests/Register-DFTool.Tests.ps1, tests/DefaultToolRoles.Tests.ps1"`
Expected: PASS.

- [ ] **Step 5: Commit**

```powershell
git add Private/Register-DFToolSteps.ps1 tests/Roles.Registration.Tests.ps1
git commit -F <message file>   # "feat: a won role with behaviors builds its aliases and pickers from the winner's flags"
```

---

### Task 6: Migrate the listing role, eza and lsd

**Files:**
- Modify: `data/roles.json` (`listing`), `Tools/eza.json`, `Tools/lsd.json`
- Modify: `tests/Roles.Contract.Tests.ps1`
- Create: `tests/Listing.Behaviors.Tests.ps1`
- Regenerate: `data/tool-registry.json`

**Interfaces:**
- Consumes: everything above.

- [ ] **Step 1: Write the failing tests**

`tests/Listing.Behaviors.Tests.ps1` (spells out the exact args, so a mapping change is a deliberate edit):

```powershell
BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    $script:Listing = (Get-DFRoleDb -Path "$PSScriptRoot/../data/roles.json")['listing']
    function script:Get-ListingAliases([string]$Name) {
        $tool = Get-DFTestToolRecord $Name
        Get-DFRoleBehaviorAlias -RoleDefinition $script:Listing -Block $tool.roles.listing -Tool $tool
    }
}

Describe 'listing behaviors' {
    It 'eza: <Alias>' -ForEach @(
        @{ Alias = 'ls';   Args = @('--color=auto', '--icons=auto', '--group-directories-first', '--no-quotes') }
        @{ Alias = 'll';   Args = @('--long', '--color=auto', '--icons=auto', '--group-directories-first', '--git', '--no-quotes') }
        @{ Alias = 'la';   Args = @('--long', '--all', '--color=auto', '--icons=auto', '--group-directories-first', '--git', '--no-quotes') }
        @{ Alias = 'tree'; Args = @('--tree', '--no-quotes') }
    ) {
        (Get-ListingAliases 'eza').$Alias.args | Should -Be $Args
    }

    It 'lsd: <Alias>' -ForEach @(
        @{ Alias = 'ls';   Args = @('--color=auto', '--icon=auto', '--group-directories-first', '--literal') }
        @{ Alias = 'll';   Args = @('--long', '--color=auto', '--icon=auto', '--group-directories-first', '--git', '--literal') }
        @{ Alias = 'la';   Args = @('--long', '--all', '--color=auto', '--icon=auto', '--group-directories-first', '--git', '--literal') }
        @{ Alias = 'tree'; Args = @('--tree', '--literal') }
    ) {
        (Get-ListingAliases 'lsd').$Alias.args | Should -Be $Args
    }

    It 'ff lists through the winner: <Name>' -ForEach @(
        @{ Name = 'eza'; List = 'eza -1 --icons=always --color=always --no-quotes' }
        @{ Name = 'lsd'; List = 'lsd -1 --icon=always --color=always --literal' }
    ) {
        $tool = Get-DFTestToolRecord $Name
        (Get-DFRolePicker -RoleDefinition $script:Listing -Block $tool.roles.listing -Tool $tool)[0].list | Should -Be $List
    }

    It 'eza no longer declares its own ff picker' {
        (Get-DFTestToolRecord 'eza').picker | Should -BeNullOrEmpty
    }
}
```

(`Get-DFTestToolRecord <name>` is the existing helper in `tests/TestSupport.ps1`: it loads and normalizes `Tools/<name>.json`.)

In `tests/Roles.Contract.Tests.ps1`:
1. Derive reserved aliases for roles with behaviors. Replace the `$script:AllReservedAliases` line:

```powershell
    $script:ReservedAliasesOf = @{}
    foreach ($roleName in $script:Roles.Keys) {
        $def = $script:Roles[$roleName]
        $script:ReservedAliasesOf[$roleName] = if ($def['behaviors']) {
            @(@($def['behaviors']['aliases'].Keys) + @($def['behaviors']['pickers'] | ForEach-Object { $_['alias'] } | Where-Object { $_ }))
        } elseif ($def['reserved']) { @($def['reserved']['aliases'] | Where-Object { $_ }) } else { @() }
    }
    $script:AllReservedAliases = @($script:ReservedAliasesOf.Values | ForEach-Object { $_ } | Where-Object { $_ })
```

2. Count `flags` as role content in `Test-RoleBlockContent`:

```powershell
        ($Block['env'] -and $Block['env'].Count -gt 0) -or ($Block['aliases'] -and $Block['aliases'].Count -gt 0) -or
            ($Block['flags'] -and $Block['flags'].Count -gt 0)
```

3. New `It` blocks inside `Describe 'Role contract: <Name>'`:

```powershell
    It 'maps every word its behaviors roles use, and only those' {
        $memberships = Get-RoleMemberships $JsonPath
        foreach ($role in $memberships.Keys) {
            $behaviors = $script:Roles[$role]['behaviors']
            if (-not $behaviors) { continue }
            $used = @(@($behaviors['aliases'].Values | ForEach-Object { $_ }) + @($behaviors['pickers'] | ForEach-Object { $_['list'] }) | Select-Object -Unique)
            $mapped = @(if ($memberships[$role]['flags']) { $memberships[$role]['flags'].Keys })
            foreach ($word in $used) { $word | Should -BeIn $mapped -Because "$Name joins '$role' but has no flag for '$word'" }
            foreach ($word in $mapped) { $word | Should -BeIn @($behaviors['words'].Keys) -Because "'$word' is not one of '$role''s words" }
        }
    }

    It 'writes no aliases by hand for a behaviors role' {
        $memberships = Get-RoleMemberships $JsonPath
        foreach ($role in $memberships.Keys) {
            if (-not $script:Roles[$role]['behaviors']) { continue }
            $hand = $memberships[$role]['aliases']
            ($hand -and $hand.Count) | Should -BeFalse -Because "'$role' defines its aliases from behaviors"
        }
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `pwsh -NoProfile -Command "./build/Test-DFFull.ps1 -Path tests/Listing.Behaviors.Tests.ps1, tests/Roles.Contract.Tests.ps1"`
Expected: FAIL (listing has no behaviors yet; eza/lsd have aliases, no flags).

- [ ] **Step 3: Migrate the data**

`data/roles.json`, `listing`, exactly as in the spec's "A role describes its behavior in words" block (without the `header` word), with `"reserved": { "env": [], "aliases": [], "code": [] }` and description "Lists directory contents. The winner defines ls, ll, la, tree and ff.". The `ff` picker carries today's eza fields: `"preview": "bat --color=always --line-range=:200 {}", "preview_window": "right:60%", "ansi": true, "header": "Select file  [Enter to output path]", "action": "output", "list_accepts_path": true`.

`Tools/eza.json`: replace `roles.listing` with:

```json
  "roles": { "listing": { "priority": 20, "flags": {
    "color": ["--color=auto"], "color-always": ["--color=always"],
    "icons": ["--icons=auto"], "icons-always": ["--icons=always"],
    "dirs-first": ["--group-directories-first"], "literal": ["--no-quotes"],
    "long": ["--long"], "all": ["--all"], "git": ["--git"],
    "tree": ["--tree"], "one-per-line": ["-1"]
  } } },
```

and set `"picker": null`.

`Tools/lsd.json`: replace `roles.listing` with:

```json
  "roles": { "listing": { "priority": 10, "flags": {
    "color": ["--color=auto"], "color-always": ["--color=always"],
    "icons": ["--icon=auto"], "icons-always": ["--icon=always"],
    "dirs-first": ["--group-directories-first"], "literal": ["--literal"],
    "long": ["--long"], "all": ["--all"], "git": ["--git"],
    "tree": ["--tree"], "one-per-line": ["-1"]
  } } },
```

Check `Tools/eza.json` for other fields that reference the `ff` picker (none expected) and `docs/guide/*.md` for doc blocks that run `ff` (`git grep -n "\bff\b" docs/guide`).

Run `pwsh -NoProfile -File build/Build-DFToolRegistry.ps1`.

- [ ] **Step 4: Run to verify they pass**

Run: `pwsh -NoProfile -Command "./build/Test-DFFull.ps1 -Path tests/Listing.Behaviors.Tests.ps1, tests/Roles.Contract.Tests.ps1, tests/ToolRegistry.Tests.ps1, tests/Tools.PickerDeclaration.Tests.ps1, tests/eza.Tests.ps1, tests/lsd.Tests.ps1, tests/DefaultToolRoles.Tests.ps1"`
Expected: PASS. Fix any test that asserted eza's old top-level `ff` picker or lsd's old `ll`/`la` args: update it to the new meaning, never delete the assertion.

- [ ] **Step 5: Try it for real**

In a clean shell with sandbox XDG folders (as in earlier sessions: set all four `XDG_*_HOME` under a temp folder, `Import-Module ./DotForge.psd1 -Force`):
- `Start-DFSession -Config @{ Tools = @('eza') }`, then `(Get-Command ll).Definition` shows eza's args, and `Get-Command ff` exists.
- `Start-DFSession -Config @{ Tools = @('lsd') }` in a new shell: `ll`'s definition shows `--long` and not `--all`; `ff` exists and its list uses lsd.

- [ ] **Step 6: Commit**

```powershell
git add data/roles.json Tools/eza.json Tools/lsd.json data/tool-registry.json tests/Roles.Contract.Tests.ps1 tests/Listing.Behaviors.Tests.ps1 <any updated test>
git commit -F <message file>   # "feat: listing describes ls/ll/la/tree/ff once; eza and lsd map its words"
```

---

### Task 7: Docs, backlog, full run, merge

**Files:**
- Modify: `docs/guide/writing-a-tool.md` ("Joining a role"), `docs/guide/tools.md`, `docs/superpowers/specs/2026-10-05-roles-v2-design.md`, `CLAUDE.md` (`roles` bullet), `CHANGELOG.md`, `TODO.md`
- Regenerate: `Bundle/DotForge.Core.ps1`, `docs/reference.md`

- [ ] **Step 1: Author docs**

`docs/guide/writing-a-tool.md`, "Joining a role", add after the role block description:

```markdown
Some roles define their aliases and pickers themselves, in words (`listing`: `ls`,
`ll`, `la`, `tree` and the `ff` picker). Join one by mapping each of its words to your
tool's flags in your role block; `[]` means your tool does that by default:

```json
"roles": { "listing": { "priority": 5, "flags": {
  "color": ["--color=auto"], "color-always": ["--color=always"],
  "icons": ["--icon=auto"], "icons-always": ["--icon=always"],
  "dirs-first": ["--group-directories-first"], "literal": ["--literal"],
  "long": ["--long"], "all": ["--all"], "git": ["--git"],
  "tree": ["--tree"], "one-per-line": ["-1"]
} } }
```

`data/roles.json` lists each role's words and what they mean. Don't write the role's
aliases yourself: they're ignored. If your tool lacks a word, the aliases that use it
are built without it, and `Get-DFToolStatus <tool>` says which.
```

`docs/guide/tools.md`: in the listing row or section, state the meanings: `ls` (names, directories first), `ll` (long, with git status), `la` (`ll` plus hidden entries), `tree`, and `ff` (file picker), the same for eza and lsd.

`docs/superpowers/specs/2026-10-05-roles-v2-design.md`: append a short "Addendum (2026-10-16): role behaviors" paragraph pointing to `2026-10-16-role-behaviors-design.md`.

`CLAUDE.md`, the `roles` bullet: add "A role may define `behaviors` (words, aliases, pickers) in `data/roles.json`; members then map words to flags (`flags`) instead of writing the aliases (`docs/superpowers/specs/2026-10-16-role-behaviors-design.md`)."

`CHANGELOG.md` `[Unreleased]`:
- `### Changed`: "**lsd's `ll` and `la` now mean what eza's do.** `ll` is a long listing without hidden entries (it had `--all` and `--header`); `la` is `ll` with hidden entries (it was a short listing)."
- `### Added`: "**Roles describe their aliases once.** A role can define its aliases and pickers in words; each member maps the words to its own flags. `listing` does this, so `ls`, `ll`, `la`, `tree` and `ff` mean the same with eza or lsd, and `ff` now works with lsd too."

`TODO.md`: delete T-34.

- [ ] **Step 2: Regenerate and run the full gate**

```powershell
pwsh -NoProfile -File build/Build-DFCoreBundle.ps1
pwsh -NoProfile -File build/Build-DFToolRegistry.ps1
pwsh -NoProfile -File build/Build-DFReferenceDocs.ps1
pwsh -NoProfile -File build/Test-DFFull.ps1
```

Expected: exit 0, no failed containers. Fix anything red; never skip a failing test.

- [ ] **Step 3: Commit and push** (standing permission after a green full run)

```powershell
git add docs CLAUDE.md CHANGELOG.md TODO.md Bundle data
git commit -F <message file>   # "docs: role behaviors" with "Closes T-34"
git push origin main
```
