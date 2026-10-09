# Slice 3: Installing Tools Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `Install-DFTool -Missing` installs everything the session reported missing, in dependency order, through package managers that are plugins. The user's choices are made up front (interactive) or taken from defaults (`-UseDefaults`).

**Architecture:**
- A manager is a tool record with an `installs` block, and a tool's `packages` are keyed by **source** (a system manager or an ecosystem registry).
- Pure functions choose a source per tool and build a staged plan. One runner executes manager commands; it is the only seam tests replace.
- `Install-DFTool` drives the choices, the plan, execution and activation.
- Pickers and catalog hints format their commands from the same `installs` blocks.

**Tech Stack:** PowerShell 7.2+, Pester 6, tool records in `Tools/*.json`.

**Spec:** `docs/superpowers/specs/2026-10-09-install-design.md` (read it first; decision numbers below refer to it). Parent: `docs/superpowers/specs/2026-10-09-tool-selection-design.md`.

## Global Constraints

- Plugin invariant: no manager or tool name in core code (`Private/`, `Public/`). Core reads `installs`, `packages`, `install.prefer`, `roles` and config only. (`docs/plugin-architecture.md`)
- No startup cost on a healthy machine: `Start-DFSession` must not read a manager record or check a manager's availability when nothing is Missing.
- Nothing unrequested is installed unless `-UseDefaults` or an interactive choice says so (decision 5).
- A third-party feed and an elevation prompt are always shown in the plan before anything runs (decisions 4, 11).
- PATH changes only through `Add-DFToPath`, appending; directories only through `New-DFDirectory`; paths through `ConvertTo-DFPath` (CLAUDE.md conventions).
- Settings are read only through `Get-DFConfig`; every new key goes in `$script:DFConfigKeys` (`Private/DFSessionConfig.ps1`); removed keys go in `$script:DFRemovedConfigKeys` with a replacement message.
- New public functions go in `DotForge.psd1` `FunctionsToExport`, with complete comment-based help (`tests/Docs.Help.Tests.ps1`).
- Tests: Pester 6 syntax only (`Should -Invoke`), load with `Get-DFTestModuleFile`, isolate XDG with `Set-DFTestXdg`/`Restore-DFTestXdg`, session with `Reset-DFTestSession`, config with `Set-DFTestConfig`. Never let a test run a real package manager: mock `Invoke-DFInstallCommand`.
- Commits are GPG-signed; never bypass. If signing times out, ask the user to run `! 'unlock' | gpg --clearsign | Out-Null`.
- Run tests from `pwsh -NoProfile`. Full-suite verification uses empty sentinel `XDG_*_HOME` folders and asserts nothing was written there. Two doc-example failures (`docs/guide/pickers-and-helpers.md:117`, `docs/guide/tools.md:30`) pre-date this slice.

## Review Focus

1. **A `packages` value that is an object (`{ id, feed }`) reaching old readers.** Catalog overlay, identity guide, reference docs and build scripts must read `.id`, not stringify the object. Task 1 adds a test per reader.
2. **A manager in the plan that is itself being installed in an earlier stage.** It must count as available for later stages, and its tools must wait. If that stage fails, they must be skipped with "skipped: <manager> failed", not attempted. Covered in Tasks 4 and 5.
3. **A non-interactive host without `-UseDefaults`** (a script or scheduled task). It must never call `Read-Host`. It installs only decision-free tools and reports gaps with their dependents. Covered in Task 6.
4. **`InstallVia` naming a source the tool doesn't have, or an unknown source.** Warn and fall through to the other layers; never throw. Covered in Task 3.
5. **Re-running `Install-DFTool -Missing` after a partial failure.** Already installed tools must not be reinstalled (availability is re-checked fresh), and feeds already present must not be re-added. Covered in Task 5 (feed list check) and Task 6 (re-run test).

---

## File Structure

| File | Responsibility |
|---|---|
| `Private/Get-DFPackageRef.ps1` (new) | `packages` value → `{ Id; Feed }` |
| `Private/DFInstallSource.ps1` (new) | `Get-DFSourceManager`, `Get-DFInstallSourceOrder`, `Resolve-DFInstallSource`: choosing a source and manager |
| `Private/New-DFInstallPlan.ps1` (new) | the install layer of the graph: stages, gaps, dependencies |
| `Private/Invoke-DFInstallCommand.ps1` (new) | **the process seam**: runs one manager command (argv or function), optionally elevated |
| `Private/Invoke-DFInstallPlan.ps1` (new) | executes a plan: feeds, batches, PATH merge, reactivate, re-check, skip dependents |
| `Private/Update-DFPathFromRegistry.ps1` (new) | appends new User/Machine PATH entries |
| `Private/Format-DFInstallCommand.ps1` (new) | a manager's install command as display text (pickers, catalog hints, plan) |
| `Private/DFInstallHost.ps1` (new) | seams: `Test-DFInteractiveHost`, `Read-DFInstallChoice`, `Test-DFElevated` |
| `Public/Install-DFTool.ps1` (rewrite) | modes, choices, plan display, run, activation, summary |
| `Public/Invoke-DFToolSetup.ps1` (new) | re-run one-time setup |
| `Private/Import-DFToolDb.ps1` | normalize `installs` and `install`; drop `scoopBucket` |
| `Private/Test-DFToolSchema.ps1` | validate `packages` values, `installs`, `install.prefer`, `after` role entries |
| `Private/DFSessionConfig.ps1` | `InstallVia`, `InstallOrder`, `ExcludeSources`; remove `PackageManagerOrder` |
| `Private/Invoke-DFSessionActivation.ps1` | `role:` in `after`; install hints on Missing status |
| `Private/Resolve-DFPackageManager.ps1`, `Private/Add-DFScoopBucket.ps1` | deleted (Task 6) |
| `Private/DFCatalog.*.ps1`, `Tools/{scoop,winget,choco}.ps1` | hints and picker commands from `installs` (Task 8) |
| `Tools/*.json`, new `Tools/{cargo,psresource,pnpm,bun,node}.json`, `data/roles.json`, `data/tool-identities.json` | data |

---

### Task 1: Source keys and package references

Rename `packages` keys to source names, fold `scoopBucket` into a feed, and make every reader go through one helper.

**Files:**
- Create: `Private/Get-DFPackageRef.ps1`, `tests/Get-DFPackageRef.Tests.ps1`
- Modify: `Tools/mdcat.json`, `Tools/mdv.json`, `Tools/posh-git.json`, `Tools/PSFzf.json`, `Tools/Terminal-Icons.json`, `Tools/ps-dotenv.json`, `data/tool-identities.json`
- Modify: `Private/Get-DFCatalogInstalled.ps1:105-111`, `Private/Get-DFToolIdentityGuide.ps1:48-51`, `build/Build-DFToolIdentities.ps1:67`, `build/Build-DFReferenceDocs.ps1:246`, `Private/Import-DFToolDb.ps1` (`scoopBucket` line 248 and help line 132), `Private/Test-DFToolSchema.ps1` (lines 76-78, 197-198)
- Modify: `Private/DFCatalog.Base.ps1` (delete `-PackageManager` and the alias loop in `ConvertTo-DFCatalogSource`), `Private/DFCatalog.Crates.ps1:145`, `Private/DFCatalog.PSGallery.ps1:115`
- Modify (temporary, replaced in Task 6): `Public/Install-DFTool.ps1` switch keys `cargo`→`crates`, `psresource`→`psgallery`, bucket from `feed`

**Interfaces:**
- Produces: `Get-DFPackageRef -Value <object>` → `[pscustomobject]@{ Id = [string]; Feed = $null | [pscustomobject]@{ name; url } }`. Returns `$null` for an empty value.

- [ ] **Step 1: Write the failing tests**

`tests/Get-DFPackageRef.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
}

Describe 'Get-DFPackageRef' {
    It 'reads a plain id' {
        $r = Get-DFPackageRef 'glow'
        $r.Id | Should -Be 'glow'
        $r.Feed | Should -BeNullOrEmpty
    }
    It 'reads an id with a feed' {
        $r = Get-DFPackageRef ('{ "id": "ps-dotenv", "feed": { "name": "insomnia", "url": "https://x" } }' | ConvertFrom-Json)
        $r.Id | Should -Be 'ps-dotenv'
        $r.Feed.name | Should -Be 'insomnia'
    }
    It 'returns nothing for an empty value' {
        Get-DFPackageRef '' | Should -BeNullOrEmpty
    }
}

Describe 'shipped packages use source keys' {
    It 'never uses the old manager keys cargo, psresource or scoopBucket' {
        foreach ($f in Get-ChildItem "$PSScriptRoot/../Tools" -Filter '*.json') {
            $j = Get-Content $f.FullName -Raw | ConvertFrom-Json
            $j.PSObject.Properties['scoopBucket'] | Should -BeNullOrEmpty -Because $f.Name
            if ($j.PSObject.Properties['packages'] -and $j.packages) {
                $j.packages.PSObject.Properties.Name | Should -Not -Contain 'cargo' -Because $f.Name
                $j.packages.PSObject.Properties.Name | Should -Not -Contain 'psresource' -Because $f.Name
            }
        }
    }
    It 'puts ps-dotenv''s third-party bucket in a feed' {
        $j = Get-Content "$PSScriptRoot/../Tools/ps-dotenv.json" -Raw | ConvertFrom-Json
        $j.packages.scoop.feed.name | Should -Be 'insomnia'
    }
}

Describe 'package readers accept a feed object' {
    BeforeEach { Set-DFTestXdg; Reset-DFTestSession }
    AfterEach { Restore-DFTestXdg }
    It 'Get-DFCatalogInstalled keys a feed package by its id' {
        $dir = Join-Path $TestDrive "pr-$([guid]::NewGuid().ToString('N').Substring(0,6))"
        New-Item -ItemType Directory $dir | Out-Null
        '{ "name": "fd2", "executable": "fd2.exe", "packages": { "scoop": { "id": "fd2", "feed": { "name": "b", "url": "https://x" } } } }' |
            Set-Content (Join-Path $dir 'fd2.json')
        $r = Get-DFCatalogInstalled -ToolsPath $dir -FetchItems { @() }
        $r.IdentityMap['scoop:fd2'] | Should -Be 'fd2'
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `pwsh -NoProfile -c "Invoke-Pester tests/Get-DFPackageRef.Tests.ps1 -Output Detailed"`
Expected: FAIL. `Get-DFPackageRef` is not recognized; the shipped files still use `cargo`/`psresource`/`scoopBucket`.

- [ ] **Step 3: Implement `Get-DFPackageRef`**

`Private/Get-DFPackageRef.ps1`:

```powershell
#Requires -Version 7.0

function Get-DFPackageRef {
    <#
    .SYNOPSIS
        Reads one packages value: a plain id, or { id, feed }.
    .DESCRIPTION
        A tool's packages map is keyed by source (a system manager or a
        registry). Each value is the package id in that source's default feed,
        or an object naming a feed the manager may have to add first:
        { "id": "ps-dotenv", "feed": { "name": "insomnia", "url": "https://..." } }.
        Every reader of packages goes through this, so a feed object is never
        stringified.
    .PARAMETER Value
        The packages value.
    .OUTPUTS
        PSCustomObject with Id and Feed ($null, or { name; url }); nothing for an empty value.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyString()][object]$Value)
    if ($null -eq $Value -or ($Value -is [string] -and -not $Value)) { return }
    if ($Value -is [string]) { return [pscustomobject]@{ Id = $Value; Feed = $null } }
    [pscustomobject]@{
        Id   = [string]$Value.PSObject.Properties['id']?.Value
        Feed = $Value.PSObject.Properties['feed']?.Value
    }
}
```

- [ ] **Step 4: Rename data keys**

Run this once from the repo root. It edits the tool files and the identity data, keeping each file's formatting:

```powershell
foreach ($f in 'mdcat','mdv','posh-git','PSFzf','Terminal-Icons') {
    $p = "Tools/$f.json"
    (Get-Content $p -Raw) -creplace '"cargo":', '"crates":' -creplace '"psresource":', '"psgallery":' | Set-Content $p -NoNewline
}
$p = 'data/tool-identities.json'
(Get-Content $p -Raw) -creplace '"cargo":', '"crates":' -creplace '"psresource":', '"psgallery":' | Set-Content $p -NoNewline
```

Then edit `Tools/ps-dotenv.json` by hand: delete the `scoopBucket` line and change `packages` to:

```json
"packages": { "scoop": { "id": "ps-dotenv", "feed": { "name": "insomnia", "url": "https://github.com/insomnimus/scoop-bucket" } } },
```

- [ ] **Step 5: Route every reader through `Get-DFPackageRef`**

`Private/Get-DFCatalogInstalled.ps1` (inside the `foreach ($property ...)` loop):

```powershell
            $ref = Get-DFPackageRef $property.Value
            if ($ref) {
                $key = "$(ConvertTo-DFCatalogSource $property.Name):$($ref.Id.ToLowerInvariant())"
                $identity[$key] = $tool.name
            }
```

`Private/Get-DFToolIdentityGuide.ps1`:

```powershell
            foreach ($pkgProp in $entry.packages.PSObject.Properties) {
                $ref = Get-DFPackageRef $pkgProp.Value
                if ($ref) { $idIndex["$(ConvertTo-DFCatalogSource $pkgProp.Name):$($ref.Id)".ToLowerInvariant()] = $key }
            }
```

In `build/Build-DFToolIdentities.ps1:67` and `build/Build-DFReferenceDocs.ps1:246`, read each value as `(Get-DFPackageRef $prop.Value).Id` (both scripts already dot-source module files; add `Private/Get-DFPackageRef.ps1` to their list if it is explicit). In the reference docs, show a feed as `id (feed name)`.

- [ ] **Step 6: Delete the alias and `scoopBucket`**

- **`Private/DFCatalog.Base.ps1`:**
  - remove the `-PackageManager` parameter, its help and the `PackageManager =` entry;
  - in `ConvertTo-DFCatalogSource`, delete the `foreach ($provider ...)` loop, so it only lowercases;
  - update its help (`cargo` → `crates` example goes; the keys now match).
- **`Private/DFCatalog.Crates.ps1:145` and `Private/DFCatalog.PSGallery.ps1:115`:** drop `-PackageManager cargo` / `-PackageManager psresource`.
- **`Private/Import-DFToolDb.ps1`:** delete `scoopBucket = ...`, and remove `scoopBucket` from the help line.
- **`Private/Test-DFToolSchema.ps1`:**
  - Replace the `scoopBucket` check (lines 76-78) with a `packages` value check:
    ```powershell
    $pk = PSProp $Tool 'packages'
    if ($pk -is [pscustomobject]) {
        foreach ($p in $pk.PSObject.Properties) {
            $v = $p.Value
            $ok = ($v -is [string]) -or ($v -is [pscustomobject] -and (PSProp $v 'id') -is [string] -and (PSProp $v 'id') -and
                  ($null -eq (PSProp $v 'feed') -or ((PSProp (PSProp $v 'feed') 'name') -and (PSProp (PSProp $v 'feed') 'url'))))
            if (-not $ok) { $errs.Add("packages.$($p.Name) must be an id, or { id, feed: { name, url } }") }
        }
    }
    if ($Tool.PSObject.Properties['scoopBucket']) { $errs.Add('scoopBucket was replaced: put { id, feed: { name, url } } in packages.scoop') }
    ```
  - Remove `'scoopBucket'` from the known top-level fields.
- **`Public/Install-DFTool.ps1`** (stop-gap until Task 6):
  - rename the switch keys `'cargo'` → `'crates'` and `'psresource'` → `'psgallery'`;
  - append `'crates'` where it appended `'cargo'`;
  - read `$pkgId = (Get-DFPackageRef $pkgProp.Value).Id`;
  - replace the `scoopBucket` branch with `$feed = (Get-DFPackageRef $pkgProp.Value).Feed; if ($pm -eq 'scoop' -and $feed) { if (-not (Add-DFScoopBucket -Bucket $feed)) { continue }; $installId = "$($feed.name)/$pkgId" }`.

  Update `tests/Install-DFTool.Tests.ps1` fixtures that use `cargo`, `psresource` or `scoopBucket` the same way.

- [ ] **Step 7: Fix the tests that referenced the old names**

Run: `git grep -n -E "scoopBucket|PackageManager (cargo|psresource)|'cargo'|\"cargo\"|psresource" -- tests`
Update each fixture to `crates`/`psgallery`/`feed`. In `tests/DFCatalog.Core.Tests.ps1`, the alias test for `ConvertTo-DFCatalogSource cargo` becomes: `ConvertTo-DFCatalogSource Crates | Should -Be 'crates'`.

- [ ] **Step 8: Run the affected suites**

Run: `pwsh -NoProfile -c "Invoke-Pester tests/Get-DFPackageRef.Tests.ps1, tests/Install-DFTool.Tests.ps1, tests/Test-DFToolSchema.Tests.ps1, tests/Get-DFCatalogInstalled.Tests.ps1, tests/DFCatalog.Core.Tests.ps1, tests/Find-DFPackage.Tests.ps1, tests/ConvertTo-DFToolRecord.Tests.ps1 -Output Normal"`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add -A Private Public Tools data build tests
git commit -m "refactor(tools)!: key packages by source; feeds replace scoopBucket"
```

