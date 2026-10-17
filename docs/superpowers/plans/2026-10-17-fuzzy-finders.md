# Fuzzy Finders and Fuzzy Keys Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add skim, television, peco and gum as full tools, give Ctrl+R and Ctrl+T each a role (`history-search`, `path-insert`), and add generic setup notes.

**Architecture:** Two new single roles bind PSReadLine keys only through `Set-DFRoleKeyHandler` (Private), which keeps a user's own binding; fzf and skim share one engine handler (`Register-DFFuzzyKeyHandler`), PSFzf and television bind their own functions. Setup gains `setup.notes` (shown once, kept in status) and `{theme}` in seed sources. Theme files for the four tools are generated from one catppuccin palette.

**Tech Stack:** PowerShell 7.2+, Pester 6, PSReadLine 2.x, JSON tool records.

**Spec:** `docs/superpowers/specs/2026-10-17-fuzzy-finders-design.md`

## Global Constraints

- No tool names in core code (`Private/`, `Shared/`, `Public/`); tool specifics live in `Tools/<tool>.json` / `.ps1` (`docs/plugin-architecture.md`).
- Every env write goes through `Set-DFEnv`; every directory creation in module code through `New-DFDirectory`.
- Tests: load with `. "$PSScriptRoot/TestSupport.ps1"; foreach ($f in Get-DFTestModuleFile) { . $f }`; `Set-DFTestXdg`/`Restore-DFTestXdg`; `Reset-DFTestSession` in `BeforeEach` of any `Describe` that registers tools; `Set-DFTestConfig`; `Remove-DFTestGlobal` for test globals; Pester 6 syntax only (`Should -Invoke`).
- No test runs a real `sk`, `tv`, `peco`, `gum`, `fzf` or PSFzf.
- Every global function a `Tools/*.ps1` defines has full comment help (`.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER` each, `.EXAMPLE` code + blank line + prose, `.OUTPUTS`).
- Every new config key goes in `$script:DFConfigKeys` (`Private/DFSessionConfig.ps1`).
- Before each commit: `./build/Build-DFCoreBundle.ps1` when `Shared/`, `Private/` or `Public/` changed; `./build/Build-DFToolRegistry.ps1` when `Tools/*.json` changed.
- Run tests: `pwsh -NoProfile -Command "./build/Test-DFFull.ps1 -Path <files>"`; the whole suite before merging.
- Commits are GPG-signed; never bypass signing. If signing times out, ask the user to run `! 'unlock' | gpg --clearsign | Out-Null`.
- Work in worktree `../DotForge-fuzzy` on branch `fuzzy-finders`.

## Review Focus

1. A multi-line command in PSReadLine history must come back from Ctrl+R exactly as it was saved (pinned in Task 2).
2. A host without PSReadLine (redirected, VS Code task) must load without errors and bind nothing (Task 2).
3. Re-registering a tool (`Register-DFTool PSFzf`) must not treat DotForge's own earlier binding as the user's (Task 2).
4. A changed `tv init power-shell` (renamed function, unparsable script) must leave the key unbound with a status note, never fail the load (Task 6).
5. A path with a space or a single quote inserted by Ctrl+T must be one valid PowerShell argument (Task 2).

---

### Task 1: Setup notes and `{theme}` seed sources

**Files:**
- Create: `Private/DFSetupNote.ps1`
- Modify: `Private/Invoke-DFToolCompanion.ps1` (setup step), `Private/Invoke-DFToolSeed.ps1` (source path), `Public/Complete-DFToolSetup.ps1` (record notes), `Private/Invoke-DFSessionActivation.ps1` (`Write-DFSessionNotice`), `Public/Get-DFToolStatus.ps1`, `Public/Invoke-DFToolSetup.ps1`, `Shared/Import-DFToolDb.ps1` (`ConvertTo-DFSetupBlock`), `Shared/Test-DFToolSchema.ps1` (`Get-DFSetupSchemaError`)
- Test: `tests/DFSetupNote.Tests.ps1`

**Interfaces:**
- Produces: `Add-DFToolSetupNote -Name <string> -Text <string>` (setup scripts call it before `Complete-DFToolSetup`); `setup.notes` = array of `{ text, ifFile?, unlessFile? }`, conditions evaluated **before** seeds are copied; seed sources may contain `{theme}` (the tool's theme value; with `theme.files` an absolute path to the theme file or folder).

- [ ] **Step 1: Write the failing tests**

`tests/DFSetupNote.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }

    function script:New-NoteTool([string]$Json, [hashtable]$Files = @{}) {
        $dir = Join-Path $TestDrive "nt-$([guid]::NewGuid().ToString('N').Substring(0,6))"
        New-Item -ItemType Directory (Join-Path $dir 'nt') -Force | Out-Null
        Set-Content (Join-Path $dir 'nt' 'c.conf') 'default' -NoNewline
        foreach ($k in $Files.Keys) {
            $path = Join-Path $dir $k
            New-Item -ItemType Directory (Split-Path $path) -Force | Out-Null
            Set-Content $path $Files[$k] -NoNewline
        }
        Set-Content (Join-Path $dir 'nt.json') $Json
        $dir
    }
    $script:NotesJson = '{ "name": "nt", "executable": "nt.exe", "setup": {
        "seed": { "${XDG_CONFIG_HOME}/nt/c.conf": "nt/c.conf" },
        "notes": [ { "text": "always" }, { "text": "you had a config", "ifFile": "${XDG_CONFIG_HOME}/nt/c.conf" } ] } }'
}

Describe 'setup notes' {
    BeforeEach {
        Set-DFTestXdg; Reset-DFTestSession; Set-DFTestConfig $null
        Mock Test-DFToolAvailable { $true }
        Mock Write-DFConflictNotice { }
        Mock Write-Host { }
    }
    AfterEach { Restore-DFTestXdg; Set-DFTestConfig $null }

    It 'records a declared note with the setup and shows it once' {
        $tools = New-NoteTool $script:NotesJson
        Start-DFSession -Config @{ Tools = @('nt') } -ToolsPath $tools 3>$null
        @((Get-DFToolSetupState).nt.notes) | Should -Be @('always')
        Should -Invoke Write-Host -Times 1 -ParameterFilter { $Object -eq 'DotForge: nt: always' }
    }
    It 'evaluates a note''s condition before the seeds are copied' {
        $tools = New-NoteTool $script:NotesJson
        $own = Join-Path $Env:XDG_CONFIG_HOME 'nt' 'c.conf'
        New-Item -ItemType Directory (Split-Path $own) -Force | Out-Null
        Set-Content $own 'mine' -NoNewline
        Start-DFSession -Config @{ Tools = @('nt') } -ToolsPath $tools 3>$null
        @((Get-DFToolSetupState).nt.notes) | Should -Be @('always', 'you had a config')
        Get-Content $own -Raw | Should -Be 'mine'
    }
    It 'does not show the note again on a later load, but keeps it in the status' {
        $tools = New-NoteTool $script:NotesJson
        Start-DFSession -Config @{ Tools = @('nt') } -ToolsPath $tools 3>$null
        Reset-DFTestSession
        Mock Write-Host { }
        Start-DFSession -Config @{ Tools = @('nt') } -ToolsPath $tools 3>$null
        # Only the first load printed it.
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { "$Object" -like 'DotForge: nt:*' }
        (Get-DFToolStatus nt).Detail | Should -Match 'setup note: always'
    }
    It 'shows and records nothing for a tool in SkipSetup' {
        $tools = New-NoteTool $script:NotesJson
        Start-DFSession -Config @{ Tools = @('nt'); SkipSetup = @('nt') } -ToolsPath $tools 3>$null
        (Get-DFToolSetupState).PSObject.Properties['nt'] | Should -BeNullOrEmpty
        Should -Invoke Write-Host -Times 0 -ParameterFilter { "$Object" -like 'DotForge: nt:*' }
    }
    It 'records a note a setup script adds' {
        $tools = New-NoteTool '{ "name": "nt", "executable": "nt.exe" }' @{
            'nt.setup.ps1' = "Add-DFToolSetupNote -Name nt -Text 'from the script'`nComplete-DFToolSetup -Name nt"
        }
        Start-DFSession -Config @{ Tools = @('nt') } -ToolsPath $tools 3>$null
        @((Get-DFToolSetupState).nt.notes) | Should -Be @('from the script')
    }
    It 'drops the notes of a setup that fails, so the retry starts clean' {
        $tools = New-NoteTool '{ "name": "nt", "executable": "nt.exe" }' @{
            'nt.setup.ps1' = "Add-DFToolSetupNote -Name nt -Text 'half done'`nthrow 'boom'"
        }
        Start-DFSession -Config @{ Tools = @('nt') } -ToolsPath $tools 3>$null
        (Get-DFToolSetupState).PSObject.Properties['nt'] | Should -BeNullOrEmpty
        Get-DFPendingSetupNote -Name nt | Should -BeNullOrEmpty
        Should -Invoke Write-Host -Times 0 -ParameterFilter { "$Object" -like 'DotForge: nt:*' }
    }
}

Describe 'seed sources with {theme}' {
    BeforeEach {
        Set-DFTestXdg; Reset-DFTestSession; Set-DFTestConfig $null
        Mock Test-DFToolAvailable { $true }
        Mock Write-DFConflictNotice { }
    }
    AfterEach { Restore-DFTestXdg; Set-DFTestConfig $null }

    It 'copies the theme''s own file, following Theme' {
        $json = '{ "name": "nt", "executable": "nt.exe", "theme": { "key": "NtTheme", "default": "one", "files": "nt" },
                   "setup": { "seed": { "${XDG_CONFIG_HOME}/nt/conf.json": "{theme}" } } }'
        $tools = New-NoteTool $json @{ 'nt/one.json' = '{"n":1}'; 'nt/two.json' = '{"n":2}' }
        Start-DFSession -Config @{ Tools = @('nt'); Theme = 'two' } -ToolsPath $tools 3>$null
        Get-Content (Join-Path $Env:XDG_CONFIG_HOME 'nt' 'conf.json') -Raw | Should -Be '{"n":2}'
    }
    It 'copies a file inside a theme folder' {
        $json = '{ "name": "nt", "executable": "nt.exe", "theme": { "key": "NtTheme", "default": "one", "files": "nt" },
                   "setup": { "seed": { "${XDG_CONFIG_HOME}/nt/config.toml": "{theme}/config.toml" } } }'
        $tools = New-NoteTool $json @{ 'nt/one/config.toml' = 'theme = "one"' }
        Start-DFSession -Config @{ Tools = @('nt') } -ToolsPath $tools 3>$null
        Get-Content (Join-Path $Env:XDG_CONFIG_HOME 'nt' 'config.toml') -Raw | Should -Be 'theme = "one"'
    }
}

Describe 'setup.notes schema' {
    BeforeAll {
        function script:Get-NoteSchemaError($Notes) {
            $tool = [pscustomobject]@{ name = 't'; executable = 't.exe'; setup = [pscustomobject]@{ notes = $Notes } }
            "$((Test-DFToolSchema -Tool $tool).Errors)"
        }
    }
    It 'accepts notes with text and optional conditions' {
        Get-NoteSchemaError @([pscustomobject]@{ text = 'x' }, [pscustomobject]@{ text = 'y'; ifFile = 'a'; unlessFile = 'b' }) | Should -BeNullOrEmpty
    }
    It 'rejects a note without text, a non-string condition, or a non-array' {
        Get-NoteSchemaError @([pscustomobject]@{ ifFile = 'a' }) | Should -Match 'setup\.notes'
        Get-NoteSchemaError @([pscustomobject]@{ text = 'x'; ifFile = 3 }) | Should -Match 'setup\.notes'
        Get-NoteSchemaError 'x' | Should -Match 'setup\.notes'
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pwsh -NoProfile -Command "./build/Test-DFFull.ps1 -Path tests/DFSetupNote.Tests.ps1"`
Expected: FAIL (`Add-DFToolSetupNote`/`Get-DFPendingSetupNote` not recognized; notes not recorded; `{theme}` seed source not found).

- [ ] **Step 3: Create `Private/DFSetupNote.ps1`**

```powershell
#Requires -Version 7.2

# Setup notes: steps only the user can take. They are collected while a tool's
# one-time setup runs, recorded with its setup record by Complete-DFToolSetup,
# printed once at the end of the load and kept in Get-DFToolStatus.
# Design: docs/superpowers/specs/2026-10-17-fuzzy-finders-design.md.
$script:DFPendingSetupNotes = @{}
$script:DFNewSetupNotes = [System.Collections.Generic.List[object]]::new()

function Add-DFToolSetupNote {
    <#
    .SYNOPSIS
        Adds a note for the user to a tool's running one-time setup.
    .DESCRIPTION
        A Tools/<name>.setup.ps1 calls it before Complete-DFToolSetup, which
        records the notes with the setup; they are printed once at the end of
        the load and stay in Get-DFToolStatus. A repeated note is kept once.
    .PARAMETER Name
        The tool name.
    .PARAMETER Text
        What the user should do.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Text)
    if (-not $script:DFPendingSetupNotes.ContainsKey($Name)) { $script:DFPendingSetupNotes[$Name] = [System.Collections.Generic.List[string]]::new() }
    if (-not $script:DFPendingSetupNotes[$Name].Contains($Text)) { $script:DFPendingSetupNotes[$Name].Add($Text) }
}

function Add-DFDeclaredSetupNote {
    <#
    .SYNOPSIS
        Adds a tool's declared setup.notes whose file conditions hold now, before its seeds are copied.
    .DESCRIPTION
        A note's ifFile/unlessFile are read like a role flag group's
        (Resolve-DFRoleFlagGroup: {theme}, {settings.<name>}, ${XDG_*}), so
        "ifFile: the config file" means the user already had one.
    .PARAMETER Tool
        A normalized tool record.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Tool)
    $setup = $Tool.setup
    if (-not $setup) { return }
    foreach ($note in @($setup.notes)) {
        if (-not $note) { continue }
        $group = [pscustomobject]@{
            ifFile     = $note.PSObject.Properties['ifFile']?.Value
            unlessFile = $note.PSObject.Properties['unlessFile']?.Value
            args       = @([string]$note.text)
        }
        foreach ($text in @(Resolve-DFRoleFlagGroup -Group $group -Tool $Tool)) { Add-DFToolSetupNote -Name $Tool.name -Text $text }
    }
}

