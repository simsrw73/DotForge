# trifle Live Install-Status Checking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `Get-DFCatalogInstalled`'s 15-minute installed-status cache (and its `-Fresh`-never-reaches-it bug) with an always-live, parallel fetch across all 7 catalog providers, each running in its own runspace and dot-sourcing only the 1-2 private files its own provider needs — never the whole module.

**Architecture:** A new private function, `Invoke-DFCatalogInstalledFetch`, runs all 7 providers as one `ForEach-Object -Parallel` batch (bounded by `-TimeoutSeconds`), each branch dot-sourcing its own minimal dependency file(s) from an explicit `$script:DFCatalogInstalledDeps` table before calling that provider's existing `GetInstalled` function by name. `Get-DFCatalogInstalled` becomes a thin, cache-free orchestrator that calls it (via an injectable `-FetchItems` seam for fast, deterministic tests) and still builds the unchanged `Tools/*.json`-derived identity map. `Update-DFPackageCache` drops the now-meaningless `-Force` flag and its "refreshing a snapshot" wording.

**Tech Stack:** PowerShell 7.2+ (`ForEach-Object -Parallel -TimeoutSeconds` requires 7.2+; this module already requires 7.0+, so this plan also bumps the effective floor — see Global Constraints), Pester 5.

**Spec:** `docs/superpowers/specs/2026-07-07-trifle-live-install-status-design.md`

## Global Constraints