---

### Task 2: The manager `installs` block and manager records

**Files:**
- Modify: `Private/Import-DFToolDb.ps1` (`ConvertTo-DFToolRecord`), `Private/Test-DFToolSchema.ps1`, `data/roles.json`
- Modify: `Tools/scoop.json`, `Tools/winget.json`, `Tools/choco.json`, `Tools/npm.json`, `Tools/fnm.json`, `Tools/mise.json`
- Create: `Tools/cargo.json`, `Tools/psresource.json`
- Test: `tests/Installs.Schema.Tests.ps1` (new)

**Interfaces:**
- Produces, on every record:
  - `installs`: `$null` or `[pscustomobject]@{ from = [string]; command = [string[]] | $null; function = [string] | $null; args = [pscustomobject] | $null; batch = [bool]; elevate = [bool]; reactivate = [bool]; feeds = $null | [pscustomobject]@{ list = [string[]]; add = [string[]]; id = [string] } }`
  - `install`: `$null` or `[pscustomobject]@{ prefer = [string[]] }`
- Placeholders in `command`/`args` values: `{id}` (one id; in a batch the token expands to every id), `{name}`/`{url}` (feed add), and in `feeds.id`: `{feed}`, `{id}`.

- [ ] **Step 1: Write the failing tests**

`tests/Installs.Schema.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    function script:Get-Errs([hashtable]$Extra) {
        $t = [pscustomobject](@{ name = 't'; executable = 't.exe' } + $Extra)
        $errs = @(); $warns = @()
        $null = Test-DFToolSchema -Tool $t -Errors ([ref]$errs) -Warnings ([ref]$warns)
        $errs
    }
    $script:Db = Import-DFToolDb -ToolsPath "$PSScriptRoot/../Tools" -Force
}

Describe 'installs and install (schema)' {
    It 'accepts a command manager and a function manager' {
        Get-Errs @{ installs = [pscustomobject]@{ from = 'x'; command = @('x', 'install', '{id}') } } | Should -BeNullOrEmpty
        Get-Errs @{ installs = [pscustomobject]@{ from = 'psgallery'; function = 'Install-PSResource'; args = [pscustomobject]@{ Name = '{id}' } } } | Should -BeNullOrEmpty
    }
    It 'requires from, and exactly one of command or function' {
        Get-Errs @{ installs = [pscustomobject]@{ command = @('x') } } | Should -Match 'installs.from'
        Get-Errs @{ installs = [pscustomobject]@{ from = 'x' } } | Should -Match 'command or function'
    }
    It 'requires install.prefer to name the tool''s own sources' {
        Get-Errs @{ packages = [pscustomobject]@{ scoop = 'g' }; install = [pscustomobject]@{ prefer = @('winget') } } | Should -Match 'install.prefer'
    }
    It 'normalizes installs with defaults' {
        $r = ConvertTo-DFToolRecord ('{ "name": "m", "executable": "m", "installs": { "from": "m", "command": ["m","i","{id}"] } }' | ConvertFrom-Json)
        $r.installs.batch | Should -BeFalse
        $r.installs.elevate | Should -BeFalse
        $r.installs.feeds | Should -BeNullOrEmpty
        $r.install | Should -BeNullOrEmpty
    }
}

Describe 'shipped managers' {
    It 'gives every source used in packages a manager whose installs.from names it' {
        $from = @($script:Db.Values | Where-Object installs | ForEach-Object { $_.installs.from })
        $used = @($script:Db.Values | Where-Object packages | ForEach-Object { $_.packages.PSObject.Properties.Name }) | Sort-Object -Unique
        foreach ($s in $used) { $from | Should -Contain $s -Because "a tool uses source '$s'" }
    }
    It 'marks choco as needing elevation and scoop as having feeds' {
        $script:Db['choco'].installs.elevate | Should -BeTrue
        $script:Db['scoop'].installs.feeds.id | Should -Be '{feed}/{id}'
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `pwsh -NoProfile -c "Invoke-Pester tests/Installs.Schema.Tests.ps1 -Output Detailed"`
Expected: FAIL. No `installs` normalization; no manager declares `installs`.

- [ ] **Step 3: Normalize `installs` and `install`**

In `ConvertTo-DFToolRecord` (`Private/Import-DFToolDb.ps1`), next to the `setup` normalization:

```powershell
    $installs = & $get $Tool 'installs' $null
    if ($installs) {
        $feeds = & $get $installs 'feeds' $null
        $installs = [pscustomobject]@{
            from       = & $get $installs 'from' $null
            command    = $(if ($c = & $get $installs 'command' $null) { [string[]]@($c) })
            function   = & $get $installs 'function' $null
            args       = & $get $installs 'args' $null
            batch      = [bool](& $get $installs 'batch' $false)
            elevate    = [bool](& $get $installs 'elevate' $false)
            reactivate = [bool](& $get $installs 'reactivate' $false)
            feeds      = $(if ($feeds) { [pscustomobject]@{
                list = [string[]]@(& $get $feeds 'list' @())
                add  = [string[]]@(& $get $feeds 'add' @())
                id   = & $get $feeds 'id' '{feed}/{id}' } })
        }
    }
    $install = & $get $Tool 'install' $null
    if ($install) { $install = [pscustomobject]@{ prefer = [string[]]@(& $get $install 'prefer' @()) } }
```

Add `installs = $installs` and `install = $install` to `$record`. Add both to the help's field list.

- [ ] **Step 4: Validate them**

In `Private/Test-DFToolSchema.ps1`, after the `setup` check:

```powershell
    $ins = PSProp $Tool 'installs'
    if ($null -ne $ins) {
        if ($ins -isnot [pscustomobject]) { $errs.Add('installs must be an object') }
        else {
            if (-not ((PSProp $ins 'from') -is [string] -and (PSProp $ins 'from'))) { $errs.Add('installs.from must name the source this manager installs from') }
            $hasCmd = $null -ne (PSProp $ins 'command'); $hasFn = $null -ne (PSProp $ins 'function')
            if ($hasCmd -eq $hasFn) { $errs.Add('installs needs exactly one of command or function') }
            if ($hasCmd -and (PSProp $ins 'command') -isnot [array]) { $errs.Add('installs.command must be an array (argv)') }
        }
    }
    $inst = PSProp $Tool 'install'
    if ($null -ne $inst) {
        $prefer = @(PSProp $inst 'prefer')
        $have = @((PSProp $Tool 'packages')?.PSObject.Properties.Name)
        $bad = @($prefer | Where-Object { $_ -and $_ -notin $have })
        if ($bad) { $errs.Add("install.prefer names sources the tool has no package for: $($bad -join ', ')") }
    }
```

Add `'installs', 'install'` to the known top-level fields; add `installs = 'from', 'command', 'function', 'args', 'batch', 'elevate', 'reactivate', 'feeds'` and `install = 'prefer'` to the `$known` sections, and register both sections like `setup`.

- [ ] **Step 5: Declare the shipped managers**

Add to each file (keep existing fields):

- `Tools/scoop.json`: `"installs": { "from": "scoop", "command": ["scoop", "install", "{id}"], "batch": true, "feeds": { "list": ["scoop", "bucket", "list"], "add": ["scoop", "bucket", "add", "{name}", "{url}"], "id": "{feed}/{id}" } }`
- `Tools/winget.json`: `"installs": { "from": "winget", "command": ["winget", "install", "--id", "{id}", "--exact", "--silent", "--accept-source-agreements", "--accept-package-agreements"] }`. winget installs one id per call, so no `batch`.
- `Tools/choco.json`: `"installs": { "from": "choco", "command": ["choco", "install", "{id}", "-y"], "batch": true, "elevate": true }`
- `Tools/npm.json`: `"installs": { "from": "npm", "command": ["npm", "install", "-g", "{id}"], "batch": true }`, and add `"roles": { "js-package-manager": { "priority": 30 } }`.
- `Tools/fnm.json`: `"installs": { "from": "fnm", "command": ["fnm", "install", "{id}"], "reactivate": true }`
- `Tools/mise.json`: `"installs": { "from": "mise", "command": ["mise", "use", "--global", "{id}"], "reactivate": true }`

Create `Tools/cargo.json`:

```json
{
  "name": "cargo",
  "description": "Rust package manager (installs crates from crates.io)",
  "tags": ["rust", "dev", "package-manager"],
  "executable": "cargo.exe",
  "roles": { "rust-package-manager": { "priority": 10 } },
  "requires": ["rustup"],
  "packages": {},
  "installs": { "from": "crates", "command": ["cargo", "install", "{id}"], "batch": true },
  "aliases": {},
  "picker": null
}
```

Create `Tools/psresource.json`:

```json
{
  "name": "psresource",
  "description": "PowerShell module installer (PSResourceGet; installs from the PowerShell Gallery)",
  "tags": ["powershell", "package-manager"],
  "type": "module",
  "executable": "Microsoft.PowerShell.PSResourceGet",
  "prewarm": false,
  "roles": { "powershell-package-manager": { "priority": 10 } },
  "packages": {},
  "installs": { "from": "psgallery", "function": "Install-PSResource", "args": { "Name": "{id}", "Scope": "CurrentUser", "TrustRepository": true } , "batch": true },
  "aliases": {},
  "picker": null
}
```

In `data/roles.json`, add these category roles after `js-runtime`:

```json
  "js-package-manager":         { "kind": "category", "description": "Installs packages from the npm registry. Install-DFTool uses the Defaults choice, else the highest priority." },
  "rust-package-manager":       { "kind": "category", "description": "Installs crates from crates.io." },
  "powershell-package-manager": { "kind": "category", "description": "Installs modules from the PowerShell Gallery." }
```

`cargo` requires `rustup`: cargo ships with rustup, so this is the "provided by" rule (spec section 8). Verify `cargo.json`'s `requires` passes `tests/Requires.Tests.ps1`'s shipped-requires test.

- [ ] **Step 6: Run the tests**

Run: `pwsh -NoProfile -c "Invoke-Pester tests/Installs.Schema.Tests.ps1, tests/Test-DFToolSchema.Tests.ps1, tests/ConvertTo-DFToolRecord.Tests.ps1, tests/Requires.Tests.ps1, tests/Roles.Contract.Tests.ps1 -Output Normal"`
Expected: PASS. If `Roles.Contract` fails because a category role needs a member, the new manager records provide one each.

- [ ] **Step 7: Commit**

```bash
git add Private/Import-DFToolDb.ps1 Private/Test-DFToolSchema.ps1 data/roles.json Tools tests/Installs.Schema.Tests.ps1
git commit -m "feat(tools): managers declare installs; cargo and psresource records"
```

---

### Task 3: Choosing a source and manager

**Files:**
- Create: `Private/DFInstallSource.ps1`, `tests/DFInstallSource.Tests.ps1`
- Modify: `Private/DFSessionConfig.ps1` (keys)

**Interfaces:**
- Consumes: `Get-DFPackageRef` (Task 1); record fields `installs`, `install`, `roles`, `packages` (Task 2).
- Produces:
  - `Get-DFSourceManager -Source <string> -ToolDb <hashtable>` → `[object[]]`: the manager records whose `installs.from -eq $Source`, best first. Order: a manager named by any `Defaults` value, then the highest priority of any role it has, then name.
  - `Get-DFInstallSourceOrder -Tool <record> -ToolDb <hashtable> [-Via <hashtable>]` → `[string[]]`: the tool's candidate sources in precedence order (decision 2), with `ExcludeSources` removed unless named by `InstallVia`. `-Via` (tool → source, from `Install-DFTool -Via`) is merged over the `InstallVia` setting.
  - `Resolve-DFInstallSource -Tool <record> -ToolDb <hashtable> -IsAvailable <scriptblock> [-Planned <string[]>] [-Choice <hashtable>] [-Via <hashtable>]` → `[pscustomobject]@{ Tool; Source; Manager; Ref; Gap; Options }`.
    - `-IsAvailable { param($record) }` returns a bool.
    - `-Planned` lists manager names that an earlier stage will install.
    - `-Choice` maps source → manager name chosen by the user.
    - `Gap` is `$null` or a reason string. `Options` lists the manager names that could serve the first gap source (for the interactive question).

- [ ] **Step 1: Write the failing tests**

`tests/DFInstallSource.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    function script:Rec([string]$Json) { ConvertTo-DFToolRecord ($Json | ConvertFrom-Json) }
    function script:New-Db {
        $db = @{}
        foreach ($r in @(
            (Rec '{ "name": "scoop", "executable": "scoop.cmd", "roles": { "package-manager": { "priority": 30 } }, "installs": { "from": "scoop", "command": ["scoop","install","{id}"], "batch": true } }'),
            (Rec '{ "name": "winget", "executable": "winget.exe", "roles": { "package-manager": { "priority": 20 } }, "installs": { "from": "winget", "command": ["winget","install","{id}"] } }'),
            (Rec '{ "name": "choco", "executable": "choco.exe", "roles": { "package-manager": { "priority": 10 } }, "installs": { "from": "choco", "command": ["choco","install","{id}"], "elevate": true } }'),
            (Rec '{ "name": "npm", "executable": "npm.cmd", "roles": { "js-package-manager": { "priority": 30 } }, "installs": { "from": "npm", "command": ["npm","i","-g","{id}"] } }'),
            (Rec '{ "name": "pnpm", "executable": "pnpm.cmd", "roles": { "js-package-manager": { "priority": 20 } }, "installs": { "from": "npm", "command": ["pnpm","add","-g","{id}"] } }'),
            (Rec '{ "name": "glow", "executable": "glow.exe", "packages": { "scoop": "glow", "winget": "charm.glow", "choco": "glow" }, "install": { "prefer": ["winget"] } }'),
            (Rec '{ "name": "ish", "executable": "is.cmd", "packages": { "npm": "@microsoft/inshellisense" } }')
        )) { $db[$r.name] = $r }
        $db
    }
    $script:All = { param($r) $true }
}