function Get-DFPendingSetupNote {
    <#
    .SYNOPSIS
        Returns the notes collected so far by a tool's running setup.
    .PARAMETER Name
        The tool name.
    .OUTPUTS
        System.String[].
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$Name)
    if ($script:DFPendingSetupNotes.ContainsKey($Name)) { [string[]]@($script:DFPendingSetupNotes[$Name]) }
}

function Clear-DFPendingSetupNote {
    <#
    .SYNOPSIS
        Forgets a tool's collected notes (its setup failed, or they were recorded).
    .PARAMETER Name
        The tool name.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $script:DFPendingSetupNotes.Remove($Name)
}

function Publish-DFSetupNote {
    <#
    .SYNOPSIS
        Moves a tool's recorded notes to this session's list to show at the end of the load.
    .PARAMETER Name
        The tool name.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    foreach ($text in @(Get-DFPendingSetupNote -Name $Name)) { $script:DFNewSetupNotes.Add([pscustomobject]@{ Tool = $Name; Text = $text }) }
    Clear-DFPendingSetupNote -Name $Name
}

function Write-DFSetupNoteNotice {
    <#
    .SYNOPSIS
        Prints, once, the setup notes recorded since the last notice.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param()
    foreach ($note in $script:DFNewSetupNotes) { Write-Host "DotForge: $($note.Tool): $($note.Text)" -ForegroundColor Cyan }
    $script:DFNewSetupNotes.Clear()
}

function Add-DFSetupNoteDetail {
    <#
    .SYNOPSIS
        Adds each tool's recorded setup notes to its status detail, once, when the status is read.
    .DESCRIPTION
        Reads the setup state only when Get-DFToolStatus runs, never at startup.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param()
    if (-not $script:DFSessionStatus) { return }
    $todo = @($script:DFSessionStatus.Values | Where-Object { -not $_.PSObject.Properties['SetupNoted'] })
    if (-not $todo) { return }
    $state = Get-DFToolSetupState
    foreach ($status in $todo) {
        $status | Add-Member -NotePropertyName SetupNoted -NotePropertyValue $true -Force
        $entry = $state.PSObject.Properties[$status.Name]?.Value
        $notes = if ($entry) { $entry.PSObject.Properties['notes']?.Value }
        foreach ($text in @($notes)) { if ($text) { Add-DFToolStatusDetail -Status $status -Text "setup note: $text" } }
    }
}
```

- [ ] **Step 4: Wire it in**

`Private/Invoke-DFToolCompanion.ps1`, the setup step (replace the `HasSeed` line through the `catch`):

```powershell
    $__dfCall.HasSeed = [bool]$__dfCall.Tool.PSObject.Properties['setup']?.Value?.seed
    $__dfCall.HasNotes = [bool]@($__dfCall.Tool.PSObject.Properties['setup']?.Value?.notes | Where-Object { $_ }).Count
    if (($__dfCall.HasSetupScript -or $__dfCall.HasSeed -or $__dfCall.HasNotes) -and
        $__dfCall.Name -notin $__dfCall.SkipSetup -and
        -not (Get-DFToolSetupState).PSObject.Properties[$__dfCall.Name]) {
        try {
            # Before the seeds: a note's ifFile can then tell an existing file from a seeded one.
            Add-DFDeclaredSetupNote -Tool $__dfCall.Tool
            $__dfCall.Seeded = @(Invoke-DFToolSeed -Tool $__dfCall.Tool -ToolsPath $__dfCall.Folder)
            if ($__dfCall.HasSetupScript) {
                $DFCurrentTool = $__dfCall.Tool
                . ($__dfCall.Setup)
            } else {
                Complete-DFToolSetup -Name $__dfCall.Name -Actions $__dfCall.Seeded
            }
        } catch {
            Clear-DFPendingSetupNote -Name $__dfCall.Name
            Write-Warning "DotForge: $($__dfCall.Name) one-time setup failed: $($_.Exception.Message)"
        }
        Remove-Variable -Name DFCurrentTool -ErrorAction Ignore
    }
```

`Private/Invoke-DFToolSeed.ps1`, inside the `foreach ($s in $seed.PSObject.Properties)` loop, replace `$src = Join-Path $ToolsPath $s.Value` with:

```powershell
        $source = [string]$s.Value
        if ($source.Contains('{theme}')) {
            # With theme.files the value is the theme's own file or folder (an absolute path).
            $theme = if ($Tool.theme) { (Get-DFToolTheme -Tool $Tool).Value }
            if (-not $theme) { throw "seed source '$source' needs a theme, and $($Tool.name) has none this session" }
            $source = $source.Replace('{theme}', [string]$theme)
        }
        $src = if ([System.IO.Path]::IsPathRooted($source)) { $source } else { Join-Path $ToolsPath $source }
```

and change the not-found message to use `$source` instead of `$s.Value`. Add to its `.DESCRIPTION`: "A source may contain {theme}: the tool's theme value this session (with theme.files, the theme file or folder)."

`Public/Complete-DFToolSetup.ps1`: the entry becomes

```powershell
    $entry = [PSCustomObject]@{
        ranAt   = (Get-Date).ToUniversalTime().ToString('o')
        actions = @($Actions)
        notes   = [string[]]@(Get-DFPendingSetupNote -Name $Name)
    }
```

and after `Write-DFFileAtomic ...` add `Publish-DFSetupNote -Name $Name`. Add to `.DESCRIPTION`: "Notes added with Add-DFToolSetupNote (or declared in setup.notes) are recorded as notes and printed once at the end of the load."

`Private/Invoke-DFSessionActivation.ps1`, `Write-DFSessionNotice`: make `Write-DFSetupNoteNotice` its first statement after `param()` (before the `DFSessionStatus` early return). Add to its `.SYNOPSIS`: "…and prints new setup notes."

`Public/Get-DFToolStatus.ps1`: after `Add-DFInstallHint` add `Add-DFSetupNoteDetail`.

`Public/Invoke-DFToolSetup.ps1`: add `Write-DFSetupNoteNotice` as the last statement of the function body (after the setup re-runs).

`Shared/Import-DFToolDb.ps1`, `ConvertTo-DFSetupBlock`:

```powershell
    [pscustomobject]@{
        seed  = Get-DFToolRecordProperty $RawSetup 'seed' $null
        notes = @(Get-DFToolRecordProperty $RawSetup 'notes' @())
    }
```

`Shared/Test-DFToolSchema.ps1`, `Get-DFSetupSchemaError` (keep the seed branch; add after it):

```powershell
        $notes = $setup.PSObject.Properties['notes']?.Value
        if ($null -ne $notes) {
            $bad = $notes -isnot [array] -or @($notes | Where-Object {
                $note = $_
                $note -isnot [pscustomobject] -or -not ($note.PSObject.Properties['text']?.Value -is [string]) -or -not $note.text -or
                @('ifFile', 'unlessFile' | Where-Object { $null -ne $note.PSObject.Properties[$_]?.Value -and $note.$_ -isnot [string] }).Count
            }).Count
            if ($bad) { 'setup.notes must be an array of { text, ifFile?, unlessFile? } objects with string values' }
        }
```

(Put it inside `if ($setup -is [pscustomobject])` so a non-object setup reports only `setup must be an object`. Update its `.SYNOPSIS` to "Schema errors in setup, setup.seed and setup.notes.")

- [ ] **Step 5: Run the tests to verify they pass**

Run: `pwsh -NoProfile -Command "./build/Test-DFFull.ps1 -Path tests/DFSetupNote.Tests.ps1, tests/Invoke-DFToolSetup.Tests.ps1, tests/Complete-DFToolSetup.Tests.ps1, tests/Register-DFTool.Tests.ps1, tests/Test-DFToolSchema.Tests.ps1, tests/ConvertTo-DFToolRecord.Tests.ps1"`
Expected: PASS, 0 failed.

- [ ] **Step 6: Commit**

```bash
./build/Build-DFCoreBundle.ps1
git add Private/DFSetupNote.ps1 Private/Invoke-DFToolCompanion.ps1 Private/Invoke-DFToolSeed.ps1 Public/Complete-DFToolSetup.ps1 Private/Invoke-DFSessionActivation.ps1 Public/Get-DFToolStatus.ps1 Public/Invoke-DFToolSetup.ps1 Shared/Import-DFToolDb.ps1 Shared/Test-DFToolSchema.ps1 Bundle/DotForge.Core.ps1 tests/DFSetupNote.Tests.ps1
git commit -m "feat: setup notes (shown once, kept in status) and {theme} in seed sources"
```

---

### Task 2: Key-binding roles and the shared handler

**Files:**
- Modify: `data/roles.json`
- Create: `Private/Set-DFRoleKeyHandler.ps1`, `Private/Register-DFFuzzyKeyHandler.ps1`
- Test: `tests/FuzzyKeys.Tests.ps1`

**Interfaces:**
- Consumes: `$script:DFSessionRoleWinners[<role>].Reason` (`'Defaults'` when chosen in Defaults); `Add-DFToolNote -Tool -Note`.
- Produces:
  - roles `history-search` (hook `Initialize-DFRoleHistorySearch`), `path-insert` (hook `Initialize-DFRolePathInsert`), category `fuzzy-finder`; both single roles reserve code `Set-DFRoleKeyHandler`, `Register-DFFuzzyKeyHandler`.
  - `Set-DFRoleKeyHandler -Role <string> -Chord <string> -Tool <string> -Bind <scriptblock>`
  - `Register-DFFuzzyKeyHandler -Engine <string> -Key History|Path -Tool <string>`
  - `Remove-DFKeyHandlerCall -Script <string>` → string, or `$null` when the script doesn't parse (Task 6 uses it).

- [ ] **Step 1: Write the failing tests**

`tests/FuzzyKeys.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    Import-Module PSReadLine -ErrorAction Ignore
}

Describe 'key-binding roles' {
    It 'defines history-search and path-insert with their hooks, and the fuzzy-finder category' {
        $db = Get-DFRoleDb
        $db['history-search'].hook | Should -Be 'Initialize-DFRoleHistorySearch'
        $db['path-insert'].hook | Should -Be 'Initialize-DFRolePathInsert'
        $db['history-search'].reserved.code | Should -Contain 'Set-DFRoleKeyHandler'
        $db['fuzzy-finder'].kind | Should -Be 'category'
    }
}

Describe 'Set-DFRoleKeyHandler' {
    BeforeEach {
        Reset-DFTestSession
        $script:DFBoundKeys.Clear()
        $script:DFSessionRoleWinners = @{ 'history-search' = [pscustomobject]@{ Winner = 'fzf'; Reason = 'priority' } }
        $script:Bound = 0
        $script:BindIt = { $script:Bound++ }
    }

    It 'binds a key that has only PSReadLine''s own handler' {
        Mock Get-PSReadLineKeyHandler { [pscustomobject]@{ Key = 'Ctrl+r'; Function = 'ReverseSearchHistory' } }
        Set-DFRoleKeyHandler -Role history-search -Chord 'Ctrl+r' -Tool fzf -Bind $script:BindIt
        $script:Bound | Should -Be 1
    }
    It 'keeps a binding the user made, with a status note' {
        Mock Get-PSReadLineKeyHandler { [pscustomobject]@{ Key = 'Ctrl+r'; Function = 'MyHistory' } }
        Set-DFRoleKeyHandler -Role history-search -Chord 'Ctrl+r' -Tool fzf -Bind $script:BindIt
        $script:Bound | Should -Be 0
        Get-DFToolNote -Tool fzf | Should -Match 'kept your own Ctrl\+r binding'
    }
    It 'replaces the user''s binding, with a warning, when Defaults names the tool' {
        $script:DFSessionRoleWinners['history-search'] = [pscustomobject]@{ Winner = 'fzf'; Reason = 'Defaults' }
        Mock Get-PSReadLineKeyHandler { [pscustomobject]@{ Key = 'Ctrl+r'; Function = 'MyHistory' } }
        Set-DFRoleKeyHandler -Role history-search -Chord 'Ctrl+r' -Tool fzf -Bind $script:BindIt -WarningVariable warned 3>$null
        $script:Bound | Should -Be 1
        "$warned" | Should -Match 'Defaults'
    }
    It 'rebinds its own earlier binding when the tool registers again' {
        Mock Get-PSReadLineKeyHandler { [pscustomobject]@{ Key = 'Ctrl+r'; Function = 'DotForge history-search (fzf)' } }
        [void]$script:DFBoundKeys.Add('Ctrl+r')
        Set-DFRoleKeyHandler -Role history-search -Chord 'Ctrl+r' -Tool fzf -Bind $script:BindIt
        $script:Bound | Should -Be 1
    }
    It 'binds nothing, without error, when PSReadLine isn''t available' {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'Set-PSReadLineKeyHandler' }
        { Set-DFRoleKeyHandler -Role history-search -Chord 'Ctrl+r' -Tool fzf -Bind $script:BindIt } | Should -Not -Throw
        $script:Bound | Should -Be 0
    }
}