- All public functions use the `DF` prefix; private helpers too, live in `Private/`, not exported.
- No `$ErrorActionPreference = 'Stop'` in any module file.
- No parameter named `-Db`/`-Force` where it would alias-collide (`-Force` itself is fine here — it's a real switch, not a naming collision like `-Db`/`-Debug`; this constraint only means never introduce a NEW `-Db`-named parameter anywhere).
- Tests run via `pwsh -NoProfile -Command "Invoke-Pester tests/<file> -Output Detailed"`.
- **`ForEach-Object -Parallel`'s `-TimeoutSeconds` parameter requires PowerShell 7.2+.** This module's manifest currently states `PowerShellVersion = '7.0'` (or similar — verify exact value in `DotForge.psd1` at Task 1 time). Part of Task 1 is bumping that floor to `'7.2'` if it is currently lower, since this feature's core mechanism depends on it.
- `$using:` inside `ForEach-Object -Parallel` can only reach plain local variables, never `$script:`-qualified names directly — copy `$script:`-scoped tables into local variables immediately before the parallel pipeline.
- A provider's failure (missing dependency file, throwing function) must degrade to zero items for that provider only, warned via `Write-Verbose`, never thrown — matching this codebase's established warn-not-throw convention.
- `Get-DFCatalogInstalled`'s public shape (`@{ Items; IdentityMap }`, `-ToolsPath` parameter) is unchanged; only `-Force` is removed (nothing left to force-bypass) and a new `-FetchItems` test seam is added.

---

### Task 1: `Invoke-DFCatalogInstalledFetch` + rewritten `Get-DFCatalogInstalled`

**Files:**
- Modify: `Private/Get-DFCatalogInstalled.ps1` (full rewrite)
- Modify: `Private/DFCatalog.ps1` (remove the now-dead `installed` TTL entry from `$script:DFCatalogTtl`)
- Modify: `DotForge.psd1` (bump `PowerShellVersion` to `'7.2'` if currently lower)
- Test: `tests/Get-DFCatalogInstalled.Tests.ps1` (full rewrite)

**Interfaces:**
- Consumes: nothing new from other tasks (this is the foundational task).
- Produces:
  - `Invoke-DFCatalogInstalledFetch -Deps <hashtable> -FnNames <hashtable> -PrivateRoot <string> [-ThrottleLimit <int> = 8] [-TimeoutSeconds <int> = 10]` → `[object[]]` (flattened, non-null items from every provider that succeeded).
  - `Get-DFCatalogInstalled [-ToolsPath <string>] [-FetchItems <scriptblock>]` → `@{ Items = [object[]]; IdentityMap = [hashtable] }` — `-Force` no longer exists.
  - `$script:DFCatalogInstalledDeps` (hashtable: provider name → array of dependency filenames relative to `Private/`) and `$script:DFCatalogInstalledFn` (hashtable: provider name → its `GetInstalled` function name), both defined at the top of `Private/Get-DFCatalogInstalled.ps1`. Task 2 does not consume these directly, but any future provider addition must update both tables (see the drift-detection test below).

- [ ] **Step 1: Confirm the manifest's PowerShell version floor**

Run: `pwsh -NoProfile -Command "(Test-ModuleManifest ./DotForge.psd1).PowerShellVersion"`

If the output is less than `7.2`, open `DotForge.psd1` and change the `PowerShellVersion` value to `'7.2'`. (If it's already `7.2` or higher, no change needed — just note that in your task report.)

- [ ] **Step 2: Write the failing tests for `Invoke-DFCatalogInstalledFetch`**

Create `tests/Get-DFCatalogInstalled.Tests.ps1` with this full content (replacing the existing file entirely):

```powershell
BeforeAll {
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/Test-DFToolSchema.ps1"
    . "$PSScriptRoot/../Private/Import-DFToolDb.ps1"
    . "$PSScriptRoot/../Private/Get-DFCatalogInstalled.ps1"
}

Describe 'Get-DFCatalogInstalled' {
    BeforeEach {
        # Minimal tool db with a cross-catalog packages map -- IdentityMap
        # construction is unchanged by this feature and unrelated to the
        # fetch mechanism below.
        $script:ToolsPath = Join-Path $TestDrive 'tools'
        New-Item -ItemType Directory $script:ToolsPath -Force | Out-Null
        @{
            name       = 'ripgrep'
            executable = 'rg.exe'
            packages   = @{ scoop = 'ripgrep'; winget = 'BurntSushi.ripgrep.MSVC'; choco = 'ripgrep' }
            xdg        = @{ method = 'default' }
        } | ConvertTo-Json | Set-Content (Join-Path $script:ToolsPath 'ripgrep.json')
    }

    It 'aggregates whatever -FetchItems returns into Items' {
        $r = Get-DFCatalogInstalled -ToolsPath $script:ToolsPath -FetchItems {
            @(
                [pscustomobject]@{ Source = 'scoop'; Name = 'ripgrep'; PackageId = 'ripgrep'; InstalledVersion = '14.1.0' }
                [pscustomobject]@{ Source = 'crates'; Name = 'fd-find'; PackageId = 'fd-find'; InstalledVersion = '10.2.0' }
            )
        }
        @($r.Items).Count | Should -Be 2
        @($r.Items | Where-Object Source -eq 'scoop')[0].Name | Should -Be 'ripgrep'
        @($r.Items | Where-Object Source -eq 'crates')[0].InstalledVersion | Should -Be '10.2.0'
    }

    It 'builds the cross-catalog identity map from Tools/*.json packages' {
        $r = Get-DFCatalogInstalled -ToolsPath $script:ToolsPath -FetchItems { @() }
        $r.IdentityMap['scoop:ripgrep'] | Should -Be 'ripgrep'
        $r.IdentityMap['winget:burntsushi.ripgrep.msvc'] | Should -Be 'ripgrep'
        $r.IdentityMap['choco:ripgrep'] | Should -Be 'ripgrep'
    }

    It 'calls the real Invoke-DFCatalogInstalledFetch when -FetchItems is not supplied' {
        Mock Invoke-DFCatalogInstalledFetch {
            @([pscustomobject]@{ Source = 'npm'; Name = 'x'; PackageId = 'x'; InstalledVersion = '1' })
        }
        $r = Get-DFCatalogInstalled -ToolsPath $script:ToolsPath
        Should -Invoke Invoke-DFCatalogInstalledFetch -Times 1
        @($r.Items)[0].Source | Should -Be 'npm'
    }
}

Describe 'Invoke-DFCatalogInstalledFetch' {
    BeforeAll {
        $script:FakeRoot = Join-Path $TestDrive 'fakeprivate'
        New-Item -ItemType Directory $script:FakeRoot -Force | Out-Null

        Set-Content (Join-Path $script:FakeRoot 'FakeGood.ps1') @'
function Get-FakeGoodInstalled {
    [pscustomobject]@{ Source = 'good'; Name = 'thing'; PackageId = 'thing'; InstalledVersion = '1.0' }
}
'@
        Set-Content (Join-Path $script:FakeRoot 'FakeBad.ps1') @'
function Get-FakeBadInstalled {
    throw 'boom'
}
'@
        Set-Content (Join-Path $script:FakeRoot 'FakeEmpty.ps1') @'
function Get-FakeEmptyInstalled {
}
'@
    }

    It 'aggregates items across multiple providers' {
        $deps = @{ good = @('FakeGood.ps1'); empty = @('FakeEmpty.ps1') }
        $fnNames = @{ good = 'Get-FakeGoodInstalled'; empty = 'Get-FakeEmptyInstalled' }
        $r = @(Invoke-DFCatalogInstalledFetch -Deps $deps -FnNames $fnNames -PrivateRoot $script:FakeRoot)
        $r.Count | Should -Be 1
        $r[0].Name | Should -Be 'thing'
    }

    It 'isolates one provider''s failure from the others' {
        $deps = @{ good = @('FakeGood.ps1'); bad = @('FakeBad.ps1') }
        $fnNames = @{ good = 'Get-FakeGoodInstalled'; bad = 'Get-FakeBadInstalled' }
        $r = @(Invoke-DFCatalogInstalledFetch -Deps $deps -FnNames $fnNames -PrivateRoot $script:FakeRoot)
        $r.Count | Should -Be 1
        $r[0].Source | Should -Be 'good'
    }

    It 'returns nothing but does not throw when every provider fails' {
        $deps = @{ bad = @('FakeBad.ps1') }
        $fnNames = @{ bad = 'Get-FakeBadInstalled' }
        { $script:r = @(Invoke-DFCatalogInstalledFetch -Deps $deps -FnNames $fnNames -PrivateRoot $script:FakeRoot) } |
            Should -Not -Throw
        $script:r.Count | Should -Be 0
    }

    It 'every real provider resolves and runs without error (drift detection against the shipped dependency map)' {
        $privateRoot = "$PSScriptRoot/../Private"
        $verboseRecords = Invoke-DFCatalogInstalledFetch -Deps $script:DFCatalogInstalledDeps `
            -FnNames $script:DFCatalogInstalledFn -PrivateRoot $privateRoot -Verbose 4>&1 |
            Where-Object { $_ -is [System.Management.Automation.VerboseRecord] }
        $failures = @($verboseRecords | Where-Object Message -match "installed enumeration for '.*' failed")
        $failures | Should -BeNullOrEmpty -Because (($failures.Message) -join '; ')
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Get-DFCatalogInstalled.Tests.ps1 -Output Detailed"`
Expected: every test fails — `Invoke-DFCatalogInstalledFetch` doesn't exist yet, and `Get-DFCatalogInstalled` doesn't accept `-FetchItems` yet.

- [ ] **Step 4: Rewrite `Private/Get-DFCatalogInstalled.ps1`**

Replace the entire file with:

```powershell
#Requires -Version 7.2

# Provider name -> array of Private/*.ps1 filenames that provider's
# GetInstalled function needs dot-sourced first (never the whole module).
$script:DFCatalogInstalledDeps = @{
    scoop     = @('DFCatalog.Scoop.ps1')
    winget    = @('DFCatalog.Winget.ps1', 'Invoke-DFSqliteQuery.ps1')
    choco     = @('DFCatalog.Choco.ps1')
    npm       = @('DFCatalog.Npm.ps1')
    crates    = @('DFCatalog.Crates.ps1')
    psgallery = @('DFCatalog.PSGallery.ps1')
    pypi      = @('DFCatalog.Pypi.ps1')
}

# Provider name -> the function to call after dot-sourcing its dependencies.
$script:DFCatalogInstalledFn = @{
    scoop     = 'Get-DFCatalogScoopInstalled'
    winget    = 'Get-DFCatalogWingetInstalled'
    choco     = 'Get-DFCatalogChocoInstalled'
    npm       = 'Get-DFCatalogNpmInstalled'
    crates    = 'Get-DFCatalogCratesInstalled'
    psgallery = 'Get-DFCatalogPSGalleryInstalled'
    pypi      = 'Get-DFCatalogPypiInstalled'
}

function Invoke-DFCatalogInstalledFetch {
    <#
    .SYNOPSIS
        Runs every provider's installed-enumeration function in parallel,
        each in its own runspace, dot-sourcing only the private files that
        specific provider needs.
    .DESCRIPTION
        A provider's failure (missing dependency file, throwing function) is
        isolated to that one provider -- it degrades to zero items for that
        provider and never blanks the others. Bounded by -TimeoutSeconds so a
        hung provider (e.g. a stalled external process) cannot stall the
        whole fetch indefinitely.
    .PARAMETER Deps
        Hashtable: provider name -> array of private .ps1 filenames (relative
        to -PrivateRoot) that provider's function needs dot-sourced first.
    .PARAMETER FnNames
        Hashtable: provider name -> the function name to call after
        dot-sourcing its dependencies.
    .PARAMETER PrivateRoot
        Directory containing the files named in -Deps.
    .PARAMETER ThrottleLimit
        Max concurrent runspaces.
    .PARAMETER TimeoutSeconds
        Overall bound on the whole parallel batch.
    .EXAMPLE
        Invoke-DFCatalogInstalledFetch -Deps $script:DFCatalogInstalledDeps `
            -FnNames $script:DFCatalogInstalledFn -PrivateRoot $PSScriptRoot
        Runs the real shipped providers.
    .OUTPUTS
        [object[]] -- flattened, non-null items from every provider that
        succeeded.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Deps,

        [Parameter(Mandatory)]
        [hashtable]$FnNames,

        [Parameter(Mandatory)]
        [string]$PrivateRoot,

        [int]$ThrottleLimit = 8,

        [int]$TimeoutSeconds = 10
    )

    @($Deps.Keys | ForEach-Object -Parallel {
        $name        = $_
        $deps        = $using:Deps
        $fnNames     = $using:FnNames
        $privateRoot = $using:PrivateRoot

        try {
            foreach ($file in $deps[$name]) {
                . (Join-Path $privateRoot $file)
            }
            @(& (Get-Command $fnNames[$name]))
        } catch {
            Write-Verbose "DotForge: installed enumeration for '$name' failed: $_"
            @()
        }
    } -ThrottleLimit $ThrottleLimit -TimeoutSeconds $TimeoutSeconds) | Where-Object { $_ }
}