Describe 'Get-DFInstallSourceOrder' {
    BeforeEach { Set-DFTestConfig $null; $script:Db = New-Db }
    AfterEach { Set-DFTestConfig $null }

    It 'puts the tool spec''s preference first, then the built-in order' {
        Get-DFInstallSourceOrder -Tool $script:Db.glow -ToolDb $script:Db | Should -Be @('winget', 'scoop', 'choco')
    }
    It 'lets InstallOrder reorder what the tool spec didn''t pin' {
        Set-DFTestConfig @{ InstallOrder = @('choco', 'scoop') }
        Get-DFInstallSourceOrder -Tool $script:Db.glow -ToolDb $script:Db | Should -Be @('winget', 'choco', 'scoop')
    }
    It 'puts InstallVia above everything' {
        Set-DFTestConfig @{ InstallVia = @{ glow = 'choco' } }
        (Get-DFInstallSourceOrder -Tool $script:Db.glow -ToolDb $script:Db)[0] | Should -Be 'choco'
    }
    It 'drops excluded sources, unless InstallVia names one' {
        Set-DFTestConfig @{ ExcludeSources = @('choco') }
        Get-DFInstallSourceOrder -Tool $script:Db.glow -ToolDb $script:Db | Should -Not -Contain 'choco'
        Set-DFTestConfig @{ ExcludeSources = @('choco'); InstallVia = @{ glow = 'choco' } }
        (Get-DFInstallSourceOrder -Tool $script:Db.glow -ToolDb $script:Db)[0] | Should -Be 'choco'
    }
    It 'warns about an InstallVia source the tool has no package for, and ignores it' {
        Set-DFTestConfig @{ InstallVia = @{ glow = 'crates' } }
        $o = Get-DFInstallSourceOrder -Tool $script:Db.glow -ToolDb $script:Db -WarningVariable w 3>$null
        $o[0] | Should -Be 'winget'
        "$w" | Should -Match "InstallVia.*glow.*crates"
    }
}

Describe 'Get-DFSourceManager' {
    BeforeEach { Set-DFTestConfig $null; $script:Db = New-Db }
    AfterEach { Set-DFTestConfig $null }
    It 'ranks a registry''s managers by priority, and Defaults first' {
        (Get-DFSourceManager -Source npm -ToolDb $script:Db).name | Should -Be @('npm', 'pnpm')
        Set-DFTestConfig @{ Defaults = @{ 'js-package-manager' = 'pnpm' } }
        (Get-DFSourceManager -Source npm -ToolDb $script:Db).name | Should -Be @('pnpm', 'npm')
    }
}

Describe 'Resolve-DFInstallSource' {
    BeforeEach { Set-DFTestConfig $null; $script:Db = New-Db }
    AfterEach { Set-DFTestConfig $null }

    It 'takes the first source whose manager is available' {
        $r = Resolve-DFInstallSource -Tool $script:Db.glow -ToolDb $script:Db -IsAvailable { param($m) $m.name -ne 'winget' }
        $r.Source | Should -Be 'scoop'
        $r.Manager.name | Should -Be 'scoop'
        $r.Ref.Id | Should -Be 'glow'
        $r.Gap | Should -BeNullOrEmpty
    }
    It 'counts a manager planned in an earlier stage as available' {
        $r = Resolve-DFInstallSource -Tool $script:Db.ish -ToolDb $script:Db -IsAvailable { param($m) $false } -Planned @('npm')
        $r.Manager.name | Should -Be 'npm'
    }
    It 'reports a gap, with the managers that could serve it, when nothing is available' {
        $r = Resolve-DFInstallSource -Tool $script:Db.ish -ToolDb $script:Db -IsAvailable { param($m) $false }
        $r.Gap | Should -Match 'npm'
        $r.Options | Should -Be @('npm', 'pnpm')
    }
    It 'uses the user''s choice for a gap source' {
        $r = Resolve-DFInstallSource -Tool $script:Db.ish -ToolDb $script:Db -IsAvailable { param($m) $false } -Choice @{ npm = 'pnpm' }
        $r.Manager.name | Should -Be 'pnpm'
        $r.Gap | Should -BeNullOrEmpty
    }
    It 'names the exclusion when it leaves no source' {
        $db = New-Db
        $db.only = Rec '{ "name": "only", "executable": "o.exe", "packages": { "choco": "only" } }'
        Set-DFTestConfig @{ ExcludeSources = @('choco') }
        (Resolve-DFInstallSource -Tool $db.only -ToolDb $db -IsAvailable $script:All).Gap |
            Should -Match 'no source left.*choco.*ExcludeSources'
    }
    It 'reports a tool with no packages at all' {
        $db = New-Db
        $db.bare = Rec '{ "name": "bare", "executable": "b.exe" }'
        (Resolve-DFInstallSource -Tool $db.bare -ToolDb $db -IsAvailable $script:All).Gap | Should -Match 'no package'
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `pwsh -NoProfile -c "Invoke-Pester tests/DFInstallSource.Tests.ps1 -Output Detailed"`
Expected: FAIL (functions not defined).

- [ ] **Step 3: Add the config keys**

In `Private/DFSessionConfig.ps1`'s `$script:DFConfigKeys`, replace `PackageManagerOrder = ...` with:

```powershell
    InstallVia          = 'Tool -> source to install it from (beats everything, including ExcludeSources)'
    InstallOrder        = 'Preferred source order for Install-DFTool (ordering only)'
    ExcludeSources      = 'Sources Install-DFTool never uses (unless InstallVia names one)'
```

and add to `$script:DFRemovedConfigKeys`: `PackageManagerOrder = 'use InstallOrder (sources, ordering only) and ExcludeSources'`.

- [ ] **Step 4: Implement `Private/DFInstallSource.ps1`**

```powershell
#Requires -Version 7.0

function Get-DFSourceManager {
    <#
    .SYNOPSIS
        Returns the managers that install from one source, best first.
    .DESCRIPTION
        A manager is any tool record whose installs.from names the source.
        A system manager (scoop) is its own only manager; a registry (npm)
        can have several (npm, pnpm, bun). Order: a manager the user named in
        Defaults (for any role), then the highest priority among its roles,
        then name.
    .PARAMETER Source
        The source name, e.g. 'scoop' or 'npm'.
    .PARAMETER ToolDb
        Name -> tool record; must include the manager records.
    .OUTPUTS
        PSCustomObject[]. Manager records.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][hashtable]$ToolDb)
    $chosen = @((Get-DFConfig Defaults -Default @{}).Values)
    @($ToolDb.Values | Where-Object { $_.installs -and $_.installs.from -eq $Source } |
        Sort-Object @{ Expression = { $_.name -in $chosen }; Descending = $true },
                    @{ Expression = { @($_.roles.PSObject.Properties.Value | ForEach-Object { $_.priority }) | Measure-Object -Maximum | ForEach-Object Maximum }; Descending = $true },
                    name)
}

function Get-DFBuiltInSourceOrder {
    <#
    .SYNOPSIS
        DotForge's fallback source order: system managers by package-manager priority, then every other source by name.
    .PARAMETER ToolDb
        Name -> tool record; must include the manager records.
    .OUTPUTS
        System.String[].
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][hashtable]$ToolDb)
    $managers = @($ToolDb.Values | Where-Object installs)
    $system = @($managers | Where-Object { $_.roles.PSObject.Properties['package-manager'] } |
        Sort-Object @{ Expression = { $_.roles.'package-manager'.priority }; Descending = $true }, name |
        ForEach-Object { $_.installs.from })
    $other = @($managers | ForEach-Object { $_.installs.from } | Where-Object { $_ -notin $system } | Sort-Object -Unique)
    [string[]]@($system + $other | Select-Object -Unique)
}

function Get-DFInstallSourceOrder {
    <#
    .SYNOPSIS
        Orders one tool's candidate sources: InstallVia, the tool's install.prefer, InstallOrder, then DotForge's order.
    .DESCRIPTION
        Only sources the tool has a package for are returned. ExcludeSources
        removes a source unless InstallVia names it for this tool. An
        InstallVia source the tool has no package for warns and is ignored.
    .PARAMETER Tool
        The tool record.
    .PARAMETER ToolDb
        Name -> tool record; must include the manager records.
    .PARAMETER Via
        Tool -> source for this call (Install-DFTool -Via); beats the InstallVia setting.
    .OUTPUTS
        System.String[].
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][pscustomobject]$Tool, [Parameter(Mandatory)][hashtable]$ToolDb, [hashtable]$Via = @{})
    $have = @($Tool.packages?.PSObject.Properties | Where-Object { Get-DFPackageRef $_.Value } | ForEach-Object Name)
    $via = $Via[$Tool.name] ?? (Get-DFConfig InstallVia -Default @{})[$Tool.name]
    if ($via -and $via -notin $have) {
        Write-Warning "DotForge: InstallVia names '$via' for $($Tool.name), which has no package there; ignoring it."
        $via = $null
    }
    $excluded = @(Get-DFConfig ExcludeSources)
    $ordered = @(@($via) + @($Tool.install?.prefer) + @(Get-DFConfig InstallOrder) + (Get-DFBuiltInSourceOrder -ToolDb $ToolDb) + $have |
        Where-Object { $_ -and $_ -in $have } | Select-Object -Unique)
    [string[]]@($ordered | Where-Object { $_ -eq $via -or $_ -notin $excluded })
}

function Resolve-DFInstallSource {
    <#
    .SYNOPSIS
        Picks the source and manager that will install one tool, or says why none can.
    .DESCRIPTION
        Walks Get-DFInstallSourceOrder. For each source, the manager is the
        user's -Choice for that source if given, else the first of
        Get-DFSourceManager that is available or -Planned (an earlier stage
        installs it). The first source with a manager wins. Otherwise Gap
        explains why, and Options lists the managers that could serve the
        first source, for the interactive question.
    .PARAMETER Tool
        The tool record.
    .PARAMETER ToolDb
        Name -> tool record; must include the manager records.
    .PARAMETER IsAvailable
        { param($record) } -> whether that manager is installed now.
    .PARAMETER Planned
        Manager names an earlier stage installs.
    .PARAMETER Choice
        Source -> manager name the user picked for it.
    .PARAMETER Via
        Tool -> source for this call; passed to Get-DFInstallSourceOrder.
    .OUTPUTS
        PSCustomObject: Tool, Source, Manager, Ref, Gap, Options.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Tool,
        [Parameter(Mandatory)][hashtable]$ToolDb,
        [Parameter(Mandatory)][scriptblock]$IsAvailable,
        [AllowEmptyCollection()][string[]]$Planned = @(),
        [hashtable]$Choice = @{},
        [hashtable]$Via = @{}
    )
    $result = [pscustomobject]@{ Tool = $Tool.name; Source = $null; Manager = $null; Ref = $null; Gap = $null; Options = @() }
    $sources = @(Get-DFInstallSourceOrder -Tool $Tool -ToolDb $ToolDb -Via $Via)
    if (-not $sources) {
        $have = @($Tool.packages?.PSObject.Properties.Name)
        $result.Gap = if (-not $have) { 'no package in any source' }
                      else { "no source left (only $($have -join ', ') $(if ($have.Count -eq 1) { 'has' } else { 'have' }) it, and ExcludeSources removes $(if ($have.Count -eq 1) { 'it' } else { 'them' }))" }
        return $result
    }
    foreach ($s in $sources) {
        $managers = @(Get-DFSourceManager -Source $s -ToolDb $ToolDb)
        $pick = if ($Choice[$s]) { $managers | Where-Object name -eq $Choice[$s] | Select-Object -First 1 }
                else { $managers | Where-Object { $_.name -in $Planned -or (& $IsAvailable $_) } | Select-Object -First 1 }
        if ($pick) {
            $result.Source = $s; $result.Manager = $pick; $result.Ref = Get-DFPackageRef $Tool.packages.$s
            return $result
        }
    }
    $first = $sources[0]
    $result.Options = [string[]]@(Get-DFSourceManager -Source $first -ToolDb $ToolDb | ForEach-Object name)
    $result.Gap = "needs a manager for $first ($(if ($result.Options) { $result.Options -join ', ' } else { 'none known' })), and none is installed or requested"
    $result
}
```

- [ ] **Step 5: Run the tests**

Run: `pwsh -NoProfile -c "Invoke-Pester tests/DFInstallSource.Tests.ps1, tests/Start-DFSession.Tests.ps1 -Output Normal"`
Expected: PASS. (`Start-DFSession` covers the config-key list; `tests/DFSessionConfig*` too if present. Run `git grep -l PackageManagerOrder -- tests` and update those fixtures to `InstallOrder`.)

- [ ] **Step 6: Commit**

```bash
git add Private/DFInstallSource.ps1 Private/DFSessionConfig.ps1 tests
git commit -m "feat(install): choose a source per tool (InstallVia, prefer, InstallOrder, built-in)"
```

---

### Task 4: The install plan (graph layer, stages, gaps)

**Files:**
- Create: `Private/New-DFInstallPlan.ps1`, `tests/New-DFInstallPlan.Tests.ps1`

**Interfaces:**
- Consumes: `Resolve-DFInstallSource` (Task 3).
- Produces: `New-DFInstallPlan -Name <string[]> -ToolDb <hashtable> -IsAvailable <scriptblock> [-Choice <hashtable>] [-Via <hashtable>]` → `[pscustomobject]@{ Stages; Gaps; Items }`.
  - **`Items`:** one per tool to install: `[pscustomobject]@{ Tool; Source; Manager; Ref; ProvidedBy; DependsOn = [string[]]; Stage = [int] }`. `ProvidedBy` is set (and `Manager`/`Source` are `$null`) for a tool with no packages that requires a tool in the plan.
  - **`Stages`:** `[object[]]`, index 0 = stage 1. Each stage is `[pscustomobject]@{ Number; Batches }`, and each batch is `[pscustomobject]@{ Manager; Source; Items }`. Batches are grouped by manager within a stage.
  - **`Gaps`:** `[pscustomobject]@{ Tool; Reason; Options; Source; Dependents = [string[]] }`.
- **Dependency rules:**
  - a tool depends on its chosen manager when that manager is also in the plan;
  - on a `requires` tool in the plan;
  - on the tool it is `ProvidedBy`.
- **Missing managers are added automatically only when they are in `-Name`** (decision 5). A missing manager not in `-Name` makes a gap, unless `-Choice` names one: then that manager joins the plan.

- [ ] **Step 1: Write the failing tests**

`tests/New-DFInstallPlan.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    function script:Rec([string]$Json) { ConvertTo-DFToolRecord ($Json | ConvertFrom-Json) }
    function script:New-ChainDb {
        $db = @{}
        foreach ($r in @(
            (Rec '{ "name": "scoop", "executable": "scoop.cmd", "roles": { "package-manager": { "priority": 30 } }, "installs": { "from": "scoop", "command": ["scoop","install","{id}"], "batch": true } }'),
            (Rec '{ "name": "fnm", "executable": "fnm.exe", "packages": { "scoop": "fnm" }, "roles": { "version-manager": {} }, "installs": { "from": "fnm", "command": ["fnm","install","{id}"], "reactivate": true } }'),
            (Rec '{ "name": "node", "executable": "node.exe", "packages": { "fnm": "lts", "scoop": "nodejs-lts" }, "install": { "prefer": ["fnm"] }, "roles": { "js-runtime": {} } }'),
            (Rec '{ "name": "npm", "executable": "npm.cmd", "requires": ["node"], "roles": { "js-package-manager": { "priority": 30 } }, "installs": { "from": "npm", "command": ["npm","i","-g","{id}"], "batch": true } }'),
            (Rec '{ "name": "ish", "executable": "is.cmd", "packages": { "npm": "@microsoft/inshellisense" } }'),
            (Rec '{ "name": "glow", "executable": "glow.exe", "packages": { "scoop": "glow" } }')
        )) { $db[$r.name] = $r }
        $db
    }
    # Only scoop is installed on this "fresh machine".
    $script:OnlyScoop = { param($m) $m.name -eq 'scoop' }
}

Describe 'New-DFInstallPlan' {
    BeforeEach { Set-DFTestConfig $null; $script:Db = New-ChainDb }
    AfterEach { Set-DFTestConfig $null }

    It 'stages the scoop -> fnm -> node -> npm -> ish chain when all are requested' {
        $p = New-DFInstallPlan -Name fnm, node, npm, ish -ToolDb $script:Db -IsAvailable $script:OnlyScoop
        ($p.Items | Where-Object Tool -eq fnm).Stage | Should -Be 1
        ($p.Items | Where-Object Tool -eq node).Stage | Should -Be 2
        ($p.Items | Where-Object Tool -eq node).Source | Should -Be 'fnm'
        ($p.Items | Where-Object Tool -eq npm).ProvidedBy | Should -Be 'node'
        ($p.Items | Where-Object Tool -eq npm).Stage | Should -Be 3
        ($p.Items | Where-Object Tool -eq ish).Stage | Should -Be 4
        $p.Gaps | Should -BeNullOrEmpty
    }
    It 'groups one stage''s tools into one batch per manager' {
        $p = New-DFInstallPlan -Name fnm, glow -ToolDb $script:Db -IsAvailable $script:OnlyScoop
        $p.Stages.Count | Should -Be 1
        $p.Stages[0].Batches.Count | Should -Be 1
        $p.Stages[0].Batches[0].Manager.name | Should -Be 'scoop'
        @($p.Stages[0].Batches[0].Items.Tool) | Should -Be @('fnm', 'glow')
    }
    It 'never adds an unrequested manager: a gap names it and the tools that wait on it' {
        $p = New-DFInstallPlan -Name ish -ToolDb $script:Db -IsAvailable $script:OnlyScoop
        $p.Items | Should -BeNullOrEmpty
        $p.Gaps[0].Tool | Should -Be 'ish'
        $p.Gaps[0].Options | Should -Be @('npm')
    }
    It 'adds a manager the user chose for a gap, with what it needs' {
        $p = New-DFInstallPlan -Name ish, fnm, node -ToolDb $script:Db -IsAvailable $script:OnlyScoop -Choice @{ npm = 'npm' }
        ($p.Items | Where-Object Tool -eq npm).ProvidedBy | Should -Be 'node'
        ($p.Items | Where-Object Tool -eq ish).DependsOn | Should -Contain 'npm'
    }
    It 'falls back past a preferred source whose manager is neither installed nor requested' {
        $p = New-DFInstallPlan -Name node, npm, ish -ToolDb $script:Db -IsAvailable $script:OnlyScoop
        # node prefers fnm, which isn't installed or requested, so scoop installs it; npm comes with it.
        ($p.Items | Where-Object Tool -eq node).Source | Should -Be 'scoop'
        $p.Gaps | Should -BeNullOrEmpty
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `pwsh -NoProfile -c "Invoke-Pester tests/New-DFInstallPlan.Tests.ps1 -Output Detailed"`
Expected: FAIL (`New-DFInstallPlan` not defined).

- [ ] **Step 3: Implement `Private/New-DFInstallPlan.ps1`**

```powershell
#Requires -Version 7.0

function New-DFInstallPlan {
    <#
    .SYNOPSIS
        Builds the install layer of the session graph: a source and manager per tool, stages in dependency order, and gaps.
    .DESCRIPTION
        For each named tool, picks a source (Resolve-DFInstallSource). A
        manager that is itself one of the named tools counts as planned, so the
        tool waits for it. A tool with no packages that requires a tool in the
        plan is "provided by" it (npm comes with node). Nothing unnamed is
        added, except a manager the user chose for a gap (-Choice), which
        joins the plan. A tool's stage is one more than the highest stage it
        depends on; within a stage, tools are batched per manager.
    .PARAMETER Name
        The tools to install.
    .PARAMETER ToolDb
        Name -> tool record; must include every named tool and the manager records.
    .PARAMETER IsAvailable
        { param($record) } -> whether that tool is installed now.
    .PARAMETER Choice
        Source -> manager name, from the user (interactive) or -UseDefaults.
    .PARAMETER Via
        Tool -> source for this call (Install-DFTool -Via).
    .OUTPUTS
        PSCustomObject: Items, Stages, Gaps.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string[]]$Name,
        [Parameter(Mandatory)][hashtable]$ToolDb,
        [Parameter(Mandatory)][scriptblock]$IsAvailable,
        [hashtable]$Choice = @{},
        [hashtable]$Via = @{}
    )
    $want = [System.Collections.Generic.List[string]]::new()
    foreach ($n in $Name) { if (-not $want.Contains($n)) { $want.Add($n) } }
    foreach ($m in $Choice.Values) { if ($m -and -not $want.Contains($m) -and -not (& $IsAvailable $ToolDb[$m])) { $want.Add($m) } }

    $items = [ordered]@{}
    $gaps = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $want.Count; $i++) {
        $t = $ToolDb[$want[$i]]
        if (-not $t) { continue }
        $provider = @($t.requires | Where-Object { $_ -notlike 'role:*' -and $want.Contains($_) }) | Select-Object -First 1
        $hasPackages = @($t.packages?.PSObject.Properties).Count -gt 0
        if (-not $hasPackages -and $provider) {
            $items[$t.name] = [pscustomobject]@{ Tool = $t.name; Source = $null; Manager = $null; Ref = $null; ProvidedBy = $provider; DependsOn = [string[]]@($provider); Stage = 0 }
            continue
        }
        $planned = [string[]]@($want | Where-Object { $_ -ne $t.name })
        $r = Resolve-DFInstallSource -Tool $t -ToolDb $ToolDb -IsAvailable $IsAvailable -Planned $planned -Choice $Choice -Via $Via
        if ($r.Gap) {
            $gaps.Add([pscustomobject]@{ Tool = $t.name; Reason = $r.Gap; Options = $r.Options; Source = (Get-DFInstallSourceOrder -Tool $t -ToolDb $ToolDb -Via $Via | Select-Object -First 1); Dependents = [string[]]@() })
            continue
        }
        $deps = @(@($t.requires | Where-Object { $_ -notlike 'role:*' -and $want.Contains($_) }) + $(if ($want.Contains($r.Manager.name)) { $r.Manager.name }) | Where-Object { $_ } | Select-Object -Unique)
        $items[$t.name] = [pscustomobject]@{ Tool = $t.name; Source = $r.Source; Manager = $r.Manager; Ref = $r.Ref; ProvidedBy = $null; DependsOn = [string[]]$deps; Stage = 0 }
    }

    # Tools that depend (transitively) on a gap can't be installed either.
    $blocked = @($gaps.Tool)
    $blockedBy = @{}
    do {
        $more = @($items.Values | Where-Object { $_.Tool -notin $blocked -and @($_.DependsOn | Where-Object { $_ -in $blocked }).Count })
        foreach ($b in $more) {
            $blocked += $b.Tool
            # Credit the dependent to the gap it ultimately waits on (directly, or through another blocked tool).
            $root = $b.DependsOn | Where-Object { $_ -in $blocked } | Select-Object -First 1
            while ($root -and -not ($gaps | Where-Object Tool -eq $root)) { $root = $blockedBy[$root] }
            $blockedBy[$b.Tool] = $root
            $g = $gaps | Where-Object Tool -eq $root | Select-Object -First 1
            if ($g) { $g.Dependents += $b.Tool }
            $items.Remove($b.Tool)
        }
    } while ($more)

    # Stage = 1 + the highest stage depended on (a cycle falls back to stage 1).
    $stageOf = @{}
    $visit = $null
    $visit = {
        param($n, $seen)
        if ($stageOf.ContainsKey($n)) { return $stageOf[$n] }
        if ($n -in $seen) { return 0 }
        $deps = @($items[$n].DependsOn | Where-Object { $items.Contains($_) })
        $s = 1 + (@($deps | ForEach-Object { & $visit $_ (@($seen) + $n) }) + 0 | Measure-Object -Maximum).Maximum
        $stageOf[$n] = $s
        $s
    }
    foreach ($n in @($items.Keys)) { $items[$n].Stage = & $visit $n @() }

    $stages = @(foreach ($g in ($items.Values | Group-Object Stage | Sort-Object { [int]$_.Name })) {
        $batches = @(foreach ($b in ($g.Group | Where-Object Manager | Group-Object { $_.Manager.name })) {
            [pscustomobject]@{ Manager = $b.Group[0].Manager; Source = $b.Group[0].Source; Items = @($b.Group) }
        })
        [pscustomobject]@{ Number = [int]$g.Name; Batches = $batches; Provided = @($g.Group | Where-Object ProvidedBy) }
    })
    [pscustomobject]@{ Items = @($items.Values); Stages = $stages; Gaps = @($gaps) }
}
```

Each stage also carries `Provided` (the "comes with X" tools). Task 5 re-checks them after their stage.

- [ ] **Step 4: Run the tests**

Run: `pwsh -NoProfile -c "Invoke-Pester tests/New-DFInstallPlan.Tests.ps1 -Output Detailed"`
Expected: PASS.

- [ ] **Step 5: Add a gap-dependents test**

Add to the `Describe` block:

```powershell
    It 'names the requested tools that wait on a gap' {
        $db = New-ChainDb
        $db.ishplug = Rec '{ "name": "ishplug", "executable": "ip.cmd", "requires": ["ish"], "packages": { "scoop": "ishplug" } }'
        $p = New-DFInstallPlan -Name ish, ishplug -ToolDb $db -IsAvailable $script:OnlyScoop
        ($p.Gaps | Where-Object Tool -eq ish).Dependents | Should -Contain 'ishplug'
        $p.Items.Tool | Should -Not -Contain 'ishplug'
    }