Describe 'shared fuzzy key handler' {
    BeforeEach { Reset-DFTestSession; $script:DFBoundKeys.Clear(); $script:DFSessionRoleWinners = @{} }

    It 'reads history newest first, without repeats, joining multi-line entries' {
        $file = Join-Path $TestDrive 'hist.txt'
        Set-Content $file -Value @('git status', 'if ($x) {`', '  y', '}', 'ls', 'git status')
        Get-DFHistoryCandidate -Path $file | Should -Be @('git status', 'ls', "if (`$x) {`n  y`n}")
    }
    It 'returns nothing for a missing history file' {
        Get-DFHistoryCandidate -Path (Join-Path $TestDrive 'none.txt') | Should -BeNullOrEmpty
    }
    It 'quotes inserted paths that hold a space or a quote' {
        Format-DFPathInsert -Path @('a.txt', 'my file.txt', "it's.txt") | Should -Be "a.txt 'my file.txt' 'it''s.txt'"
    }
    It 'History: runs the engine on the history with the line as query and replaces the line' {
        $file = Join-Path $TestDrive 'h2.txt'
        Set-Content $file -Value @('git status')
        Mock Get-DFReadLineBuffer { [pscustomobject]@{ Line = 'git'; Cursor = 3 } }
        Mock Get-PSReadLineOption { [pscustomobject]@{ HistorySavePath = $file } }
        Mock Invoke-DFFuzzyEngine { 'git status' }
        Mock Update-DFReadLineBuffer { }
        Invoke-DFFuzzyKey -Engine sk -Key History
        Should -Invoke Invoke-DFFuzzyEngine -Times 1 -ParameterFilter { $Engine -eq 'sk' -and ($Arguments -join ' ') -eq '--no-sort --query git' -and @($InputObject) -contains 'git status' }
        Should -Invoke Update-DFReadLineBuffer -Times 1 -ParameterFilter { $Replace -eq 'git status' }
    }
    It 'History: a multi-line entry comes back exactly as saved' {
        $file = Join-Path $TestDrive 'h3.txt'
        Set-Content $file -Value @('a `', 'b')
        Mock Get-DFReadLineBuffer { [pscustomobject]@{ Line = ''; Cursor = 0 } }
        Mock Get-PSReadLineOption { [pscustomobject]@{ HistorySavePath = $file } }
        Mock Invoke-DFFuzzyEngine { @($InputObject)[0] }
        Mock Update-DFReadLineBuffer { }
        Invoke-DFFuzzyKey -Engine fzf -Key History
        Should -Invoke Update-DFReadLineBuffer -Times 1 -ParameterFilter { $Replace -eq "a `nb" }
    }
    It 'Esc changes nothing but redraws the prompt' {
        Mock Get-DFReadLineBuffer { [pscustomobject]@{ Line = 'x'; Cursor = 1 } }
        Mock Get-PSReadLineOption { [pscustomobject]@{ HistorySavePath = (Join-Path $TestDrive 'none.txt') } }
        Mock Invoke-DFFuzzyEngine { }
        Mock Update-DFReadLineBuffer { }
        Invoke-DFFuzzyKey -Engine fzf -Key History
        Should -Invoke Update-DFReadLineBuffer -Times 1 -ParameterFilter { -not $Replace -and -not $Insert }
    }
    It 'Path: runs the engine''s own default command with --multi and inserts the quoted picks' {
        Mock Get-DFReadLineBuffer { [pscustomobject]@{ Line = 'code '; Cursor = 5 } }
        Mock Invoke-DFFuzzyEngine { 'src/a.ps1'; 'my dir/b.ps1' }
        Mock Update-DFReadLineBuffer { }
        Invoke-DFFuzzyKey -Engine fzf -Key Path
        Should -Invoke Invoke-DFFuzzyEngine -Times 1 -ParameterFilter { ($Arguments -join ' ') -eq '--multi' -and -not $PSBoundParameters.ContainsKey('InputObject') }
        Should -Invoke Update-DFReadLineBuffer -Times 1 -ParameterFilter { $Insert -eq "src/a.ps1 'my dir/b.ps1'" }
    }
    It 'binds Ctrl+r for History and Ctrl+t for Path' {
        Mock Get-PSReadLineKeyHandler { }
        Mock Set-PSReadLineKeyHandler { }
        Register-DFFuzzyKeyHandler -Engine fzf -Key History -Tool fzf
        Register-DFFuzzyKeyHandler -Engine fzf -Key Path -Tool fzf
        Should -Invoke Set-PSReadLineKeyHandler -Times 1 -ParameterFilter { $Chord -eq 'Ctrl+r' }
        Should -Invoke Set-PSReadLineKeyHandler -Times 1 -ParameterFilter { $Chord -eq 'Ctrl+t' }
    }
}

Describe 'Remove-DFKeyHandlerCall' {
    It 'removes every Set-PSReadLineKeyHandler call and keeps the rest' {
        $script = @'
function Invoke-A { 'a' }
Set-PSReadLineKeyHandler -Chord 'Ctrl+t' -ScriptBlock {
    Invoke-A
}
Set-PSReadLineKeyHandler -Chord 'Ctrl+r' -ScriptBlock { Set-PSReadLineKeyHandler -Chord x -ScriptBlock {} }
'@
        $out = Remove-DFKeyHandlerCall -Script $script
        $out | Should -Not -Match 'Set-PSReadLineKeyHandler'
        $out | Should -Match 'function Invoke-A'
    }
    It 'returns $null for a script that doesn''t parse' {
        Remove-DFKeyHandlerCall -Script 'function {' | Should -BeNullOrEmpty
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pwsh -NoProfile -Command "./build/Test-DFFull.ps1 -Path tests/FuzzyKeys.Tests.ps1"`
Expected: FAIL (roles missing; `Set-DFRoleKeyHandler` etc. not recognized).

- [ ] **Step 3: Add the roles to `data/roles.json`**

After the `picker` entry:

```json
  "history-search": {
    "kind": "single",
    "exclusive": false,
    "hook": "Initialize-DFRoleHistorySearch",
    "reserved": { "env": [], "aliases": [], "code": ["Set-DFRoleKeyHandler", "Register-DFFuzzyKeyHandler"] },
    "description": "Searches command history from Ctrl+R. Only the winner binds the key; a binding you made yourself is kept."
  },
  "path-insert": {
    "kind": "single",
    "exclusive": false,
    "hook": "Initialize-DFRolePathInsert",
    "reserved": { "env": [], "aliases": [], "code": ["Set-DFRoleKeyHandler", "Register-DFFuzzyKeyHandler"] },
    "description": "Inserts picked paths at the cursor from Ctrl+T. Only the winner binds the key; a binding you made yourself is kept."
  },
```

and with the categories:

```json
  "fuzzy-finder":    { "kind": "category", "description": "Filters a list interactively as you type." },
```

- [ ] **Step 4: Create `Private/Set-DFRoleKeyHandler.ps1`**

```powershell
#Requires -Version 7.2

# Chords DotForge bound this session, so registering a tool again doesn't mistake
# DotForge's own earlier binding for one the user made.
$script:DFBoundKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

function Set-DFRoleKeyHandler {
    <#
    .SYNOPSIS
        Binds a key-binding role's PSReadLine chord for its winner, keeping a binding the user made.
    .DESCRIPTION
        The history-search and path-insert roles bind only through this (it is
        their reserved code). When the chord already runs a custom handler that
        DotForge didn't bind this session, it is kept and the tool's status says
        so, unless Defaults names this tool for the role: then it is replaced
        with a warning. Without PSReadLine (a redirected host) nothing is bound.
    .PARAMETER Role
        The role name.
    .PARAMETER Chord
        The PSReadLine chord, e.g. 'Ctrl+r'.
    .PARAMETER Tool
        The winning tool's name.
    .PARAMETER Bind
        Binds the chord: Set-PSReadLineKeyHandler, or the tool's own option.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Role,
        [Parameter(Mandatory)][string]$Chord,
        [Parameter(Mandatory)][string]$Tool,
        [Parameter(Mandatory)][scriptblock]$Bind
    )
    if (-not (Get-Command -Name Set-PSReadLineKeyHandler -ErrorAction Ignore)) { return }
    $existing = Get-PSReadLineKeyHandler -Chord $Chord -ErrorAction Ignore | Select-Object -First 1
    if ($existing -and -not $script:DFBoundKeys.Contains($Chord) -and (Test-DFCustomKeyHandler -Handler $existing)) {
        $winner = if ($script:DFSessionRoleWinners) { $script:DFSessionRoleWinners[$Role] }
        if (-not ($winner -and $winner.Reason -eq 'Defaults')) {
            Add-DFToolNote -Tool $Tool -Note "kept your own $Chord binding, so $Tool doesn't bind it ($Role)"
            return
        }
        Write-Warning "DotForge: Defaults names $Tool for $Role; replacing your $Chord binding."
    }
    & $Bind
    [void]$script:DFBoundKeys.Add($Chord)
}

function Test-DFCustomKeyHandler {
    <#
    .SYNOPSIS
        True when a PSReadLine key handler is a custom one rather than a PSReadLine function.
    .PARAMETER Handler
        A Get-PSReadLineKeyHandler result.
    .OUTPUTS
        System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$Handler)
    $readLine = 'Microsoft.PowerShell.PSConsoleReadLine' -as [type]
    if (-not $readLine) { return $false }
    $name = [string]$Handler.Function
    -not ($name -and $readLine.GetMethod($name))
}
```

- [ ] **Step 5: Create `Private/Register-DFFuzzyKeyHandler.ps1`**

```powershell
#Requires -Version 7.2

# Ctrl+R / Ctrl+T for fzf-compatible engines that ship no PowerShell bindings
# (fzf, skim). Each tool's role hook passes its own executable; nothing here names
# a tool. Design: docs/superpowers/specs/2026-10-17-fuzzy-finders-design.md.

# How a multi-line history entry is shown on one line in the picker.
$script:DFHistoryLineMark = ' ␤ '

function Register-DFFuzzyKeyHandler {
    <#
    .SYNOPSIS
        Binds Ctrl+R (history) or Ctrl+T (paths) to an fzf-compatible engine.
    .DESCRIPTION
        History: PSReadLine's saved history, newest first and without repeats,
        is piped to <engine> --no-sort --query <line>, and the pick replaces
        the line. Path: the engine runs its own default command
        (FZF_DEFAULT_COMMAND / SKIM_DEFAULT_COMMAND) with --multi, and the
        picks are inserted at the cursor. Esc changes nothing. Binds through
        Set-DFRoleKeyHandler, so a binding the user made is kept.
    .PARAMETER Engine
        The executable, e.g. fzf or sk.
    .PARAMETER Key
        History (Ctrl+r, role history-search) or Path (Ctrl+t, role path-insert).
    .PARAMETER Tool
        The tool's name, for its status.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Engine,
        [Parameter(Mandatory)][ValidateSet('History', 'Path')][string]$Key,
        [Parameter(Mandatory)][string]$Tool
    )
    $role = if ($Key -eq 'History') { 'history-search' } else { 'path-insert' }
    $chord = if ($Key -eq 'History') { 'Ctrl+r' } else { 'Ctrl+t' }
    # The handler runs later, outside the module: carry the private function along.
    $invoke = ${function:Invoke-DFFuzzyKey}
    $handler = { & $invoke -Engine $Engine -Key $Key }.GetNewClosure()
    Set-DFRoleKeyHandler -Role $role -Chord $chord -Tool $Tool -Bind {
        Set-PSReadLineKeyHandler -Chord $chord -BriefDescription "DotForge $role ($Engine)" -Description "Fuzzy $role with $Engine (DotForge)" -ScriptBlock $handler
    }.GetNewClosure()
}

function Invoke-DFFuzzyKey {
    <#
    .SYNOPSIS
        Runs one fuzzy key press: picks with the engine, then edits the command line.
    .PARAMETER Engine
        The executable.
    .PARAMETER Key
        History or Path.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Engine, [Parameter(Mandatory)][ValidateSet('History', 'Path')][string]$Key)
    $buffer = Get-DFReadLineBuffer
    if ($Key -eq 'History') {
        $shown = [ordered]@{}
        foreach ($entry in @(Get-DFHistoryCandidate -Path (Get-PSReadLineOption).HistorySavePath)) {
            $shown[$entry.Replace("`n", $script:DFHistoryLineMark)] = $entry
        }
        $picked = @(Invoke-DFFuzzyEngine -Engine $Engine -Arguments @('--no-sort', '--query', $buffer.Line) -InputObject ([string[]]@($shown.Keys)))
        if ($picked.Count -and $shown.Contains([string]$picked[0])) { Update-DFReadLineBuffer -Replace $shown[[string]$picked[0]]; return }
    } else {
        $picked = @(Invoke-DFFuzzyEngine -Engine $Engine -Arguments @('--multi'))
        if ($picked.Count) { Update-DFReadLineBuffer -Insert (Format-DFPathInsert -Path $picked); return }
    }
    Update-DFReadLineBuffer
}

function Get-DFHistoryCandidate {
    <#
    .SYNOPSIS
        PSReadLine's saved history, newest first, without repeats; a multi-line entry stays one entry.
    .DESCRIPTION
        PSReadLine saves a multi-line command with a backtick ending every line
        but the last; those lines are joined with a newline.
    .PARAMETER Path
        The history file (Get-PSReadLineOption).HistorySavePath.
    .OUTPUTS
        System.String[].
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $entries = [System.Collections.Generic.List[string]]::new()
    $pending = [System.Text.StringBuilder]::new()
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        if ($line.EndsWith('`')) { [void]$pending.Append($line.Substring(0, $line.Length - 1)).Append("`n"); continue }
        $entries.Add($pending.ToString() + $line)
        [void]$pending.Clear()
    }
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    for ($i = $entries.Count - 1; $i -ge 0; $i--) {
        $entry = $entries[$i]
        if ($entry.Trim() -and $seen.Add($entry)) { $entry }
    }
}

function Format-DFPathInsert {
    <#
    .SYNOPSIS
        Joins picked paths into PowerShell arguments, single-quoting any with a space or a quote.
    .PARAMETER Path
        The picked paths.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string[]]$Path)
    @(foreach ($p in $Path) { if ($p -match "[\s']") { "'" + $p.Replace("'", "''") + "'" } else { $p } }) -join ' '
}

function Invoke-DFFuzzyEngine {
    <#
    .SYNOPSIS
        Runs the engine: on the given items, or on its own default command when none are given.
    .PARAMETER Engine
        The executable.
    .PARAMETER Arguments
        Its arguments.
    .PARAMETER InputObject
        Lines to pick from; omit it to let the engine list files itself.
    .OUTPUTS
        System.String[]: the picks.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Engine, [string[]]$Arguments = @(), [string[]]$InputObject)
    if ($PSBoundParameters.ContainsKey('InputObject')) { $InputObject | & $Engine @Arguments } else { & $Engine @Arguments }
}