function Get-DFCatalogInstalled {
    <#
    .SYNOPSIS
        Unified installed-package snapshot across all catalog providers, plus
        the cross-catalog identity map derived from Tools/*.json packages blocks.
    .DESCRIPTION
        Always live -- every call runs all 7 providers' installed-enumeration
        functions fresh, in parallel (see Invoke-DFCatalogInstalledFetch),
        never cached. The identity map is rebuilt on every call too -- it
        comes from the in-memory tool db and is cheap.

        Returns @{ Items; IdentityMap } where Items are per-source
        {Source, Name, PackageId, InstalledVersion} records and IdentityMap maps
        lowercase 'source:packageid' keys to the owning DotForge tool name.
    .PARAMETER ToolsPath
        Override the tool db location (tests).
    .PARAMETER FetchItems
        Test seam: a scriptblock called with no arguments in place of the
        real parallel fetch. Defaults to the real
        Invoke-DFCatalogInstalledFetch call against the shipped provider
        tables.
    .EXAMPLE
        Get-DFCatalogInstalled
        Returns the live installed snapshot and identity map.
    .OUTPUTS
        [hashtable] -- @{ Items; IdentityMap }.
    #>
    [CmdletBinding()]
    param(
        [string]$ToolsPath,

        [scriptblock]$FetchItems
    )

    $identity = @{}
    $dbParams = @{}
    if ($ToolsPath) { $dbParams.ToolsPath = $ToolsPath }
    try { $db = Import-DFToolDb @dbParams } catch { $db = @{} }
    foreach ($tool in $db.Values) {
        $packages = $tool.PSObject.Properties['packages']?.Value
        if (-not $packages) { continue }
        foreach ($property in $packages.PSObject.Properties) {
            if ($property.Value) {
                $key = "$($property.Name.ToLowerInvariant()):$(([string]$property.Value).ToLowerInvariant())"
                $identity[$key] = $tool.name
            }
        }
    }

    $fetch = $FetchItems ? $FetchItems : {
        Invoke-DFCatalogInstalledFetch -Deps $script:DFCatalogInstalledDeps `
            -FnNames $script:DFCatalogInstalledFn -PrivateRoot $PSScriptRoot
    }
    $items = @(& $fetch)

    @{ Items = $items; IdentityMap = $identity }
}
```

- [ ] **Step 5: Remove the now-dead `installed` TTL entry**

In `Private/DFCatalog.ps1`, find the `$script:DFCatalogTtl` hashtable (near the top of the file) and remove the `installed = [timespan]::FromMinutes(15)` line, leaving `choco` and `default` untouched. For example, change:

```powershell
$script:DFCatalogTtl = @{
    installed = [timespan]::FromMinutes(15)
    choco     = [timespan]::FromHours(72)
    default   = [timespan]::FromHours(24)
}
```

to:

```powershell
$script:DFCatalogTtl = @{
    choco   = [timespan]::FromHours(72)
    default = [timespan]::FromHours(24)
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Get-DFCatalogInstalled.Tests.ps1 -Output Detailed"`
Expected: PASS (7 tests: 3 in `Get-DFCatalogInstalled`, 4 in `Invoke-DFCatalogInstalledFetch`).

If the drift-detection test fails with a specific provider's dependency being insufficient, that means the minimal file list above is wrong for that provider — check the actual production `Private/DFCatalog.<Provider>.ps1` file to see what it really depends on and correct the `$script:DFCatalogInstalledDeps` entry (do not weaken the test).

- [ ] **Step 7: Run the full suite for regressions**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/ -Output Detailed"`
Expected: all tests pass except `tests/Update-DFPackageCache.Tests.ps1`, which is expected to fail at this point (it still relies on the old cached `-Force` behavior — Task 2 fixes it). If any *other* file fails, investigate before proceeding.

- [ ] **Step 8: Commit**

```bash
git add Private/Get-DFCatalogInstalled.ps1 Private/DFCatalog.ps1 DotForge.psd1 tests/Get-DFCatalogInstalled.Tests.ps1
git commit -m "fix(trifle): make installed-status checking always-live via a minimal-dot-source parallel fetch"
```

---

### Task 2: Fix `Update-DFPackageCache`

**Files:**
- Modify: `Public/Update-DFPackageCache.ps1:59-60`
- Test: `tests/Update-DFPackageCache.Tests.ps1`

**Interfaces:**
- Consumes: `Get-DFCatalogInstalled [-ToolsPath <string>] [-FetchItems <scriptblock>]` → `@{ Items; IdentityMap }` (from Task 1; no `-Force` parameter exists anymore).
- Produces: nothing new — this task only fixes an internal call site and its test isolation.

- [ ] **Step 1: Update the test file's `BeforeEach` to mock `Get-DFCatalogInstalled` directly**

The existing fake `$script:DFCatalogProviders` table's `GetInstalled` scriptblocks are no longer consulted by anything (Task 1 changed `Get-DFCatalogInstalled` to use `Invoke-DFCatalogInstalledFetch` against the real shipped provider files, not `$script:DFCatalogProviders`). Without a fix, `Update-DFPackageCache`'s tests would silently start invoking the real parallel fetch against this machine's actual installed packages — slow and non-deterministic. Replace `tests/Update-DFPackageCache.Tests.ps1` in full with:

```powershell
BeforeAll {
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/Test-DFToolSchema.ps1"
    . "$PSScriptRoot/../Private/Import-DFToolDb.ps1"
    . "$PSScriptRoot/../Private/DFCatalog.ps1"
    . "$PSScriptRoot/../Private/Get-DFCatalogInstalled.ps1"
    . "$PSScriptRoot/../Public/Update-DFPackageCache.ps1"
}

Describe 'Update-DFPackageCache' {
    BeforeEach {
        $script:SavedXdgCache = $Env:XDG_CACHE_HOME
        $Env:XDG_CACHE_HOME = Join-Path $TestDrive 'cache'
        $script:SavedProviders = $script:DFCatalogProviders
        $script:DFCatalogAvailability = @{}
        $global:DFTestRefreshLog = [System.Collections.Generic.List[string]]::new()

        $script:DFCatalogProviders = @{
            scoop = @{
                Name = 'scoop'; Kind = 'snapshot'; Test = { $true }
                Search = { }
                Refresh = { param($Query) $global:DFTestRefreshLog.Add("scoop:$Query") }
            }
            crates = @{
                Name = 'crates'; Kind = 'query-cache'; Test = { $true }
                Search = { }
                Refresh = { param($Query) $global:DFTestRefreshLog.Add("crates:$Query") }
            }
            npm = @{
                Name = 'npm'; Kind = 'query-cache'; Test = { $true }
                Search = { }
                Refresh = { param($Query) $global:DFTestRefreshLog.Add("npm:$Query") }
            }
        }

        Mock Get-DFCatalogInstalled {
            @{
                Items       = @([pscustomobject]@{ Source = 'scoop'; Name = 'ripgrep'; PackageId = 'ripgrep'; InstalledVersion = '14.1.0' })
                IdentityMap = @{}
            }
        }
    }
    AfterEach {
        $Env:XDG_CACHE_HOME = $script:SavedXdgCache
        $script:DFCatalogProviders = $script:SavedProviders
        $script:DFCatalogAvailability = @{}
        Remove-Variable -Name DFTestRefreshLog -Scope Global -ErrorAction Ignore
        Remove-Item (Join-Path $TestDrive 'cache') -Recurse -Force -ErrorAction Ignore
    }

    It 'refreshes snapshot provider indexes' {
        Update-DFPackageCache -Quiet
        $global:DFTestRefreshLog | Where-Object { $_ -like 'scoop:*' } | Should -Not -BeNullOrEmpty
    }

    It 're-warms every seen query against each query-cache provider' {
        Add-DFCatalogSeenQuery -Query 'static site generator'
        Update-DFPackageCache -Quiet
        $global:DFTestRefreshLog | Should -Contain 'crates:static site generator'
        $global:DFTestRefreshLog | Should -Contain 'npm:static site generator'
    }

    It 're-warms installed tool names' {
        Update-DFPackageCache -Quiet
        $global:DFTestRefreshLog | Should -Contain 'crates:ripgrep'
        $global:DFTestRefreshLog | Should -Contain 'npm:ripgrep'
    }

    It 'does not re-warm the same query twice' {
        Add-DFCatalogSeenQuery -Query 'ripgrep'     # duplicates the installed tool name
        Update-DFPackageCache -Quiet
        @($global:DFTestRefreshLog | Where-Object { $_ -eq 'crates:ripgrep' }).Count | Should -Be 1
    }

    It 'honors -Source' {
        Update-DFPackageCache -Quiet -Source crates
        $global:DFTestRefreshLog | Where-Object { $_ -like 'scoop:*' } | Should -BeNullOrEmpty
        $global:DFTestRefreshLog | Where-Object { $_ -like 'npm:*' } | Should -BeNullOrEmpty
    }

    It 'keeps going when one provider refresh fails' {
        $script:DFCatalogProviders['crates'].Refresh = { param($Query) throw 'boom' }
        { Update-DFPackageCache -Quiet -WarningAction SilentlyContinue } | Should -Not -Throw
        $global:DFTestRefreshLog | Should -Contain 'npm:ripgrep'
    }

    It 're-warms cached detail entries with the stored raw PackageId' {
        $script:DetailCalls = [System.Collections.Generic.List[string]]::new()
        $script:DFCatalogProviders['npm'].Detail = { param($Id, $Fresh)
            $script:DetailCalls.Add("$Id fresh=$Fresh") }

        $detailsDir = Join-Path $Env:XDG_CACHE_HOME 'dotforge/catalogs/npm/details'
        New-Item -ItemType Directory -Path $detailsDir -Force | Out-Null
        @{ timestamp = [datetime]::UtcNow.ToString('o'); query = 'RipGrep'; results = @(@{ PackageId = 'RipGrep' }) } |
            ConvertTo-Json -Depth 4 | Set-Content (Join-Path $detailsDir 'ripgrep-abcd1234.json')

        Update-DFPackageCache -Quiet
        $script:DetailCalls | Should -Contain 'RipGrep fresh=True'
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Update-DFPackageCache.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Update-DFPackageCache.ps1:60` still calls `Get-DFCatalogInstalled -Force`, and `-Force` no longer exists as a parameter (Task 1 removed it), so this throws a parameter-binding error.

- [ ] **Step 3: Fix `Public/Update-DFPackageCache.ps1`**

Change lines 59-60 from:

```powershell
    if (-not $Quiet) { Write-Host 'Refreshing installed-package snapshot…' }
    $installed = Get-DFCatalogInstalled -Force
```

to:

```powershell
    if (-not $Quiet) { Write-Host 'Reading installed packages…' }
    $installed = Get-DFCatalogInstalled
```

(The message wording now matches the phrasing `Resolve-DFCatalogQueryMerge` already uses for this same operation — "refreshing a snapshot" implied a cache that no longer exists.)

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Update-DFPackageCache.Tests.ps1 -Output Detailed"`
Expected: PASS (7/7).

- [ ] **Step 5: Run the full suite for regressions**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/ -Output Detailed"`
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add Public/Update-DFPackageCache.ps1 tests/Update-DFPackageCache.Tests.ps1
git commit -m "fix(trifle): Update-DFPackageCache no longer passes -Force to Get-DFCatalogInstalled"
```

---

### Task 3: Documentation + final verification

**Files:**
- Modify: `README.md`
- Modify: `CHANGELOG.md`
- Modify: `TODO.md`

**Interfaces:**
- Consumes: the finished feature from Tasks 1-2 (no new interfaces produced by this task).

- [ ] **Step 1: Update README.md**

In the "Package Catalog Info (trifle)" prose (the paragraph right before or after the Exported Cmdlets table, around line 195-198, that currently reads something like *"...Answers are cache-first: ... Cache ages are shown on the card; `-Fresh` forces live fetches."*), add one sentence clarifying that installed-status itself is never cached. For example, append after the existing "Cache ages are shown on the card; `-Fresh` forces live fetches." sentence:

```markdown
Installed-status checking is always live (not cached) — every query re-checks all seven catalogs' actual installed state in parallel, so it never goes stale.
```

- [ ] **Step 2: Add a CHANGELOG.md entry**

Under the `[Unreleased]` heading, add a `### Fixed` subsection (or a new bullet under an existing one if `### Fixed` already exists there) with:

```markdown
- `trifle`'s installed-status check no longer relies on a 15-minute cache that `-Fresh` never actually reached — installing a tool and immediately re-running `trifle <tool>` now always reflects the true current state. All 7 catalog providers run as one parallel batch, each dot-sourcing only the small set of private files its own check needs (not the whole module), keeping the added latency to roughly the single slowest provider rather than their sum.
```

- [ ] **Step 3: Remove the now-resolved TODO.md entry**

Find and delete this entry under "Priority 3 — Features" (it described exactly the problem this plan fixes, and explicitly investigated during design whether manifest/binary-level verification was needed — it was ruled out as unnecessary, since installed-status was never actually keyed by binary name):

```markdown
- [ ] **trifle install-status verification (manifest/binary-driven)** —
  sequenced next after the tool-identity guide. Package names frequently
  differ from the binaries they install (Sysinternals-style collections:
  one package, dozens of executables, none matching the package name).
  Verify installed status against a package's actual declared
  binaries/manifest rather than name-based heuristics; investigate whether
  per-catalog checks can run live (uncached) cheaply enough for most
  catalogs, given `Get-DFCatalogInstalled`'s existing 15-minute cache exists
  specifically to amortize the few genuinely slow probes (PSGallery's
  `Get-Module -ListAvailable` fallback, pipx's process spawn).
```

- [ ] **Step 4: Full suite**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/ -Output Detailed"`
Expected: all tests pass, 0 failed.

- [ ] **Step 5: Manifest validation and help check**

Run:
```powershell
pwsh -NoProfile -Command "Test-ModuleManifest ./DotForge.psd1"
```
Expected: clean, no errors, `PowerShellVersion` reads `7.2` (or higher).

Neither `Get-DFCatalogInstalled` nor `Invoke-DFCatalogInstalledFetch` are exported (both stay `Private/`), so no `Get-Help -Full` check is needed for this task — `Update-DFPackageCache` is the only touched public function and its help text is unchanged.

- [ ] **Step 6: Live smoke test — confirm no code change was needed in `Resolve-DFCatalogQueryMerge.ps1`**

This is a verification-only step, not a code change: `Resolve-DFCatalogQueryMerge.ps1` already emits `Write-Progress -Id $progressId -Activity 'trifle' -Status 'Reading installed packages…'` immediately before calling `Get-DFCatalogInstalled`, and it never passed `-Force` in the first place — so the spec's "extend Write-Progress feedback" goal and the "-Fresh reaches installed status" goal are both already satisfied by Task 1 alone, with zero changes needed in this file. Confirm this by reading `Private/Resolve-DFCatalogQueryMerge.ps1` and checking that line still reads exactly as described — if it does, no action is needed; note this confirmation in your task report.

- [ ] **Step 7: Live smoke test — confirm the actual fix**

Run this as a PowerShell script (assumes `$Env:XDG_CACHE_HOME` is already set in the session):

```powershell
Import-Module ./DotForge.psd1 -Force
Measure-Command { trifle ripgrep -AsObject | Out-Null } | Select-Object TotalMilliseconds
```

Expected: completes in roughly the range this plan's spec measured (typically well under 1 second; dominated by whichever single provider is slowest on this machine, e.g. `pipx` if installed). Then verify the actual bug fix scenario is now correct: pick any tool you can install/uninstall via scoop, choco, or winget (or trust the following description if you'd rather not install anything): install it, then immediately run `trifle <tool> -AsObject | Select-Object Installed, InstalledVia` with no delay — it should report `Installed = $true` right away, with no dependency on any TTL window.

- [ ] **Step 8: Commit**

```bash
git add README.md CHANGELOG.md TODO.md
git commit -m "docs(trifle): document always-live install-status checking"
```

## Verification (whole feature)

- [ ] `pwsh -NoProfile -Command "Invoke-Pester tests/ -Output Detailed"` — all green.
- [ ] `pwsh -NoProfile -Command "Test-ModuleManifest ./DotForge.psd1"` — clean, `PowerShellVersion` is `7.2`+.
- [ ] `Get-DFCatalogInstalled` and `Invoke-DFCatalogInstalledFetch` are both `Private/`, unexported, not present in `DotForge.psd1`'s `FunctionsToExport`.
- [ ] No remaining reference to `$script:DFCatalogTtl.installed` anywhere in the codebase (`grep -rn "DFCatalogTtl.installed"` returns nothing).
- [ ] No remaining call to `Get-DFCatalogInstalled -Force` anywhere in the codebase (`grep -rn "Get-DFCatalogInstalled -Force"` returns nothing).
- [ ] Live smoke test from Task 3 Step 7 confirms installed status updates immediately after a real install, with no 15-minute lag.