```

Run it again. Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Private/New-DFInstallPlan.ps1 tests/New-DFInstallPlan.Tests.ps1
git commit -m "feat(install): staged install plan with gaps and provided-by"
```

---

### Task 5: Running a plan (the process seam)

**Files:**
- Create: `Private/Invoke-DFInstallCommand.ps1`, `Private/Invoke-DFInstallPlan.ps1`, `Private/Update-DFPathFromRegistry.ps1`, `Private/DFInstallHost.ps1`
- Test: `tests/Invoke-DFInstallPlan.Tests.ps1`

**Interfaces:**
- Consumes: plan objects (Task 4); `Add-DFToPath`; `Register-DFTool -Name` (re-activation); `Test-DFToolAvailable -Force`.
- Produces:
  - `Invoke-DFInstallCommand -Manager <record> -Argv <string[]> [-Function <string>] [-Arguments <hashtable>] [-Elevate]` → `[pscustomobject]@{ ExitCode = [int]; Output = [string] }`. **This is the only function that runs a manager**, so tests mock it.
  - `Expand-DFInstallArgv -Template <string[]> -Values <hashtable>` → `[string[]]`. `{id}` expands to every id in `$Values.ids`; other `{x}` tokens use `$Values.x`.
  - `Invoke-DFInstallPlan -Plan <plan> -ToolDb <hashtable> -IsAvailable <scriptblock> [-ToolsPath <string>]` → `[pscustomobject[]]`, each `@{ Tool; Result = 'Installed'|'Failed'|'Skipped'|'NotFound'; Detail }`.
  - `Update-DFPathFromRegistry` → none (appends new registry PATH entries via `Add-DFToPath`).
  - `Test-DFElevated` → bool. `Test-DFInteractiveHost` → bool. `Read-DFInstallChoice -Prompt <string> -Options <string[]> -Default <string>` → string. These are host seams, also used by Task 6.

- [ ] **Step 1: Write the failing tests**