function Get-DFReadLineBuffer {
    <#
    .SYNOPSIS
        The command line being edited and the cursor position.
    .OUTPUTS
        PSCustomObject: Line, Cursor.
    #>
    [CmdletBinding()]
    param()
    $line = $null; $cursor = $null
    [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
    [pscustomobject]@{ Line = $line; Cursor = $cursor }
}

function Update-DFReadLineBuffer {
    <#
    .SYNOPSIS
        Replaces the command line or inserts text at the cursor, then redraws the prompt.
    .PARAMETER Replace
        The new command line.
    .PARAMETER Insert
        Text to insert at the cursor.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([string]$Replace, [string]$Insert)
    if ($Replace) {
        $buffer = Get-DFReadLineBuffer
        [Microsoft.PowerShell.PSConsoleReadLine]::Replace(0, $buffer.Line.Length, $Replace)
    } elseif ($Insert) {
        [Microsoft.PowerShell.PSConsoleReadLine]::Insert($Insert)
    }
    # A full-screen picker leaves the prompt half-drawn.
    [Microsoft.PowerShell.PSConsoleReadLine]::InvokePrompt()
}

function Remove-DFKeyHandlerCall {
    <#
    .SYNOPSIS
        Removes every Set-PSReadLineKeyHandler call from a tool's init script, so only role winners bind keys.
    .DESCRIPTION
        Parses the script and cuts out each outermost Set-PSReadLineKeyHandler
        command. A script that doesn't parse returns $null: loading nothing is
        safer than loading a script whose bindings couldn't be removed.
    .PARAMETER Script
        The init script text.
    .OUTPUTS
        System.String, or $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Script)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Script, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { return $null }
    $calls = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Set-PSReadLineKeyHandler' }, $true))
    $outermost = @($calls | Where-Object {
        $parent = $_.Parent
        while ($parent) { if ($parent -in $calls) { return $false }; $parent = $parent.Parent }
        $true
    })
    $text = $Script
    foreach ($call in @($outermost | Sort-Object { $_.Extent.StartOffset } -Descending)) {
        $text = $text.Remove($call.Extent.StartOffset, $call.Extent.EndOffset - $call.Extent.StartOffset)
    }
    $text
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `pwsh -NoProfile -Command "./build/Test-DFFull.ps1 -Path tests/FuzzyKeys.Tests.ps1, tests/Get-DFRoleDb.Tests.ps1, tests/Roles.Contract.Tests.ps1"`
Expected: PASS. (If `Get-DFRoleDb.Tests.ps1` counts roles, update the count and ledger it.)

- [ ] **Step 7: Commit**

```bash
./build/Build-DFCoreBundle.ps1
git add data/roles.json Private/Set-DFRoleKeyHandler.ps1 Private/Register-DFFuzzyKeyHandler.ps1 Bundle/DotForge.Core.ps1 tests/FuzzyKeys.Tests.ps1
git commit -m "feat: history-search and path-insert roles, with a shared Ctrl+R/Ctrl+T handler"
```

---

### Task 3: PSFzf and fzf join the key roles

**Files:**
- Modify: `Tools/PSFzf.json`, `Tools/PSFzf.ps1`, `Tools/fzf.json`, `Tools/fzf.ps1`
- Test: `tests/FuzzyKeys.Members.Tests.ps1`

**Interfaces:**
- Consumes: `Set-DFRoleKeyHandler`, `Register-DFFuzzyKeyHandler` (Task 2).
- Produces: PSFzf in `history-search`/`path-insert` at 30; fzf at 10 and in `fuzzy-finder`.

- [ ] **Step 1: Write the failing tests**

`tests/FuzzyKeys.Members.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    function Set-PsFzfOption { param([Parameter(ValueFromRemainingArguments)]$Rest) }
    $script:Tools = Join-Path $PSScriptRoot '..' 'Tools'
}

Describe 'PSFzf binds only the keys it won' {
    BeforeEach {
        Mock Import-Module { } -ParameterFilter { $Name -eq 'PSFzf' }
        Mock Get-Module { [pscustomobject]@{ Name = 'PSFzf' } } -ParameterFilter { $Name -eq 'PSFzf' }
        Mock Set-PsFzfOption { }
        Mock Set-DFRoleKeyHandler { & $Bind }
        . (Join-Path $script:Tools 'PSFzf.ps1')
    }
    It 'binds no chord in its companion body' {
        Should -Invoke Set-PsFzfOption -Times 0 -ParameterFilter { $Rest -contains '-PSReadlineChordReverseHistory' -or $Rest -contains '-PSReadlineChordProvider' }
    }
    It 'binds Ctrl+r from the history-search hook' {
        Initialize-DFRoleHistorySearch -Tool ([pscustomobject]@{ name = 'PSFzf' }) -Role 'history-search'
        Should -Invoke Set-DFRoleKeyHandler -Times 1 -ParameterFilter { $Role -eq 'history-search' -and $Chord -eq 'Ctrl+r' -and $Tool -eq 'PSFzf' }
        Should -Invoke Set-PsFzfOption -Times 1 -ParameterFilter { $Rest -contains '-PSReadlineChordReverseHistory' }
    }
    It 'binds Ctrl+t from the path-insert hook' {
        Initialize-DFRolePathInsert -Tool ([pscustomobject]@{ name = 'PSFzf' }) -Role 'path-insert'
        Should -Invoke Set-PsFzfOption -Times 1 -ParameterFilter { $Rest -contains '-PSReadlineChordProvider' }
    }
}

Describe 'fzf binds through the shared handler' {
    BeforeEach {
        $script:SavedOpts = $Env:FZF_DEFAULT_OPTS
        Mock Register-DFFuzzyKeyHandler { }
        Mock Get-DFToolTheme { [pscustomobject]@{ Native = 'catppuccin-mocha'; Explicit = $false } }
        $DFCurrentTool = [pscustomobject]@{ name = 'fzf' }
        . (Join-Path $script:Tools 'fzf.ps1')
    }
    AfterEach { $Env:FZF_DEFAULT_OPTS = $script:SavedOpts; Remove-DFTestGlobal -Function 'Invoke-DFApplyFzfTheme' }
    It 'binds History and Path with fzf' {
        Initialize-DFRoleHistorySearch -Tool ([pscustomobject]@{ name = 'fzf' }) -Role 'history-search'
        Initialize-DFRolePathInsert -Tool ([pscustomobject]@{ name = 'fzf' }) -Role 'path-insert'
        Should -Invoke Register-DFFuzzyKeyHandler -Times 1 -ParameterFilter { $Engine -eq 'fzf' -and $Key -eq 'History' }
        Should -Invoke Register-DFFuzzyKeyHandler -Times 1 -ParameterFilter { $Engine -eq 'fzf' -and $Key -eq 'Path' }
    }
}

Describe 'key role winners' {
    It 'ranks PSFzf over fzf in both roles' {
        $db = Import-DFToolDb -ToolsPath $script:Tools -Name fzf, PSFzf
        $db['PSFzf'].roles.'history-search'.priority | Should -BeGreaterThan $db['fzf'].roles.'history-search'.priority
        $db['PSFzf'].roles.'path-insert'.priority | Should -BeGreaterThan $db['fzf'].roles.'path-insert'.priority
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pwsh -NoProfile -Command "./build/Test-DFFull.ps1 -Path tests/FuzzyKeys.Members.Tests.ps1"`
Expected: FAIL (chord options still in the companion body; hooks not defined; roles missing).

- [ ] **Step 3: Change the records and companions**

`Tools/PSFzf.json` roles: `"roles": { "completion": {}, "tab-completion": { "priority": 20 }, "history-search": { "priority": 30 }, "path-insert": { "priority": 30 } },`

`Tools/fzf.json` roles: `"roles": { "picker": { "priority": 10, "env": { "Picker": "fzf" } }, "history-search": { "priority": 10 }, "path-insert": { "priority": 10 }, "fuzzy-finder": {} },`

`Tools/PSFzf.ps1`: delete the `Set-PsFzfOption -PSReadlineChordProvider 'Ctrl+t' -PSReadlineChordReverseHistory 'Ctrl+r'` call; change the header's first two lines to

```powershell
# Companion for PSFzf — imports the module and configures its key bindings:
#   Ctrl+T  fzf file picker (when PSFzf wins path-insert)   Ctrl+R  history (when it wins history-search)
```

and append:

```powershell
function Initialize-DFRoleHistorySearch {
    param($Tool, $Role)
    if (-not (Get-Module -Name PSFzf)) { return }
    Set-DFRoleKeyHandler -Role $Role -Chord 'Ctrl+r' -Tool $Tool.name -Bind { Set-PsFzfOption -PSReadlineChordReverseHistory 'Ctrl+r' }
}

function Initialize-DFRolePathInsert {
    param($Tool, $Role)
    if (-not (Get-Module -Name PSFzf)) { return }
    Set-DFRoleKeyHandler -Role $Role -Chord 'Ctrl+t' -Tool $Tool.name -Bind { Set-PsFzfOption -PSReadlineChordProvider 'Ctrl+t' }
}
```

`Tools/fzf.ps1`: add to the header "Binds Ctrl+R / Ctrl+T through the shared handler when fzf wins history-search / path-insert (PSFzf outranks it)." and append:

```powershell
function Initialize-DFRoleHistorySearch {
    param($Tool, $Role)
    Register-DFFuzzyKeyHandler -Engine 'fzf' -Key History -Tool $Tool.name
}

function Initialize-DFRolePathInsert {
    param($Tool, $Role)
    Register-DFFuzzyKeyHandler -Engine 'fzf' -Key Path -Tool $Tool.name
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pwsh -NoProfile -Command "./build/Test-DFFull.ps1 -Path tests/FuzzyKeys.Members.Tests.ps1, tests/TabCompletionHooks.Tests.ps1, tests/fzf.Tests.ps1, tests/Roles.Contract.Tests.ps1, tests/Tools.CompanionPickers.Tests.ps1"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
./build/Build-DFToolRegistry.ps1
git add Tools/PSFzf.json Tools/PSFzf.ps1 Tools/fzf.json Tools/fzf.ps1 data/tool-registry.json tests/FuzzyKeys.Members.Tests.ps1
git commit -m "feat: PSFzf and fzf bind Ctrl+R/Ctrl+T only when they win the key roles"
```

---

### Task 4: Catppuccin theme files for skim, peco, gum and television

**Files:**
- Create: `build/catppuccin-palette.psd1`, `build/New-DFCatppuccinThemes.ps1`, generated `Tools/{skim,peco,gum}/catppuccin-<flavor>.json`, `Tools/television/catppuccin-<flavor>/{theme.toml,config.toml}`, `Tools/{skim,peco,gum,television}/LICENSE-catppuccin`
- Test: `tests/CatppuccinThemes.Tests.ps1`

**Interfaces:**
- Produces: skim/gum files `{ name, colors|env }` (fzf's theme-file shape); peco files are peco `config.json` documents; television folders hold a tv theme (`theme.toml`) and a seed config (`config.toml`, `[ui] theme = "catppuccin-<flavor>"`).

- [ ] **Step 1: Write the failing test**

`tests/CatppuccinThemes.Tests.ps1`:

```powershell
Describe 'generated catppuccin theme files' {
    BeforeAll {
        $script:Repo = Join-Path $PSScriptRoot '..'
        $script:Out = Join-Path $TestDrive 'Tools'
        & (Join-Path $script:Repo 'build' 'New-DFCatppuccinThemes.ps1') -OutputRoot $script:Out
        $script:Generated = @(Get-ChildItem $script:Out -Recurse -File | ForEach-Object { [System.IO.Path]::GetRelativePath($script:Out, $_.FullName) })
    }
    It 'writes every file' {
        $script:Generated.Count | Should -Be 24   # skim/peco/gum: 4 + license each; television: 4 x 2 + license
    }
    It 'matches the files in Tools (run build/New-DFCatppuccinThemes.ps1 after changing it)' {
        foreach ($rel in $script:Generated) {
            $repoFile = Join-Path $script:Repo 'Tools' $rel
            Test-Path $repoFile | Should -BeTrue -Because "$rel is generated"
            (Get-Content $repoFile -Raw) -replace "`r`n", "`n" | Should -BeExactly ((Get-Content (Join-Path $script:Out $rel) -Raw) -replace "`r`n", "`n") -Because "$rel is stale"
        }
    }
    It 'uses each flavor''s own colors' {
        $palette = Import-PowerShellDataFile (Join-Path $script:Repo 'build' 'catppuccin-palette.psd1')
        foreach ($flavor in 'mocha', 'macchiato', 'frappe', 'latte') {
            (Get-Content (Join-Path $script:Out 'skim' "catppuccin-$flavor.json") -Raw | ConvertFrom-Json).colors.bg | Should -Be $palette[$flavor].base
            (Get-Content (Join-Path $script:Out 'gum' "catppuccin-$flavor.json") -Raw | ConvertFrom-Json).env.GUM_FILTER_MATCH_FOREGROUND | Should -Be $palette[$flavor].red
            (Get-Content (Join-Path $script:Out 'peco' "catppuccin-$flavor.json") -Raw | ConvertFrom-Json).Style.Matched | Should -Be @($palette[$flavor].red)
            Get-Content (Join-Path $script:Out 'television' "catppuccin-$flavor" 'theme.toml') -Raw | Should -Match "background = '$($palette[$flavor].base)'"
            Get-Content (Join-Path $script:Out 'television' "catppuccin-$flavor" 'config.toml') -Raw | Should -Match "theme = `"catppuccin-$flavor`""
        }
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `pwsh -NoProfile -Command "./build/Test-DFFull.ps1 -Path tests/CatppuccinThemes.Tests.ps1"`
Expected: FAIL (generator not found).

- [ ] **Step 3: Write the palette** — `build/catppuccin-palette.psd1`:

```powershell
# Catppuccin palette (https://github.com/catppuccin/palette, MIT). Read by
# build/New-DFCatppuccinThemes.ps1.
@{
    mocha     = @{ rosewater = '#f5e0dc'; flamingo = '#f2cdcd'; pink = '#f5c2e7'; mauve = '#cba6f7'; red = '#f38ba8'; maroon = '#eba0ac'; peach = '#fab387'; yellow = '#f9e2af'; green = '#a6e3a1'; teal = '#94e2d5'; sky = '#89dceb'; sapphire = '#74c7ec'; blue = '#89b4fa'; lavender = '#b4befe'; text = '#cdd6f4'; subtext1 = '#bac2de'; subtext0 = '#a6adc8'; overlay2 = '#9399b2'; overlay1 = '#7f849c'; overlay0 = '#6c7086'; surface2 = '#585b70'; surface1 = '#45475a'; surface0 = '#313244'; base = '#1e1e2e'; mantle = '#181825'; crust = '#11111b' }
    macchiato = @{ rosewater = '#f4dbd6'; flamingo = '#f0c6c6'; pink = '#f5bde6'; mauve = '#c6a0f6'; red = '#ed8796'; maroon = '#ee99a0'; peach = '#f5a97f'; yellow = '#eed49f'; green = '#a6da95'; teal = '#8bd5ca'; sky = '#91d7e3'; sapphire = '#7dc4e4'; blue = '#8aadf4'; lavender = '#b7bdf8'; text = '#cad3f5'; subtext1 = '#b8c0e0'; subtext0 = '#a5adcb'; overlay2 = '#939ab7'; overlay1 = '#8087a2'; overlay0 = '#6e738d'; surface2 = '#5b6078'; surface1 = '#494d64'; surface0 = '#363a4f'; base = '#24273a'; mantle = '#1e2030'; crust = '#181926' }
    frappe    = @{ rosewater = '#f2d5cf'; flamingo = '#eebebe'; pink = '#f4b8e4'; mauve = '#ca9ee6'; red = '#e78284'; maroon = '#ea999c'; peach = '#ef9f76'; yellow = '#e5c890'; green = '#a6d189'; teal = '#81c8be'; sky = '#99d1db'; sapphire = '#85c1dc'; blue = '#8caaee'; lavender = '#babbf1'; text = '#c6d0f5'; subtext1 = '#b5bfe2'; subtext0 = '#a5adce'; overlay2 = '#949cbb'; overlay1 = '#838ba7'; overlay0 = '#737994'; surface2 = '#626880'; surface1 = '#51576d'; surface0 = '#414559'; base = '#303446'; mantle = '#292c3c'; crust = '#232634' }
    latte     = @{ rosewater = '#dc8a78'; flamingo = '#dd7878'; pink = '#ea76cb'; mauve = '#8839ef'; red = '#d20f39'; maroon = '#e64553'; peach = '#fe640b'; yellow = '#df8e1d'; green = '#40a02b'; teal = '#179299'; sky = '#04a5e5'; sapphire = '#209fb5'; blue = '#1e66f5'; lavender = '#7287fd'; text = '#4c4f69'; subtext1 = '#5c5f77'; subtext0 = '#6c6f85'; overlay2 = '#7c7f93'; overlay1 = '#8c8fa1'; overlay0 = '#9ca0b0'; surface2 = '#acb0be'; surface1 = '#bcc0cc'; surface0 = '#ccd0da'; base = '#eff1f5'; mantle = '#e6e9ef'; crust = '#dce0e8' }
}
```

- [ ] **Step 4: Write the generator** — `build/New-DFCatppuccinThemes.ps1`:

```powershell
#Requires -Version 7.2
<#
.SYNOPSIS
    Writes the catppuccin theme files for skim, peco, gum and television from build/catppuccin-palette.psd1.
.DESCRIPTION
    One map per tool (the tool's color key -> a palette color), four flavors each.
    Run it after changing a map or the palette; tests/CatppuccinThemes.Tests.ps1
    fails when the files in Tools are stale.
.PARAMETER OutputRoot
    The Tools folder to write into.
#>
param([string]$OutputRoot = (Join-Path $PSScriptRoot '..' 'Tools'))

$palette = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'catppuccin-palette.psd1')
$license = Join-Path $PSScriptRoot '..' 'Tools' 'ov' 'LICENSE-catppuccin'

# skim's --color elements (not fzf's names), modeled on DotForge's fzf mocha theme.
$skimMap = [ordered]@{ fg = 'text'; bg = 'base'; matched = 'red'; current = 'text'; current_bg = 'surface0'; current_match = 'red'; spinner = 'rosewater'; info = 'mauve'; prompt = 'mauve'; cursor = 'rosewater'; selected = 'rosewater'; header = 'red'; border = 'overlay0' }
$gumMap = [ordered]@{
    GUM_CHOOSE_CURSOR_FOREGROUND = 'pink'; GUM_CHOOSE_SELECTED_FOREGROUND = 'mauve'; GUM_CHOOSE_HEADER_FOREGROUND = 'overlay1'; GUM_CHOOSE_ITEM_FOREGROUND = 'text'
    GUM_FILTER_INDICATOR_FOREGROUND = 'pink'; GUM_FILTER_MATCH_FOREGROUND = 'red'; GUM_FILTER_PROMPT_FOREGROUND = 'mauve'; GUM_FILTER_HEADER_FOREGROUND = 'overlay1'
    GUM_FILTER_TEXT_FOREGROUND = 'text'; GUM_FILTER_PLACEHOLDER_FOREGROUND = 'overlay0'; GUM_FILTER_SELECTED_PREFIX_FOREGROUND = 'green'; GUM_FILTER_UNSELECTED_PREFIX_FOREGROUND = 'overlay0'
    GUM_INPUT_PROMPT_FOREGROUND = 'mauve'; GUM_INPUT_CURSOR_FOREGROUND = 'rosewater'; GUM_INPUT_HEADER_FOREGROUND = 'overlay1'; GUM_INPUT_PLACEHOLDER_FOREGROUND = 'overlay0'
    GUM_CONFIRM_PROMPT_FOREGROUND = 'mauve'; GUM_CONFIRM_SELECTED_FOREGROUND = 'base'; GUM_CONFIRM_SELECTED_BACKGROUND = 'mauve'; GUM_CONFIRM_UNSELECTED_FOREGROUND = 'text'; GUM_CONFIRM_UNSELECTED_BACKGROUND = 'surface0'
    GUM_SPIN_SPINNER_FOREGROUND = 'pink'; GUM_SPIN_TITLE_FOREGROUND = 'text'
}
# television's theme keys, as in tv's own themes/catppuccin.toml (mocha).
$tvMap = [ordered]@{
    background = 'base'; border_fg = 'overlay0'; text_fg = 'text'; dimmed_text_fg = 'overlay0'
    input_text_fg = 'red'; result_count_fg = 'red'
    result_name_fg = 'blue'; result_line_number_fg = 'yellow'; result_value_fg = 'lavender'; selection_fg = 'green'; selection_bg = 'surface0'; match_fg = 'red'
    preview_title_fg = 'peach'
    channel_mode_fg = 'base'; channel_mode_bg = 'pink'; remote_control_mode_fg = 'base'; remote_control_mode_bg = 'green'; action_picker_mode_fg = 'base'; action_picker_mode_bg = 'blue'
}

function Write-DFThemeFile([string]$Path, [string]$Text) {
    New-Item -ItemType Directory -Force (Split-Path $Path) | Out-Null
    [System.IO.File]::WriteAllText($Path, ($Text -replace "`r`n", "`n").TrimEnd() + "`n")
}

function Select-DFColor([System.Collections.Specialized.OrderedDictionary]$Map, [hashtable]$Colors) {
    $picked = [ordered]@{}
    foreach ($key in $Map.Keys) { $picked[$key] = $Colors[$Map[$key]] }
    $picked
}

foreach ($flavor in 'mocha', 'macchiato', 'frappe', 'latte') {
    $c = $palette[$flavor]
    $name = "catppuccin-$flavor"
    Write-DFThemeFile (Join-Path $OutputRoot 'skim' "$name.json") ([ordered]@{ name = $name; colors = (Select-DFColor $skimMap $c) } | ConvertTo-Json -Depth 5)
    Write-DFThemeFile (Join-Path $OutputRoot 'gum' "$name.json") ([ordered]@{ name = $name; env = (Select-DFColor $gumMap $c) } | ConvertTo-Json -Depth 5)
    $style = [ordered]@{
        Basic = @($c.text); SavedSelection = @('bold', $c.rosewater); Selected = @($c.text, "on_$($c.surface0)")
        Query = @($c.text); Matched = @($c.red); Prompt = @($c.mauve)
    }
    Write-DFThemeFile (Join-Path $OutputRoot 'peco' "$name.json") ([ordered]@{ Style = $style; Layout = 'top-down' } | ConvertTo-Json -Depth 5)
    $toml = @("# Catppuccin $flavor for television, generated by build/New-DFCatppuccinThemes.ps1.") +
        @(foreach ($key in $tvMap.Keys) { "$key = '$($c[$tvMap[$key]])'" })
    Write-DFThemeFile (Join-Path $OutputRoot 'television' $name 'theme.toml') ($toml -join "`n")
    Write-DFThemeFile (Join-Path $OutputRoot 'television' $name 'config.toml') (
        "# Seeded by DotForge once; television's own defaults fill in everything else.`n[ui]`ntheme = `"$name`"")
}
foreach ($tool in 'skim', 'peco', 'gum', 'television') {
    Copy-Item -LiteralPath $license -Destination (Join-Path $OutputRoot $tool 'LICENSE-catppuccin') -Force
}
```

- [ ] **Step 5: Generate and run the test**

Run: `pwsh -NoProfile -File ./build/New-DFCatppuccinThemes.ps1; pwsh -NoProfile -Command "./build/Test-DFFull.ps1 -Path tests/CatppuccinThemes.Tests.ps1"`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add build/catppuccin-palette.psd1 build/New-DFCatppuccinThemes.ps1 Tools/skim Tools/peco Tools/gum Tools/television tests/CatppuccinThemes.Tests.ps1
git commit -m "build: catppuccin theme files for skim, peco, gum and television from one palette"
```

---

### Task 5: skim

**Files:**
- Create: `Private/ConvertTo-DFColorOption.ps1`, `Tools/skim.json`, `Tools/skim.ps1`
- Modify: `Tools/fzf.ps1` (use the shared helper), `Private/DFSessionConfig.ps1` (`SkimTheme`)
- Test: `tests/skim.Tests.ps1`

**Interfaces:**
- Consumes: Task 4's `Tools/skim/catppuccin-<flavor>.json`; `Register-DFFuzzyKeyHandler`.
- Produces: `ConvertTo-DFColorOption -Path <string> -Tool <string>` → `'--color=k:v,...'` or `$null`; global `Invoke-DFApplySkimTheme -Name [-Implicit]`.

- [ ] **Step 1: Write the failing tests**

`tests/skim.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    $script:Tools = Join-Path $PSScriptRoot '..' 'Tools'
}

Describe 'ConvertTo-DFColorOption' {
    It 'joins valid colors and skips an entry that could inject an option' {
        $file = Join-Path $TestDrive 't.json'
        '{ "colors": { "bg": "#1e1e2e", "matched": "red:bold", "bad": "x --bind=execute(calc)" } }' | Set-Content $file
        ConvertTo-DFColorOption -Path $file -Tool skim 3>$null | Should -Be '--color=bg:#1e1e2e,matched:red:bold'
    }
}

Describe 'skim tool' {
    BeforeEach {
        Reset-DFTestSession; Set-DFTestXdg
        $script:Saved = @{ O = $Env:SKIM_DEFAULT_OPTIONS; C = $Env:SKIM_DEFAULT_COMMAND }
        Remove-Item Env:SKIM_DEFAULT_OPTIONS, Env:SKIM_DEFAULT_COMMAND -ErrorAction Ignore
        Mock Test-DFExecutableOnPath { $true }
        Mock Get-DFCachedCommandOutput { '' }
    }
    AfterEach {
        $Env:SKIM_DEFAULT_OPTIONS = $script:Saved.O; $Env:SKIM_DEFAULT_COMMAND = $script:Saved.C
        Set-DFTestConfig $null
        Remove-DFTestGlobal -Function 'Invoke-DFApplySkimTheme'
        Restore-DFTestXdg
    }
    It 'gets fzf''s layout defaults and the catppuccin-mocha colors' {
        Register-DFTool -Name skim -ToolsPath $script:Tools
        $Env:SKIM_DEFAULT_OPTIONS | Should -Match '--layout=reverse'
        $Env:SKIM_DEFAULT_OPTIONS | Should -Match 'current_bg:#313244'
        $Env:SKIM_DEFAULT_COMMAND | Should -Match '^fd '
    }
    It 'follows Theme' {
        Set-DFTestConfig @{ Theme = 'catppuccin-latte' }
        Register-DFTool -Name skim -ToolsPath $script:Tools
        $Env:SKIM_DEFAULT_OPTIONS | Should -Match 'bg:#eff1f5'
    }
    It 'joins the picker role below fzf, setting Picker to sk' {
        $db = Import-DFToolDb -ToolsPath $script:Tools -Name skim, fzf
        $db['skim'].roles.picker.env.Picker | Should -Be 'sk'
        $db['skim'].roles.picker.priority | Should -BeLessThan $db['fzf'].roles.picker.priority
    }
}

Describe 'skim key hooks' {
    BeforeEach {
        $script:SavedOpts = $Env:SKIM_DEFAULT_OPTIONS
        Mock Register-DFFuzzyKeyHandler { }
        Mock Get-DFCachedCommandOutput { '' }
        Mock Get-DFToolTheme { [pscustomobject]@{ Native = 'catppuccin-mocha'; Explicit = $false } }
        $DFCurrentTool = [pscustomobject]@{ name = 'skim' }
        . (Join-Path $script:Tools 'skim.ps1')
    }
    AfterEach { $Env:SKIM_DEFAULT_OPTIONS = $script:SavedOpts; Remove-DFTestGlobal -Function 'Invoke-DFApplySkimTheme' }
    It 'binds History and Path with sk' {
        Initialize-DFRoleHistorySearch -Tool ([pscustomobject]@{ name = 'skim' }) -Role 'history-search'
        Initialize-DFRolePathInsert -Tool ([pscustomobject]@{ name = 'skim' }) -Role 'path-insert'
        Should -Invoke Register-DFFuzzyKeyHandler -Times 1 -ParameterFilter { $Engine -eq 'sk' -and $Key -eq 'History' }
        Should -Invoke Register-DFFuzzyKeyHandler -Times 1 -ParameterFilter { $Engine -eq 'sk' -and $Key -eq 'Path' }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pwsh -NoProfile -Command "./build/Test-DFFull.ps1 -Path tests/skim.Tests.ps1"`
Expected: FAIL (`ConvertTo-DFColorOption` not recognized; no skim record).

- [ ] **Step 3: Extract the color helper** — `Private/ConvertTo-DFColorOption.ps1`:

```powershell
#Requires -Version 7.2

function ConvertTo-DFColorOption {
    <#
    .SYNOPSIS
        Builds a --color=name:value,... option from a theme file's "colors" object, skipping invalid entries.
    .DESCRIPTION
        fzf and skim share this grammar. The option becomes a raw token in
        FZF_DEFAULT_OPTS / SKIM_DEFAULT_OPTIONS, which the tool splits into
        options, so only the documented color grammar is accepted (hex, -1,
        0-255, default, or a color name, each optionally followed by :bold and
        similar); anything else is skipped with a warning, so a theme file can't
        inject an option such as --bind=execute(...).
    .PARAMETER Path
        The theme file.
    .PARAMETER Tool
        The tool name, for the warning.
    .OUTPUTS
        System.String, or $null when the file has no valid colors.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Tool)
    $theme = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $colors = $theme.PSObject.Properties['colors']?.Value
    if (-not $colors) { return $null }
    $validKey   = '^[A-Za-z][A-Za-z0-9_-]*\+?$'
    $validValue = '^(#[0-9A-Fa-f]{3,8}|-1|[0-9]{1,3}|default|[A-Za-z]+(:(bold|underline|reverse|italic|dim|strikethrough))*)$'
    $pairs = @(foreach ($entry in $colors.PSObject.Properties) {
        if ($entry.Name -cmatch $validKey -and [string]$entry.Value -cmatch $validValue) {
            "$($entry.Name):$($entry.Value)"
        } else {
            Write-Warning "DotForge: invalid $Tool color entry '$($entry.Name)':'$($entry.Value)' — skipping"
        }
    })
    if ($pairs.Count -eq 0) { return $null }
    '--color=' + ($pairs -join ',')
}
```

In `Tools/fzf.ps1`: add `$_colorOption = ${function:ConvertTo-DFColorOption}` next to the other captures, and replace everything from `$theme = Get-Content $path -Raw | ConvertFrom-Json` through `$colorArg = '--color=' + ($pairs -join ',')` with:

```powershell
    $colorArg = & $_colorOption -Path $path -Tool 'fzf'
    if (-not $colorArg) { return }
```

(Move the injection comment into the helper; the help text of `Invoke-DFApplyFzfTheme` stays.)

- [ ] **Step 4: Add the tool** — `Tools/skim.json`:

```json
{
  "name": "skim",
  "description": "Fuzzy finder in Rust that takes fzf's options",
  "tags": ["fuzzy", "picker", "search"],
  "executable": "sk.exe",
  "roles": {
    "picker": { "priority": 5, "env": { "Picker": "sk" } },
    "history-search": { "priority": 5 },
    "path-insert": { "priority": 5 },
    "fuzzy-finder": {}
  },
  "packages": { "scoop": "skim", "winget": "skim-rs.skim", "crates": "skim" },
  "xdg": { "compliance": "none", "method": "default" },
  "env": {
    "SKIM_DEFAULT_COMMAND": "fd --type f --strip-cwd-prefix --hidden --follow --exclude .git",
    "SKIM_DEFAULT_OPTIONS": "--layout=reverse\n--inline-info\n--height=40%\n--border"
  },
  "theme": { "key": "SkimTheme", "default": "catppuccin-mocha", "command": "Invoke-DFApplySkimTheme" },
  "aliases": {},
  "picker": null
}
```

`Tools/skim.ps1`:

```powershell
# Companion for skim (sk) — applies its color theme, loads its PowerShell
# completions, and binds Ctrl+R / Ctrl+T through the shared handler when skim
# wins history-search / path-insert (PSFzf, television and fzf outrank it).
# skim reads SKIM_DEFAULT_OPTIONS like fzf's FZF_DEFAULT_OPTS (verified with sk
# 5.7.4; not in its README, see docs/external-dependencies.md).
#
# Theme: the theme block in Tools/skim.json (Get-DFToolTheme).
# Theme files: $XDG_CONFIG_HOME\skim\themes\<name>.json, else bundled Tools\skim\.
# Sets: SKIM_DEFAULT_OPTIONS. Writes no files.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingInvokeExpression', '')]
param()

$_bundledDir = Join-Path $PSScriptRoot 'skim'
# Private helpers can't be called by name from a function:global: closure; captured scriptblocks can.
$_resolveThemeFile = ${function:Resolve-DFThemeFile}
$_colorOption = ${function:ConvertTo-DFColorOption}
$_setEnv = ${function:Set-DFEnv}

Set-Item -Path 'function:global:Invoke-DFApplySkimTheme' -Value ({
    <#
    .SYNOPSIS
        Applies a skim color theme to this session by appending a --color option to SKIM_DEFAULT_OPTIONS.
    .DESCRIPTION
        Resolves -Name to a theme file: an absolute path is used as is,
        otherwise $XDG_CONFIG_HOME\skim\themes\<Name>.json, then DotForge's
        bundled Tools\skim\<Name>.json. The file's "colors" object of skim
        color elements (fg, bg, matched, current, current_bg, ...) becomes one
        --color=name:value,... option appended to $Env:SKIM_DEFAULT_OPTIONS.
        skim merges repeated --color options in order, so the last theme
        applied wins. Invalid entries are skipped with a warning; an unknown
        theme name warns and changes nothing.
    .PARAMETER Name
        A theme name (e.g. catppuccin-mocha) or the full path to a theme JSON file.
    .PARAMETER Implicit
        Used by the companion at startup when the theme came from Theme or the
        default: a SKIM_DEFAULT_OPTIONS you set outside DotForge is then kept as
        is. Without it, the colors are appended to it.
    .EXAMPLE
        Invoke-DFApplySkimTheme -Name catppuccin-latte

        Switches skim to the bundled Catppuccin Latte colors for this session.
    .OUTPUTS
        None. Changes $Env:SKIM_DEFAULT_OPTIONS for the current session.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/tools.md
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [switch]$Implicit)
    $path = & $_resolveThemeFile -Tool 'skim' -Name $Name -BundledDir $_bundledDir
    if (-not $path) { Write-Warning "DotForge: skim theme '$Name' not found"; return }
    $colorArg = & $_colorOption -Path $path -Tool 'skim'
    if (-not $colorArg) { return }
    $existing = [string]$Env:SKIM_DEFAULT_OPTIONS
    $value = if ($existing) { "$existing`n$colorArg" } else { $colorArg }
    $explicit = if (-not $Implicit) { "skim theme '$Name' was applied" }
    & $_setEnv -Name 'SKIM_DEFAULT_OPTIONS' -Value $value -Tool 'skim' -ExplicitReason $explicit
}.GetNewClosure())

$_theme = Get-DFToolTheme -Tool $DFCurrentTool
Invoke-DFApplySkimTheme -Name $_theme.Native -Implicit:(-not $_theme.Explicit)

# skim's own -Native completer, cached against its binary (verified byte-identical across runs).
$_completions = Get-DFCachedCommandOutput -Name 'skim-completions' -Executable 'sk' -Generate {
    sk --shell power-shell | Out-String
}
if ($_completions) { Invoke-Expression $_completions }

function Initialize-DFRoleHistorySearch {
    param($Tool, $Role)
    Register-DFFuzzyKeyHandler -Engine 'sk' -Key History -Tool $Tool.name
}

function Initialize-DFRolePathInsert {
    param($Tool, $Role)
    Register-DFFuzzyKeyHandler -Engine 'sk' -Key Path -Tool $Tool.name
}
```

`Private/DFSessionConfig.ps1`: add `SkimTheme = 'skim theme'` after `OvTheme`.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `pwsh -NoProfile -Command "./build/Test-DFFull.ps1 -Path tests/skim.Tests.ps1, tests/fzf.Tests.ps1, tests/Roles.Contract.Tests.ps1, tests/DFSessionConfig.Tests.ps1, tests/Docs.Help.Tests.ps1, tests/ToolNative.Coverage.Tests.ps1"`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
./build/Build-DFCoreBundle.ps1; ./build/Build-DFToolRegistry.ps1
git add Private/ConvertTo-DFColorOption.ps1 Private/DFSessionConfig.ps1 Tools/fzf.ps1 Tools/skim.json Tools/skim.ps1 Bundle/DotForge.Core.ps1 data/tool-registry.json tests/skim.Tests.ps1
git commit -m "feat: skim, a picker engine with Ctrl+R/Ctrl+T and catppuccin colors"
```

---

### Task 6: television

**Files:**
- Create: `Tools/television.json`, `Tools/television.ps1`, `Tools/television.setup.ps1`
- Modify: `Private/DFSessionConfig.ps1` (`TelevisionTheme`), `docs/external-dependencies.md`
- Test: `tests/television.Tests.ps1`

**Interfaces:**
- Consumes: Task 1 (`setup.notes`, `{theme}` seeds, `Add-DFToolSetupNote`); Task 2 (`Set-DFRoleKeyHandler`, `Remove-DFKeyHandlerCall`); Task 4 (`Tools/television/catppuccin-<flavor>/`).
- Produces: dynamic module `DotForge.Television` (tv's functions, global).

- [ ] **Step 1: Write the failing tests**

`tests/television.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    $script:Tools = Join-Path $PSScriptRoot '..' 'Tools'
    # A stripped tv init script (Remove-DFKeyHandlerCall has run on it).
    $script:Init = @'
function Invoke-TvSmartAutocomplete { 'auto' }
function Invoke-TvShellHistory { 'history' }
'@
}

Describe 'television companion' {
    BeforeEach {
        Mock Set-DFRoleKeyHandler { & $Bind }
        Mock Set-PSReadLineKeyHandler { }
    }
    AfterEach { Remove-Module DotForge.Television -ErrorAction Ignore }

    It 'loads tv''s functions without its key bindings and binds Ctrl+r from the hook' {
        Mock Get-DFCachedCommandOutput { $script:Init }
        . (Join-Path $script:Tools 'television.ps1')
        Get-Command Invoke-TvShellHistory -ErrorAction Ignore | Should -Not -BeNullOrEmpty
        Should -Invoke Set-PSReadLineKeyHandler -Times 0
        Initialize-DFRoleHistorySearch -Tool ([pscustomobject]@{ name = 'television' }) -Role 'history-search'
        Should -Invoke Set-PSReadLineKeyHandler -Times 1 -ParameterFilter { $Chord -eq 'Ctrl+r' }
    }
    It 'leaves Ctrl+t unbound, with a note, when tv no longer defines its function' {
        Reset-DFTestSession
        Mock Get-DFCachedCommandOutput { 'function Invoke-TvShellHistory { }' }
        . (Join-Path $script:Tools 'television.ps1')
        Initialize-DFRolePathInsert -Tool ([pscustomobject]@{ name = 'television' }) -Role 'path-insert'
        Should -Invoke Set-PSReadLineKeyHandler -Times 0
        Get-DFToolNote -Tool television | Should -Match 'Invoke-TvSmartAutocomplete'
    }
    It 'loads nothing, with a note, when tv''s script couldn''t be read' {
        Reset-DFTestSession
        Mock Get-DFCachedCommandOutput { $null }
        $DFCurrentTool = [pscustomobject]@{ name = 'television' }
        . (Join-Path $script:Tools 'television.ps1')
        Get-Module DotForge.Television | Should -BeNullOrEmpty
        Get-DFToolNote -Tool television | Should -Match 'integration'
    }
}

Describe 'television setup' {
    BeforeEach {
        Set-DFTestXdg; Reset-DFTestSession; Set-DFTestConfig $null
        Mock Test-DFToolAvailable { $true }
        Mock Write-DFConflictNotice { }
        Mock Get-DFCachedCommandOutput { '' }
        Mock Write-Host { }
        $global:DFTestTvExit = 0
        $global:DFTestTvCalls = @()
        function global:tv { $global:DFTestTvCalls += ,@($args); $global:LASTEXITCODE = $global:DFTestTvExit }
        $script:Config = Join-Path $Env:XDG_CONFIG_HOME 'television' 'config.toml'
    }
    AfterEach {
        Remove-DFTestGlobal -Function 'tv'
        Remove-Variable -Scope Global -Name DFTestTvExit, DFTestTvCalls -ErrorAction Ignore
        Remove-Module DotForge.Television -ErrorAction Ignore
        Restore-DFTestXdg; Set-DFTestConfig $null
    }

    It 'seeds the config with the theme, the four theme files, and downloads the channels once' {
        Start-DFSession -Config @{ Tools = @('television') } -ToolsPath $script:Tools 3>$null
        Get-Content $script:Config -Raw | Should -Match 'theme = "catppuccin-mocha"'
        @(Get-ChildItem (Join-Path $Env:XDG_CONFIG_HOME 'television' 'themes') -Filter 'catppuccin-*.toml').Count | Should -Be 4
        @($global:DFTestTvCalls | Where-Object { $_ -contains 'update-channels' }).Count | Should -Be 1
        @((Get-DFToolSetupState).television.notes) | Should -BeNullOrEmpty
        $Env:TELEVISION_CONFIG | Should -Be (Join-Path $Env:XDG_CONFIG_HOME 'television')
    }
    It 'follows Theme in the seeded config' {
        Start-DFSession -Config @{ Tools = @('television'); Theme = 'catppuccin-latte' } -ToolsPath $script:Tools 3>$null
        Get-Content $script:Config -Raw | Should -Match 'theme = "catppuccin-latte"'
    }
    It 'keeps an existing config and leaves a note about ui.theme' {
        New-Item -ItemType Directory (Split-Path $script:Config) -Force | Out-Null
        Set-Content $script:Config 'mine' -NoNewline
        Start-DFSession -Config @{ Tools = @('television') } -ToolsPath $script:Tools 3>$null
        Get-Content $script:Config -Raw | Should -Be 'mine'
        "$((Get-DFToolSetupState).television.notes)" | Should -Match 'ui\.theme'
    }
    It 'still completes when the download fails, with a note to run it by hand' {
        $global:DFTestTvExit = 1
        Start-DFSession -Config @{ Tools = @('television') } -ToolsPath $script:Tools 3>$null
        (Get-DFToolSetupState).PSObject.Properties['television'] | Should -Not -BeNullOrEmpty
        "$((Get-DFToolSetupState).television.notes)" | Should -Match 'tv update-channels'
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pwsh -NoProfile -Command "./build/Test-DFFull.ps1 -Path tests/television.Tests.ps1"`
Expected: FAIL (no television record or companion).

- [ ] **Step 3: Add the tool** — `Tools/television.json`:

```json
{
  "name": "television",
  "description": "Fast, hackable fuzzy finder with channels for files, git, env and more",
  "tags": ["fuzzy", "picker", "search"],
  "executable": "tv.exe",
  "roles": { "history-search": { "priority": 20 }, "path-insert": { "priority": 20 }, "fuzzy-finder": {} },
  "packages": {
    "scoop": { "id": "television", "feed": { "name": "extras", "url": "https://github.com/ScoopInstaller/Extras" } },
    "winget": "alexpasmantier.television",
    "crates": "television"
  },
  "xdg": {
    "compliance": "full",
    "method": "env",
    "vars": { "TELEVISION_CONFIG": "${XDG_CONFIG_HOME}/television" },
    "native": {
      "TELEVISION_CONFIG": [],
      "${XDG_CONFIG_HOME}/television/config.toml": ["${LOCALAPPDATA}/television/config/config.toml"]
    }
  },
  "theme": { "key": "TelevisionTheme", "default": "catppuccin-mocha", "files": "television" },
  "setup": {
    "seed": {
      "${XDG_CONFIG_HOME}/television/config.toml": "{theme}/config.toml",
      "${XDG_CONFIG_HOME}/television/themes/catppuccin-mocha.toml": "television/catppuccin-mocha/theme.toml",
      "${XDG_CONFIG_HOME}/television/themes/catppuccin-macchiato.toml": "television/catppuccin-macchiato/theme.toml",
      "${XDG_CONFIG_HOME}/television/themes/catppuccin-frappe.toml": "television/catppuccin-frappe/theme.toml",
      "${XDG_CONFIG_HOME}/television/themes/catppuccin-latte.toml": "television/catppuccin-latte/theme.toml"
    },
    "notes": [
      {
        "text": "your television config.toml predates DotForge; set ui.theme = \"catppuccin-mocha\" (or catppuccin-macchiato, -frappe, -latte) in it to use the DotForge theme.",
        "ifFile": "${XDG_CONFIG_HOME}/television/config.toml"
      }
    ]
  },
  "aliases": {},
  "picker": null
}
```

`Tools/television.ps1`:

```powershell
# Companion for television (tv) — loads tv's PowerShell integration (its
# completer and its history / smart-autocomplete functions) without tv's own key
# bindings, then binds Ctrl+R / Ctrl+T when television wins history-search /
# path-insert. tv init power-shell ends by binding both keys itself; DotForge
# removes those calls so only role winners bind keys, and loads the rest as the
# module DotForge.Television so its functions outlive this companion. tv's
# function names are an undocumented dependency (docs/external-dependencies.md):
# if one disappears, its key stays unbound and the status says so.
# Theme and config: one-time setup (Tools/television.json, Tools/television.setup.ps1).

$_init = Get-DFCachedCommandOutput -Name 'television-init' -Executable 'tv' -Generate {
    Remove-DFKeyHandlerCall -Script (tv init power-shell | Out-String)
}
if ($_init) {
    New-Module -Name 'DotForge.Television' -ScriptBlock ([scriptblock]::Create($_init)) | Import-Module -Global -Force
} else {
    Add-DFToolNote -Tool 'television' -Note "couldn't load tv's PowerShell integration (tv init power-shell); Ctrl+R/Ctrl+T aren't bound to tv"
}

function Initialize-DFRoleHistorySearch {
    param($Tool, $Role)
    if (-not (Get-Command -Name Invoke-TvShellHistory -ErrorAction Ignore)) {
        Add-DFToolNote -Tool $Tool.name -Note "tv no longer defines Invoke-TvShellHistory, so Ctrl+R isn't bound"
        return
    }
    Set-DFRoleKeyHandler -Role $Role -Chord 'Ctrl+r' -Tool $Tool.name -Bind {
        Set-PSReadLineKeyHandler -Chord 'Ctrl+r' -BriefDescription 'DotForge history-search (tv)' -Description 'Search history with television (DotForge)' -ScriptBlock { Invoke-TvShellHistory }
    }
}

function Initialize-DFRolePathInsert {
    param($Tool, $Role)
    if (-not (Get-Command -Name Invoke-TvSmartAutocomplete -ErrorAction Ignore)) {
        Add-DFToolNote -Tool $Tool.name -Note "tv no longer defines Invoke-TvSmartAutocomplete, so Ctrl+T isn't bound"
        return
    }
    Set-DFRoleKeyHandler -Role $Role -Chord 'Ctrl+t' -Tool $Tool.name -Bind {
        Set-PSReadLineKeyHandler -Chord 'Ctrl+t' -BriefDescription 'DotForge path-insert (tv)' -Description 'Smart autocomplete with television (DotForge)' -ScriptBlock { Invoke-TvSmartAutocomplete }
    }
}
```

`Tools/television.setup.ps1`:

```powershell
# One-time setup for television: download tv's channels once (tv update-channels)
# into $TELEVISION_CONFIG\cable, so its channels (files, git, env, ...) exist.
# The seeds (config.toml when absent, the four catppuccin themes) and the note
# for an existing config.toml are declared in Tools/television.json and run
# before this. A failed download doesn't fail setup: it leaves a note instead,
# so an offline start doesn't retry it every time. To run it again yourself:
# tv update-channels. To skip: SkipSetup = @('television').
Write-Host 'DotForge: downloading television channels (once)…'
$_ok = $false
try {
    tv update-channels *> $null
    $_ok = $LASTEXITCODE -eq 0
} catch {
    $_ok = $false
}
if (-not $_ok) { Add-DFToolSetupNote -Name 'television' -Text "couldn't download television's channels; run 'tv update-channels' to get them." }
Complete-DFToolSetup -Name 'television' -Actions @(@{ type = 'updateChannels'; ok = $_ok })
```

`Private/DFSessionConfig.ps1`: add `TelevisionTheme = 'television theme (seeded into its config.toml once; edit ui.theme there to change it)'`.

`docs/external-dependencies.md`: add a numbered section after the last one (### 18):

```markdown
### 18. television: `tv init power-shell` function names, `TELEVISION_CONFIG`, partial config

| | |
|---|---|
| **What** | `tv init power-shell` (tv 0.15.9) prints tv's completer, the functions `Invoke-TvShellHistory` and `Invoke-TvSmartAutocomplete`, then two `Set-PSReadLineKeyHandler` calls binding Ctrl+R and Ctrl+T. tv honors `TELEVISION_CONFIG`, writes a full default `config.toml` on its first run when none exists, and accepts a partial `config.toml` (its defaults fill the rest). `tv update-channels` downloads its channels into `<config>\cable`. |
| **Where** | `Tools/television.ps1`, `Tools/television.setup.ps1`, `Tools/television.json` |
| **Why** | Only the winners of history-search and path-insert may bind those keys, so DotForge removes tv's two binding calls (`Remove-DFKeyHandlerCall`) and binds tv's functions from the role hooks. The seeded `config.toml` holds only `ui.theme`. |
| **If it changes** | A renamed function leaves its key unbound with a status note; a script that no longer parses loads nothing, with a note. A tv that stops honoring `TELEVISION_CONFIG` falls back to `XDG_CONFIG_HOME\television`, the same folder. |
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pwsh -NoProfile -Command "./build/Test-DFFull.ps1 -Path tests/television.Tests.ps1, tests/Roles.Contract.Tests.ps1, tests/ToolNative.Coverage.Tests.ps1, tests/ToolNative.Schema.Tests.ps1, tests/DFSessionConfig.Tests.ps1, tests/Docs.Help.Tests.ps1"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
./build/Build-DFToolRegistry.ps1
git add Tools/television.json Tools/television.ps1 Tools/television.setup.ps1 Private/DFSessionConfig.ps1 docs/external-dependencies.md data/tool-registry.json tests/television.Tests.ps1
git commit -m "feat: television, with its channels, a catppuccin theme and Ctrl+R/Ctrl+T"
```

(`Private/DFSessionConfig.ps1` changed: run `./build/Build-DFCoreBundle.ps1` and add `Bundle/DotForge.Core.ps1` too.)

---

### Task 7: peco

**Files:**
- Create: `Tools/peco.json`, `Tools/carapace/specs/peco.yaml`
- Modify: `Private/DFSessionConfig.ps1` (`PecoTheme`), `docs/external-dependencies.md` (hand-authored specs row)
- Test: `tests/peco.Tests.ps1`

**Interfaces:**
- Consumes: Task 1 (`{theme}` seed), Task 4 (`Tools/peco/catppuccin-<flavor>.json`).

- [ ] **Step 1: Write the failing tests**

`tests/peco.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    $script:Tools = Join-Path $PSScriptRoot '..' 'Tools'
}

Describe 'peco tool' {
    BeforeEach {
        Set-DFTestXdg; Reset-DFTestSession; Set-DFTestConfig $null
        Mock Test-DFToolAvailable { $true }
        Mock Write-DFConflictNotice { }
        $script:Config = Join-Path $Env:XDG_CONFIG_HOME 'peco' 'config.json'
    }
    AfterEach { Restore-DFTestXdg; Set-DFTestConfig $null }

    It 'seeds its config with the catppuccin-mocha style' {
        Start-DFSession -Config @{ Tools = @('peco') } -ToolsPath $script:Tools 3>$null
        Get-Content $script:Config -Raw | Should -Be (Get-Content (Join-Path $script:Tools 'peco' 'catppuccin-mocha.json') -Raw)
    }
    It 'follows Theme' {
        Start-DFSession -Config @{ Tools = @('peco'); Theme = 'catppuccin-frappe' } -ToolsPath $script:Tools 3>$null
        (Get-Content $script:Config -Raw | ConvertFrom-Json).Style.Matched | Should -Be @('#e78284')
    }
    It 'keeps an existing config' {
        New-Item -ItemType Directory (Split-Path $script:Config) -Force | Out-Null
        Set-Content $script:Config '{}' -NoNewline
        Start-DFSession -Config @{ Tools = @('peco') } -ToolsPath $script:Tools 3>$null
        Get-Content $script:Config -Raw | Should -Be '{}'
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pwsh -NoProfile -Command "./build/Test-DFFull.ps1 -Path tests/peco.Tests.ps1"`
Expected: FAIL (no peco record).

- [ ] **Step 3: Add the tool** — `Tools/peco.json`:

```json
{
  "name": "peco",
  "description": "Simplistic interactive filtering tool",
  "tags": ["fuzzy", "filter", "search"],
  "executable": "peco.exe",
  "roles": { "fuzzy-finder": {} },
  "packages": { "scoop": "peco", "winget": "peco.peco" },
  "xdg": {
    "compliance": "full",
    "method": "default",
    "native": { "${XDG_CONFIG_HOME}/peco/config.json": ["${HOME}/.config/peco/config.json", "${HOME}/.peco/config.json"] }
  },
  "theme": { "key": "PecoTheme", "default": "catppuccin-mocha", "files": "peco" },
  "setup": { "seed": { "${XDG_CONFIG_HOME}/peco/config.json": "{theme}" } },
  "aliases": {},
  "picker": null
}
```

`Tools/carapace/specs/peco.yaml`:

```yaml
# Carapace spec for peco.
#
# peco has no completion generator and carapace ships no peco completer. DotForge
# deploys this to $XDG_CONFIG_HOME/carapace/specs/ (Tools/carapace.ps1).
#
# Hand-authored from `peco --help` (peco 0.6.0), so it can drift from the
# installed binary; catalogued in docs/external-dependencies.md.
name: peco
description: Simplistic interactive filtering tool
flags:
  -h, --help: Show help
  --version: Print the version
  --query=: Initial value for the query
  --rcfile=: Path to the settings file
  -b, --buffer-size=: Lines to keep in the search buffer
  --null: Expect NUL as the separator for input and output
  --initial-index=: Index of the initially selected line (0 based)
  --initial-filter=: Default filter
  --prompt=: Prompt string
  --layout=: Layout
  --select-1: Select the only line and exit when the input has one
  --exit-0: Exit with status 1 when the input is empty
  --select-all: Select all lines and exit
  --on-cancel=: What a cancel returns
  --selection-prefix=: Prefix for selected lines instead of color
  --exec=: Command to run on the selection
  --print-query: Print the query as the first output line
  --color=: Color mode
  --height=: Height in lines or percent
completion:
  flag:
    layout: [top-down, bottom-up, top-down-query-bottom]
    on-cancel: [success, error]
    color: [auto, none]
    initial-filter: [IgnoreCase, CaseSensitive, SmartCase, Regexp, Fuzzy]
    rcfile: ["$files"]
```

`Private/DFSessionConfig.ps1`: add `PecoTheme = 'peco theme (seeded into its config.json once)'`.

`docs/external-dependencies.md`: in the "Hand-authored carapace specs for bw, broot, …" row, add peco to the list (alphabetical: `… moor, peco, pymanager …`).

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pwsh -NoProfile -Command "./build/Test-DFFull.ps1 -Path tests/peco.Tests.ps1, tests/CarapaceSpecs.Tests.ps1, tests/ToolNative.Coverage.Tests.ps1, tests/DFSessionConfig.Tests.ps1"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
./build/Build-DFCoreBundle.ps1; ./build/Build-DFToolRegistry.ps1
git add Tools/peco.json Tools/carapace/specs/peco.yaml Private/DFSessionConfig.ps1 docs/external-dependencies.md Bundle/DotForge.Core.ps1 data/tool-registry.json tests/peco.Tests.ps1
git commit -m "feat: peco, with a catppuccin config and a carapace spec"
```

---

### Task 8: gum and the `fuzzy` group

**Files:**
- Create: `Tools/gum.json`, `Tools/gum.ps1`
- Modify: `Private/DFSessionConfig.ps1` (`GumTheme`), `data/groups.json`
- Test: `tests/gum.Tests.ps1`

**Interfaces:**
- Consumes: Task 4 (`Tools/gum/catppuccin-<flavor>.json`).
- Produces: global `Invoke-DFApplyGumTheme -Name [-Implicit]`; group `fuzzy`.

- [ ] **Step 1: Write the failing tests**

`tests/gum.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    $script:Tools = Join-Path $PSScriptRoot '..' 'Tools'
}

Describe 'gum tool' {
    BeforeEach {
        Reset-DFTestSession; Set-DFTestXdg
        $script:Saved = @{}
        foreach ($item in Get-ChildItem Env:GUM_* -ErrorAction Ignore) { $script:Saved[$item.Name] = $item.Value; Remove-Item "Env:$($item.Name)" }
        Mock Test-DFExecutableOnPath { $true }
    }
    AfterEach {
        Get-ChildItem Env:GUM_* -ErrorAction Ignore | ForEach-Object { Remove-Item "Env:$($_.Name)" }
        foreach ($k in $script:Saved.Keys) { Set-Item "Env:$k" $script:Saved[$k] }
        Set-DFTestConfig $null
        Remove-DFTestGlobal -Function 'Invoke-DFApplyGumTheme'
        Restore-DFTestXdg
    }
    It 'sets the catppuccin-mocha colors' {
        Register-DFTool -Name gum -ToolsPath $script:Tools
        $Env:GUM_CHOOSE_CURSOR_FOREGROUND | Should -Be '#f5c2e7'
        $Env:GUM_FILTER_MATCH_FOREGROUND | Should -Be '#f38ba8'
    }
    It 'follows Theme' {
        Set-DFTestConfig @{ Theme = 'catppuccin-latte' }
        Register-DFTool -Name gum -ToolsPath $script:Tools
        $Env:GUM_CONFIRM_SELECTED_BACKGROUND | Should -Be '#8839ef'
    }
    It 'keeps a color you set yourself' {
        $Env:GUM_FILTER_MATCH_FOREGROUND = '#000000'
        Register-DFTool -Name gum -ToolsPath $script:Tools
        $Env:GUM_FILTER_MATCH_FOREGROUND | Should -Be '#000000'
    }
    It 'skips an invalid entry in a theme file you wrote' {
        Register-DFTool -Name gum -ToolsPath $script:Tools
        $file = Join-Path $TestDrive 'mine.json'
        '{ "env": { "GUM_SPIN_TITLE_FOREGROUND": "#ffffff", "PATH": "#000000", "GUM_SPIN_SPINNER_FOREGROUND": "red; calc" } }' | Set-Content $file
        Invoke-DFApplyGumTheme -Name $file 3>$null
        $Env:GUM_SPIN_TITLE_FOREGROUND | Should -Be '#ffffff'
        $Env:GUM_SPIN_SPINNER_FOREGROUND | Should -Not -Be 'red; calc'
    }
}

Describe 'fuzzy group' {
    It 'lists the five fuzzy finders' {
        $groups = Get-Content (Join-Path $PSScriptRoot '..' 'data' 'groups.json') -Raw | ConvertFrom-Json
        $groups.fuzzy.tools | Should -Be @('fzf', 'skim', 'television', 'peco', 'gum')
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pwsh -NoProfile -Command "./build/Test-DFFull.ps1 -Path tests/gum.Tests.ps1"`
Expected: FAIL (no gum record, no group).

- [ ] **Step 3: Add the tool and the group** — `Tools/gum.json`:

```json
{
  "name": "gum",
  "description": "Building blocks for shell scripts: choose, filter, input, confirm, spin",
  "tags": ["fuzzy", "scripting", "tui"],
  "executable": "gum.exe",
  "roles": { "fuzzy-finder": {} },
  "packages": { "scoop": "gum", "winget": "charmbracelet.gum" },
  "xdg": { "compliance": "none", "method": "default" },
  "theme": { "key": "GumTheme", "default": "catppuccin-mocha", "command": "Invoke-DFApplyGumTheme" },
  "aliases": {},
  "picker": null
}
```

`Tools/gum.ps1`:

```powershell
# Companion for gum — applies its color theme through gum's GUM_* variables
# (gum has no config file). Only colors: gum is a scripting toolkit, and scripts
# expect its stock behavior.
#
# Theme: the theme block in Tools/gum.json (Get-DFToolTheme).
# Theme files: $XDG_CONFIG_HOME\gum\themes\<name>.json, else bundled Tools\gum\.
# Sets: GUM_*_FOREGROUND / GUM_*_BACKGROUND. Writes no files.

$_bundledDir = Join-Path $PSScriptRoot 'gum'
# Private helpers can't be called by name from a function:global: closure; captured scriptblocks can.
$_resolveThemeFile = ${function:Resolve-DFThemeFile}
$_setEnv = ${function:Set-DFEnv}

Set-Item -Path 'function:global:Invoke-DFApplyGumTheme' -Value ({
    <#
    .SYNOPSIS
        Applies a gum color theme to this session through gum's GUM_* color variables.
    .DESCRIPTION
        Resolves -Name to a theme file: an absolute path is used as is,
        otherwise $XDG_CONFIG_HOME\gum\themes\<Name>.json, then DotForge's
        bundled Tools\gum\<Name>.json. Each entry of the file's "env" object
        (a GUM_* variable and a #rrggbb color) is set for this session; a
        variable you set outside DotForge is kept unless you call this
        yourself. Entries that aren't GUM_* variables with a hex color are
        skipped with a warning.
    .PARAMETER Name
        A theme name (e.g. catppuccin-mocha) or the full path to a theme JSON file.
    .PARAMETER Implicit
        Used by the companion at startup when the theme came from Theme or the
        default: a GUM_* variable you set outside DotForge is then kept as is.
    .EXAMPLE
        Invoke-DFApplyGumTheme -Name catppuccin-frappe

        Switches gum to the bundled Catppuccin Frappé colors for this session.
    .OUTPUTS
        None. Changes GUM_* environment variables for the current session.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/tools.md
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [switch]$Implicit)
    $path = & $_resolveThemeFile -Tool 'gum' -Name $Name -BundledDir $_bundledDir
    if (-not $path) { Write-Warning "DotForge: gum theme '$Name' not found"; return }
    $vars = (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).PSObject.Properties['env']?.Value
    if (-not $vars) { return }
    $explicit = if (-not $Implicit) { "gum theme '$Name' was applied" }
    foreach ($entry in $vars.PSObject.Properties) {
        if ($entry.Name -cnotmatch '^GUM_[A-Z_]+$' -or [string]$entry.Value -notmatch '^#[0-9A-Fa-f]{6}$') {
            Write-Warning "DotForge: invalid gum theme entry '$($entry.Name)':'$($entry.Value)' — skipping"
            continue
        }
        & $_setEnv -Name $entry.Name -Value ([string]$entry.Value) -Tool 'gum' -ExplicitReason $explicit
    }
}.GetNewClosure())

$_theme = Get-DFToolTheme -Tool $DFCurrentTool
Invoke-DFApplyGumTheme -Name $_theme.Native -Implicit:(-not $_theme.Explicit)
```

`Private/DFSessionConfig.ps1`: add `GumTheme = 'gum theme (GUM_* colors)'`.

`data/groups.json`: add after `core` (match the file's formatting):

```json
  "fuzzy": {
    "description": "Fuzzy finders: fzf, skim and television (which can own Ctrl+R/Ctrl+T), peco, and gum for scripts",
    "tools": ["fzf", "skim", "television", "peco", "gum"]
  },
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pwsh -NoProfile -Command "./build/Test-DFFull.ps1 -Path tests/gum.Tests.ps1, tests/Groups.Tests.ps1, tests/DFSessionConfig.Tests.ps1, tests/Docs.Help.Tests.ps1"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
./build/Build-DFCoreBundle.ps1; ./build/Build-DFToolRegistry.ps1
git add Tools/gum.json Tools/gum.ps1 Private/DFSessionConfig.ps1 data/groups.json Bundle/DotForge.Core.ps1 data/tool-registry.json tests/gum.Tests.ps1
git commit -m "feat: gum with catppuccin colors, and the +fuzzy group"
```

---

### Task 9: Docs, reference, backlog, full gate

**Files:**
- Modify: `docs/guide/tools.md`, `docs/guide/configuration.md`, `docs/guide/writing-a-tool.md`, `docs/external-dependencies.md`, `CLAUDE.md`, `CHANGELOG.md`, `TODO.md`, `docs/reference.md` (generated)

- [ ] **Step 1: User docs**

- `docs/guide/tools.md`: the PSFzf row says Ctrl+T / Ctrl+R are bound when PSFzf wins `path-insert` / `history-search` (it does by default); add rows for skim (picker engine, Ctrl+R/Ctrl+T when it wins, `SKIM_DEFAULT_OPTIONS`), television (channels downloaded once, Ctrl+R history / Ctrl+T smart autocomplete when it wins, theme in its `config.toml`), peco (seeded `config.json`), gum (colors only). Add a short "Ctrl+R and Ctrl+T" paragraph: two roles, priorities PSFzf 30, television 20, fzf 10, skim 5; pick with `Defaults = @{ 'history-search' = 'television'; 'path-insert' = 'skim' }`; a binding you made yourself before DotForge loads is kept unless Defaults names a tool.
- `docs/guide/configuration.md`: add `GumTheme`, `PecoTheme`, `SkimTheme`, `TelevisionTheme` to the per-tool theme row (alphabetical); add theme-table rows (skim: `--color` in `SKIM_DEFAULT_OPTIONS`; television: seeded once into `config.toml`, change `ui.theme` there; peco: seeded once into `config.json`; gum: `GUM_*` colors); in Defaults, list `history-search` and `path-insert`.
- `docs/guide/writing-a-tool.md`: the `setup` row becomes `{ "seed": { … }, "notes": [ { "text", "ifFile"?, "unlessFile"? } ] }`; under "Seeding a default config file" add that a source may use `{theme}` (with `theme.files`, the theme's file or folder: `"{theme}"`, `"{theme}/config.toml"`), and a paragraph "Setup notes": declared notes are evaluated before seeds (so `ifFile` on the seed's own target means "the user already had one"), a setup script adds one with `Add-DFToolSetupNote -Name <tool> -Text '…'` before `Complete-DFToolSetup`, shown once at the end of the load and kept in `Get-DFToolStatus`. In the roles section mention `history-search`/`path-insert`: bind only through `Set-DFRoleKeyHandler` (or `Register-DFFuzzyKeyHandler` for an fzf-compatible engine) from the hook.
- `docs/external-dependencies.md`: add a "Documented but load-bearing" row: skim reads `SKIM_DEFAULT_OPTIONS` (verified sk 5.7.4, not in its README) and `sk --shell power-shell` emits one `-Native` completer; if `SKIM_DEFAULT_OPTIONS` stops being read, skim runs with its defaults and no theme.
- `CLAUDE.md`, Tool JSON Schema: in the roles bullet add "`history-search`/`path-insert` bind keys only through `Set-DFRoleKeyHandler`, which keeps a user's own binding"; add a `setup` bullet: "`setup` (optional): `seed` (sources may use `{theme}`) and `notes` (shown once at the end of the load, kept in `Get-DFToolStatus`; `Add-DFToolSetupNote` from a setup script)."
- Every new ```` ```powershell ```` block that runs real tools gets `<!-- requires: … -->`, and any that changes state outside the sandbox gets `<!-- system -->`.

- [ ] **Step 2: Changelog and backlog**

- `CHANGELOG.md` `[Unreleased]` → Added: skim, television, peco, gum; `history-search` (Ctrl+R) and `path-insert` (Ctrl+T) roles; setup notes; `{theme}` in seed sources; `+fuzzy` group. Changed: PSFzf binds Ctrl+R/Ctrl+T through the roles (same result by default); a Ctrl+R/Ctrl+T binding you make before DotForge loads is now kept.
- `TODO.md` T-35: change the note to "pagers done (2026-10-16: moor, ov, less, `more` fallback); fuzzy finders done (2026-10-17: skim, television, peco, gum; history-search, path-insert)"; remove "picker (skim; television needs its own adapter);" and "shell-history (atuin)," (now T-67).

- [ ] **Step 3: Regenerate and run the whole suite**

Run:
```bash
./build/Build-DFCoreBundle.ps1; ./build/Build-DFToolRegistry.ps1; ./build/Build-DFReferenceDocs.ps1
pwsh -NoProfile -Command "./build/Test-DFFull.ps1"
```
Expected: exit 0, no failed tests or containers. Fix anything red at its source.

- [ ] **Step 4: Commit**

```bash
git add -A docs CLAUDE.md CHANGELOG.md TODO.md Bundle data
git commit -m "docs: fuzzy finders and the Ctrl+R/Ctrl+T roles"
```
