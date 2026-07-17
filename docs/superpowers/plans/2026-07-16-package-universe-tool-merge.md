# Package Universe Phase C: Tool Merge — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Flatten Phase B clusters and singletons into a master `tools` table — one row per real-world tool across the whole 30,251-package corpus, lossless, with per-field priority picks, a license conflict flag, a tag union, and first-pass categories.

**Architecture:** A new offline build stage (`stage='merge'`) reading `raw_packages` + `cluster_members` from the shared `universe.db`. A logic module `build/Private/DFPackageUniverse.Merge.ps1` groups packages (clustered → one tool; unclustered → singleton tool), reduces each group to a canonical `tools` row while copying every source row verbatim to `tool_packages`, and derives `tool_tags` + `tool_categories`. A thin orchestrator `build/Build-DFPackageUniverseTools.ps1` mirrors the Phase A/B scripts.

**Tech Stack:** PowerShell 7+, PSSQLite (`Invoke-SqliteQuery`, `New-SQLiteConnection`), Pester 5. Follows the Phase A/B build conventions exactly.

## Global Constraints

- **PowerShell 7+**; every module file starts with `#Requires -Version 7.0`.
- **`Set-StrictMode -Version Latest`** in the orchestrator and in every test file's `BeforeAll` (Pester does not set it). Strict-safe access only: `$obj.PSObject.Properties['Key']` probes, `@(x | Where-Object {...})` wrapping whole pipelines, no `.property` access on possibly-absent members.
- **DBNull:** PSSQLite returns `[DBNull]` for NULL columns — coerce to `$null` before any truthiness/string use.
- **`DF` prefix** on all functions; build-phase helpers live in `build/Private/`.
- **`pipeline_log`** is shared: this stage uses `stage='merge'` and clears only its own rows.
- **Truncate-rebuild:** the stage clears its own four tables + `pipeline_log WHERE stage='merge'`, never another phase's.
- **No network in any test.** All inputs are DB rows or a fixture rules file.
- **Pester 5:** no `<angle brackets>` in `It`/`Describe` names (treated as `-ForEach` placeholders).
- **Core contract:** `Σ tool_packages == COUNT(raw_packages)`, every `(source, package_id)` in exactly one tool.
- **Priority order** for display fields: `winget > choco > scoop`. For `repo_url`: `choco > scoop > winget` (choco `ProjectSourceUrl` is the authoritative repo signal).

---

## File Structure

- **Create** `build/Private/DFPackageUniverse.Merge.ps1` — all Phase C logic functions.
- **Create** `build/Build-DFPackageUniverseTools.ps1` — thin orchestrator.
- **Create** `data/package-universe-categories.jsonc` — seed keyword→category rules.
- **Create** `tests/DFPackageUniverse.Merge.Tests.ps1` — Pester 5 tests.
- **Modify** `CHANGELOG.md` — `[Unreleased]` entry.

`Get-DFPackageUniverseRepoKey` is reused verbatim from `build/Private/DFPackageUniverse.Links.ps1` (Phase B); the Merge module and tests dot-source that file for it.

---

## Task 1: Merge foundations — DBNull coercion + license normalization

**Files:**
- Create: `build/Private/DFPackageUniverse.Merge.ps1`
- Test: `tests/DFPackageUniverse.Merge.Tests.ps1`

**Interfaces:**
- Produces: `ConvertFrom-DFDbNull($Value) -> value or $null`; `ConvertTo-DFNormalizedLicense([string]$Value) -> normalized identifier string or $null` (URLs and empties become `$null`).

- [ ] **Step 1: Write the failing test**

Create `tests/DFPackageUniverse.Merge.Tests.ps1`:

```powershell
BeforeAll {
    Set-StrictMode -Version Latest
    Import-Module PSSQLite
    . "$PSScriptRoot/../build/Private/DFPackageUniverse.Links.ps1"  # Get-DFPackageUniverseRepoKey
    . "$PSScriptRoot/../build/Private/DFPackageUniverse.Merge.ps1"
}

Describe 'DFPackageUniverse.Merge' {
    Context 'ConvertFrom-DFDbNull' {
        It 'maps DBNull to null and passes other values through' {
            ConvertFrom-DFDbNull ([DBNull]::Value) | Should -BeNullOrEmpty
            ConvertFrom-DFDbNull 'hello' | Should -Be 'hello'
        }
    }

    Context 'ConvertTo-DFNormalizedLicense' {
        It 'folds MIT and MIT License to the same identifier' {
            (ConvertTo-DFNormalizedLicense 'MIT') | Should -Be (ConvertTo-DFNormalizedLicense 'MIT License')
        }
        It 'treats a license URL as null (choco stores LicenseUrl, not an SPDX id)' {
            ConvertTo-DFNormalizedLicense 'https://github.com/x/y/blob/main/LICENSE' | Should -BeNullOrEmpty
        }
        It 'returns null for empty input' {
            ConvertTo-DFNormalizedLicense '' | Should -BeNullOrEmpty
        }
        It 'distinguishes genuinely different licenses' {
            (ConvertTo-DFNormalizedLicense 'Apache-2.0') | Should -Not -Be (ConvertTo-DFNormalizedLicense 'MIT')
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/DFPackageUniverse.Merge.Tests.ps1 -Output Detailed"`
Expected: FAIL — `The term 'ConvertFrom-DFDbNull' is not recognized` (module file doesn't exist yet).

- [ ] **Step 3: Write minimal implementation**

Create `build/Private/DFPackageUniverse.Merge.ps1`:

```powershell
#Requires -Version 7.0

# Phase C (tool merge) build helpers. Flattens Phase B clusters + singletons
# into the master tools table, losslessly. See
# docs/superpowers/specs/2026-07-16-package-universe-tool-merge-design.md

function ConvertFrom-DFDbNull {
    <#
    .SYNOPSIS
        Coerces a PSSQLite [DBNull] cell to $null; passes any other value through.
    #>
    [CmdletBinding()]
    param($Value)
    if ($Value -is [DBNull]) { $null } else { $Value }
}

function ConvertTo-DFNormalizedLicense {
    <#
    .SYNOPSIS
        Canonical license identifier for single-answer conflict detection:
        lowercased, the word 'license' removed, non-alphanumeric stripped
        ('MIT' and 'MIT License' -> 'mit'). Returns $null for empties AND for
        URL-shaped values -- choco's license column holds LicenseUrl, not an
        SPDX id, so comparing it to winget's 'MIT' would false-conflict on every
        multi-source choco tool. URLs simply do not participate in the check.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][string]$Value)

    if (-not $Value) { return $null }
    if ($Value -match '^\s*https?://') { return $null }
    $t = ($Value.ToLowerInvariant() -replace '\blicense\b', '') -replace '[^a-z0-9]', ''
    if ($t -eq '') { return $null }
    $t
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/DFPackageUniverse.Merge.Tests.ps1 -Output Detailed"`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add build/Private/DFPackageUniverse.Merge.ps1 tests/DFPackageUniverse.Merge.Tests.ps1
git commit -m "feat(package-universe): Phase C merge foundations (dbnull + license normalize)"
```

---

## Task 2: Canonical record — priority picks, provenance, repo, license flag

**Files:**
- Modify: `build/Private/DFPackageUniverse.Merge.ps1`
- Test: `tests/DFPackageUniverse.Merge.Tests.ps1`

**Interfaces:**
- Consumes: `Get-DFPackageUniverseRepoKey` (Phase B), `ConvertTo-DFNormalizedLicense` (Task 1).
- Produces:
  - `Select-DFByPriority([object[]]$Members, [string[]]$Order, [string]$Field) -> { Value; Source }` (first non-empty `$Field` scanning `$Order`; `Value=$null`, `Source=$null` if none).
  - `Resolve-DFPackageUniverseToolRecord([object[]]$Members) -> { Name; NameSource; Description; DescriptionSource; Homepage; RepoUrl; License; SourceCount; NeedsReview [bool]; ReviewReasons [string[]] }`.
- Member row shape (used everywhere downstream): `{ source; package_id; name; version; description; homepage; license; publisher; tags; extra }`.

- [ ] **Step 1: Write the failing test**

Add to the `Describe 'DFPackageUniverse.Merge'` block:

```powershell
    Context 'Resolve-DFPackageUniverseToolRecord' {
        function M {
            param($Source, $PackageId, $Name = $null, $Description = $null, $Homepage = $null, $License = $null, $Publisher = $null, $Extra = $null)
            [pscustomobject]@{
                source = $Source; package_id = $PackageId; name = $Name; version = '1'
                description = $Description; homepage = $Homepage; license = $License
                publisher = $Publisher; tags = $null; extra = $Extra
            }
        }

        It 'prefers the winget friendly name over choco and scoop' {
            $members = @(
                (M -Source 'scoop'  -PackageId 'main/bat' -Name 'bat')
                (M -Source 'winget' -PackageId 'sharkdp.bat' -Name 'bat')
                (M -Source 'choco'  -PackageId 'bat' -Name 'Bat')
            )
            $rec = Resolve-DFPackageUniverseToolRecord -Members $members
            $rec.Name | Should -Be 'bat'
            $rec.NameSource | Should -Be 'winget'
            $rec.SourceCount | Should -Be 3
        }

        It 'picks the richer winget description over a terse scoop one' {
            $members = @(
                (M -Source 'scoop'  -PackageId 'main/x' -Name 'x' -Description 'short')
                (M -Source 'winget' -PackageId 'A.X' -Name 'x' -Description 'A full description of what X does.')
            )
            $rec = Resolve-DFPackageUniverseToolRecord -Members $members
            $rec.Description | Should -Be 'A full description of what X does.'
            $rec.DescriptionSource | Should -Be 'winget'
        }

        It 'derives repo_url from choco ProjectSourceUrl' {
            $extra = ConvertTo-Json -Compress @{ ProjectSourceUrl = 'https://github.com/sharkdp/bat' }
            $members = @( (M -Source 'choco' -PackageId 'bat' -Name 'bat' -Extra $extra) )
            $rec = Resolve-DFPackageUniverseToolRecord -Members $members
            $rec.RepoUrl | Should -Be 'https://github.com/sharkdp/bat'
        }

        It 'flags a genuine license conflict but not MIT vs MIT License' {
            $conflict = Resolve-DFPackageUniverseToolRecord -Members @(
                (M -Source 'winget' -PackageId 'A.X' -Name 'x' -License 'MIT')
                (M -Source 'choco'  -PackageId 'x'   -Name 'x' -License 'Apache-2.0')
            )
            $conflict.NeedsReview | Should -BeTrue
            $conflict.ReviewReasons[0] | Should -Match 'license-conflict'

            $ok = Resolve-DFPackageUniverseToolRecord -Members @(
                (M -Source 'winget' -PackageId 'A.X' -Name 'x' -License 'MIT')
                (M -Source 'choco'  -PackageId 'x'   -Name 'x' -License 'MIT License')
            )
            $ok.NeedsReview | Should -BeFalse
        }

        It 'does not flag winget MIT against a choco license URL' {
            $rec = Resolve-DFPackageUniverseToolRecord -Members @(
                (M -Source 'winget' -PackageId 'A.X' -Name 'x' -License 'MIT')
                (M -Source 'choco'  -PackageId 'x'   -Name 'x' -License 'https://opensource.org/licenses/MIT')
            )
            $rec.NeedsReview | Should -BeFalse
        }

        It 'falls back to package_id when no member has a name (NOT NULL guard)' {
            $rec = Resolve-DFPackageUniverseToolRecord -Members @( (M -Source 'scoop' -PackageId 'main/thing') )
            $rec.Name | Should -Be 'main/thing'
        }
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/DFPackageUniverse.Merge.Tests.ps1 -Output Detailed"`
Expected: FAIL — `'Resolve-DFPackageUniverseToolRecord' is not recognized`.

- [ ] **Step 3: Write minimal implementation**

Append to `build/Private/DFPackageUniverse.Merge.ps1`:

```powershell
function Select-DFByPriority {
    <#
    .SYNOPSIS
        First non-empty value of $Field across $Members, scanning source names in
        $Order. Returns { Value; Source } ($null/$null when none supply it).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Members,
        [Parameter(Mandatory)][string[]]$Order,
        [Parameter(Mandatory)][string]$Field
    )
    foreach ($src in $Order) {
        foreach ($m in $Members) {
            if ($m.source -eq $src) {
                $v = ConvertFrom-DFDbNull $m.$Field
                if ($null -ne $v -and "$v".Trim() -ne '') {
                    return [pscustomobject]@{ Value = [string]$v; Source = $src }
                }
            }
        }
    }
    [pscustomobject]@{ Value = $null; Source = $null }
}

function Resolve-DFPackageUniverseToolRecord {
    <#
    .SYNOPSIS
        Reduces one group's member rows to the canonical parent tool record.
        Display scalars are per-field priority picks (winget>choco>scoop) with
        provenance; repo_url uses the Phase B repo authority (choco>scoop>winget);
        a post-normalization license disagreement sets NeedsReview.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Members)

    $display = @('winget', 'choco', 'scoop')
    $name = Select-DFByPriority -Members $Members -Order $display -Field 'name'
    $desc = Select-DFByPriority -Members $Members -Order $display -Field 'description'
    $home = Select-DFByPriority -Members $Members -Order $display -Field 'homepage'
    $lic  = Select-DFByPriority -Members $Members -Order $display -Field 'license'

    # repo: choco ProjectSourceUrl is the strongest signal (Phase B priority),
    # then scoop checkver/autoupdate, then winget (homepage only).
    $repoUrl = $null
    foreach ($src in @('choco', 'scoop', 'winget')) {
        foreach ($m in $Members) {
            if ($m.source -eq $src) {
                $key = Get-DFPackageUniverseRepoKey -Row $m
                if ($key) { $repoUrl = "https://github.com/$key"; break }
            }
        }
        if ($repoUrl) { break }
    }

    # License single-answer conflict: compare only identifier-shaped licenses
    # (ConvertTo-DFNormalizedLicense drops URLs and empties).
    $norm = @($Members | ForEach-Object { ConvertTo-DFNormalizedLicense -Value (ConvertFrom-DFDbNull $_.license) } | Where-Object { $_ } | Select-Object -Unique)
    $reasons = [System.Collections.Generic.List[string]]::new()
    if ($norm.Count -gt 1) {
        $raw = @($Members | ForEach-Object { ConvertFrom-DFDbNull $_.license } | Where-Object { $_ -and $_ -notmatch '^\s*https?://' } | Select-Object -Unique)
        $reasons.Add("license-conflict: $($raw -join ' | ')")
    }

    $nameVal = if ($name.Value) { $name.Value } else { [string](@($Members)[0].package_id) }

    [pscustomobject]@{
        Name              = $nameVal
        NameSource        = $name.Source
        Description       = $desc.Value
        DescriptionSource = $desc.Source
        Homepage          = $home.Value
        RepoUrl           = $repoUrl
        License           = $lic.Value
        SourceCount       = @($Members | ForEach-Object { $_.source } | Select-Object -Unique).Count
        NeedsReview       = ($reasons.Count -gt 0)
        ReviewReasons     = $reasons.ToArray()
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/DFPackageUniverse.Merge.Tests.ps1 -Output Detailed"`
Expected: PASS (all Task 1 + Task 2 tests).

- [ ] **Step 5: Commit**

```bash
git add build/Private/DFPackageUniverse.Merge.ps1 tests/DFPackageUniverse.Merge.Tests.ps1
git commit -m "feat(package-universe): Phase C canonical tool record (picks + provenance + license flag)"
```

---

## Task 3: Tag union

**Files:**
- Modify: `build/Private/DFPackageUniverse.Merge.ps1`
- Test: `tests/DFPackageUniverse.Merge.Tests.ps1`

**Interfaces:**
- Produces: `Get-DFPackageUniverseToolTags([object[]]$Members) -> [string[]]` — normalized (lowercase/trim), deduped, first-seen order. Reads each member's `tags` column (a JSON array string for winget and choco; NULL for scoop).

- [ ] **Step 1: Write the failing test**

Add to the `Describe` block:

```powershell
    Context 'Get-DFPackageUniverseToolTags' {
        It 'unions and normalizes tags across members, deduping' {
            $members = @(
                [pscustomobject]@{ source = 'winget'; package_id = 'A.X'; tags = (ConvertTo-Json -Compress @('Cat', 'Viewer')) }
                [pscustomobject]@{ source = 'choco';  package_id = 'x';   tags = (ConvertTo-Json -Compress @('cat', 'less')) }
                [pscustomobject]@{ source = 'scoop';  package_id = 'main/x'; tags = $null }
            )
            $tags = Get-DFPackageUniverseToolTags -Members $members
            $tags | Should -Contain 'cat'
            $tags | Should -Contain 'viewer'
            $tags | Should -Contain 'less'
            @($tags | Where-Object { $_ -eq 'cat' }).Count | Should -Be 1
        }

        It 'does not throw under strict on a DBNull tags cell' {
            $members = @([pscustomobject]@{ source = 'scoop'; package_id = 'main/x'; tags = [DBNull]::Value })
            { Get-DFPackageUniverseToolTags -Members $members } | Should -Not -Throw
            @(Get-DFPackageUniverseToolTags -Members $members).Count | Should -Be 0
        }
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/DFPackageUniverse.Merge.Tests.ps1 -Output Detailed"`
Expected: FAIL — `'Get-DFPackageUniverseToolTags' is not recognized`.

- [ ] **Step 3: Write minimal implementation**

Append to `build/Private/DFPackageUniverse.Merge.ps1`:

```powershell
function Get-DFPackageUniverseToolTags {
    <#
    .SYNOPSIS
        Normalized (lowercase/trim) deduped union of every member's tags. Each
        catalog stores tags as a JSON array string in the tags column (winget and
        choco populate it; scoop leaves it NULL). First-seen order is preserved so
        the output is deterministic (idempotent runs).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Members)

    $out = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($m in $Members) {
        $raw = ConvertFrom-DFDbNull $m.tags
        if (-not $raw) { continue }
        $parsed = $null
        try { $parsed = $raw | ConvertFrom-Json } catch { $parsed = $null }
        if ($null -eq $parsed) { continue }
        foreach ($t in @($parsed)) {
            $norm = "$t".Trim().ToLowerInvariant()
            if ($norm -and $seen.Add($norm)) { $out.Add($norm) }
        }
    }
    $out.ToArray()
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/DFPackageUniverse.Merge.Tests.ps1 -Output Detailed"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add build/Private/DFPackageUniverse.Merge.ps1 tests/DFPackageUniverse.Merge.Tests.ps1
git commit -m "feat(package-universe): Phase C tag union"
```

---

## Task 4: Category derivation — rule file, tokens, mapping

**Files:**
- Create: `data/package-universe-categories.jsonc`
- Modify: `build/Private/DFPackageUniverse.Merge.ps1`
- Test: `tests/DFPackageUniverse.Merge.Tests.ps1`

**Interfaces:**
- Produces:
  - `Import-DFPackageUniverseCategoryRules([string]$Path) -> [object[]]` of `{ Category [string]; Keywords [string[]] }` (JSONC comments stripped; missing file → `@()`).
  - `Get-DFPackageUniverseCategoryTokens([object[]]$Members, [string[]]$Tags) -> [string[]]` — the tag union plus any winget `Moniker`, all lowercased.
  - `ConvertTo-DFPackageUniverseCategories([string[]]$Tokens, [object[]]$Rules) -> [string[]]` — categories whose rule keywords intersect the tokens; deduped, rule order preserved.

- [ ] **Step 1: Write the failing test**

Add to the `Describe` block:

```powershell
    Context 'categories' {
        BeforeAll {
            $script:rulesFile = Join-Path ([System.IO.Path]::GetTempPath()) ("catrules-" + [guid]::NewGuid().ToString('N') + ".jsonc")
            @'
{
  // keyword -> category rules (first-pass)
  "schemaVersion": 1,
  "rules": [
    { "category": "viewer", "keywords": ["cat", "pager", "viewer"] },
    { "category": "search", "keywords": ["search", "grep", "find"] }
  ]
}
'@ | Set-Content -Path $script:rulesFile -Encoding utf8
        }
        AfterAll { Remove-Item -Path $script:rulesFile -ErrorAction Ignore }

        It 'loads rules, ignoring comments' {
            $rules = Import-DFPackageUniverseCategoryRules -Path $script:rulesFile
            @($rules).Count | Should -Be 2
            $rules[0].Category | Should -Be 'viewer'
            $rules[0].Keywords | Should -Contain 'cat'
        }

        It 'returns empty for a missing rules file' {
            @(Import-DFPackageUniverseCategoryRules -Path 'C:\nope\missing.jsonc').Count | Should -Be 0
        }

        It 'includes a winget Moniker in the token set' {
            $members = @([pscustomobject]@{ source = 'winget'; package_id = 'A.X'; extra = (ConvertTo-Json -Compress @{ Moniker = 'grep' }) })
            $tokens = Get-DFPackageUniverseCategoryTokens -Members $members -Tags @('viewer')
            $tokens | Should -Contain 'grep'
            $tokens | Should -Contain 'viewer'
        }

        It 'maps tokens to categories via the rules, deduped' {
            $rules = Import-DFPackageUniverseCategoryRules -Path $script:rulesFile
            $cats = ConvertTo-DFPackageUniverseCategories -Tokens @('cat', 'grep') -Rules $rules
            $cats | Should -Contain 'viewer'
            $cats | Should -Contain 'search'
            @($cats).Count | Should -Be 2
        }

        It 'yields no category for unmatched tokens' {
            $rules = Import-DFPackageUniverseCategoryRules -Path $script:rulesFile
            @(ConvertTo-DFPackageUniverseCategories -Tokens @('zzz') -Rules $rules).Count | Should -Be 0
        }
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/DFPackageUniverse.Merge.Tests.ps1 -Output Detailed"`
Expected: FAIL — `'Import-DFPackageUniverseCategoryRules' is not recognized`.

- [ ] **Step 3: Write minimal implementation**

Create `data/package-universe-categories.jsonc`:

```jsonc
{
  // Phase C first-pass category rules. Each rule maps any matching `keywords`
  // (compared against a tool's normalized tags + winget Moniker) to `category`.
  // Version-controlled and human-growable; full ontology is Phase D.
  "schemaVersion": 1,
  "rules": [
    { "category": "search",   "keywords": ["search", "grep", "find", "ripgrep", "fuzzy-finder"] },
    { "category": "editor",   "keywords": ["editor", "ide", "vim", "neovim", "emacs", "text-editor"] },
    { "category": "viewer",   "keywords": ["cat", "pager", "viewer", "less", "syntax-highlighting"] },
    { "category": "shell",    "keywords": ["shell", "terminal", "prompt", "console"] },
    { "category": "git",      "keywords": ["git", "version-control", "vcs", "diff"] },
    { "category": "files",    "keywords": ["filesystem", "file-manager", "ls", "directory", "disk-usage"] },
    { "category": "network",  "keywords": ["http", "network", "curl", "dns", "download"] },
    { "category": "dev",      "keywords": ["compiler", "build", "linter", "formatter", "package-manager"] },
    { "category": "data",     "keywords": ["json", "yaml", "csv", "database", "sql"] }
  ]
}
```

Append to `build/Private/DFPackageUniverse.Merge.ps1`:

```powershell
function Import-DFPackageUniverseCategoryRules {
    <#
    .SYNOPSIS
        Loads the version-controlled keyword->category rule file into
        { Category; Keywords[] } objects. JSONC: whole-line // comments and
        /* */ blocks are stripped (line comments anchored to line start so a
        '//' inside a value is safe). A missing file yields @().
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path $Path)) { return @() }
    $text = Get-Content -Raw -Path $Path
    $text = [regex]::Replace($text, '(?m)^\s*//.*$', '')
    $text = [regex]::Replace($text, '(?s)/\*.*?\*/', '')
    $doc = $text | ConvertFrom-Json

    $rulesProp = $doc.PSObject.Properties['rules']
    if (-not $rulesProp) { return @() }
    @(foreach ($r in @($rulesProp.Value)) {
        $kw = @(@($r.keywords) | ForEach-Object { "$_".Trim().ToLowerInvariant() } | Where-Object { $_ })
        [pscustomobject]@{ Category = [string]$r.category; Keywords = $kw }
    })
}

function Get-DFPackageUniverseCategoryTokens {
    <#
    .SYNOPSIS
        The match set for category derivation: the tool's tag union plus any
        winget Moniker (a strong single-word category hint), all lowercased.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Members,
        [AllowEmptyCollection()][string[]]$Tags = @()
    )
    $tokens = [System.Collections.Generic.List[string]]::new()
    foreach ($t in @($Tags)) { if ($t) { $tokens.Add("$t".Trim().ToLowerInvariant()) } }
    foreach ($m in $Members) {
        if ($m.source -eq 'winget') {
            $extra = ConvertFrom-DFDbNull $m.extra
            if ($extra) {
                $e = $null
                try { $e = $extra | ConvertFrom-Json } catch { $e = $null }
                if ($e) {
                    $mon = $e.PSObject.Properties['Moniker']
                    if ($mon -and $mon.Value) { $tokens.Add("$($mon.Value)".Trim().ToLowerInvariant()) }
                }
            }
        }
    }
    $tokens.ToArray()
}

function ConvertTo-DFPackageUniverseCategories {
    <#
    .SYNOPSIS
        Categories whose rule keywords intersect the token set. Deduped, rule
        order preserved (deterministic).
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][string[]]$Tokens = @(),
        [AllowEmptyCollection()][object[]]$Rules = @()
    )
    $set = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($t in @($Tokens)) { if ($t) { [void]$set.Add(("$t".Trim().ToLowerInvariant())) } }

    $out = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($rule in @($Rules)) {
        foreach ($kw in @($rule.Keywords)) {
            if ($set.Contains($kw)) {
                if ($seen.Add($rule.Category)) { $out.Add($rule.Category) }
                break
            }
        }
    }
    $out.ToArray()
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/DFPackageUniverse.Merge.Tests.ps1 -Output Detailed"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add build/Private/DFPackageUniverse.Merge.ps1 tests/DFPackageUniverse.Merge.Tests.ps1 data/package-universe-categories.jsonc
git commit -m "feat(package-universe): Phase C first-pass category derivation + seed rules"
```

---

## Task 5: Grouping — clusters and singletons

**Files:**
- Modify: `build/Private/DFPackageUniverse.Merge.ps1`
- Test: `tests/DFPackageUniverse.Merge.Tests.ps1`

**Interfaces:**
- Produces: `Get-DFPackageUniverseToolGroups([object[]]$Rows, [object[]]$ClusterMembers) -> [object[]]` of `{ ClusterId [int or $null]; Members [object[]] }`. Every row lands in exactly one group; clustered groups (ordered by `cluster_id`) precede singletons (ordered by `source|package_id`) for deterministic tool_id assignment.

- [ ] **Step 1: Write the failing test**

Add to the `Describe` block:

```powershell
    Context 'Get-DFPackageUniverseToolGroups' {
        function R($s, $p) { [pscustomobject]@{ source = $s; package_id = $p } }
        function CM($cid, $s, $p) { [pscustomobject]@{ cluster_id = $cid; source = $s; package_id = $p } }

        It 'groups clustered rows together and makes each unclustered row a singleton' {
            $rows = @( (R 'scoop' 'main/bat'), (R 'winget' 'sharkdp.bat'), (R 'choco' 'solo') )
            $members = @( (CM 1 'scoop' 'main/bat'), (CM 1 'winget' 'sharkdp.bat') )
            $groups = Get-DFPackageUniverseToolGroups -Rows $rows -ClusterMembers $members

            @($groups).Count | Should -Be 2
            $groups[0].ClusterId | Should -Be 1
            @($groups[0].Members).Count | Should -Be 2
            $groups[1].ClusterId | Should -BeNullOrEmpty
            $groups[1].Members[0].package_id | Should -Be 'solo'
        }

        It 'accounts for every row exactly once' {
            $rows = @( (R 'scoop' 'a'), (R 'winget' 'b'), (R 'choco' 'c') )
            $members = @( (CM 7 'scoop' 'a'), (CM 7 'winget' 'b') )
            $groups = Get-DFPackageUniverseToolGroups -Rows $rows -ClusterMembers $members
            $total = (@($groups | ForEach-Object { $_.Members.Count } | Measure-Object -Sum).Sum)
            $total | Should -Be 3
        }
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/DFPackageUniverse.Merge.Tests.ps1 -Output Detailed"`
Expected: FAIL — `'Get-DFPackageUniverseToolGroups' is not recognized`.

- [ ] **Step 3: Write minimal implementation**

Append to `build/Private/DFPackageUniverse.Merge.ps1`:

```powershell
function Get-DFPackageUniverseToolGroups {
    <#
    .SYNOPSIS
        Partitions raw_packages rows into per-tool groups: rows in cluster_members
        accumulate under their cluster_id; every other row is its own singleton
        group (ClusterId $null). Clustered groups (sorted by cluster_id) precede
        singletons (sorted by source|package_id) so tool_id assignment is
        deterministic and runs are idempotent. Every row appears in exactly one group.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ClusterMembers
    )

    $byKey = @{}
    foreach ($cm in $ClusterMembers) { $byKey["$($cm.source)|$($cm.package_id)"] = [int]$cm.cluster_id }

    $clustered = @{}
    $singletons = [System.Collections.Generic.List[object]]::new()
    foreach ($r in $Rows) {
        $k = "$($r.source)|$($r.package_id)"
        if ($byKey.ContainsKey($k)) {
            $cid = $byKey[$k]
            if (-not $clustered.ContainsKey($cid)) { $clustered[$cid] = [System.Collections.Generic.List[object]]::new() }
            $clustered[$cid].Add($r)
        } else {
            $singletons.Add($r)
        }
    }

    $groups = [System.Collections.Generic.List[object]]::new()
    foreach ($cid in ($clustered.Keys | Sort-Object)) {
        $groups.Add([pscustomobject]@{ ClusterId = $cid; Members = @($clustered[$cid]) })
    }
    foreach ($r in ($singletons | Sort-Object { "$($_.source)|$($_.package_id)" })) {
        $groups.Add([pscustomobject]@{ ClusterId = $null; Members = @($r) })
    }
    $groups.ToArray()
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/DFPackageUniverse.Merge.Tests.ps1 -Output Detailed"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add build/Private/DFPackageUniverse.Merge.ps1 tests/DFPackageUniverse.Merge.Tests.ps1
git commit -m "feat(package-universe): Phase C grouping (clusters + singletons)"
```

---

## Task 6: Schema init + truncation

**Files:**
- Modify: `build/Private/DFPackageUniverse.Merge.ps1`
- Test: `tests/DFPackageUniverse.Merge.Tests.ps1`

**Interfaces:**
- Produces: `Initialize-DFPackageUniverseToolsSchema([string]$DatabasePath)` — creates `tools`, `tool_packages`, `tool_tags`, `tool_categories` if missing; then clears those four + `pipeline_log WHERE stage='merge'`. Leaves other stages' `pipeline_log` untouched.

- [ ] **Step 1: Write the failing test**

Add to the `Describe` block:

```powershell
    Context 'Initialize-DFPackageUniverseToolsSchema' {
        It 'creates the four tables and clears only stage=merge log rows' {
            $db = Join-Path ([System.IO.Path]::GetTempPath()) ("schematest-" + [guid]::NewGuid().ToString('N') + ".db")
            try {
                Invoke-SqliteQuery -DataSource $db -Query 'CREATE TABLE pipeline_log (id INTEGER PRIMARY KEY, stage TEXT, source TEXT, package_id TEXT, level TEXT, message TEXT, logged_at TEXT);'
                Invoke-SqliteQuery -DataSource $db -Query "INSERT INTO pipeline_log (stage, level, message, logged_at) VALUES ('link', 'review', 'keep me', 'now'), ('merge', 'review', 'drop me', 'now');"

                Initialize-DFPackageUniverseToolsSchema -DatabasePath $db

                $tables = @(Invoke-SqliteQuery -DataSource $db -Query "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name").name
                $tables | Should -Contain 'tools'
                $tables | Should -Contain 'tool_packages'
                $tables | Should -Contain 'tool_tags'
                $tables | Should -Contain 'tool_categories'

                $logs = @(Invoke-SqliteQuery -DataSource $db -Query 'SELECT stage FROM pipeline_log')
                @($logs).Count | Should -Be 1
                $logs[0].stage | Should -Be 'link'
            } finally { Remove-Item -Path $db -ErrorAction Ignore }
        }
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/DFPackageUniverse.Merge.Tests.ps1 -Output Detailed"`
Expected: FAIL — `'Initialize-DFPackageUniverseToolsSchema' is not recognized`.

- [ ] **Step 3: Write minimal implementation**

Append to `build/Private/DFPackageUniverse.Merge.ps1`:

```powershell
function Initialize-DFPackageUniverseToolsSchema {
    <#
    .SYNOPSIS
        Creates the Phase C (merge stage) tables if missing, then clears this
        stage's own rows -- the four tool tables plus pipeline_log stage='merge'
        -- so each run rebuilds the master tools table as a reproducible view
        over raw_packages + cluster_members. Other phases' log history is untouched.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DatabasePath)

    Invoke-SqliteQuery -DataSource $DatabasePath -Query @'
CREATE TABLE IF NOT EXISTS tools (
  tool_id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  name_source TEXT,
  description TEXT,
  description_source TEXT,
  homepage TEXT,
  repo_url TEXT,
  license TEXT,
  source_count INTEGER NOT NULL,
  cluster_id INTEGER,
  needs_review INTEGER NOT NULL,
  review_reasons TEXT,
  created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS tool_packages (
  tool_id INTEGER NOT NULL,
  source TEXT NOT NULL, package_id TEXT NOT NULL,
  name TEXT, version TEXT, description TEXT, homepage TEXT, license TEXT, publisher TEXT,
  extra TEXT,
  PRIMARY KEY(source, package_id)
);
CREATE TABLE IF NOT EXISTS tool_tags (
  tool_id INTEGER NOT NULL,
  tag TEXT NOT NULL,
  PRIMARY KEY(tool_id, tag)
);
CREATE TABLE IF NOT EXISTS tool_categories (
  tool_id INTEGER NOT NULL,
  category TEXT NOT NULL,
  PRIMARY KEY(tool_id, category)
);
'@

    foreach ($t in 'tools', 'tool_packages', 'tool_tags', 'tool_categories') {
        Invoke-SqliteQuery -DataSource $DatabasePath -Query "DELETE FROM $t;"
    }
    Invoke-SqliteQuery -DataSource $DatabasePath -Query "DELETE FROM pipeline_log WHERE stage = 'merge';"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/DFPackageUniverse.Merge.Tests.ps1 -Output Detailed"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add build/Private/DFPackageUniverse.Merge.ps1 tests/DFPackageUniverse.Merge.Tests.ps1
git commit -m "feat(package-universe): Phase C tools schema + truncation"
```

---

## Task 7: Persistence

**Files:**
- Modify: `build/Private/DFPackageUniverse.Merge.ps1`
- Test: `tests/DFPackageUniverse.Merge.Tests.ps1`

**Interfaces:**
- Consumes: an open PSSQLite `$Connection`; Tool objects `{ Record; Members [object[]]; Tags [string[]]; Categories [string[]]; ClusterId }`.
- Produces: `Save-DFPackageUniverseTools($Connection, [object[]]$Tools)` — one transaction writing `tools` (sequential `tool_id`), `tool_packages` (one per member, full `extra`), `tool_tags`, `tool_categories`, and a `pipeline_log` stage='merge' review row per needs-review tool.

- [ ] **Step 1: Write the failing test**

Add a shared DB helper to the top-level `BeforeAll` (below the dot-sources):

```powershell
    function New-MergeTestDb {
        $db = Join-Path ([System.IO.Path]::GetTempPath()) ("mergetest-" + [guid]::NewGuid().ToString('N') + ".db")
        Invoke-SqliteQuery -DataSource $db -Query @'
CREATE TABLE raw_packages (id INTEGER PRIMARY KEY, source TEXT, package_id TEXT, name TEXT, version TEXT, description TEXT, homepage TEXT, license TEXT, publisher TEXT, tags TEXT, extra TEXT, fetched_at TEXT, UNIQUE(source, package_id));
CREATE TABLE pipeline_log (id INTEGER PRIMARY KEY, stage TEXT, source TEXT, package_id TEXT, level TEXT, message TEXT, logged_at TEXT);
CREATE TABLE cluster_members (cluster_id INTEGER, source TEXT, package_id TEXT, join_method TEXT, join_confidence REAL, PRIMARY KEY(source, package_id));
'@
        Initialize-DFPackageUniverseToolsSchema -DatabasePath $db
        $db
    }
```

Add to the `Describe` block:

```powershell
    Context 'Save-DFPackageUniverseTools' {
        It 'writes the parent, packages, tags, categories, and a review log row' {
            $db = New-MergeTestDb
            try {
                $tool = [pscustomobject]@{
                    ClusterId = 1
                    Record = [pscustomobject]@{
                        Name = 'bat'; NameSource = 'winget'; Description = 'A cat clone'; DescriptionSource = 'winget'
                        Homepage = 'https://github.com/sharkdp/bat'; RepoUrl = 'https://github.com/sharkdp/bat'
                        License = 'MIT'; SourceCount = 2; NeedsReview = $true; ReviewReasons = @('license-conflict: MIT | Apache-2.0')
                    }
                    Members = @(
                        [pscustomobject]@{ source = 'winget'; package_id = 'sharkdp.bat'; name = 'bat'; version = '0.24'; description = 'A cat clone'; homepage = 'h'; license = 'MIT'; publisher = 'sharkdp'; extra = '{"a":1}' }
                        [pscustomobject]@{ source = 'choco'; package_id = 'bat'; name = 'Bat'; version = '0.24.0'; description = 'd'; homepage = 'h'; license = 'https://x/LICENSE'; publisher = 'p'; extra = $null }
                    )
                    Tags = @('cat', 'viewer')
                    Categories = @('viewer')
                }
                $conn = New-SQLiteConnection -DataSource $db
                try { Save-DFPackageUniverseTools -Connection $conn -Tools @($tool) } finally { $conn.Close() }

                (Invoke-SqliteQuery -DataSource $db -Query 'SELECT COUNT(*) n FROM tools').n | Should -Be 1
                (Invoke-SqliteQuery -DataSource $db -Query 'SELECT name, name_source, needs_review FROM tools').name | Should -Be 'bat'
                (Invoke-SqliteQuery -DataSource $db -Query 'SELECT needs_review FROM tools').needs_review | Should -Be 1
                (Invoke-SqliteQuery -DataSource $db -Query 'SELECT COUNT(*) n FROM tool_packages').n | Should -Be 2
                (Invoke-SqliteQuery -DataSource $db -Query "SELECT extra FROM tool_packages WHERE source='winget'").extra | Should -Be '{"a":1}'
                (Invoke-SqliteQuery -DataSource $db -Query 'SELECT COUNT(*) n FROM tool_tags').n | Should -Be 2
                (Invoke-SqliteQuery -DataSource $db -Query 'SELECT COUNT(*) n FROM tool_categories').n | Should -Be 1
                (Invoke-SqliteQuery -DataSource $db -Query "SELECT COUNT(*) n FROM pipeline_log WHERE stage='merge' AND level='review'").n | Should -Be 1
            } finally { Remove-Item -Path $db -ErrorAction Ignore }
        }
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/DFPackageUniverse.Merge.Tests.ps1 -Output Detailed"`
Expected: FAIL — `'Save-DFPackageUniverseTools' is not recognized`.

- [ ] **Step 3: Write minimal implementation**

Append to `build/Private/DFPackageUniverse.Merge.ps1`:

```powershell
function Save-DFPackageUniverseTools {
    <#
    .SYNOPSIS
        Persists a merge run in one transaction: the master tools rows (sequential
        tool_id), the lossless tool_packages children (every member's typed fields
        + verbatim extra), tool_tags, tool_categories, and a pipeline_log
        stage='merge' level='review' row per needs-review tool.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Connection,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Tools
    )

    $now = [datetime]::UtcNow.ToString('o')
    Invoke-SqliteQuery -SQLiteConnection $Connection -Query 'BEGIN TRANSACTION;'
    try {
        $tid = 0
        foreach ($tool in $Tools) {
            $tid++
            $rec = $tool.Record
            $rr = if (@($rec.ReviewReasons).Count -gt 0) { ConvertTo-Json -Compress -InputObject @($rec.ReviewReasons) } else { $null }
            Invoke-SqliteQuery -SQLiteConnection $Connection -Query @'
INSERT INTO tools (tool_id, name, name_source, description, description_source, homepage, repo_url, license, source_count, cluster_id, needs_review, review_reasons, created_at)
VALUES (@id, @name, @ns, @desc, @ds, @home, @repo, @lic, @sc, @cid, @rev, @rr, @at);
'@ -SqlParameters @{
                id = $tid; name = $rec.Name; ns = $rec.NameSource; desc = $rec.Description; ds = $rec.DescriptionSource
                home = $rec.Homepage; repo = $rec.RepoUrl; lic = $rec.License; sc = $rec.SourceCount
                cid = $tool.ClusterId; rev = [int][bool]$rec.NeedsReview; rr = $rr; at = $now
            }

            foreach ($m in $tool.Members) {
                Invoke-SqliteQuery -SQLiteConnection $Connection -Query @'
INSERT INTO tool_packages (tool_id, source, package_id, name, version, description, homepage, license, publisher, extra)
VALUES (@id, @src, @pid, @name, @ver, @desc, @home, @lic, @pub, @extra);
'@ -SqlParameters @{
                    id = $tid; src = $m.source; pid = $m.package_id; name = $m.name; ver = $m.version
                    desc = $m.description; home = $m.homepage; lic = $m.license; pub = $m.publisher; extra = $m.extra
                }
            }

            foreach ($tag in @($tool.Tags)) {
                Invoke-SqliteQuery -SQLiteConnection $Connection -Query 'INSERT OR IGNORE INTO tool_tags (tool_id, tag) VALUES (@id, @tag);' -SqlParameters @{ id = $tid; tag = $tag }
            }
            foreach ($cat in @($tool.Categories)) {
                Invoke-SqliteQuery -SQLiteConnection $Connection -Query 'INSERT OR IGNORE INTO tool_categories (tool_id, category) VALUES (@id, @cat);' -SqlParameters @{ id = $tid; cat = $cat }
            }

            if ($rec.NeedsReview) {
                Invoke-SqliteQuery -SQLiteConnection $Connection -Query @'
INSERT INTO pipeline_log (stage, source, package_id, level, message, logged_at)
VALUES ('merge', NULL, NULL, 'review', @msg, @at);
'@ -SqlParameters @{ msg = "tool $tid ($($rec.Name)) needs review: $(@($rec.ReviewReasons) -join '; ')"; at = $now }
            }
        }
        Invoke-SqliteQuery -SQLiteConnection $Connection -Query 'COMMIT;'
    } catch {
        Invoke-SqliteQuery -SQLiteConnection $Connection -Query 'ROLLBACK;'
        throw
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/DFPackageUniverse.Merge.Tests.ps1 -Output Detailed"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add build/Private/DFPackageUniverse.Merge.ps1 tests/DFPackageUniverse.Merge.Tests.ps1
git commit -m "feat(package-universe): Phase C persistence (tools + packages + tags + categories)"
```

---

## Task 8: Orchestration — end-to-end merge over a connection

**Files:**
- Modify: `build/Private/DFPackageUniverse.Merge.ps1`
- Test: `tests/DFPackageUniverse.Merge.Tests.ps1`

**Interfaces:**
- Consumes: an open `$Connection` (schema already initialized); optional `[string]$CategoryRulesPath`.
- Produces: `Invoke-DFPackageUniverseToolMerge($Connection, [string]$CategoryRulesPath) -> { RowsRead; Tools; Packages; Singletons; Tags; Categories; Review }`. Reads `raw_packages` + `cluster_members`, builds groups (asserting `Σ members == RowsRead`), resolves records + tags + categories, and persists via `Save-DFPackageUniverseTools`.

- [ ] **Step 1: Write the failing test**

Add a seeding helper to the top-level `BeforeAll`:

```powershell
    function Add-RawRow {
        param($Db, $Source, $PackageId, $Name, $Description = 'd', $Homepage = $null, $License = 'MIT', $Publisher = $null, $Tags = $null, $Extra = $null)
        Invoke-SqliteQuery -DataSource $Db -Query @'
INSERT INTO raw_packages (source, package_id, name, version, description, homepage, license, publisher, tags, extra, fetched_at)
VALUES (@s, @p, @n, '1', @d, @h, @l, @pub, @t, @e, 'now');
'@ -SqlParameters @{ s = $Source; p = $PackageId; n = $Name; d = $Description; h = $Homepage; l = $License; pub = $Publisher; t = $Tags; e = $Extra }
    }
    function Add-ClusterMember { param($Db, $Cid, $Source, $PackageId)
        Invoke-SqliteQuery -DataSource $Db -Query "INSERT INTO cluster_members (cluster_id, source, package_id, join_method, join_confidence) VALUES (@c, @s, @p, 'repo', 1.0);" -SqlParameters @{ c = $Cid; s = $Source; p = $PackageId }
    }
```

Add to the `Describe` block:

```powershell
    Context 'Invoke-DFPackageUniverseToolMerge' {
        It 'merges a 3-catalog cluster into one tool and keeps a singleton separate (no data lost)' {
            $db = New-MergeTestDb
            try {
                $batExtra = ConvertTo-Json -Compress @{ ProjectSourceUrl = 'https://github.com/sharkdp/bat' }
                Add-RawRow -Db $db -Source 'scoop'  -PackageId 'main/bat'    -Name 'bat' -Description 'short' -Tags (ConvertTo-Json -Compress @('cat'))
                Add-RawRow -Db $db -Source 'winget' -PackageId 'sharkdp.bat' -Name 'bat' -Description 'A cat(1) clone with wings.' -Tags (ConvertTo-Json -Compress @('cat', 'less'))
                Add-RawRow -Db $db -Source 'choco'  -PackageId 'bat'         -Name 'Bat' -License 'https://x/LICENSE' -Extra $batExtra
                Add-RawRow -Db $db -Source 'scoop'  -PackageId 'main/solo'   -Name 'solo'
                Add-ClusterMember -Db $db -Cid 1 -Source 'scoop'  -PackageId 'main/bat'
                Add-ClusterMember -Db $db -Cid 1 -Source 'winget' -PackageId 'sharkdp.bat'
                Add-ClusterMember -Db $db -Cid 1 -Source 'choco'  -PackageId 'bat'

                $conn = New-SQLiteConnection -DataSource $db
                try { $summary = Invoke-DFPackageUniverseToolMerge -Connection $conn -CategoryRulesPath $null } finally { $conn.Close() }

                $summary.RowsRead | Should -Be 4
                $summary.Tools | Should -Be 2
                $summary.Packages | Should -Be 4     # no data lost: every package accounted for
                $summary.Singletons | Should -Be 1

                $bat = Invoke-SqliteQuery -DataSource $db -Query "SELECT * FROM tools WHERE cluster_id = 1"
                $bat.name | Should -Be 'bat'
                $bat.name_source | Should -Be 'winget'
                $bat.description_source | Should -Be 'winget'
                $bat.repo_url | Should -Be 'https://github.com/sharkdp/bat'
                $bat.source_count | Should -Be 3

                (Invoke-SqliteQuery -DataSource $db -Query "SELECT COUNT(*) n FROM tool_packages WHERE tool_id = $($bat.tool_id)").n | Should -Be 3
                $tags = @(Invoke-SqliteQuery -DataSource $db -Query "SELECT tag FROM tool_tags WHERE tool_id = $($bat.tool_id)").tag
                $tags | Should -Contain 'cat'
                $tags | Should -Contain 'less'

                # Core contract: sum of children equals the input row count.
                (Invoke-SqliteQuery -DataSource $db -Query 'SELECT COUNT(*) n FROM tool_packages').n | Should -Be 4
            } finally { Remove-Item -Path $db -ErrorAction Ignore }
        }

        It 'is idempotent: a second run reproduces identical row counts' {
            $db = New-MergeTestDb
            try {
                Add-RawRow -Db $db -Source 'winget' -PackageId 'A.X' -Name 'x' -Tags (ConvertTo-Json -Compress @('grep'))
                Add-RawRow -Db $db -Source 'scoop'  -PackageId 'main/y' -Name 'y'
                foreach ($i in 1..2) {
                    $conn = New-SQLiteConnection -DataSource $db
                    try { Invoke-DFPackageUniverseToolMerge -Connection $conn -CategoryRulesPath $null | Out-Null } finally { $conn.Close() }
                    Initialize-DFPackageUniverseToolsSchema -DatabasePath $db  # truncate before re-run, as the orchestrator does
                }
                # Final populated run (schema was just truncated):
                $conn = New-SQLiteConnection -DataSource $db
                try { $s = Invoke-DFPackageUniverseToolMerge -Connection $conn -CategoryRulesPath $null } finally { $conn.Close() }
                $s.Tools | Should -Be 2
                (Invoke-SqliteQuery -DataSource $db -Query 'SELECT COUNT(*) n FROM tool_packages').n | Should -Be 2
            } finally { Remove-Item -Path $db -ErrorAction Ignore }
        }
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/DFPackageUniverse.Merge.Tests.ps1 -Output Detailed"`
Expected: FAIL — `'Invoke-DFPackageUniverseToolMerge' is not recognized`.

- [ ] **Step 3: Write minimal implementation**

Append to `build/Private/DFPackageUniverse.Merge.ps1`:

```powershell
function Invoke-DFPackageUniverseToolMerge {
    <#
    .SYNOPSIS
        The Phase C core: reads raw_packages + cluster_members from an open
        connection, groups them into tools (clusters + singletons), resolves each
        tool's canonical record/tags/categories, persists everything, and returns
        a reconciliation summary. The schema must already be initialized. Asserts
        the no-data-lost contract (grouped packages == raw_packages count).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Connection,
        [string]$CategoryRulesPath
    )

    $raw = @(Invoke-SqliteQuery -SQLiteConnection $Connection -Query 'SELECT source, package_id, name, version, description, homepage, license, publisher, tags, extra FROM raw_packages')
    $rows = @(foreach ($r in $raw) {
        [pscustomobject]@{
            source      = $r.source
            package_id  = $r.package_id
            name        = ConvertFrom-DFDbNull $r.name
            version     = ConvertFrom-DFDbNull $r.version
            description = ConvertFrom-DFDbNull $r.description
            homepage    = ConvertFrom-DFDbNull $r.homepage
            license     = ConvertFrom-DFDbNull $r.license
            publisher   = ConvertFrom-DFDbNull $r.publisher
            tags        = ConvertFrom-DFDbNull $r.tags
            extra       = ConvertFrom-DFDbNull $r.extra
        }
    })

    $members = @(Invoke-SqliteQuery -SQLiteConnection $Connection -Query 'SELECT cluster_id, source, package_id FROM cluster_members')
    $groups = @(Get-DFPackageUniverseToolGroups -Rows $rows -ClusterMembers $members)

    $grouped = [int](@($groups | ForEach-Object { $_.Members.Count } | Measure-Object -Sum).Sum)
    if ($grouped -ne $rows.Count) {
        throw "Phase C reconciliation failed: $grouped packages grouped but raw_packages has $($rows.Count)"
    }

    $rules = if ($CategoryRulesPath) { Import-DFPackageUniverseCategoryRules -Path $CategoryRulesPath } else { @() }

    $tools = @(foreach ($g in $groups) {
        $ms = @($g.Members)
        $record = Resolve-DFPackageUniverseToolRecord -Members $ms
        $tags = Get-DFPackageUniverseToolTags -Members $ms
        $tokens = Get-DFPackageUniverseCategoryTokens -Members $ms -Tags $tags
        $cats = ConvertTo-DFPackageUniverseCategories -Tokens $tokens -Rules $rules
        [pscustomobject]@{ Record = $record; Members = $ms; Tags = $tags; Categories = $cats; ClusterId = $g.ClusterId }
    })

    Save-DFPackageUniverseTools -Connection $Connection -Tools $tools

    [pscustomobject]@{
        RowsRead   = $rows.Count
        Tools      = $tools.Count
        Packages   = $grouped
        Singletons = @($tools | Where-Object { $_.Record.SourceCount -eq 1 }).Count
        Tags       = [int](@($tools | ForEach-Object { $_.Tags.Count } | Measure-Object -Sum).Sum)
        Categories = [int](@($tools | ForEach-Object { $_.Categories.Count } | Measure-Object -Sum).Sum)
        Review     = @($tools | Where-Object { $_.Record.NeedsReview }).Count
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/DFPackageUniverse.Merge.Tests.ps1 -Output Detailed"`
Expected: PASS (all merge tests).

- [ ] **Step 5: Commit**

```bash
git add build/Private/DFPackageUniverse.Merge.ps1 tests/DFPackageUniverse.Merge.Tests.ps1
git commit -m "feat(package-universe): Phase C merge orchestration + reconciliation"
```

---

## Task 9: Build orchestrator script + CHANGELOG

**Files:**
- Create: `build/Build-DFPackageUniverseTools.ps1`
- Modify: `CHANGELOG.md`
- Test: `tests/DFPackageUniverse.Merge.Tests.ps1`

**Interfaces:**
- Consumes: `Initialize-DFPackageUniverseToolsSchema`, `Invoke-DFPackageUniverseToolMerge`, `Get-DFPackageUniverseRepoKey` (via dot-sourced `build/Private/*.ps1`).
- Produces: a runnable script that opens `universe.db`, guards that `cluster_members` exists (Phase B ran), initializes the schema, runs the merge, prints a reconciliation summary, and returns the summary object.

- [ ] **Step 1: Write the failing test**

Add to the `Describe` block:

```powershell
    Context 'Build-DFPackageUniverseTools.ps1' {
        It 'runs end-to-end against a prepared DB and returns a summary' {
            $db = New-MergeTestDb
            try {
                Add-RawRow -Db $db -Source 'winget' -PackageId 'A.X' -Name 'x'
                Add-RawRow -Db $db -Source 'scoop'  -PackageId 'main/y' -Name 'y'
                $summary = & "$PSScriptRoot/../build/Build-DFPackageUniverseTools.ps1" -DatabasePath $db -CategoryRulesPath $null 6>$null
                $summary.Tools | Should -Be 2
                $summary.Packages | Should -Be 2
            } finally { Remove-Item -Path $db -ErrorAction Ignore }
        }

        It 'throws a helpful error when cluster_members is missing (Phase B not run)' {
            $db = Join-Path ([System.IO.Path]::GetTempPath()) ("nob-" + [guid]::NewGuid().ToString('N') + ".db")
            try {
                Invoke-SqliteQuery -DataSource $db -Query 'CREATE TABLE raw_packages (id INTEGER PRIMARY KEY, source TEXT, package_id TEXT, fetched_at TEXT); CREATE TABLE pipeline_log (id INTEGER PRIMARY KEY, stage TEXT, source TEXT, package_id TEXT, level TEXT, message TEXT, logged_at TEXT);'
                { & "$PSScriptRoot/../build/Build-DFPackageUniverseTools.ps1" -DatabasePath $db -CategoryRulesPath $null 6>$null } | Should -Throw '*cluster_members*'
            } finally { Remove-Item -Path $db -ErrorAction Ignore }
        }
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/DFPackageUniverse.Merge.Tests.ps1 -Output Detailed"`
Expected: FAIL — the script file does not exist.

- [ ] **Step 3: Write minimal implementation**

Create `build/Build-DFPackageUniverseTools.ps1`:

```powershell
#Requires -Version 7.0
<#
.SYNOPSIS
    Phase C of the package-universe pipeline: tool merge (cluster flattening).
.DESCRIPTION
    Reads raw_packages (Phase A) and cluster_members (Phase B) from the shared
    universe.db and flattens them into the master tools table: one row per
    real-world tool across the whole corpus (clusters + singletons), lossless
    (per-catalog rows preserved in tool_packages), with per-field priority picks,
    a license conflict flag, a tag union, and first-pass categories. Writes
    tools / tool_packages / tool_tags / tool_categories plus review rows to
    pipeline_log (stage='merge'). See
    docs/superpowers/specs/2026-07-16-package-universe-tool-merge-design.md.
.PARAMETER DatabasePath
    Path to the shared SQLite working database (default: the standard
    build/.package-universe/universe.db next to this script).
.PARAMETER CategoryRulesPath
    Path to the keyword->category rule file (default: data/package-universe-categories.jsonc).
.OUTPUTS
    A reconciliation summary object (RowsRead, Tools, Packages, Singletons, Tags,
    Categories, Review).
.EXAMPLE
    ./build/Build-DFPackageUniverseTools.ps1
#>
[CmdletBinding()]
param(
    [string]$DatabasePath = (Join-Path $PSScriptRoot '.package-universe/universe.db'),
    [string]$CategoryRulesPath = (Join-Path $PSScriptRoot '../data/package-universe-categories.jsonc')
)

Set-StrictMode -Version Latest

if (-not (Get-Module -ListAvailable -Name 'PSSQLite')) {
    throw "Build-DFPackageUniverseTools: required module 'PSSQLite' is not installed. Install it with: Install-Module PSSQLite -Scope CurrentUser"
}
Import-Module PSSQLite -ErrorAction Stop

# Private/*.ps1 functions aren't exported; dot-source directly (mirroring the
# Phase A/B scripts). build/Private supplies the DB helpers, the Phase B repo-key
# helper reused here, and the Phase C merge helpers.
if (-not (Get-Command Invoke-DFPackageUniverseToolMerge -ErrorAction Ignore)) {
    Get-ChildItem -Path (Join-Path $PSScriptRoot 'Private') -Filter '*.ps1' | ForEach-Object { . $_.FullName }
}

if (-not (Test-Path $DatabasePath)) {
    throw "Build-DFPackageUniverseTools: database not found at '$DatabasePath'. Run Build-DFPackageUniverseRaw.ps1 (Phase A) and Build-DFPackageUniverseLinks.ps1 (Phase B) first."
}

$hasMembers = @(Invoke-SqliteQuery -DataSource $DatabasePath -Query "SELECT name FROM sqlite_master WHERE type='table' AND name='cluster_members';")
if ($hasMembers.Count -eq 0) {
    throw "Build-DFPackageUniverseTools: cluster_members table not found. Run Build-DFPackageUniverseLinks.ps1 (Phase B) first."
}

Initialize-DFPackageUniverseToolsSchema -DatabasePath $DatabasePath

$conn = New-SQLiteConnection -DataSource $DatabasePath
try {
    $summary = Invoke-DFPackageUniverseToolMerge -Connection $conn -CategoryRulesPath $CategoryRulesPath
} finally {
    $conn.Close()
}

Write-Host 'Phase C (tool merge) complete:'
Write-Host "  raw_packages read : $($summary.RowsRead)"
Write-Host "  tools             : $($summary.Tools)"
Write-Host "  ‣ singletons      : $($summary.Singletons)"
Write-Host "  tool_packages     : $($summary.Packages)"
Write-Host "  tags              : $($summary.Tags)"
Write-Host "  categories        : $($summary.Categories)"
Write-Host "  review (license)  : $($summary.Review)"

$summary
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/DFPackageUniverse.Merge.Tests.ps1 -Output Detailed"`
Expected: PASS.

- [ ] **Step 5: Update CHANGELOG**

Add under the `[Unreleased]` heading in `CHANGELOG.md`:

```markdown
### Added
- **Package-universe Phase C (tool merge)** — `build/Build-DFPackageUniverseTools.ps1` flattens Phase B clusters and singletons into a master `tools` table (one row per real-world tool across the whole corpus, lossless via a `tool_packages` child), with per-field priority picks (winget > choco > scoop) and provenance, a license single-answer conflict flag, a `tool_tags` union, and first-pass `tool_categories` from a committed `data/package-universe-categories.jsonc` rule file. Build-only; no public module surface change.
```

- [ ] **Step 6: Run the full suite to confirm no regressions**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/ -Output Detailed"`
Expected: all tests pass (the Clipboard test is a known contention flake — re-run once if it fails in isolation).

- [ ] **Step 7: Commit**

```bash
git add build/Build-DFPackageUniverseTools.ps1 tests/DFPackageUniverse.Merge.Tests.ps1 CHANGELOG.md
git commit -m "feat(package-universe): Phase C build orchestrator (Build-DFPackageUniverseTools)"
```

---

## Post-implementation: live verification (user-run)

After the suite is green, run the merge against the real `universe.db` (offline; requires Phase A + B already run):

```powershell
./build/Build-DFPackageUniverseTools.ps1
```

Then sanity-check (evidence before assertions):

```powershell
$db = './build/.package-universe/universe.db'
Invoke-SqliteQuery -DataSource $db -Query 'SELECT COUNT(*) tools, SUM(source_count = 1) singletons, SUM(needs_review) review FROM tools'
# Core contract must hold exactly:
Invoke-SqliteQuery -DataSource $db -Query 'SELECT (SELECT COUNT(*) FROM tool_packages) packages, (SELECT COUNT(*) FROM raw_packages) raw'
# Ground truth:
Invoke-SqliteQuery -DataSource $db -Query "SELECT t.name, t.name_source, t.repo_url, GROUP_CONCAT(p.source) srcs FROM tools t JOIN tool_packages p ON p.tool_id = t.tool_id WHERE t.name = 'bat' GROUP BY t.tool_id"
```

Expect `packages == raw` exactly (no data lost), `bat` resolving to one tool with `name_source='winget'` and `repo_url` `https://github.com/sharkdp/bat`, and a small license review count.

---

## Self-Review (completed during authoring)

- **Spec coverage:** master `tools` table (Tasks 6–8) ✓; lossless `tool_packages` (Task 7, no-data-lost assert Task 8) ✓; per-field priority + provenance (Task 2) ✓; winget friendly name (Task 2) ✓; repo via Phase B authority (Task 2) ✓; license single-answer flag (Task 2) ✓; publisher left on child, not parent (Task 7 schema — no publisher column on `tools`) ✓; tag union (Task 3) ✓; category rule file + derivation (Task 4) ✓; singletons covered (Task 5) ✓; truncate-rebuild + `stage='merge'` (Task 6) ✓; reconciliation (Task 8) ✓; ground-truth `bat` + idempotency tests (Task 8) ✓; orchestrator mirroring Phase A/B (Task 9) ✓.
- **Two spec refinements found in code, applied here:** choco tags are in the `tags` column (not `extra`), so the union reads the column for all sources (Task 3); choco `license` is a URL, so the conflict check excludes URLs to stay precise (Tasks 1–2). Both documented in the code comments.
- **Type consistency:** the member row shape `{ source; package_id; name; version; description; homepage; license; publisher; tags; extra }` and the Tool object `{ Record; Members; Tags; Categories; ClusterId }` are used identically across Tasks 2–8. `Record` fields match between Task 2 (producer) and Task 7 (consumer).