`tests/Invoke-DFInstallPlan.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    function script:Rec([string]$Json) { ConvertTo-DFToolRecord ($Json | ConvertFrom-Json) }
}

Describe 'Expand-DFInstallArgv' {
    It 'expands {id} to every id, and other tokens from values' {
        Expand-DFInstallArgv -Template 'scoop', 'install', '{id}' -Values @{ ids = @('a', 'b') } | Should -Be @('scoop', 'install', 'a', 'b')
        Expand-DFInstallArgv -Template 'scoop', 'bucket', 'add', '{name}', '{url}' -Values @{ name = 'x'; url = 'https://u' } |
            Should -Be @('scoop', 'bucket', 'add', 'x', 'https://u')
    }
}

Describe 'Invoke-DFInstallPlan' {
    BeforeEach {
        Set-DFTestXdg; Reset-DFTestSession; Set-DFTestConfig $null
        $script:Calls = [System.Collections.Generic.List[string]]::new()
        $script:Fail = @()
        Mock Invoke-DFInstallCommand {
            $line = ($Argv -join ' ')
            if ($Elevate) { $line = "[elevated] $line" }
            $script:Calls.Add($line)
            [pscustomobject]@{ ExitCode = $(if (@($Argv | Where-Object { $_ -in $script:Fail }).Count) { 1 } else { 0 }); Output = 'out' }
        }
        Mock Update-DFPathFromRegistry { }
        Mock Register-DFTool { }
        Mock Test-DFElevated { $false }
        $script:Db = @{}
        foreach ($r in @(
            (Rec '{ "name": "scoop", "executable": "scoop.cmd", "installs": { "from": "scoop", "command": ["scoop","install","{id}"], "batch": true, "feeds": { "list": ["scoop","bucket","list"], "add": ["scoop","bucket","add","{name}","{url}"], "id": "{feed}/{id}" } } }'),
            (Rec '{ "name": "choco", "executable": "choco.exe", "installs": { "from": "choco", "command": ["choco","install","{id}","-y"], "batch": true, "elevate": true } }'),
            (Rec '{ "name": "gsudo", "executable": "gsudo.exe" }'),
            (Rec '{ "name": "fnm", "executable": "fnm.exe", "packages": { "scoop": "fnm" }, "installs": { "from": "fnm", "command": ["fnm","install","{id}"], "reactivate": true } }'),
            (Rec '{ "name": "node", "executable": "node.exe", "packages": { "fnm": "lts" } }'),
            (Rec '{ "name": "glow", "executable": "glow.exe", "packages": { "scoop": "glow", "choco": "glow" } }'),
            (Rec '{ "name": "dotenv", "executable": "Dotenv", "type": "module", "packages": { "scoop": { "id": "ps-dotenv", "feed": { "name": "insomnia", "url": "https://u" } } } }')
        )) { $script:Db[$r.name] = $r }
        $script:Installed = @('scoop')
        $script:Avail = { param($m) $m.name -in $script:Installed }
        # After a successful install, the tool is "found".
        Mock Test-DFToolAvailable { $true }
    }
    AfterEach { Restore-DFTestXdg; Set-DFTestConfig $null }

    It 'runs one batch per manager, in stage order' {
        $plan = New-DFInstallPlan -Name fnm, glow, node -ToolDb $script:Db -IsAvailable $script:Avail
        $r = Invoke-DFInstallPlan -Plan $plan -ToolDb $script:Db -IsAvailable $script:Avail
        $script:Calls | Should -Be @('scoop install fnm glow', 'fnm install lts')
        ($r | Where-Object Result -eq 'Installed').Tool | Should -Be @('fnm', 'glow', 'node')
    }
    It 're-activates a manager that asks for it, and merges PATH, after its stage' {
        $plan = New-DFInstallPlan -Name fnm, node -ToolDb $script:Db -IsAvailable $script:Avail
        $null = Invoke-DFInstallPlan -Plan $plan -ToolDb $script:Db -IsAvailable $script:Avail
        Should -Invoke Update-DFPathFromRegistry -Times 2 -Exactly
        Should -Invoke Register-DFTool -Times 1 -ParameterFilter { $Name -contains 'fnm' }
    }
    It 'skips what depends on a failed stage, saying why' {
        $script:Fail = @('fnm')
        $plan = New-DFInstallPlan -Name fnm, node -ToolDb $script:Db -IsAvailable $script:Avail
        $r = Invoke-DFInstallPlan -Plan $plan -ToolDb $script:Db -IsAvailable $script:Avail
        ($r | Where-Object Tool -eq fnm).Result | Should -Be 'Failed'
        ($r | Where-Object Tool -eq node).Result | Should -Be 'Skipped'
        ($r | Where-Object Tool -eq node).Detail | Should -Match 'fnm failed'
        $script:Calls | Should -Not -Contain 'fnm install lts'
    }
    It 'adds a missing feed before installing from it, and not when it is already there' {
        $plan = New-DFInstallPlan -Name dotenv -ToolDb $script:Db -IsAvailable $script:Avail
        $null = Invoke-DFInstallPlan -Plan $plan -ToolDb $script:Db -IsAvailable $script:Avail
        $script:Calls | Should -Be @('scoop bucket list', 'scoop bucket add insomnia https://u', 'scoop install insomnia/ps-dotenv')

        $script:Calls.Clear()
        Mock Invoke-DFInstallCommand {
            $script:Calls.Add($Argv -join ' ')
            [pscustomobject]@{ ExitCode = 0; Output = $(if ($Argv -contains 'list') { "insomnia https://u`nmain x" } else { '' }) }
        }
        $null = Invoke-DFInstallPlan -Plan $plan -ToolDb $script:Db -IsAvailable $script:Avail
        $script:Calls | Should -Not -Contain 'scoop bucket add insomnia https://u'
    }
    It 'runs an elevated manager through gsudo when it is installed, and skips it otherwise' {
        Set-DFTestConfig @{ InstallVia = @{ glow = 'choco' } }
        $script:Installed = @('scoop', 'choco', 'gsudo')
        $plan = New-DFInstallPlan -Name glow -ToolDb $script:Db -IsAvailable $script:Avail
        $null = Invoke-DFInstallPlan -Plan $plan -ToolDb $script:Db -IsAvailable $script:Avail
        $script:Calls | Should -Be @('[elevated] choco install glow -y')

        $script:Calls.Clear(); $script:Installed = @('scoop', 'choco')
        $plan = New-DFInstallPlan -Name glow -ToolDb $script:Db -IsAvailable $script:Avail
        $r = Invoke-DFInstallPlan -Plan $plan -ToolDb $script:Db -IsAvailable $script:Avail
        $script:Calls | Should -BeNullOrEmpty
        ($r | Where-Object Tool -eq glow).Detail | Should -Match 'elevated shell.*gsudo'
    }
    It 'reports a tool that installed but still isn''t found' {
        Mock Test-DFToolAvailable { $false }
        $plan = New-DFInstallPlan -Name glow -ToolDb $script:Db -IsAvailable $script:Avail
        $r = Invoke-DFInstallPlan -Plan $plan -ToolDb $script:Db -IsAvailable $script:Avail
        ($r | Where-Object Tool -eq glow).Result | Should -Be 'NotFound'
        ($r | Where-Object Tool -eq glow).Detail | Should -Match 'open a new shell'
    }
}

Describe 'Update-DFPathFromRegistry' {
    It 'appends only entries the session lacks, and never reorders' {
        $saved = $Env:Path
        try {
            $Env:Path = 'C:\a;C:\b'
            Mock Get-DFRegistryPath { 'C:\b;C:\new' }
            Update-DFPathFromRegistry
            $Env:Path | Should -Be 'C:\a;C:\b;C:\new'
        } finally { $Env:Path = $saved }
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `pwsh -NoProfile -c "Invoke-Pester tests/Invoke-DFInstallPlan.Tests.ps1 -Output Detailed"`
Expected: FAIL (functions not defined).

- [ ] **Step 3: Implement the host seams, `Private/DFInstallHost.ps1`**

```powershell
#Requires -Version 7.0

function Test-DFElevated {
    <#
    .SYNOPSIS
        Whether this shell runs elevated (as administrator).
    .OUTPUTS
        System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if (-not $IsWindows) { return [bool](id -u 2>$null) -eq 0 }
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-DFInteractiveHost {
    <#
    .SYNOPSIS
        Whether there is a person to ask: an interactive console host that isn't redirected.
    .OUTPUTS
        System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    [Environment]::UserInteractive -and $Host.Name -eq 'ConsoleHost' -and -not [Console]::IsInputRedirected
}

function Read-DFInstallChoice {
    <#
    .SYNOPSIS
        Asks one install question, showing the default; Enter keeps it.
    .PARAMETER Prompt
        The question.
    .PARAMETER Options
        The allowed answers.
    .PARAMETER Default
        The answer Enter gives.
    .OUTPUTS
        System.String. One of -Options.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Prompt, [Parameter(Mandatory)][string[]]$Options, [Parameter(Mandatory)][string]$Default)
    while ($true) {
        $a = Read-Host "$Prompt [$($Options -join '/')] (Enter = $Default)"
        if (-not $a) { return $Default }
        $hit = $Options | Where-Object { $_ -eq $a.Trim() } | Select-Object -First 1
        if ($hit) { return $hit }
        Write-Host "  Choose one of: $($Options -join ', ')"
    }
}
```

- [ ] **Step 4: Implement the seam, `Private/Invoke-DFInstallCommand.ps1`**

```powershell
#Requires -Version 7.0

function Expand-DFInstallArgv {
    <#
    .SYNOPSIS
        Fills a manager's argv template: {id} becomes every id, other {name} tokens come from -Values.
    .PARAMETER Template
        The argv template from installs.command or installs.feeds.
    .PARAMETER Values
        ids (string[]) plus any other token values (name, url).
    .OUTPUTS
        System.String[].
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string[]]$Template, [Parameter(Mandatory)][hashtable]$Values)
    [string[]]@(foreach ($t in $Template) {
        if ($t -eq '{id}') { @($Values.ids) }
        else { [regex]::Replace($t, '\{(\w+)\}', { param($m) [string]$Values[$m.Groups[1].Value] }) }
    })
}

function Invoke-DFInstallCommand {
    <#
    .SYNOPSIS
        Runs one package-manager command and returns its exit code and output. The only place DotForge runs a manager.
    .DESCRIPTION
        An argv runs as a native command; a function (installs.function, e.g.
        Install-PSResource) is called with -Arguments splatted. -Elevate runs
        the argv through gsudo. Tests mock this function.
    .PARAMETER Manager
        The manager's tool record (for messages).
    .PARAMETER Argv
        The command line, already expanded.
    .PARAMETER Function
        A PowerShell command to call instead of an argv.
    .PARAMETER Arguments
        Parameters for -Function.
    .PARAMETER Elevate
        Run through gsudo.
    .OUTPUTS
        PSCustomObject: ExitCode, Output.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Manager,
        [string[]]$Argv = @(),
        [string]$Function,
        [hashtable]$Arguments = @{},
        [switch]$Elevate
    )
    if ($Function) {
        try {
            $out = & $Function @Arguments -ErrorAction Stop 2>&1 | Out-String
            return [pscustomobject]@{ ExitCode = 0; Output = $out }
        } catch {
            return [pscustomobject]@{ ExitCode = 1; Output = $_.Exception.Message }
        }
    }
    $exe, $rest = if ($Elevate) { 'gsudo', $Argv } else { $Argv[0], @($Argv | Select-Object -Skip 1) }
    $out = & $exe @rest 2>&1 | Out-String
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
}
```

- [ ] **Step 5: Implement `Private/Update-DFPathFromRegistry.ps1`**

```powershell
#Requires -Version 7.0

function Get-DFRegistryPath {
    <#
    .SYNOPSIS
        Returns the persisted Machine and User PATH (what a new shell would get).
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    @([Environment]::GetEnvironmentVariable('Path', 'Machine'), [Environment]::GetEnvironmentVariable('Path', 'User')) -join [IO.Path]::PathSeparator
}

function Update-DFPathFromRegistry {
    <#
    .SYNOPSIS
        Appends PATH entries an installer wrote to the registry, so this shell finds new tools without a restart.
    .DESCRIPTION
        Only entries the session lacks are added, at the end, through
        Add-DFToPath. Nothing is removed or reordered, so session-only entries
        (fnm's multishell folder, a venv) survive.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param()
    $have = @($Env:Path -split [IO.Path]::PathSeparator | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\', '/') })
    foreach ($p in (Get-DFRegistryPath) -split [IO.Path]::PathSeparator) {
        $p = [Environment]::ExpandEnvironmentVariables($p.Trim())
        if ($p -and $p.TrimEnd('\', '/') -notin $have) { Add-DFToPath $p; $have += $p.TrimEnd('\', '/') }
    }
}
```

Check `Public/Add-DFToPath.ps1`'s parameters before relying on `Add-DFToPath $p`. If it prepends by default, pass its append switch (read the help with `Get-Help Add-DFToPath -Full`), and note the exact call in this step's commit message. If `Add-DFToPath` skips folders that don't exist, that's fine: an installer creates its folder before writing PATH.

- [ ] **Step 6: Implement `Private/Invoke-DFInstallPlan.ps1`**

```powershell
#Requires -Version 7.0

function Invoke-DFInstallPlan {
    <#
    .SYNOPSIS
        Runs an install plan stage by stage and reports each tool's result.
    .DESCRIPTION
        For each stage, each manager batch:
          - its feeds are added if missing (listed first, added once);
          - the batch runs as one command when the manager supports batch,
            else one command per tool;
          - a manager with installs.elevate runs through gsudo unless the shell
            is elevated; with neither, the batch is skipped with the reason.
        After the stage:
          - PATH is merged from the registry;
          - managers with installs.reactivate that installed something are
            re-activated (Register-DFTool -Name), so new runtimes reach PATH;
          - each tool is re-checked with no cached answer.
        A tool whose dependency failed or was skipped is skipped, naming it.
    .PARAMETER Plan
        From New-DFInstallPlan.
    .PARAMETER ToolDb
        Name -> tool record.
    .PARAMETER IsAvailable
        { param($record) } -> whether that tool is installed now.
    .PARAMETER ToolsPath
        Tools folder for re-activation. Default: the module's Tools/.
    .OUTPUTS
        PSCustomObject[]: Tool, Result (Installed, Failed, Skipped, NotFound), Detail.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Plan,
        [Parameter(Mandatory)][hashtable]$ToolDb,
        [Parameter(Mandatory)][scriptblock]$IsAvailable,
        [string]$ToolsPath
    )
    $pathArgs = if ($ToolsPath) { @{ ToolsPath = $ToolsPath } } else { @{} }
    $result = [ordered]@{}
    $set = { param($tool, $r, $d) $result[$tool] = [pscustomobject]@{ Tool = $tool; Result = $r; Detail = $d } }
    $badDep = {
        param($item)
        foreach ($d in $item.DependsOn) { if ($result.Contains($d) -and $result[$d].Result -in 'Failed', 'Skipped', 'NotFound') { return $d } }
    }
    $elevated = Test-DFElevated
    $gsudo = $ToolDb['gsudo']

    foreach ($stage in $Plan.Stages) {
        $reactivate = [System.Collections.Generic.List[string]]::new()
        foreach ($batch in $stage.Batches) {
            $m = $batch.Manager
            $ready = @(foreach ($it in $batch.Items) {
                $d = & $badDep $it
                if ($d) { & $set $it.Tool 'Skipped' "skipped: $d $($result[$d].Result.ToLower())" } else { $it }
            })
            if (-not $ready) { continue }
            $elevate = $m.installs.elevate -and -not $elevated
            if ($elevate -and -not ($gsudo -and (& $IsAvailable $gsudo))) {
                foreach ($it in $ready) { & $set $it.Tool 'Skipped' "$($m.name) needs an elevated shell: rerun as administrator, or add gsudo" }
                continue
            }
            # Feeds first, each once.
            if ($m.installs.feeds) {
                $feeds = @($ready | Where-Object { $_.Ref.Feed } | ForEach-Object { $_.Ref.Feed } | Sort-Object name -Unique)
                if ($feeds) {
                    $listed = (Invoke-DFInstallCommand -Manager $m -Argv (Expand-DFInstallArgv -Template $m.installs.feeds.list -Values @{})).Output
                    $names = @($listed -split "`r?`n" | ForEach-Object { ($_.Trim() -split '\s+')[0] })
                    foreach ($f in $feeds | Where-Object { $_.name -notin $names }) {
                        $r = Invoke-DFInstallCommand -Manager $m -Argv (Expand-DFInstallArgv -Template $m.installs.feeds.add -Values @{ name = $f.name; url = $f.url })
                        if ($r.ExitCode -ne 0) { Write-Warning "DotForge: could not add $($m.name) feed '$($f.name)' ($($f.url))." }
                    }
                }
            }
            $idOf = { param($it) if ($it.Ref.Feed -and $m.installs.feeds) { $m.installs.feeds.id.Replace('{feed}', $it.Ref.Feed.name).Replace('{id}', $it.Ref.Id) } else { $it.Ref.Id } }
            $groups = if ($m.installs.batch) { , $ready } else { $ready | ForEach-Object { , @($_) } }
            foreach ($group in $groups) {
                $ids = [string[]]@($group | ForEach-Object { & $idOf $_ })
                $r = if ($m.installs.function) {
                    $args2 = @{}
                    foreach ($p in $m.installs.args.PSObject.Properties) { $args2[$p.Name] = if ($p.Value -eq '{id}') { $ids } else { $p.Value } }
                    Invoke-DFInstallCommand -Manager $m -Function $m.installs.function -Arguments $args2
                } else {
                    Invoke-DFInstallCommand -Manager $m -Argv (Expand-DFInstallArgv -Template $m.installs.command -Values @{ ids = $ids }) -Elevate:$elevate
                }
                foreach ($it in $group) {
                    if ($r.ExitCode -eq 0) { & $set $it.Tool 'Installed' "via $($m.name)" }
                    else { & $set $it.Tool 'Failed' "$($m.name) failed: $($r.Output.Trim() -split "`r?`n" | Select-Object -Last 3 | Join-String -Separator ' / ')" }
                }
                if ($r.ExitCode -eq 0 -and $m.installs.reactivate -and -not $reactivate.Contains($m.name)) { $reactivate.Add($m.name) }
            }
        }
        foreach ($p in $stage.Provided) {
            $d = & $badDep $p
            if ($d) { & $set $p.Tool 'Skipped' "skipped: $d $($result[$d].Result.ToLower())" } else { & $set $p.Tool 'Installed' "comes with $($p.ProvidedBy)" }
        }

        Update-DFPathFromRegistry
        if ($reactivate.Count) { Register-DFTool -Name $reactivate.ToArray() @pathArgs 3>$null }
        foreach ($it in @($stage.Batches.Items) + @($stage.Provided)) {
            if ($result[$it.Tool].Result -ne 'Installed') { continue }
            $t = $ToolDb[$it.Tool]
            if (-not (Test-DFToolAvailable -Executable $t.executable -Type $t.type -Force)) {
                & $set $it.Tool 'NotFound' "installed, but '$($t.executable)' isn't found yet: open a new shell"
            }
        }
    }
    @($result.Values)
}
```

- [ ] **Step 7: Run the tests**

Run: `pwsh -NoProfile -c "Invoke-Pester tests/Invoke-DFInstallPlan.Tests.ps1 -Output Detailed"`
Expected: PASS. If the gsudo test fails because `New-DFInstallPlan` picked scoop for glow (InstallVia goes first, so it shouldn't), check `Get-DFInstallSourceOrder` reads `InstallVia` through `Get-DFConfig`.

- [ ] **Step 8: Commit**

```bash
git add Private/Invoke-DFInstallCommand.ps1 Private/Invoke-DFInstallPlan.ps1 Private/Update-DFPathFromRegistry.ps1 Private/DFInstallHost.ps1 tests/Invoke-DFInstallPlan.Tests.ps1
git commit -m "feat(install): run plans stage by stage through one process seam"
```

---

### Task 6: `Install-DFTool` (modes, choices, activation) and session hints

**Files:**
- Rewrite: `Public/Install-DFTool.ps1`
- Delete: `Private/Resolve-DFPackageManager.ps1`, `Private/Add-DFScoopBucket.ps1`, `tests/Resolve-DFPackageManager.Tests.ps1`, and the `Add-DFScoopBucket` tests (find with `git grep -l Add-DFScoopBucket -- tests`)
- Rewrite: `tests/Install-DFTool.Tests.ps1`
- Modify: `Private/Invoke-DFSessionActivation.ps1` (install hints on Missing status)

**Interfaces:**
- Consumes: `New-DFInstallPlan`, `Invoke-DFInstallPlan`, `Resolve-DFRequestedTools`, `Get-DFGroupDb`, `Get-DFToolStatus`, `Register-DFTool`, `Import-DFToolDb`, the host seams (Task 5).
- Produces: `Install-DFTool -Missing | -Name <string[]> [-Via <string>] [-UseDefaults] [-ToolsPath <string>] [-WhatIf]` → `[pscustomobject[]]` results (Task 5 shape, plus gaps as `Result = 'Gap'`). `-WhatIf` shows the plan only; there is no `-Confirm` prompt (interactive mode asks through `Read-DFInstallChoice`).

Before rewriting, check who calls `Resolve-DFPackageManager` / `Get-DFPackageManagerOrder` outside `Install-DFTool` (`git grep -n "Resolve-DFPackageManager\|Get-DFPackageManagerOrder" -- Private Public Tools`). Any picker or role hook that uses the order switches to `Get-DFBuiltInSourceOrder -ToolDb (Import-DFToolDb)` filtered to available managers. Keep `Get-DFPackageManagerOrder` only if a caller remains; delete it otherwise.

- [ ] **Step 1: Write the failing tests**

Replace `tests/Install-DFTool.Tests.ps1` with:

```powershell
BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    function script:New-InstallTools {
        $dir = Join-Path $TestDrive "it-$([guid]::NewGuid().ToString('N').Substring(0,6))"
        New-Item -ItemType Directory $dir | Out-Null
        @{
            scoop = '{ "name": "scoop", "executable": "scoop.cmd", "roles": { "package-manager": { "priority": 30 } }, "installs": { "from": "scoop", "command": ["scoop","install","{id}"], "batch": true } }'
            npm   = '{ "name": "npm", "executable": "npm.cmd", "roles": { "js-package-manager": { "priority": 30 } }, "packages": { "scoop": "nodejs" }, "installs": { "from": "npm", "command": ["npm","i","-g","{id}"], "batch": true } }'
            pnpm  = '{ "name": "pnpm", "executable": "pnpm.cmd", "roles": { "js-package-manager": { "priority": 20 } }, "packages": { "scoop": "pnpm" }, "installs": { "from": "npm", "command": ["pnpm","add","-g","{id}"], "batch": true } }'
            glow  = '{ "name": "glow", "executable": "glow.exe", "packages": { "scoop": "glow" } }'
            ish   = '{ "name": "ish", "executable": "is.cmd", "packages": { "npm": "@microsoft/inshellisense" } }'
        }.GetEnumerator() | ForEach-Object { Set-Content (Join-Path $dir "$($_.Key).json") $_.Value }
        $dir
    }
}

Describe 'Install-DFTool' {
    BeforeEach {
        Set-DFTestXdg; Reset-DFTestSession; Set-DFTestConfig $null
        $script:Tools = New-InstallTools
        $script:Installed = @('scoop.cmd')
        $script:Calls = [System.Collections.Generic.List[string]]::new()
        Mock Test-DFToolAvailable { $Executable -in $script:Installed }
        Mock Invoke-DFInstallCommand {
            $script:Calls.Add($Argv -join ' ')
            # An install makes its tools "installed".
            if ($Argv[1] -in 'install', 'i', 'add') { $script:Installed += @($Argv | Select-Object -Skip 2 | ForEach-Object { @{ glow = 'glow.exe'; '@microsoft/inshellisense' = 'is.cmd'; nodejs = 'npm.cmd'; pnpm = 'pnpm.cmd' }[$_] }) }
            [pscustomobject]@{ ExitCode = 0; Output = '' }
        }
        Mock Update-DFPathFromRegistry { }
        Mock Test-DFElevated { $false }
        Mock Write-DFConflictNotice { }
        Mock Test-DFInteractiveHost { $false }
        Mock Read-DFInstallChoice { $Default }
    }
    AfterEach { Restore-DFTestXdg; Set-DFTestConfig $null }

    It '-Missing installs the session''s missing tools and activates them' {
        Start-DFSession -Config @{ Tools = @('glow') } -ToolsPath $script:Tools 3>$null
        $r = Install-DFTool -Missing -UseDefaults -ToolsPath $script:Tools 6>$null
        $script:Calls | Should -Be @('scoop install glow')
        ($r | Where-Object Tool -eq glow).Result | Should -Be 'Installed'
        (Get-DFToolStatus -Name glow).State | Should -Be 'Active'
    }
    It '-WhatIf installs nothing' {
        Start-DFSession -Config @{ Tools = @('glow') } -ToolsPath $script:Tools 3>$null
        $null = Install-DFTool -Missing -WhatIf -ToolsPath $script:Tools 6>$null
        $script:Calls | Should -BeNullOrEmpty
    }
    It 'a non-interactive host without -UseDefaults reports a gap and its dependents, and asks nothing' {
        $r = Install-DFTool -Name ish -ToolsPath $script:Tools 3>$null 6>$null
        Should -Invoke Read-DFInstallChoice -Times 0
        $script:Calls | Should -BeNullOrEmpty
        ($r | Where-Object Tool -eq ish).Result | Should -Be 'Gap'
        ($r | Where-Object Tool -eq ish).Detail | Should -Match 'npm, pnpm'
    }
    It '-UseDefaults fills a gap with the role''s top member and installs it first' {
        $null = Install-DFTool -Name ish -UseDefaults -ToolsPath $script:Tools 3>$null 6>$null
        $script:Calls | Should -Be @('scoop install nodejs', 'npm i -g @microsoft/inshellisense')
    }
    It 'interactive mode asks for each open choice, showing the default, and uses the answer' {
        Mock Test-DFInteractiveHost { $true }
        # Pick pnpm for the manager question; say yes to the plan.
        Mock Read-DFInstallChoice { if ($Options -contains 'pnpm') { 'pnpm' } else { 'y' } }
        $null = Install-DFTool -Name ish -ToolsPath $script:Tools 3>$null 6>$null
        Should -Invoke Read-DFInstallChoice -Times 1 -ParameterFilter { $Default -eq 'npm' -and $Options -contains 'pnpm' }
        Should -Invoke Read-DFInstallChoice -Times 1 -ParameterFilter { $Options -contains 'y' }
        $script:Calls | Should -Be @('scoop install pnpm', 'pnpm add -g @microsoft/inshellisense')
    }
    It 'warns that a tool installed by name but not in Tools loads only this session' {
        Start-DFSession -Config @{ Tools = @() } -ToolsPath $script:Tools 3>$null
        $null = Install-DFTool -Name glow -UseDefaults -ToolsPath $script:Tools -WarningVariable w 3>$null 6>$null
        "$w" | Should -Match 'glow.*add it to Tools'
    }
    It 'does not reinstall what a previous partial run already installed' {
        $script:Installed += 'glow.exe'
        $null = Install-DFTool -Name glow -UseDefaults -ToolsPath $script:Tools 3>$null 6>$null
        $script:Calls | Should -BeNullOrEmpty
    }
    It '-Via installs from the named source for this call' {
        $null = Install-DFTool -Name glow -Via scoop -UseDefaults -ToolsPath $script:Tools 3>$null 6>$null
        $script:Calls | Should -Be @('scoop install glow')
    }
}

Describe 'Start-DFSession install hints' {
    BeforeEach { Set-DFTestXdg; Reset-DFTestSession; Set-DFTestConfig $null; $script:Tools = New-InstallTools; Mock Write-DFConflictNotice { } }
    AfterEach { Restore-DFTestXdg; Set-DFTestConfig $null }
    It 'reads no manager record when nothing is missing' {
        Mock Test-DFToolAvailable { $true }
        Mock New-DFInstallPlan { }
        Start-DFSession -Config @{ Tools = @('glow') } -ToolsPath $script:Tools 3>$null
        Should -Invoke New-DFInstallPlan -Times 0
    }
    It 'says how a missing tool would be installed' {
        Mock Test-DFToolAvailable { $Executable -eq 'scoop.cmd' }
        Start-DFSession -Config @{ Tools = @('glow') } -ToolsPath $script:Tools 3>$null
        (Get-DFToolStatus -Name glow).Detail | Should -Match 'Install-DFTool -Missing will install it via scoop'
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `pwsh -NoProfile -c "Invoke-Pester tests/Install-DFTool.Tests.ps1 -Output Detailed"`
Expected: FAIL. The old `Install-DFTool` has no `-Missing`/`-UseDefaults`/`-Via`.

- [ ] **Step 3: Rewrite `Public/Install-DFTool.ps1`**

```powershell
#Requires -Version 7.0

function Install-DFTool {
    <#
    .SYNOPSIS
        Installs missing tools: everything the session reported missing (-Missing), or the named tools.
    .DESCRIPTION
        Builds one plan for all targets: a source and manager per tool
        (InstallVia, the tool's install.prefer, InstallOrder, DotForge's
        order; ExcludeSources never used unless InstallVia names it), in
        stages so that a manager or runtime installs before the tools that
        need it. Nothing you didn't ask for is installed, unless you choose it
        or pass -UseDefaults.

        Modes:
          - Interactive (default, when someone can answer): each open choice
            shows its default ("Enter keeps it"); then the whole plan is shown,
            including third-party feeds and elevation, and confirmed once.
          - -UseDefaults: no questions; DotForge's and the tool specs'
            defaults fill every gap.
          - No one to ask and no -UseDefaults (a script): only what needs no
            decision installs; each gap is reported with the tools waiting on it.
          - -WhatIf: the plan only.

        Afterwards, new tools are activated in this session. A tool you named
        that isn't in your Tools setting is active only until the shell closes.
    .PARAMETER Missing
        Install the tools Get-DFToolStatus -Missing lists.
    .PARAMETER Name
        Tools (and +groups) to install.
    .PARAMETER Via
        Install the named tools from this source, for this call only.
    .PARAMETER UseDefaults
        Don't ask: take the default for every open choice.
    .PARAMETER ToolsPath
        Tools folder. Default: the module's Tools/.
    .EXAMPLE
        Install-DFTool -Missing

        Asks about anything undecided, shows the plan, and installs it.
    .EXAMPLE
        Install-DFTool -Name glow -Via scoop -UseDefaults

        Installs glow from scoop without asking.
    .EXAMPLE
        Install-DFTool -Missing -WhatIf

        Shows what would be installed, in which stage, and from where.
    .OUTPUTS
        PSCustomObject. One per tool: Tool, Result (Installed, Failed, Skipped, NotFound, Gap), Detail.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/getting-started.md
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Missing')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Missing')][switch]$Missing,
        [Parameter(Mandatory, ParameterSetName = 'Name')][string[]]$Name,
        [Parameter(ParameterSetName = 'Name')][string]$Via,
        [switch]$UseDefaults,
        [string]$ToolsPath
    )
    $pathArgs = if ($ToolsPath) { @{ ToolsPath = $ToolsPath } } else { @{} }
    $db = Import-DFToolDb @pathArgs

    $targets = if ($Missing) {
        @(Get-DFToolStatus -Missing 3>$null | ForEach-Object Name)
    } else {
        @(Resolve-DFRequestedTools -Tools $Name -GroupDb (Get-DFGroupDb) -KnownTools @($db.Keys) -Source 'Install-DFTool' | ForEach-Object Name)
    }
    # Fresh checks: a previous partial run may have installed some of these.
    $isAvailable = { param($r) $r -and (Test-DFToolAvailable -Executable $r.executable -Type $r.type -Force) }
    $targets = @($targets | Where-Object { $db.ContainsKey($_) -and -not (& $isAvailable $db[$_]) })
    if (-not $targets) { Write-Host 'DotForge: nothing to install.'; return }

    $viaMap = @{}
    if ($Via) { foreach ($t in $targets) { $viaMap[$t] = $Via } }

    # Choices: one question per open gap source, until nothing more can be decided.
    $interactive = -not $UseDefaults -and (Test-DFInteractiveHost)
    $choice = @{}
    while ($true) {
        $plan = New-DFInstallPlan -Name $targets -ToolDb $db -IsAvailable $isAvailable -Choice $choice -Via $viaMap
        $open = @($plan.Gaps | Where-Object { $_.Options -and $_.Source -and -not $choice.ContainsKey($_.Source) })
        if (-not $open -or -not ($UseDefaults -or $interactive)) { break }
        $g = $open[0]
        $choice[$g.Source] = if ($UseDefaults) { $g.Options[0] }
            else { Read-DFInstallChoice -Prompt "$($g.Tool) needs a manager for $($g.Source)" -Options $g.Options -Default $g.Options[0] }
    }

    Write-DFInstallPlan -Plan $plan
    $gapRows = @(Get-DFInstallGapResult -Plan $plan)
    # -WhatIf: the plan only. Interactive: confirm once. -UseDefaults, or no one
    # to ask: no prompt (without -UseDefaults, only decision-free tools are planned).
    if (-not $plan.Items -or $WhatIfPreference) { return $gapRows }
    if ($interactive -and (Read-DFInstallChoice -Prompt "Install $(@($plan.Items).Count) tool(s) as planned above?" -Options 'y', 'n' -Default 'y') -ne 'y') { return $gapRows }

    $results = @(Invoke-DFInstallPlan -Plan $plan -ToolDb $db -IsAvailable $isAvailable @pathArgs)
    $done = @($results | Where-Object Result -eq 'Installed' | ForEach-Object Tool)
    if ($done) {
        Register-DFTool -Name $done @pathArgs 3>$null
        $requested = @(Resolve-DFRequestedTools -Tools @(Get-DFConfig Tools) -GroupDb (Get-DFGroupDb) -KnownTools @($db.Keys) 3>$null | ForEach-Object Name)
        foreach ($t in $done | Where-Object { $_ -notin $requested -and $_ -in $targets }) {
            Write-Warning "DotForge: $t is installed and active now; add it to Tools to load it in future sessions."
        }
    }
    $all = @($results) + $gapRows
    Write-DFInstallSummary -Result $all
    $all
}
```

The interactive confirmation goes through `Read-DFInstallChoice`, the same seam as the choices, so tests answer it and a non-interactive host never reaches it. `ShouldProcess` is there only for `-WhatIf`. `-Via` is passed down as a map (`New-DFInstallPlan -Via`, Task 3/4 signatures), so session config is never modified.

Add these private helpers in the same file, below `Install-DFTool` (each with help):

```powershell
function Write-DFInstallPlan {
    <#
    .SYNOPSIS
        Prints an install plan: stages, manager batches, feeds to add, elevation, and gaps.
    .PARAMETER Plan
        From New-DFInstallPlan.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Plan)
    foreach ($s in $Plan.Stages) {
        $parts = foreach ($b in $s.Batches) {
            $feeds = @($b.Items | Where-Object { $_.Ref.Feed } | ForEach-Object { "+ feed '$($_.Ref.Feed.name)' ($($_.Ref.Feed.url))" } | Select-Object -Unique)
            $elev = if ($b.Manager.installs.elevate) { ' (needs admin: 1 UAC prompt via gsudo)' } else { '' }
            "$($b.Manager.name)$elev`: $(@($feeds) + @($b.Items | ForEach-Object { "$($_.Tool) ($($_.Ref.Id))" }) -join ' · ')"
        }
        $parts += @($s.Provided | ForEach-Object { "$($_.Tool) (comes with $($_.ProvidedBy))" })
        Write-Host ("  stage {0}  {1}" -f $s.Number, ($parts -join "`n           "))
    }
    foreach ($g in $Plan.Gaps) {
        Write-Host "  not installed: $($g.Tool) — $($g.Reason)$(if ($g.Dependents) { "; also waiting: $($g.Dependents -join ', ')" })" -ForegroundColor Yellow
    }
}

function Get-DFInstallGapResult {
    <#
    .SYNOPSIS
        Turns a plan's gaps into result rows (Result 'Gap').
    .PARAMETER Plan
        From New-DFInstallPlan.
    .OUTPUTS
        PSCustomObject[].
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Plan)
    foreach ($g in $Plan.Gaps) {
        [pscustomobject]@{ Tool = $g.Tool; Result = 'Gap'; Detail = "$($g.Reason)$(if ($g.Dependents) { "; also waiting: $($g.Dependents -join ', ')" })" }
        foreach ($d in $g.Dependents) { [pscustomobject]@{ Tool = $d; Result = 'Skipped'; Detail = "waits on $($g.Tool)" } }
    }
}

function Write-DFInstallSummary {
    <#
    .SYNOPSIS
        Prints one line per result group: installed, failed (with output), skipped, not found, gaps.
    .PARAMETER Result
        Rows from Invoke-DFInstallPlan and Get-DFInstallGapResult.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Result = @())
    foreach ($g in $Result | Group-Object Result) {
        Write-Host "  $($g.Name): $(@($g.Group | ForEach-Object { if ($_.Result -eq 'Installed') { $_.Tool } else { "$($_.Tool) ($($_.Detail))" } }) -join ', ')"
    }
}
```

- [ ] **Step 4: Session hints for Missing tools**

In `Private/Invoke-DFSessionActivation.ps1`, at the end of `Invoke-DFSessionActivation` (after the activation loop), add:

```powershell
    # The install layer is built only when something is missing (no cost on a
    # healthy machine): each Missing tool's detail says how it would install.
    $missingNames = @($status.Values | Where-Object { $_.State -eq 'Missing' -and -not $_.PSObject.Properties['FallbackTool'] } | ForEach-Object Name)
    if ($missingNames) {
        $all = Import-DFToolDb @pathArgs
        $plan = New-DFInstallPlan -Name $missingNames -ToolDb $all -IsAvailable { param($r) $r -and (Test-DFToolAvailable -Executable $r.executable -Type $r.type) } 3>$null
        foreach ($it in $plan.Items) {
            $how = if ($it.ProvidedBy) { "comes with $($it.ProvidedBy)" } else { "via $($it.Manager.name)" }
            $s = $status[$it.Tool]; $s.Detail = "$($s.Detail); Install-DFTool -Missing will install it $how"
        }
        foreach ($g in $plan.Gaps) { $s = $status[$g.Tool]; if ($s) { $s.Detail = "$($s.Detail); can't install yet: $($g.Reason)" } }
    }
```

`Detail` must be settable. If `New-DFToolStatus` returns a read-only object, it doesn't (it's a `[pscustomobject]`), so this works.

- [ ] **Step 5: Delete the replaced code**

Run: `git rm Private/Resolve-DFPackageManager.ps1 Private/Add-DFScoopBucket.ps1 tests/Resolve-DFPackageManager.Tests.ps1`, plus the `Add-DFScoopBucket` test file if it exists. Then `git grep -n "Resolve-DFPackageManager\|Get-DFPackageManagerOrder\|Add-DFScoopBucket\|PackageManagerOrder" -- Private Public Tools tests examples docs/guide` and fix each remaining caller as described above this task's steps.

- [ ] **Step 6: Run the tests**

Run: `pwsh -NoProfile -c "Invoke-Pester tests/Install-DFTool.Tests.ps1, tests/Start-DFSession.Tests.ps1, tests/Register-DFTool.Tests.ps1, tests/Requires.Tests.ps1 -Output Normal"`
Expected: PASS. `Start-DFSession` tests that assert an exact `Detail` (e.g. "'gamma.exe' is not installed") may now carry an appended hint. Change those assertions to `-Match` on the original text.

- [ ] **Step 7: Commit**

```bash
git add -A Public/Install-DFTool.ps1 Private tests
git commit -m "feat(install)!: Install-DFTool -Missing, interactive and -UseDefaults modes"
```

---

### Task 7: Runtimes (node, bun, pnpm) and `role:` in `after`

**Files:**
- Create: `Tools/node.json`, `Tools/bun.json`, `Tools/pnpm.json`
- Modify: `Tools/fnm.json`, `Tools/mise.json`, `Tools/npm.json`, `Tools/inshellisense.json`, `data/roles.json` (js-runtime description)
- Modify: `Private/Invoke-DFSessionActivation.ps1` (`after` role entries), `Private/Test-DFToolSchema.ps1` (`after` pattern)
- Test: `tests/Requires.Tests.ps1` (extend), `tests/Runtimes.Tests.ps1` (new)

**Interfaces:**
- Consumes: `Resolve-DFToolRequirements` edges (`-Edges`), `Invoke-DFTopoSort -ExtraEdges`.
- Produces: `after` entries of the form `role:<name>`, which order the tool after every *requested* member of that role.

- [ ] **Step 1: Write the failing tests**

Add to `tests/Requires.Tests.ps1` inside `Describe 'requires (tools and role:<name>)'`:

```powershell
    It 'orders a tool after every requested member of a role named in after' {
        New-ReqTool 'rt' ', "after": ["role:version-manager"]'
        New-ReqTool 'vm1' ', "roles": { "version-manager": {} }'
        $script:Installed = 'rt.exe', 'vm1.exe'
        Start-DFSession -Config @{ Tools = @('rt', 'vm1') } -ToolsPath $script:Tools 3>$null
        $global:DFTestOrder | Should -Be @('vm1', 'rt')
    }
```

`tests/Runtimes.Tests.ps1`:

```powershell
BeforeAll {
    $script:J = @{}
    foreach ($n in 'node', 'bun', 'pnpm', 'npm', 'fnm', 'mise', 'inshellisense') {
        $script:J[$n] = Get-Content "$PSScriptRoot/../Tools/$n.json" -Raw | ConvertFrom-Json
    }
}
Describe 'runtimes and version managers (install spec, section 8)' {
    It 'makes node and bun the js-runtime members, and takes fnm and mise out' {
        $script:J.node.roles.PSObject.Properties.Name | Should -Contain 'js-runtime'
        $script:J.bun.roles.PSObject.Properties.Name | Should -Contain 'js-runtime'
        $script:J.fnm.roles.PSObject.Properties.Name | Should -Not -Contain 'js-runtime'
        $script:J.mise.roles.PSObject.Properties.Name | Should -Not -Contain 'js-runtime'
    }
    It 'installs node through a version manager first, and checks it after them' {
        $script:J.node.install.prefer[0] | Should -Be 'fnm'
        $script:J.node.after | Should -Contain 'role:version-manager'
    }
    It 'makes npm come with node, and bun a js-package-manager too' {
        $script:J.npm.requires | Should -Contain 'node'
        $script:J.bun.roles.PSObject.Properties.Name | Should -Contain 'js-package-manager'
        $script:J.pnpm.installs.from | Should -Be 'npm'
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `pwsh -NoProfile -c "Invoke-Pester tests/Runtimes.Tests.ps1, tests/Requires.Tests.ps1 -Output Detailed"`
Expected: FAIL (no node/bun/pnpm records; `after` role entries ignored).

- [ ] **Step 3: Support `role:` in `after`**

In `Private/Test-DFToolSchema.ps1`, the `after` check accepts the same pattern as `requires`:

```powershell
    if ($null -ne $after -and ($after -isnot [array] -or @($after | Where-Object { $_ -isnot [string] -or $_ -notmatch '^(role:)?[A-Za-z0-9][A-Za-z0-9._-]*$' }).Count)) {
        $errs.Add('after must be an array of tool names or role:<role> entries')
    }
```

In `Private/Invoke-DFSessionActivation.ps1`, after the `Resolve-DFToolRequirements` call and before `Invoke-DFTopoSort`, add the role edges from `after`:

```powershell
    foreach ($r in $records) {
        foreach ($a in @($r.after | Where-Object { $_ -like 'role:*' })) {
            $role = $a.Substring(5)
            foreach ($m in @($db.Values | Where-Object { $_.name -ne $r.name -and $_.roles.PSObject.Properties[$role] })) {
                $edges[$r.name] = @(@($edges[$r.name]) + $m.name | Where-Object { $_ })
            }
        }
    }
```

`Invoke-DFTopoSort` already ignores a plain `after` entry naming no requested tool, so `role:` strings left in `$t.after` add no edge there. Verify by reading `Private/Invoke-DFTopoSort.ps1:40-46`.

- [ ] **Step 4: Add the records**

`Tools/node.json`:

```json
{
  "name": "node",
  "description": "Node.js JavaScript runtime",
  "tags": ["node", "javascript", "dev", "runtime"],
  "executable": "node.exe",
  "roles": { "js-runtime": { "priority": 20 } },
  "after": ["role:version-manager"],
  "packages": { "fnm": "lts", "mise": "node@lts", "scoop": "nodejs-lts", "winget": "OpenJS.NodeJS.LTS", "choco": "nodejs-lts" },
  "install": { "prefer": ["fnm", "mise"] },
  "aliases": {},
  "picker": null
}
```

`Tools/bun.json`:

```json
{
  "name": "bun",
  "description": "Bun JavaScript runtime and package manager",
  "tags": ["javascript", "dev", "runtime", "package-manager"],
  "executable": "bun.exe",
  "roles": { "js-runtime": { "priority": 10 }, "js-package-manager": { "priority": 10 } },
  "after": ["role:version-manager"],
  "packages": { "scoop": "bun", "winget": "Oven-sh.Bun", "npm": "bun" },
  "installs": { "from": "npm", "command": ["bun", "add", "-g", "{id}"], "batch": true },
  "aliases": {},
  "picker": null
}
```

`Tools/pnpm.json`:

```json
{
  "name": "pnpm",
  "description": "Fast, disk-efficient JavaScript package manager",
  "tags": ["javascript", "dev", "package-manager"],
  "executable": "pnpm.cmd",
  "roles": { "js-package-manager": { "priority": 20 } },
  "requires": ["role:js-runtime"],
  "packages": { "scoop": "pnpm", "winget": "pnpm.pnpm", "npm": "pnpm" },
  "installs": { "from": "npm", "command": ["pnpm", "add", "-g", "{id}"], "batch": true },
  "aliases": {},
  "picker": null
}
```

- **`Tools/npm.json`:** `"requires": ["node"]` (replacing `role:js-runtime`).
- **`Tools/fnm.json`, `Tools/mise.json`:** remove `"js-runtime"` from `roles`.
- **`data/roles.json` `js-runtime` description:** `"Provides a JavaScript runtime on PATH (node, bun). Tools that need one declare requires: [\"role:js-runtime\"]."`
- **`tests/Requires.Tests.ps1`'s shipped test:** change `'gives npm and inshellisense a JavaScript runtime, and puts fnm and mise in that role'` to assert `npm.requires -contains 'node'`, `inshellisense.requires -contains 'role:js-runtime'`, and `node.roles.'js-runtime'` present.

Check the role contract (`tests/Roles.Contract.Tests.ps1`) and `tests/Tools.*` shipped-record tests: each new tool needs whatever every shipped record needs (e.g. a `Tools.md` row or a category in `data/categories*` if a test demands it). Fix what they report.

- [ ] **Step 5: Run the tests**

Run: `pwsh -NoProfile -c "Invoke-Pester tests/Runtimes.Tests.ps1, tests/Requires.Tests.ps1, tests/Roles.Contract.Tests.ps1, tests/Test-DFToolSchema.Tests.ps1, tests/Installs.Schema.Tests.ps1 -Output Normal"`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Tools data Private tests
git commit -m "feat(tools): node and bun are the js-runtime members; version managers install them"
```

---

### Task 8: Pickers, catalog hints, and `Invoke-DFToolSetup`

**Files:**
- Create: `Private/Format-DFInstallCommand.ps1`, `Public/Invoke-DFToolSetup.ps1`, `tests/Format-DFInstallCommand.Tests.ps1`, `tests/Invoke-DFToolSetup.Tests.ps1`
- Modify: `Tools/scoop.ps1:105`, `Tools/winget.ps1:63`, `Tools/choco.ps1:91`; `Private/DFCatalog.Choco.ps1:209`, `DFCatalog.Crates.ps1:119`, `DFCatalog.Npm.ps1:162`, `DFCatalog.PSGallery.ps1:91`, `DFCatalog.Scoop.ps1:374`, `DFCatalog.Winget.ps1:375`; `DotForge.psd1` (export `Invoke-DFToolSetup`)

**Interfaces:**
- Produces:
  - `Format-DFInstallCommand -Manager <record> [-Id <string>] [-Feed <string>]` → `[string]`. It is the manager's install command as one line. With no `-Id`, `{id}` is left as `{0}` (a format string for pickers). With `-Feed`, the id is formed by `installs.feeds.id`.
  - `Get-DFInstallHint -Source <string> -Id <string> [-Feed <string>]` → `[string]` or `$null`. It uses the best manager for the source (`Get-DFSourceManager` over `Import-DFToolDb`).
  - `Invoke-DFToolSetup -Name <string> [-Force] [-ToolsPath <string>]` → none.

- [ ] **Step 1: Write the failing tests**

`tests/Format-DFInstallCommand.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    $script:Db = Import-DFToolDb -ToolsPath "$PSScriptRoot/../Tools" -Force
}
Describe 'Format-DFInstallCommand' {
    It 'formats a manager''s command for an id, and as a {0} template' {
        Format-DFInstallCommand -Manager $script:Db.scoop -Id glow | Should -Be 'scoop install glow'
        Format-DFInstallCommand -Manager $script:Db.scoop | Should -Be 'scoop install {0}'
    }
    It 'forms a feed-qualified id' {
        Format-DFInstallCommand -Manager $script:Db.scoop -Id ps-dotenv -Feed insomnia | Should -Be 'scoop install insomnia/ps-dotenv'
    }
    It 'formats a function manager' {
        Format-DFInstallCommand -Manager $script:Db.psresource -Id PSFzf | Should -Match '^Install-PSResource -Name PSFzf'
    }
}
Describe 'pickers and catalog hints read installs' {
    It 'has no hard-coded install command left in the picker sidecars or catalog providers' {
        $hits = git -C "$PSScriptRoot/.." grep -n -E "InstallCommand\s*=\s*'|InstallHint\s+""(scoop|winget|choco|cargo|npm) install|InstallHint\s+""Install-PSResource" -- Tools Private
        $hits | Should -BeNullOrEmpty
    }
}
```

`tests/Invoke-DFToolSetup.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
}
Describe 'Invoke-DFToolSetup' {
    BeforeEach {
        Set-DFTestXdg; Reset-DFTestSession; Set-DFTestConfig $null
        $script:Tools = Join-Path $TestDrive "su-$([guid]::NewGuid().ToString('N').Substring(0,6))"
        New-Item -ItemType Directory (Join-Path $script:Tools 'st') -Force | Out-Null
        Set-Content (Join-Path $script:Tools 'st' 'c.conf') 'default' -NoNewline
        '{ "name": "st", "executable": "st.exe", "setup": { "seed": { "${XDG_CONFIG_HOME}/st/c.conf": "st/c.conf" } } }' |
            Set-Content (Join-Path $script:Tools 'st.json')
        Mock Test-DFToolAvailable { $true }
        Mock Write-DFConflictNotice { }
        Start-DFSession -Config @{ Tools = @('st') } -ToolsPath $script:Tools 3>$null
        $script:Dest = Join-Path $Env:XDG_CONFIG_HOME 'st' 'c.conf'
    }
    AfterEach { Restore-DFTestXdg; Set-DFTestConfig $null }

    It 'brings back a deleted seed' {
        Remove-Item $script:Dest
        Invoke-DFToolSetup -Name st -ToolsPath $script:Tools
        Get-Content $script:Dest -Raw | Should -Be 'default'
    }
    It 'keeps an edited seed without -Force, and overwrites it with -Force' {
        Set-Content $script:Dest 'mine' -NoNewline
        Invoke-DFToolSetup -Name st -ToolsPath $script:Tools
        Get-Content $script:Dest -Raw | Should -Be 'mine'
        Invoke-DFToolSetup -Name st -Force -Confirm:$false -ToolsPath $script:Tools
        Get-Content $script:Dest -Raw | Should -Be 'default'
    }
    It 'refuses a tool that isn''t active in the session' {
        { Invoke-DFToolSetup -Name nope -ToolsPath $script:Tools -ErrorAction Stop } | Should -Throw '*not active*'
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `pwsh -NoProfile -c "Invoke-Pester tests/Format-DFInstallCommand.Tests.ps1, tests/Invoke-DFToolSetup.Tests.ps1 -Output Detailed"`
Expected: FAIL (functions not defined; hard-coded commands present).

- [ ] **Step 3: Implement `Private/Format-DFInstallCommand.ps1`**

```powershell
#Requires -Version 7.0

function Format-DFInstallCommand {
    <#
    .SYNOPSIS
        A manager's install command as one line of text, for a picker, a catalog hint, or the plan.
    .PARAMETER Manager
        The manager's tool record (has installs).
    .PARAMETER Id
        The package id. Omitted: {0} stands in for it (a format string).
    .PARAMETER Feed
        A feed name; the id is then formed by installs.feeds.id.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][pscustomobject]$Manager, [string]$Id, [string]$Feed)
    $i = $Manager.installs
    $idText = if ($Id) { $Id } else { '{0}' }
    if ($Feed -and $i.feeds) { $idText = $i.feeds.id.Replace('{feed}', $Feed).Replace('{id}', $idText) }
    if ($i.function) {
        $args = @($i.args.PSObject.Properties | ForEach-Object { "-$($_.Name) $(if ($_.Value -eq '{id}') { $idText } elseif ($_.Value -is [bool]) { '' } else { $_.Value })".TrimEnd() })
        return (@($i.function) + $args) -join ' '
    }
    (@($i.command | ForEach-Object { if ($_ -eq '{id}') { $idText } else { $_ } })) -join ' '
}

function Get-DFInstallHint {
    <#
    .SYNOPSIS
        The command that installs one catalog package, from the best manager for its source.
    .PARAMETER Source
        The catalog source (scoop, winget, choco, npm, crates, psgallery).
    .PARAMETER Id
        The package id.
    .PARAMETER Feed
        The feed (e.g. a scoop bucket), when the id needs one.
    .OUTPUTS
        System.String, or nothing when no manager installs from the source.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Id, [string]$Feed)
    $m = Get-DFSourceManager -Source $Source -ToolDb (Import-DFToolDb) | Select-Object -First 1
    if ($m) { Format-DFInstallCommand -Manager $m -Id $Id -Feed $Feed }
}
```

The function manager's bool arguments (`TrustRepository`) render as switches (`-TrustRepository`). Check the third test's expected text against the output, and adjust the test (not the code) only if the switch rendering is the difference.

- [ ] **Step 4: Switch the pickers and providers**

- **`Tools/scoop.ps1`, `Tools/winget.ps1`, `Tools/choco.ps1`:** replace the literal with `InstallCommand = Format-DFInstallCommand -Manager $DFCurrentTool`. Companions run with `$DFCurrentTool` set; if the picker spec is built later, inside a function, capture the value in a variable at companion top level first.
- **Each catalog provider:** replace the literal `-InstallHint "..."` with a call to `Get-DFInstallHint`:
  - Scoop: `-InstallHint (Get-DFInstallHint -Source scoop -Id $name -Feed $bucket)`. Keep the main bucket qualified as before, or pass `-Feed` only when `$bucket -ne 'main'`, whichever matches the existing tests in `tests/DFCatalog.Scoop.Tests.ps1`.
  - Winget: `-InstallHint (Get-DFInstallHint -Source winget -Id $PackageId)`.
  - Choco: `-InstallHint (Get-DFInstallHint -Source choco -Id $PackageId)`.
  - Crates: `-InstallHint (Get-DFInstallHint -Source crates -Id $crate.name)`.
  - Npm: `-InstallHint (Get-DFInstallHint -Source npm -Id $doc.name)`.
  - PSGallery: `-InstallHint (Get-DFInstallHint -Source psgallery -Id $PackageId)`.

  Run `tests/DFCatalog*.Tests.ps1`. Hints that were asserted literally (e.g. `winget install --id X --exact`) now include the manager's full flags. Update those expectations to `Format-DFInstallCommand`'s output.

- [ ] **Step 5: Implement `Public/Invoke-DFToolSetup.ps1`**

```powershell
#Requires -Version 7.0

function Invoke-DFToolSetup {
    <#
    .SYNOPSIS
        Runs a tool's one-time setup again: its seeded config files, then its setup script.
    .DESCRIPTION
        Setup normally runs once per machine, the first time a tool is
        activated, and is then recorded so it never repeats (a config file you
        delete stays deleted). This clears that record for one tool and runs
        setup now. A seeded file that exists is kept, unless -Force, which
        overwrites it with DotForge's default after confirmation. The tool
        must be active in this session.
    .PARAMETER Name
        The tool.
    .PARAMETER Force
        Overwrite seeded files that exist (asks first).
    .PARAMETER ToolsPath
        Tools folder. Default: the module's Tools/.
    .EXAMPLE
        Invoke-DFToolSetup -Name fastfetch

        Recreates fastfetch's default config if you deleted it.
    .EXAMPLE
        Invoke-DFToolSetup -Name fastfetch -Force

        Replaces your fastfetch config with DotForge's default.
    .OUTPUTS
        None.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([Parameter(Mandatory)][string]$Name, [switch]$Force, [string]$ToolsPath)
    $s = Get-DFToolStatus -Name $Name 3>$null
    if (-not $s -or $s.State -ne 'Active') { Write-Error "DotForge: $Name is not active in this session; Start-DFSession with it in Tools first."; return }
    $pathArgs = if ($ToolsPath) { @{ ToolsPath = $ToolsPath } } else { @{} }
    $tool = (Import-DFToolDb -Name $Name @pathArgs)[$Name]
    $toolsDir = ConvertTo-DFPath $(if ($ToolsPath) { $ToolsPath } else { Join-Path $PSScriptRoot '../Tools' })
    if ($Force) {
        foreach ($p in @($tool.setup?.seed?.PSObject.Properties)) {
            $dest = ConvertTo-DFPath (Expand-DFXdgPath $p.Name)
            if ((Test-Path -LiteralPath $dest) -and $PSCmdlet.ShouldProcess($dest, 'Overwrite with the default')) { Remove-Item -LiteralPath $dest }
        }
    }
    Clear-DFToolSetupState -Name $Name
    Invoke-DFToolCompanion -Tool $tool -ToolsPath $toolsDir -SkipSetup @() -SetupOnly
}
```

This needs two small additions, each with a test in `tests/Invoke-DFToolCompanion.Tests.ps1` / `tests/Complete-DFToolSetup.Tests.ps1`:
- **`Clear-DFToolSetupState -Name`** in `Private/Get-DFToolSetupState.ps1`: reads the state, removes the tool's property, and writes it back with `Write-DFFileAtomic`.
- **A `-SetupOnly` switch on `Invoke-DFToolCompanion`:** it runs the setup step and returns before the companion. Test: with `-SetupOnly`, a companion that appends to a global list doesn't run, and the seed is copied.

Add `'Invoke-DFToolSetup'` to `FunctionsToExport` in `DotForge.psd1`.

- [ ] **Step 6: Run the tests**

Run: `pwsh -NoProfile -c "Invoke-Pester tests/Format-DFInstallCommand.Tests.ps1, tests/Invoke-DFToolSetup.Tests.ps1, tests/Invoke-DFToolCompanion.Tests.ps1, tests/Complete-DFToolSetup.Tests.ps1, tests/Invoke-DFPackageManagerPicker.Tests.ps1, tests/DFCatalog.Core.Tests.ps1, tests/DFCatalog.Scoop.Tests.ps1, tests/DFCatalog.Winget.Tests.ps1, tests/DFCatalog.WebProviders.Tests.ps1, tests/DFCatalogDetailProviders.OData.Tests.ps1, tests/Docs.Help.Tests.ps1 -Output Normal"`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add -A Private Public Tools DotForge.psd1 tests
git commit -m "feat: pickers and catalog hints read installs; Invoke-DFToolSetup"
```

---

### Task 9: Docs, examples, full verification

**Files:**
- Modify: `docs/guide/getting-started.md`, `docs/guide/configuration.md`, `docs/guide/writing-a-tool.md`, `docs/guide/troubleshooting.md`, `docs/guide/tools.md`, `examples/*.ps1` (any `Install-DFTool` or `PackageManagerOrder` use), `README.md` (only if it shows `Install-DFTool`), `CHANGELOG.md`, `CLAUDE.md`, `TODO.md`, `docs/reference.md` (regenerated)
- Modify: `docs/superpowers/specs/2026-10-09-install-design.md` (status line: implemented, with any deviations)

- [ ] **Step 1: Update the guides**

- **`getting-started.md`:** installing is `Install-DFTool -Missing`. Show the three modes in one short section and a sample plan. Mark install blocks `<!-- system -->`, since they change the machine (see `build/DFDocExamples.ps1`).
- **`configuration.md`:** document `InstallVia`, `InstallOrder` and `ExcludeSources`, plus `Defaults['js-package-manager']` (and the other ecosystem roles). Note that `PackageManagerOrder` is replaced.
- **`writing-a-tool.md`:**
  - `packages` keyed by source, and a value can be `{ id, feed }`;
  - `install.prefer`;
  - a manager's `installs` block (every field);
  - `after` accepts `role:`;
  - the "provided by" rule.
- **`troubleshooting.md`:** the gap messages ("needs a manager for npm …", "no source left …", "needs an elevated shell …", "installed … open a new shell").
- **`tools.md`:** node, bun, pnpm, cargo and psresource in the tool list. Add them to groups in `data/groups.json` only if the user asks; leave groups unchanged by default.

- [ ] **Step 2: CHANGELOG and CLAUDE.md**

- **CHANGELOG `[Unreleased]`:**
  - Added: `Install-DFTool -Missing`/modes, `Invoke-DFToolSetup`, managers as plugins, node/bun/pnpm/cargo/psresource records.
  - Changed: package keys, `after` with roles.
  - Removed: `PackageManagerOrder`, `-PackageManager`, `scoopBucket`, `Resolve-DFPackageManager`, the catalog alias.
  - Fixed: npm-only tools can now be installed.
- **CLAUDE.md "Tool JSON Schema":** add `packages` (source keys, feeds), `install.prefer` and `installs`. Add one Key Design Decisions bullet for the install model, pointing at the spec.
- **TODO.md:** close the node/bun item.

- [ ] **Step 3: Regenerate the reference**

Run: `pwsh -NoProfile -File build/Build-DFReferenceDocs.ps1`
Expected: `Wrote ...docs\reference.md`.

- [ ] **Step 4: Full suite with sentinel XDG folders**

Run (PowerShell):

```powershell
$s = Join-Path $env:TEMP "dfsent$(Get-Random)"
foreach ($v in 'CONFIG','CACHE','DATA','STATE') { New-Item -ItemType Directory "$s\$v" -Force | Out-Null; Set-Item "env:XDG_$($v)_HOME" "$s\$v" }
$r = Invoke-Pester tests/ -PassThru -Output None
"Passed $($r.PassedCount) Failed $($r.FailedCount)"; $r.Failed | ForEach-Object ExpandedPath
"Sentinel files: $(@(Get-ChildItem $s -Recurse -File).Count)"
```

Expected: only the two pre-existing doc-example failures, and `Sentinel files: 0`.

- [ ] **Step 5: Live check with the real profile (read-only)**

Run: `TERM_PROGRAM=vscode pwsh -NoLogo -Command 'Get-DFToolStatus | Where-Object State -ne Active | Format-Table Name,State,Detail -AutoSize; Install-DFTool -Missing -WhatIf'`
Expected: every requested tool Active (or Excluded), and "nothing to install", or a plan if something is genuinely missing. **Do not run a real install without the user.**

- [ ] **Step 6: Commit**

```bash
git add -A docs examples README.md CHANGELOG.md CLAUDE.md TODO.md
git commit -m "docs: installing with Install-DFTool -Missing; managers, sources and feeds"
```
