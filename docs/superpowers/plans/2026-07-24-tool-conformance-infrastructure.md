# Tool Conformance Infrastructure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build DotForge's author-time tool-conformance subsystem — a probe harness, a versioned ledger, an issue report, and adapter↔claim linking — proven end to end on `bat` and `glow`.

**Architecture:** A dot-sourced function library (`build/DFConformance.ps1`) holds all conformance logic (descriptor validation, probe execution, ledger merge/schema, adapter scan, report render). A thin orchestrator script (`build/Test-DFToolConformance.ps1`) wires the library to hand-authored `build/conformance/<tool>.jsonc` descriptors and an injectable spawn seam, writing `data/tool-conformance.json` + `reports/tool-conformance-issues.md`. All external-tool spawning routes through one scriptblock so tests run with canned output and never spawn a real process. Nothing here is ever loaded by the DotForge module.

**Tech Stack:** PowerShell 7+, Pester 5/6 (suite passes under both). Mirrors the existing `build/Build-DFToolIdentities.ps1` + `tests/Build-DFToolIdentities.Tests.ps1` pattern.

## Global Constraints

Copied from `docs/superpowers/specs/2026-07-24-tool-conformance-infrastructure-design.md`. Every task implicitly includes these:

- **Author-time only.** No file under `build/`, `data/tool-conformance.json`, or `reports/` is ever loaded or invoked by the DotForge module (`DotForge.psm1`). Do not add dot-sources of these to any module file.
- **`#Requires -Version 7.0`** and **`Set-StrictMode -Version Latest`** at the top of every author-side `.ps1` (harness, library, code-probes).
- **No system clock.** The harness NEVER calls `Get-Date`/`[DateTime]::Now`. Timestamps arrive via the `-ProbedAt` parameter or a descriptor field.
- **Injectable spawn seam.** All external-tool execution goes through a `[scriptblock]$SpawnTool` parameter; tests inject a canned scriptblock. Default is the real child-process implementation.
- **Seam contract:** `$SpawnTool` is invoked `& $SpawnTool $Exe $Argv $EnvMap $Cwd` and MUST return a hashtable `@{ ExitCode = [int]; StdOut = [string]; StdErr = [string]; Absent = [bool] }`. `Absent = $true` means the executable could not be resolved.
- **Claim id grammar:** `^[a-z0-9][a-z0-9._-]*/honors-(xdg|env|config-read|config-content|flag)(:[^/]+)?$` (e.g. `bat/honors-env:BAT_CONFIG_PATH`, `glow/honors-flag:-s`).
- **Verdict enum:** `pass | fail | manual | unknown`. A `manual` claim MUST carry a non-empty `retest` string.
- **Probe `kind` set:** `env-then-spawn | flag-then-spawn | manual | code`.
- **`expect` vocabulary (spawn kinds):** exactly one of `match` (regex), `notMatch` (regex), `contains` (literal substring), `notContains` (literal substring); tested against combined `StdOut` + `StdErr`. Values are token-expanded before comparison.
- **Token expansion:** descriptor string values expand `${SCRATCH}` (the per-probe temp dir) then delegate `${XDG_*}` to `Private/Expand-DFXdgPath.ps1`. `Expand-DFConformanceToken` does NOT normalize non-XDG values — a `${SCRATCH}`-expanded path is already canonical, and normalizing an `expect` substring would break `contains` matching against the tool's raw output.
- **StrictMode-safe optional property access.** Under `Set-StrictMode -Version Latest`, referencing a genuinely-absent property of a `[pscustomobject]` (a JSON field omitted from a fragment) THROWS `PropertyNotFoundException` — it does NOT return `$null`. For any OPTIONAL field on a parsed fragment/probe/claim, read it with `$obj.PSObject.Properties['name']?.Value` (yields `$null` when absent), never bare `$obj.name`. Fields already validated as present may use bare access. Hashtables are exempt — `$hash.MissingKey` returns `$null` under StrictMode.
- **Paths through `ConvertTo-DFPath`** where a filesystem path is stored/compared (house rule). `Expand-DFXdgPath` already applies it for `${XDG_*}` values.
- **Tests run:** `pwsh -NoProfile -Command 'Invoke-Pester tests/<file> -Output Detailed'`. Full suite: `Invoke-Pester tests/ -Output Detailed`. Must stay green under Pester 5.8.0 and 6.0.1.

## File Structure

**Create (author-side):**
- `build/DFConformance.ps1` — function library, dot-sourced by the harness and the unit tests. No param block, no top-level side effects; function definitions only.
- `build/Test-DFToolConformance.ps1` — orchestrator / entry point (param block + real seam + wiring).
- `build/conformance/bat.jsonc` — bat probe descriptors.
- `build/conformance/glow.jsonc` — glow probe descriptors.
- `build/conformance/probes/bat.theme.ps1` — bespoke `code` probe for `bat/honors-config-content:theme`.
- `data/tool-conformance.json` — generated, committed ledger.
- `reports/tool-conformance-issues.md` — generated, committed issue report.
- `tests/DFConformance.Tests.ps1` — unit tests for the library functions.
- `tests/Test-DFToolConformance.Tests.ps1` — integration + shipped-data tests for the harness.

**Modify:**
- `Tools/glow.ps1` — add the `# adapter for glow/honors-env:GLOW_CONFIG_DIR` comment.
- `docs/external-dependencies.md` — cross-reference the glow entry to its ledger claim id.

## Library function inventory (defined across Tasks 1–5)

These signatures are the contract later tasks rely on. All live in `build/DFConformance.ps1`.

```
Read-DFConformanceFragment  -Path <string>                       -> [pscustomobject]  # parse .jsonc (strip // comments)
Expand-DFConformanceToken   -Value <string> -Scratch <string>    -> [string]
Test-DFConformanceDescriptor -Fragment <pscustomobject>          -> void (throws on invalid)
Get-DFToolVersion  -Exe <string> -VersionArgs <string[]> -SpawnTool <scriptblock> -> [string] or $null
Invoke-DFConformanceProbe -Claim <pscustomobject> -Scratch <string> -ProbesDir <string> -SpawnTool <scriptblock>
                                                                 -> [hashtable] @{ id; verdict; kind; evidence; retest }
Merge-DFConformanceRecord -Existing <pscustomobject> -FreshClaims <hashtable[]> -Version <string>
                                                                 -> [hashtable] @{ Claims = [hashtable[]]; Notes = [string[]] }
Test-DFConformanceLedgerSchema -Ledger <pscustomobject>          -> void (throws on invalid)
Get-DFConformanceAdapterLink -ToolsPath <string>                 -> [hashtable[]] @{ Claim; File; Line }
Write-DFConformanceReport -Ledger <hashtable> -AdapterLinks <hashtable[]> -Path <string> -> void
```

---

### Task 1: Library scaffold — fragment reader, token expansion, descriptor validation

**Files:**
- Create: `build/DFConformance.ps1`
- Test: `tests/DFConformance.Tests.ps1`

**Interfaces:**
- Consumes: `Private/Expand-DFXdgPath.ps1` (function `Expand-DFXdgPath -Template <string>`), `Private/ConvertTo-DFPath.ps1`.
- Produces: `Read-DFConformanceFragment`, `Expand-DFConformanceToken`, `Test-DFConformanceDescriptor` (signatures above).

- [ ] **Step 1: Write the failing test**

Create `tests/DFConformance.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/../Private/ConvertTo-DFPath.ps1"
    . "$PSScriptRoot/../Private/Expand-DFXdgPath.ps1"
    . "$PSScriptRoot/../build/DFConformance.ps1"
}

Describe 'Expand-DFConformanceToken' {
    It 'expands ${SCRATCH} to the scratch dir' {
        Expand-DFConformanceToken -Value '${SCRATCH}/bat.conf' -Scratch 'C:\tmp\s' |
            Should -Be 'C:\tmp\s\bat.conf'
    }
    It 'delegates ${XDG_CONFIG_HOME} to Expand-DFXdgPath' {
        $Env:XDG_CONFIG_HOME = 'C:\cfg'
        Expand-DFConformanceToken -Value '${XDG_CONFIG_HOME}/glow' -Scratch 'C:\tmp\s' |
            Should -Be 'C:\cfg\glow'
    }
    It 'passes a token-less literal through unchanged' {
        Expand-DFConformanceToken -Value '--theme=ansi' -Scratch 'C:\tmp\s' |
            Should -Be '--theme=ansi'
    }
}

Describe 'Read-DFConformanceFragment' {
    It 'strips // comments and parses JSON' {
        $p = Join-Path $TestDrive 'f.jsonc'
        @'
{
  // a comment
  "tool": "bat",
  "claims": []
}
'@ | Set-Content $p
        (Read-DFConformanceFragment -Path $p).tool | Should -Be 'bat'
    }
}

Describe 'Test-DFConformanceDescriptor' {
    It 'accepts a valid env-then-spawn descriptor' {
        $frag = [pscustomobject]@{ tool = 'bat'; claims = @(
            [pscustomobject]@{ id = 'bat/honors-env:BAT_CONFIG_PATH'; probe = [pscustomobject]@{
                kind = 'env-then-spawn'; setEnv = [pscustomobject]@{ BAT_CONFIG_PATH = '${SCRATCH}/bat.conf' };
                spawn = @('bat','--config-file'); expect = [pscustomobject]@{ contains = '${SCRATCH}' } } }
        ) }
        { Test-DFConformanceDescriptor -Fragment $frag } | Should -Not -Throw
    }
    It 'rejects an unknown probe kind' {
        $frag = [pscustomobject]@{ tool = 'bat'; claims = @(
            [pscustomobject]@{ id = 'bat/honors-env:X'; probe = [pscustomobject]@{ kind = 'wat' } }) }
        { Test-DFConformanceDescriptor -Fragment $frag } | Should -Throw '*kind*'
    }
    It 'rejects a spawn kind missing expect' {
        $frag = [pscustomobject]@{ tool = 'bat'; claims = @(
            [pscustomobject]@{ id = 'bat/honors-flag:-s'; probe = [pscustomobject]@{
                kind = 'flag-then-spawn'; spawn = @('bat','-s') } }) }
        { Test-DFConformanceDescriptor -Fragment $frag } | Should -Throw '*expect*'
    }
    It 'rejects a manual claim with no retest' {
        $frag = [pscustomobject]@{ tool = 'bat'; claims = @(
            [pscustomobject]@{ id = 'bat/honors-flag:--config'; probe = [pscustomobject]@{ kind = 'manual' } }) }
        { Test-DFConformanceDescriptor -Fragment $frag } | Should -Throw '*retest*'
    }
    It 'rejects a claim id that violates the grammar' {
        $frag = [pscustomobject]@{ tool = 'bat'; claims = @(
            [pscustomobject]@{ id = 'BAT/Honors-Env'; probe = [pscustomobject]@{
                kind = 'manual'; retest = 'x' } }) }
        { Test-DFConformanceDescriptor -Fragment $frag } | Should -Throw '*id*'
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `pwsh -NoProfile -Command 'Invoke-Pester tests/DFConformance.Tests.ps1 -Output Detailed'`
Expected: FAIL — `Read-DFConformanceFragment`/`Expand-DFConformanceToken`/`Test-DFConformanceDescriptor` not defined.

- [ ] **Step 3: Write the library scaffold**

Create `build/DFConformance.ps1`:

```powershell
#Requires -Version 7.0
Set-StrictMode -Version Latest

# Author-side conformance library. Dot-sourced by build/Test-DFToolConformance.ps1
# and by tests. NEVER loaded by the DotForge module.
# Requires Expand-DFXdgPath / ConvertTo-DFPath to be dot-sourced first.

$script:DFConfClaimGrammar =
    '^[a-z0-9][a-z0-9._-]*/honors-(xdg|env|config-read|config-content|flag)(:[^/]+)?$'
$script:DFConfKinds = @('env-then-spawn','flag-then-spawn','manual','code')
$script:DFConfSpawnKinds = @('env-then-spawn','flag-then-spawn')
$script:DFConfVerdicts = @('pass','fail','manual','unknown')

function Read-DFConformanceFragment {
    [CmdletBinding()] [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path)
    $raw = Get-Content $Path -Raw
    $stripped = ($raw -split "`n" | ForEach-Object {
        if ($_ -match '^(?<code>(?:[^"]|"[^"]*")*?)//') { $Matches.code } else { $_ }
    }) -join "`n"
    $stripped | ConvertFrom-Json
}

function Expand-DFConformanceToken {
    [CmdletBinding()] [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value,
          [Parameter(Mandatory)][string]$Scratch)
    if ([string]::IsNullOrEmpty($Value)) { return $Value }
    # Literal string replace (not -replace): $Scratch may contain backslashes that
    # would be interpreted as regex replacement groups.
    $v = $Value.Replace('${SCRATCH}', $Scratch)
    if ($v -cmatch '\$\{XDG_(CONFIG|DATA|STATE|CACHE)_HOME\}') { return Expand-DFXdgPath $v }
    $v
}

function Test-DFConformanceDescriptor {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Fragment)
    if (-not $Fragment.tool -or $Fragment.tool -isnot [string]) {
        throw "DFConformance: fragment missing a string 'tool' field."
    }
    if ($null -eq $Fragment.claims) { throw "DFConformance: '$($Fragment.tool)' has no 'claims' array." }
    foreach ($c in $Fragment.claims) {
        if (-not $c.id -or $c.id -notmatch $script:DFConfClaimGrammar) {
            throw "DFConformance: claim id '$($c.id)' violates the id grammar."
        }
        $probe = $c.probe
        if (-not $probe -or $probe.kind -notin $script:DFConfKinds) {
            throw "DFConformance: claim '$($c.id)' has an unknown probe kind '$($probe.kind)'."
        }
        switch ($probe.kind) {
            { $_ -in $script:DFConfSpawnKinds } {
                if (-not $probe.spawn) { throw "DFConformance: claim '$($c.id)' ($_) needs a 'spawn' array." }
                $exp = $probe.expect
                $set = @('match','notMatch','contains','notContains') |
                    Where-Object { $exp -and $null -ne $exp.PSObject.Properties[$_] }
                if ($set.Count -ne 1) {
                    throw "DFConformance: claim '$($c.id)' needs exactly one 'expect' rule (got $($set.Count))."
                }
            }
            'manual' {
                if (-not $c.probe.retest -and -not $c.retest) {
                    throw "DFConformance: manual claim '$($c.id)' needs a 'retest' string."
                }
            }
            'code' {
                if (-not $probe.ref) { throw "DFConformance: code claim '$($c.id)' needs a 'ref'." }
            }
        }
    }
}
```

Note the deliberate two-line `$v` in `Expand-DFConformanceToken`: keep only the `$Value.Replace(...)` line — delete the first `-replace` line during implementation (it is shown to make the intent explicit that a literal replace, not a regex, is correct so backslashes in `$Scratch` are safe).

- [ ] **Step 4: Run the test to verify it passes**

Run: `pwsh -NoProfile -Command 'Invoke-Pester tests/DFConformance.Tests.ps1 -Output Detailed'`
Expected: PASS (all Describe blocks green).

- [ ] **Step 5: Commit**

```bash
git add build/DFConformance.ps1 tests/DFConformance.Tests.ps1
git commit -m "feat(conformance): descriptor validation + token expansion library"
```

---

### Task 2: Probe execution — spawn kinds, manual, and version capture

**Files:**
- Modify: `build/DFConformance.ps1`
- Test: `tests/DFConformance.Tests.ps1`

**Interfaces:**
- Consumes: `Expand-DFConformanceToken` (Task 1); the seam contract (Global Constraints).
- Produces: `Get-DFToolVersion`, `Invoke-DFConformanceProbe` (signatures above). `Invoke-DFConformanceProbe` returns `@{ id; verdict; kind; evidence; retest }`; `retest` is `$null` unless the claim is `manual`.

- [ ] **Step 1: Write the failing test**

Append to `tests/DFConformance.Tests.ps1`:

```powershell
Describe 'Get-DFToolVersion' {
    It 'returns the first semver-looking token from --version output' {
        $spawn = { param($e,$a,$env,$cwd) @{ ExitCode=0; StdOut='bat 0.24.0 (a1b2c3)'; StdErr=''; Absent=$false } }
        Get-DFToolVersion -Exe 'bat' -SpawnTool $spawn | Should -Be '0.24.0'
    }
    It 'returns $null when the tool is absent' {
        $spawn = { param($e,$a,$env,$cwd) @{ Absent=$true; ExitCode=-1; StdOut=''; StdErr='' } }
        Get-DFToolVersion -Exe 'nope' -SpawnTool $spawn | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-DFConformanceProbe' {
    BeforeEach { $script:scratch = Join-Path $TestDrive ([guid]::NewGuid().Guid)
                 New-Item -ItemType Directory -Path $script:scratch -Force | Out-Null }

    It 'env-then-spawn: PASS when combined output contains the expected substring' {
        $claim = [pscustomobject]@{ id='bat/honors-env:BAT_CONFIG_PATH'; probe=[pscustomobject]@{
            kind='env-then-spawn'; setEnv=[pscustomobject]@{ BAT_CONFIG_PATH='${SCRATCH}/bat.conf' };
            writeFile=[pscustomobject]@{ '${SCRATCH}/bat.conf'='--theme="ansi"' };
            spawn=@('bat','--config-file'); expect=[pscustomobject]@{ contains='${SCRATCH}' } } }
        $spawn = { param($e,$a,$env,$cwd) @{ ExitCode=0; StdOut="$($env.BAT_CONFIG_PATH)"; StdErr=''; Absent=$false } }
        $r = Invoke-DFConformanceProbe -Claim $claim -Scratch $script:scratch -ProbesDir $TestDrive -SpawnTool $spawn
        $r.verdict | Should -Be 'pass'
    }
    It 'env-then-spawn: FAIL when output lacks the expected substring' {
        $claim = [pscustomobject]@{ id='glow/honors-env:GLOW_CONFIG_DIR'; probe=[pscustomobject]@{
            kind='env-then-spawn'; setEnv=[pscustomobject]@{ GLOW_CONFIG_DIR='${SCRATCH}' };
            spawn=@('glow','--help'); expect=[pscustomobject]@{ contains='${SCRATCH}' } } }
        $spawn = { param($e,$a,$env,$cwd) @{ ExitCode=0; StdOut='config default C:\Users\me\AppData\glow'; StdErr=''; Absent=$false } }
        $r = Invoke-DFConformanceProbe -Claim $claim -Scratch $script:scratch -ProbesDir $TestDrive -SpawnTool $spawn
        $r.verdict | Should -Be 'fail'
    }
    It 'manual: passes the descriptor verdict and retest through' {
        $claim = [pscustomobject]@{ id='glow/honors-flag:--config'; probe=[pscustomobject]@{
            kind='manual'; retest='run glow config; confirm file path' } }
        $spawn = { throw 'manual must not spawn' }
        $r = Invoke-DFConformanceProbe -Claim $claim -Scratch $script:scratch -ProbesDir $TestDrive -SpawnTool $spawn
        $r.verdict | Should -Be 'manual'
        $r.retest  | Should -Match 'glow config'
    }
    It 'writeFile writes the sentinel into the scratch dir before spawning' {
        $claim = [pscustomobject]@{ id='bat/honors-config-read'; probe=[pscustomobject]@{
            kind='env-then-spawn'; setEnv=[pscustomobject]@{ BAT_CONFIG_PATH='${SCRATCH}/bat.conf' };
            writeFile=[pscustomobject]@{ '${SCRATCH}/bat.conf'='--not-a-real-flag' };
            spawn=@('bat','x'); expect=[pscustomobject]@{ contains='error' } } }
        $seen = $null
        $spawn = { param($e,$a,$env,$cwd)
            $script:seen = Get-Content (Join-Path $using:script:scratch 'bat.conf') -Raw
            @{ ExitCode=1; StdOut=''; StdErr='error: unexpected argument'; Absent=$false } }
        $r = Invoke-DFConformanceProbe -Claim $claim -Scratch $script:scratch -ProbesDir $TestDrive -SpawnTool $spawn
        $r.verdict | Should -Be 'pass'
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `pwsh -NoProfile -Command 'Invoke-Pester tests/DFConformance.Tests.ps1 -Output Detailed'`
Expected: FAIL — `Get-DFToolVersion` / `Invoke-DFConformanceProbe` not defined.

- [ ] **Step 3: Add the probe functions to `build/DFConformance.ps1`**

```powershell
function Get-DFToolVersion {
    [CmdletBinding()] [OutputType([string])]
    param([Parameter(Mandatory)][string]$Exe,
          [string[]]$VersionArgs = @('--version'),
          [Parameter(Mandatory)][scriptblock]$SpawnTool)
    $res = & $SpawnTool $Exe $VersionArgs @{} $null
    if ($res.Absent) { return $null }
    $text = "$($res.StdOut) $($res.StdErr)"
    if ($text -match '\d+\.\d+(\.\d+)?') { return $Matches[0] }
    ($text.Trim() -split "`n")[0].Trim()
}

function Test-DFConformanceExpect {
    param([pscustomobject]$Expect, [string]$Text, [string]$Scratch)
    if ($null -ne $Expect.PSObject.Properties['match']) {
        return [bool]($Text -match (Expand-DFConformanceToken -Value $Expect.match -Scratch $Scratch)) }
    if ($null -ne $Expect.PSObject.Properties['notMatch']) {
        return -not [bool]($Text -match (Expand-DFConformanceToken -Value $Expect.notMatch -Scratch $Scratch)) }
    if ($null -ne $Expect.PSObject.Properties['contains']) {
        return $Text.Contains((Expand-DFConformanceToken -Value $Expect.contains -Scratch $Scratch)) }
    return -not $Text.Contains((Expand-DFConformanceToken -Value $Expect.notContains -Scratch $Scratch))
}

function Invoke-DFConformanceProbe {
    [CmdletBinding()] [OutputType([hashtable])]
    param([Parameter(Mandatory)][pscustomobject]$Claim,
          [Parameter(Mandatory)][string]$Scratch,
          [Parameter(Mandatory)][string]$ProbesDir,
          [Parameter(Mandatory)][scriptblock]$SpawnTool)

    $probe = $Claim.probe
    $result = @{ id = $Claim.id; kind = $probe.kind; verdict = 'unknown'; evidence = ''; retest = $null }

    switch ($probe.kind) {
        'manual' {
            $result.verdict  = 'manual'
            $result.retest   = ($Claim.PSObject.Properties['retest']?.Value) ?? ($probe.PSObject.Properties['retest']?.Value)
            $result.evidence = ($probe.PSObject.Properties['evidence']?.Value) ?? 'human-verified; see retest'
            return $result
        }
        'code' {
            $script = Join-Path $ProbesDir "$($probe.ref).ps1"
            $out = & $script -Scratch $Scratch -SpawnTool $SpawnTool
            $result.verdict  = $out.verdict
            $result.evidence = $out.evidence
            if ($out.verdict -eq 'manual') {
                $fallback = $probe.PSObject.Properties['manualFallback']?.Value?.retest
                $result.retest = $out.retest ?? $fallback
            }
            return $result
        }
        default {
            # env-then-spawn / flag-then-spawn
            $envMap = @{}
            $setEnv = $probe.PSObject.Properties['setEnv']?.Value
            if ($setEnv) {
                foreach ($p in $setEnv.PSObject.Properties) {
                    $envMap[$p.Name] = Expand-DFConformanceToken -Value $p.Value -Scratch $Scratch
                }
            }
            $writeFile = $probe.PSObject.Properties['writeFile']?.Value
            if ($writeFile) {
                foreach ($p in $writeFile.PSObject.Properties) {
                    $path = Expand-DFConformanceToken -Value $p.Name -Scratch $Scratch
                    New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null
                    Set-Content -Path $path -Value $p.Value -NoNewline
                }
            }
            $exe  = $probe.spawn[0]
            $argv = @($probe.spawn[1..($probe.spawn.Count-1)] |
                        ForEach-Object { Expand-DFConformanceToken -Value $_ -Scratch $Scratch })
            $res = & $SpawnTool $exe $argv $envMap $Scratch
            if ($res.Absent) { $result.verdict = 'unknown'; $result.evidence = 'tool absent'; return $result }
            $text = "$($res.StdOut) $($res.StdErr)"
            $ok = Test-DFConformanceExpect -Expect $probe.expect -Text $text -Scratch $Scratch
            $result.verdict  = if ($ok) { 'pass' } else { 'fail' }
            $flat = ($text -replace '\s+', ' ').Trim()
            if ($flat.Length -gt 200) { $flat = $flat.Substring(0, 200) }
            $result.evidence = "exit=$($res.ExitCode); output=$flat"
            return $result
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `pwsh -NoProfile -Command 'Invoke-Pester tests/DFConformance.Tests.ps1 -Output Detailed'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add build/DFConformance.ps1 tests/DFConformance.Tests.ps1
git commit -m "feat(conformance): spawn-kind probes, manual passthrough, version capture"
```

---

### Task 3: Code-probe hatch + the `bat.theme` probe

**Files:**
- Create: `build/conformance/probes/bat.theme.ps1`
- Test: `tests/DFConformance.Tests.ps1`

**Interfaces:**
- Consumes: `Invoke-DFConformanceProbe`'s `code` branch (Task 2), which invokes `& <ProbesDir>/<ref>.ps1 -Scratch <string> -SpawnTool <scriptblock>` and expects back `@{ verdict; evidence; retest }`.
- Produces: the code-probe contract — a probe script returns `@{ verdict = 'pass'|'fail'|'manual'; evidence = [string]; retest = [string] }`.

- [ ] **Step 1: Write the failing test**

Append to `tests/DFConformance.Tests.ps1`:

```powershell
Describe 'code probe: bat.theme' {
    BeforeEach { $script:scratch = Join-Path $TestDrive ([guid]::NewGuid().Guid)
                 New-Item -ItemType Directory -Path $script:scratch -Force | Out-Null }
    $probesDir = "$PSScriptRoot/../build/conformance/probes"

    It 'PASS when the two theme configs yield different rendered output' {
        $calls = 0
        $spawn = { param($e,$a,$env,$cwd) $script:calls++
                   @{ ExitCode=0; StdOut="render-$($script:calls)"; StdErr=''; Absent=$false } }
        $out = & "$probesDir/bat.theme.ps1" -Scratch $script:scratch -SpawnTool $spawn
        $out.verdict | Should -Be 'pass'
    }
    It 'falls back to manual when the two renders are identical' {
        $spawn = { param($e,$a,$env,$cwd) @{ ExitCode=0; StdOut='same'; StdErr=''; Absent=$false } }
        $out = & "$probesDir/bat.theme.ps1" -Scratch $script:scratch -SpawnTool $spawn
        $out.verdict | Should -Be 'manual'
        $out.retest  | Should -Not -BeNullOrEmpty
    }
    It 'reports unknown when bat is absent' {
        $spawn = { param($e,$a,$env,$cwd) @{ Absent=$true; ExitCode=-1; StdOut=''; StdErr='' } }
        (& "$probesDir/bat.theme.ps1" -Scratch $script:scratch -SpawnTool $spawn).verdict | Should -Be 'unknown'
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `pwsh -NoProfile -Command 'Invoke-Pester tests/DFConformance.Tests.ps1 -Output Detailed'`
Expected: FAIL — `build/conformance/probes/bat.theme.ps1` does not exist.

- [ ] **Step 3: Write the code probe**

Create `build/conformance/probes/bat.theme.ps1`:

```powershell
#Requires -Version 7.0
Set-StrictMode -Version Latest
<#
.SYNOPSIS
    Code probe for bat/honors-config-content:theme. Dispositive test that the
    `--theme` directive INSIDE bat.conf changes rendering: render a sample with
    two configs differing only in theme; if output differs, the config theme is
    honored (pass). If identical (or bat can't demonstrate it), fall back to a
    manual visual verdict.
#>
[CmdletBinding()] [OutputType([hashtable])]
param([Parameter(Mandatory)][string]$Scratch,
      [Parameter(Mandatory)][scriptblock]$SpawnTool)

$sample = Join-Path $Scratch 'sample.md'
Set-Content -Path $sample -Value "# Title`n`n``code``" -NoNewline

function Render-WithTheme([string]$Theme) {
    $conf = Join-Path $Scratch "bat.$Theme.conf"
    Set-Content -Path $conf -Value "--theme=`"$Theme`"" -NoNewline
    $res = & $SpawnTool 'bat' @('--color=always','--language=md',$sample) @{ BAT_CONFIG_PATH = $conf } $Scratch
    $res
}

$a = Render-WithTheme 'ansi'
if ($a.Absent) { return @{ verdict = 'unknown'; evidence = 'bat absent'; retest = $null } }
$b = Render-WithTheme 'Dracula'

if ($a.StdOut -ne $b.StdOut) {
    return @{ verdict = 'pass'
              evidence = 'rendered output differs between config theme=ansi and theme=Dracula'
              retest   = $null }
}
@{ verdict  = 'manual'
   evidence = 'automated differ inconclusive; confirm visually'
   retest   = 'set theme=ansi in bat.conf, run `bat sample.md`; confirm the ANSI palette renders' }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `pwsh -NoProfile -Command 'Invoke-Pester tests/DFConformance.Tests.ps1 -Output Detailed'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add build/conformance/probes/bat.theme.ps1 tests/DFConformance.Tests.ps1
git commit -m "feat(conformance): code-probe hatch + bat.theme differ probe"
```

---

### Task 4: Ledger merge + ledger schema validation

**Files:**
- Modify: `build/DFConformance.ps1`
- Test: `tests/DFConformance.Tests.ps1`

**Interfaces:**
- Consumes: probe result hashtables `@{ id; verdict; kind; evidence; retest }` (Task 2).
- Produces: `Merge-DFConformanceRecord` → `@{ Claims = [hashtable[]]; Notes = [string[]] }`; `Test-DFConformanceLedgerSchema` (throws on invalid). Merged claim shape: `@{ id; verdict; kind; evidence; retest? }` (retest present only for `manual`).

- [ ] **Step 1: Write the failing test**

Append to `tests/DFConformance.Tests.ps1`:

```powershell
Describe 'Merge-DFConformanceRecord' {
    It 'overwrites automated claims with fresh results' {
        $existing = [pscustomobject]@{ versionTested='0.23.0'; claims=@(
            [pscustomobject]@{ id='bat/honors-env:BAT_CONFIG_PATH'; verdict='fail'; kind='env-then-spawn'; evidence='old' }) }
        $fresh = @( @{ id='bat/honors-env:BAT_CONFIG_PATH'; verdict='pass'; kind='env-then-spawn'; evidence='new'; retest=$null } )
        $m = Merge-DFConformanceRecord -Existing $existing -FreshClaims $fresh -Version '0.24.0'
        ($m.Claims | Where-Object id -eq 'bat/honors-env:BAT_CONFIG_PATH').verdict | Should -Be 'pass'
    }
    It 'preserves a manual verdict when versionTested is unchanged' {
        $existing = [pscustomobject]@{ versionTested='0.24.0'; claims=@(
            [pscustomobject]@{ id='bat/honors-config-content:theme'; verdict='manual'; kind='code';
                evidence='confirmed visually 2026-07-24'; retest='...' }) }
        $fresh = @( @{ id='bat/honors-config-content:theme'; verdict='manual'; kind='code'; evidence='generic'; retest='...' } )
        $m = Merge-DFConformanceRecord -Existing $existing -FreshClaims $fresh -Version '0.24.0'
        ($m.Claims | Where-Object id -eq 'bat/honors-config-content:theme').evidence |
            Should -Be 'confirmed visually 2026-07-24'
    }
    It 'flags a manual verdict for re-confirmation when the version moved' {
        $existing = [pscustomobject]@{ versionTested='0.23.0'; claims=@(
            [pscustomobject]@{ id='bat/honors-config-content:theme'; verdict='manual'; kind='code';
                evidence='confirmed 0.23.0'; retest='...' }) }
        $fresh = @( @{ id='bat/honors-config-content:theme'; verdict='manual'; kind='code'; evidence='generic'; retest='...' } )
        $m = Merge-DFConformanceRecord -Existing $existing -FreshClaims $fresh -Version '0.24.0'
        ($m.Notes -join ' ') | Should -Match 'reconfirm|re-confirm'
    }
}

Describe 'Test-DFConformanceLedgerSchema' {
    It 'accepts a well-formed ledger' {
        $led = [pscustomobject]@{ bat = [pscustomobject]@{ versionTested='0.24.0'; claims=@(
            [pscustomobject]@{ id='bat/honors-env:BAT_CONFIG_PATH'; verdict='pass'; kind='env-then-spawn'; evidence='x' }) } }
        { Test-DFConformanceLedgerSchema -Ledger $led } | Should -Not -Throw
    }
    It 'rejects a manual claim with no retest' {
        $led = [pscustomobject]@{ bat = [pscustomobject]@{ versionTested='0.24.0'; claims=@(
            [pscustomobject]@{ id='bat/honors-config-content:theme'; verdict='manual'; kind='code'; evidence='x' }) } }
        { Test-DFConformanceLedgerSchema -Ledger $led } | Should -Throw '*retest*'
    }
    It 'rejects a verdict outside the enum' {
        $led = [pscustomobject]@{ bat = [pscustomobject]@{ versionTested='0.24.0'; claims=@(
            [pscustomobject]@{ id='bat/honors-env:X'; verdict='maybe'; kind='env-then-spawn'; evidence='x' }) } }
        { Test-DFConformanceLedgerSchema -Ledger $led } | Should -Throw '*verdict*'
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `pwsh -NoProfile -Command 'Invoke-Pester tests/DFConformance.Tests.ps1 -Output Detailed'`
Expected: FAIL — `Merge-DFConformanceRecord` / `Test-DFConformanceLedgerSchema` not defined.

- [ ] **Step 3: Add the functions to `build/DFConformance.ps1`**

```powershell
function Merge-DFConformanceRecord {
    [CmdletBinding()] [OutputType([hashtable])]
    param([pscustomobject]$Existing,
          [Parameter(Mandatory)][hashtable[]]$FreshClaims,
          [Parameter(Mandatory)][string]$Version)
    $notes = @()
    $prev = @{}
    if ($Existing -and $Existing.claims) {
        foreach ($c in $Existing.claims) { $prev[$c.id] = $c }
    }
    $prevVersion = if ($Existing) { $Existing.versionTested } else { $null }

    $claims = foreach ($f in $FreshClaims) {
        if ($f.verdict -eq 'manual' -and $prev.ContainsKey($f.id) -and $prev[$f.id].verdict -eq 'manual') {
            if ($prevVersion -eq $Version) {
                # Human's ledger evidence is authoritative — keep it verbatim.
                $keep = $prev[$f.id]
                @{ id=$keep.id; verdict='manual'; kind=$keep.kind; evidence=$keep.evidence; retest=$keep.retest }
            } else {
                $notes += "manual claim '$($f.id)' needs reconfirmation (version $prevVersion -> $Version)"
                @{ id=$f.id; verdict='manual'; kind=$f.kind; evidence=$f.evidence; retest=$f.retest }
            }
        } else {
            $out = @{ id=$f.id; verdict=$f.verdict; kind=$f.kind; evidence=$f.evidence }
            if ($f.verdict -eq 'manual') { $out.retest = $f.retest }
            $out
        }
    }
    @{ Claims = @($claims); Notes = $notes }
}

function Test-DFConformanceLedgerSchema {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Ledger)
    foreach ($tool in $Ledger.PSObject.Properties) {
        $rec = $tool.Value
        if (-not $rec.versionTested) { throw "DFConformance: '$($tool.Name)' missing versionTested." }
        foreach ($c in $rec.claims) {
            if (-not $c.id -or $c.id -notmatch $script:DFConfClaimGrammar) {
                throw "DFConformance: ledger claim id '$($c.id)' violates the grammar." }
            if ($c.verdict -notin $script:DFConfVerdicts) {
                throw "DFConformance: ledger claim '$($c.id)' has an invalid verdict '$($c.verdict)'." }
            if ($c.verdict -eq 'manual' -and -not $c.retest) {
                throw "DFConformance: manual ledger claim '$($c.id)' needs a retest string." }
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `pwsh -NoProfile -Command 'Invoke-Pester tests/DFConformance.Tests.ps1 -Output Detailed'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add build/DFConformance.ps1 tests/DFConformance.Tests.ps1
git commit -m "feat(conformance): ledger merge (manual preservation) + schema validation"
```

---

### Task 5: Adapter link scan + issue-report rendering

**Files:**
- Modify: `build/DFConformance.ps1`
- Test: `tests/DFConformance.Tests.ps1`

**Interfaces:**
- Consumes: the merged ledger as a hashtable `@{ <tool> = @{ versionTested; claims = @(@{id;verdict;...}) } }`.
- Produces: `Get-DFConformanceAdapterLink -ToolsPath` → `@(@{ Claim; File; Line })`; `Write-DFConformanceReport -Ledger -AdapterLinks -Path` (writes markdown).

- [ ] **Step 1: Write the failing test**

Append to `tests/DFConformance.Tests.ps1`:

```powershell
Describe 'Get-DFConformanceAdapterLink' {
    It 'finds # adapter for <claim-id> comments in Tools/*.ps1' {
        $tools = Join-Path $TestDrive 'Tools'; New-Item -ItemType Directory -Path $tools -Force | Out-Null
        Set-Content (Join-Path $tools 'glow.ps1') "# adapter for glow/honors-env:GLOW_CONFIG_DIR`n`$x = 1"
        $links = Get-DFConformanceAdapterLink -ToolsPath $tools
        $links[0].Claim | Should -Be 'glow/honors-env:GLOW_CONFIG_DIR'
        $links[0].File  | Should -Match 'glow\.ps1'
    }
}

Describe 'Write-DFConformanceReport' {
    BeforeEach { $script:rpt = Join-Path $TestDrive 'issues.md' }

    It 'writes a fail section for each failing claim' {
        $led = @{ glow = @{ versionTested='2.1.2'; claims=@(
            @{ id='glow/honors-env:GLOW_CONFIG_DIR'; verdict='fail'; kind='env-then-spawn'; evidence='no scratch path in --help' }) } }
        Write-DFConformanceReport -Ledger $led -AdapterLinks @() -Path $script:rpt
        (Get-Content $script:rpt -Raw) | Should -Match 'glow/honors-env:GLOW_CONFIG_DIR'
    }
    It 'writes a no-failures stub when everything passes' {
        $led = @{ bat = @{ versionTested='0.24.0'; claims=@(
            @{ id='bat/honors-env:BAT_CONFIG_PATH'; verdict='pass'; kind='env-then-spawn'; evidence='x' }) } }
        Write-DFConformanceReport -Ledger $led -AdapterLinks @() -Path $script:rpt
        (Get-Content $script:rpt -Raw) | Should -Match 'no open conformance failures'
    }
    It 'flags a dead adapter when its claim now passes' {
        $led = @{ glow = @{ versionTested='2.2.0'; claims=@(
            @{ id='glow/honors-env:GLOW_CONFIG_DIR'; verdict='pass'; kind='env-then-spawn'; evidence='fixed upstream' }) } }
        $links = @( @{ Claim='glow/honors-env:GLOW_CONFIG_DIR'; File='Tools/glow.ps1'; Line=1 } )
        Write-DFConformanceReport -Ledger $led -AdapterLinks $links -Path $script:rpt
        (Get-Content $script:rpt -Raw) | Should -Match 'dead code'
    }
    It 'warns about an orphan adapter referencing an unknown claim' {
        $led = @{ glow = @{ versionTested='2.1.2'; claims=@(
            @{ id='glow/honors-flag:-s'; verdict='pass'; kind='flag-then-spawn'; evidence='x' }) } }
        $links = @( @{ Claim='glow/honors-env:TYPO'; File='Tools/glow.ps1'; Line=1 } )
        Write-DFConformanceReport -Ledger $led -AdapterLinks $links -Path $script:rpt
        (Get-Content $script:rpt -Raw) | Should -Match 'orphan'
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `pwsh -NoProfile -Command 'Invoke-Pester tests/DFConformance.Tests.ps1 -Output Detailed'`
Expected: FAIL — `Get-DFConformanceAdapterLink` / `Write-DFConformanceReport` not defined.

- [ ] **Step 3: Add the functions to `build/DFConformance.ps1`**

```powershell
function Get-DFConformanceAdapterLink {
    [CmdletBinding()] [OutputType([hashtable[]])]
    param([Parameter(Mandatory)][string]$ToolsPath)
    $links = @()
    Get-ChildItem -Path $ToolsPath -Filter '*.ps1' -ErrorAction Ignore | ForEach-Object {
        $n = 0
        foreach ($line in (Get-Content $_.FullName)) {
            $n++
            if ($line -match '#\s*adapter for\s+(?<id>\S+)') {
                $links += @{ Claim = $Matches.id; File = $_.Name; Line = $n }
            }
        }
    }
    ,$links
}

function Write-DFConformanceReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Ledger,
          [Parameter(Mandatory)][AllowEmptyCollection()][hashtable[]]$AdapterLinks,
          [Parameter(Mandatory)][string]$Path)

    # Build an id -> verdict index across the whole ledger.
    $verdicts = @{}
    foreach ($tool in $Ledger.Keys) {
        foreach ($c in $Ledger[$tool].claims) { $verdicts[$c.id] = $c.verdict }
    }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('# Tool Conformance Issues').AppendLine()
    [void]$sb.AppendLine('_Generated by build/Test-DFToolConformance.ps1 — do not edit by hand._').AppendLine()

    $fails = foreach ($tool in ($Ledger.Keys | Sort-Object)) {
        foreach ($c in $Ledger[$tool].claims | Where-Object verdict -eq 'fail') {
            [pscustomobject]@{ Tool=$tool; Version=$Ledger[$tool].versionTested; Claim=$c.id; Evidence=$c.evidence }
        }
    }
    if ($fails) {
        [void]$sb.AppendLine('## Open failures').AppendLine()
        foreach ($f in $fails) {
            [void]$sb.AppendLine("### $($f.Claim)")
            [void]$sb.AppendLine("- **Tool/version:** $($f.Tool) $($f.Version)")
            [void]$sb.AppendLine("- **Observed:** $($f.Evidence)").AppendLine()
        }
    } else {
        [void]$sb.AppendLine('There are no open conformance failures.').AppendLine()
    }

    $orphans = $AdapterLinks | Where-Object { -not $verdicts.ContainsKey($_.Claim) }
    $dead    = $AdapterLinks | Where-Object { $verdicts[$_.Claim] -eq 'pass' }
    if ($orphans) {
        [void]$sb.AppendLine('## Orphan adapters (claim id not in ledger)').AppendLine()
        foreach ($o in $orphans) { [void]$sb.AppendLine("- $($o.File):$($o.Line) -> ``$($o.Claim)``") }
        [void]$sb.AppendLine()
    }
    if ($dead) {
        [void]$sb.AppendLine('## Dead adapters (claim now passes — remove this dead code)').AppendLine()
        foreach ($d in $dead) { [void]$sb.AppendLine("- $($d.File):$($d.Line) -> ``$($d.Claim)`` (verdict: pass)") }
        [void]$sb.AppendLine()
    }

    Set-Content -Path $Path -Value $sb.ToString()
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `pwsh -NoProfile -Command 'Invoke-Pester tests/DFConformance.Tests.ps1 -Output Detailed'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add build/DFConformance.ps1 tests/DFConformance.Tests.ps1
git commit -m "feat(conformance): adapter link scan + issue-report rendering"
```

---

### Task 6: Orchestrator — `build/Test-DFToolConformance.ps1`

**Files:**
- Create: `build/Test-DFToolConformance.ps1`
- Test: `tests/Test-DFToolConformance.Tests.ps1`

**Interfaces:**
- Consumes: every library function (Tasks 1–5); the seam contract.
- Produces: the entry-point script. Parameters: `-ConformanceDir`, `-OutPath`, `-ReportPath`, `-Tool <string[]>`, `-ProbedAt <string>`, `-SpawnTool <scriptblock>`. Writes the ledger JSON to `-OutPath` and the report to `-ReportPath`.

- [ ] **Step 1: Write the failing test**

Create `tests/Test-DFToolConformance.Tests.ps1`:

```powershell
Describe 'Test-DFToolConformance harness' {
    BeforeEach {
        $script:confDir = Join-Path $TestDrive 'conformance'
        $script:probes  = Join-Path $script:confDir 'probes'
        New-Item -ItemType Directory -Path $script:probes -Force | Out-Null
        $script:out = Join-Path $TestDrive 'ledger.json'
        $script:rpt = Join-Path $TestDrive 'issues.md'
        @'
{
  "tool": "bat",
  "claims": [
    { "id": "bat/honors-env:BAT_CONFIG_PATH", "probe": {
        "kind": "env-then-spawn",
        "setEnv": { "BAT_CONFIG_PATH": "${SCRATCH}/bat.conf" },
        "spawn": ["bat", "--config-file"],
        "expect": { "contains": "${SCRATCH}" } } }
  ]
}
'@ | Set-Content (Join-Path $script:confDir 'bat.jsonc')
    }

    It 'writes a ledger with a pass verdict from canned spawn output' {
        $spawn = { param($e,$a,$env,$cwd)
            if ($a -contains '--version') { return @{ ExitCode=0; StdOut='bat 0.24.0'; StdErr=''; Absent=$false } }
            @{ ExitCode=0; StdOut="$($env.BAT_CONFIG_PATH)"; StdErr=''; Absent=$false } }
        & "$PSScriptRoot/../build/Test-DFToolConformance.ps1" -ConformanceDir $script:confDir `
            -OutPath $script:out -ReportPath $script:rpt -ProbedAt '2026-07-24' -SpawnTool $spawn
        $led = Get-Content $script:out -Raw | ConvertFrom-Json
        $led.bat.versionTested | Should -Be '0.24.0'
        ($led.bat.claims | Where-Object id -eq 'bat/honors-env:BAT_CONFIG_PATH').verdict | Should -Be 'pass'
    }

    It 'marks every claim unknown when the tool is absent' {
        $spawn = { param($e,$a,$env,$cwd) @{ Absent=$true; ExitCode=-1; StdOut=''; StdErr='' } }
        & "$PSScriptRoot/../build/Test-DFToolConformance.ps1" -ConformanceDir $script:confDir `
            -OutPath $script:out -ReportPath $script:rpt -ProbedAt '2026-07-24' -SpawnTool $spawn
        $led = Get-Content $script:out -Raw | ConvertFrom-Json
        ($led.bat.claims | Where-Object id -eq 'bat/honors-env:BAT_CONFIG_PATH').verdict | Should -Be 'unknown'
    }

    It 'writes the issue report' {
        $spawn = { param($e,$a,$env,$cwd)
            if ($a -contains '--version') { return @{ ExitCode=0; StdOut='bat 0.24.0'; StdErr=''; Absent=$false } }
            @{ ExitCode=0; StdOut="$($env.BAT_CONFIG_PATH)"; StdErr=''; Absent=$false } }
        & "$PSScriptRoot/../build/Test-DFToolConformance.ps1" -ConformanceDir $script:confDir `
            -OutPath $script:out -ReportPath $script:rpt -ProbedAt '2026-07-24' -SpawnTool $spawn
        Test-Path $script:rpt | Should -BeTrue
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `pwsh -NoProfile -Command 'Invoke-Pester tests/Test-DFToolConformance.Tests.ps1 -Output Detailed'`
Expected: FAIL — `build/Test-DFToolConformance.ps1` does not exist.

- [ ] **Step 3: Write the orchestrator**

Create `build/Test-DFToolConformance.ps1`:

```powershell
#Requires -Version 7.0
<#
.SYNOPSIS
    Author-time tool-conformance harness. Reads build/conformance/*.jsonc probe
    descriptors, runs each claim's probe against the real tool, and writes the
    versioned ledger (data/tool-conformance.json) plus the issue report
    (reports/tool-conformance-issues.md). NEVER loaded by the DotForge module.
.PARAMETER SpawnTool
    Override the tool-spawning seam. Tests inject a canned scriptblock; the
    default launches the real executable in an isolated environment.
#>
[CmdletBinding()]
param(
    [string]$ConformanceDir = (Join-Path $PSScriptRoot 'conformance'),
    [string]$OutPath        = (Join-Path $PSScriptRoot '../data/tool-conformance.json'),
    [string]$ReportPath     = (Join-Path $PSScriptRoot '../reports/tool-conformance-issues.md'),
    [string[]]$Tool,
    [string]$ProbedAt,
    [scriptblock]$SpawnTool
)
Set-StrictMode -Version Latest

# Private helpers (Expand-DFXdgPath / ConvertTo-DFPath) are not exported; dot-source
# them directly, mirroring build/Build-DFToolIdentities.ps1.
Get-ChildItem -Path (Join-Path $PSScriptRoot '../Private') -Filter '*.ps1' |
    ForEach-Object { . $_.FullName }
. (Join-Path $PSScriptRoot 'DFConformance.ps1')

if (-not $SpawnTool) {
    $SpawnTool = {
        param($Exe, $Argv, $EnvMap, $Cwd)
        $cmd = Get-Command $Exe -CommandType Application -ErrorAction Ignore | Select-Object -First 1
        if (-not $cmd) { return @{ Absent = $true; ExitCode = -1; StdOut = ''; StdErr = '' } }
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $cmd.Source
        foreach ($arg in @($Argv)) { $psi.ArgumentList.Add([string]$arg) }
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.UseShellExecute = $false
        if ($Cwd) { $psi.WorkingDirectory = $Cwd }
        $psi.EnvironmentVariables.Clear()
        foreach ($k in 'SystemRoot','windir','TEMP','TMP','PATH','PATHEXT') {
            $val = [Environment]::GetEnvironmentVariable($k)
            if ($val) { $psi.EnvironmentVariables[$k] = $val }
        }
        if ($EnvMap) { foreach ($k in $EnvMap.Keys) { $psi.EnvironmentVariables[$k] = [string]$EnvMap[$k] } }
        $p = [System.Diagnostics.Process]::Start($psi)
        $so = $p.StandardOutput.ReadToEnd()
        $se = $p.StandardError.ReadToEnd()
        $p.WaitForExit()
        @{ ExitCode = $p.ExitCode; StdOut = $so; StdErr = $se; Absent = $false }
    }
}

$probesDir = Join-Path $ConformanceDir 'probes'
$existingLedger = if (Test-Path $OutPath) { Get-Content $OutPath -Raw | ConvertFrom-Json } else { $null }

$fragments = Get-ChildItem -Path $ConformanceDir -Filter '*.jsonc' -ErrorAction Ignore
if ($Tool) { $fragments = $fragments | Where-Object { $_.BaseName -in $Tool } }

$ledger = [ordered]@{}
$allNotes = @()

foreach ($file in ($fragments | Sort-Object Name)) {
    $frag = Read-DFConformanceFragment -Path $file.FullName
    Test-DFConformanceDescriptor -Fragment $frag
    $toolName = $frag.tool

    $exe = ($frag.claims | ForEach-Object { $_.probe.PSObject.Properties['spawn']?.Value } |
                Where-Object { $_ } | Select-Object -First 1)
    $exe = if ($exe) { $exe[0] } else { $toolName }
    $verArgs = if ($frag.PSObject.Properties['versionArgs']) { @($frag.versionArgs) } else { @('--version') }
    $version = Get-DFToolVersion -Exe $exe -VersionArgs $verArgs -SpawnTool $SpawnTool

    $fresh = foreach ($claim in $frag.claims) {
        if ($null -eq $version) {
            @{ id=$claim.id; verdict='unknown'; kind=$claim.probe.kind; evidence='tool absent'; retest=$null }
        } else {
            $scratch = Join-Path ([System.IO.Path]::GetTempPath()) ("dfconf-" + [guid]::NewGuid().Guid)
            New-Item -ItemType Directory -Path $scratch -Force | Out-Null
            try {
                Invoke-DFConformanceProbe -Claim $claim -Scratch $scratch -ProbesDir $probesDir -SpawnTool $SpawnTool
            } finally { Remove-Item $scratch -Recurse -Force -ErrorAction Ignore }
        }
    }

    $existingRec = if ($existingLedger -and $existingLedger.PSObject.Properties[$toolName]) {
        $existingLedger.$toolName } else { $null }
    $merged = Merge-DFConformanceRecord -Existing $existingRec -FreshClaims @($fresh) -Version ($version ?? 'unknown')
    $allNotes += $merged.Notes

    $rec = [ordered]@{ versionTested = ($version ?? 'unknown') }
    if ($ProbedAt) { $rec.probedAt = $ProbedAt }
    $rec.claims = $merged.Claims
    $ledger[$toolName] = $rec
}

# Validate before writing; a schema violation is an author bug, fail loudly.
$ledgerObj = $ledger | ConvertTo-Json -Depth 10 | ConvertFrom-Json
Test-DFConformanceLedgerSchema -Ledger $ledgerObj

New-Item -ItemType Directory -Path (Split-Path $OutPath) -Force | Out-Null
$ledger | ConvertTo-Json -Depth 10 | Set-Content -Path $OutPath

$links = Get-DFConformanceAdapterLink -ToolsPath (Join-Path $PSScriptRoot '../Tools')
New-Item -ItemType Directory -Path (Split-Path $ReportPath) -Force | Out-Null
# Convert the ordered ledger to a plain hashtable for the report renderer.
$ledgerHash = @{}; foreach ($k in $ledger.Keys) { $ledgerHash[$k] = $ledger[$k] }
Write-DFConformanceReport -Ledger $ledgerHash -AdapterLinks $links -Path $ReportPath

foreach ($n in $allNotes) { Write-Warning $n }
Write-Verbose "Conformance ledger written to $OutPath"
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `pwsh -NoProfile -Command 'Invoke-Pester tests/Test-DFToolConformance.Tests.ps1 -Output Detailed'`
Expected: PASS.

- [ ] **Step 5: Run the full suite for regressions**

Run: `pwsh -NoProfile -Command 'Invoke-Pester tests/ -Output Detailed'`
Expected: PASS — existing tests unaffected (new files are additive).

- [ ] **Step 6: Commit**

```bash
git add build/Test-DFToolConformance.ps1 tests/Test-DFToolConformance.Tests.ps1
git commit -m "feat(conformance): orchestrator harness with isolated real-spawn seam"
```

---

### Task 7: Pilot descriptors, generated ledger, glow adapter annotation, docs, shipped-data tests

**Files:**
- Create: `build/conformance/bat.jsonc`, `build/conformance/glow.jsonc`
- Create (generated): `data/tool-conformance.json`, `reports/tool-conformance-issues.md`
- Modify: `Tools/glow.ps1` (adapter comment), `docs/external-dependencies.md` (claim cross-ref)
- Test: `tests/Test-DFToolConformance.Tests.ps1` (shipped-data consistency block)

**Interfaces:**
- Consumes: the orchestrator (Task 6), all library functions.
- Produces: the committed pilot artifacts and the shipped-data tests that guard them.

- [ ] **Step 1: Write the pilot descriptors**

Create `build/conformance/bat.jsonc`:

```jsonc
{
  // bat — conformance probes. See docs/superpowers/specs/2026-07-24-tool-conformance-infrastructure-design.md
  "tool": "bat",
  "claims": [
    {
      "id": "bat/honors-env:BAT_CONFIG_PATH",
      "probe": {
        "kind": "env-then-spawn",
        "setEnv": { "BAT_CONFIG_PATH": "${SCRATCH}/bat.conf" },
        "writeFile": { "${SCRATCH}/bat.conf": "--theme=\"ansi\"" },
        "spawn": ["bat", "--config-file"],
        "expect": { "contains": "${SCRATCH}" }
      }
    },
    {
      "id": "bat/honors-config-read",
      "probe": {
        "kind": "env-then-spawn",
        "setEnv": { "BAT_CONFIG_PATH": "${SCRATCH}/bat.conf" },
        "writeFile": {
          "${SCRATCH}/bat.conf": "--this-is-not-a-real-bat-flag",
          "${SCRATCH}/sample.md": "# hi"
        },
        "spawn": ["bat", "${SCRATCH}/sample.md"],
        "expect": { "contains": "error" }
      }
    },
    {
      "id": "bat/honors-config-content:theme",
      "probe": {
        "kind": "code",
        "ref": "bat.theme",
        "manualFallback": {
          "retest": "set theme=ansi in bat.conf; run `bat sample.md`; confirm the ANSI palette"
        }
      }
    }
  ]
}
```

Create `build/conformance/glow.jsonc`:

```jsonc
{
  // glow — env vars are ignored (Win32 known-folder config path); only flags work.
  // See Tools/glow.ps1 and docs/external-dependencies.md.
  "tool": "glow",
  "claims": [
    {
      "id": "glow/honors-env:GLOW_CONFIG_DIR",
      "probe": {
        "kind": "env-then-spawn",
        "setEnv": { "GLOW_CONFIG_DIR": "${SCRATCH}" },
        "spawn": ["glow", "--help"],
        "expect": { "contains": "${SCRATCH}" }
      }
    },
    {
      "id": "glow/honors-flag:-s",
      "probe": {
        "kind": "flag-then-spawn",
        "writeFile": { "${SCRATCH}/s.md": "# hi" },
        "spawn": ["glow", "-s", "__no_such_style__", "${SCRATCH}/s.md"],
        "expect": { "contains": "does not exist" }
      }
    },
    {
      "id": "glow/honors-flag:--config",
      "probe": {
        "kind": "manual",
        "retest": "glow --config <file> locates the file but its contents do not affect `glow <file>` rendering (verified glow 2.1.2); re-check on new versions whether --config content becomes effective"
      }
    }
  ]
}
```

- [ ] **Step 2: Annotate the glow adapter**

In `Tools/glow.ps1`, add the adapter reference to the existing header comment. Change the line (currently near line 11):

```powershell
# Only the --config and -s flags work reliably, hence this wrapper.
# See docs/external-dependencies.md.
```

to:

```powershell
# Only the --config and -s flags work reliably, hence this wrapper.
# adapter for glow/honors-env:GLOW_CONFIG_DIR
# See docs/external-dependencies.md.
```

- [ ] **Step 3: Generate the ledger + report against the real tools**

Ensure `bat` and `glow` are installed (they are in the tool DB):

Run: `pwsh -NoProfile -Command 'if (-not (Get-Command bat -EA Ignore)) { scoop install bat }; if (-not (Get-Command glow -EA Ignore)) { scoop install glow }'`

Then generate:

Run: `pwsh -NoProfile -Command './build/Test-DFToolConformance.ps1 -ProbedAt 2026-07-24 -Verbose'`
Expected: writes `data/tool-conformance.json` and `reports/tool-conformance-issues.md`. Inspect the ledger:

Run: `pwsh -NoProfile -Command 'Get-Content data/tool-conformance.json'`
Expected: `bat` record with `honors-env:BAT_CONFIG_PATH` = `pass`, `honors-config-read` = `pass`, `honors-config-content:theme` = `pass` or `manual`; `glow` record with `honors-env:GLOW_CONFIG_DIR` = `fail`, `honors-flag:-s` = `pass`, `honors-flag:--config` = `manual`. The report lists the glow env failure.

If `honors-config-content:theme` comes back `manual`, edit its ledger `evidence` to record your visual confirmation (e.g. `"ANSI palette confirmed visually 2026-07-24"`) — this is the human verdict the merge step will preserve on future regens.

- [ ] **Step 4: Write the shipped-data consistency tests**

Append to `tests/Test-DFToolConformance.Tests.ps1`:

```powershell
Describe 'Shipped conformance data' {
    BeforeAll {
        . "$PSScriptRoot/../Private/ConvertTo-DFPath.ps1"
        . "$PSScriptRoot/../Private/Expand-DFXdgPath.ps1"
        . "$PSScriptRoot/../build/DFConformance.ps1"
        $script:ledger = Get-Content "$PSScriptRoot/../data/tool-conformance.json" -Raw | ConvertFrom-Json
        $script:confDir = "$PSScriptRoot/../build/conformance"
    }

    It 'validates against the ledger schema' {
        { Test-DFConformanceLedgerSchema -Ledger $script:ledger } | Should -Not -Throw
    }

    It 'has a ledger record for every conformance fragment' {
        Get-ChildItem $script:confDir -Filter '*.jsonc' | ForEach-Object {
            $tool = (Read-DFConformanceFragment -Path $_.FullName).tool
            $script:ledger.PSObject.Properties.Name | Should -Contain $tool
        }
    }

    It 'every ledger claim id traces back to a descriptor claim' {
        $descIds = Get-ChildItem $script:confDir -Filter '*.jsonc' | ForEach-Object {
            (Read-DFConformanceFragment -Path $_.FullName).claims.id }
        foreach ($tool in $script:ledger.PSObject.Properties.Name) {
            foreach ($c in $script:ledger.$tool.claims) { $descIds | Should -Contain $c.id }
        }
    }

    It 'records glow env-immunity as a fail and bat env-honoring as a pass' {
        ($script:ledger.glow.claims | Where-Object id -eq 'glow/honors-env:GLOW_CONFIG_DIR').verdict | Should -Be 'fail'
        ($script:ledger.bat.claims  | Where-Object id -eq 'bat/honors-env:BAT_CONFIG_PATH').verdict | Should -Be 'pass'
    }

    It 'every adapter comment in Tools/*.ps1 references a claim present in the ledger (no orphans)' {
        $ids = @{}
        foreach ($t in $script:ledger.PSObject.Properties.Name) {
            foreach ($c in $script:ledger.$t.claims) { $ids[$c.id] = $true } }
        foreach ($link in Get-DFConformanceAdapterLink -ToolsPath "$PSScriptRoot/../Tools") {
            $ids.ContainsKey($link.Claim) | Should -BeTrue -Because "adapter references $($link.Claim)"
        }
    }
}
```

- [ ] **Step 5: Add the docs cross-reference**

In `docs/external-dependencies.md`, find the glow entry and append a line to it referencing the ledger claim id. Add (adjust surrounding wording to match the file's existing entry style):

```markdown
- Conformance claim: `glow/honors-env:GLOW_CONFIG_DIR` (verdict `fail`) — see `data/tool-conformance.json`. The `Tools/glow.ps1` wrapper is the adapter for this failure.
```

If no glow entry exists yet, add one under the appropriate heading describing that glow ignores all `GLOW_CONFIG_*`/`GLAMOUR_STYLE` env vars (Win32 known-folder config path) and that DotForge adapts via the `--config`/`-s` flag wrapper, cross-referencing the claim id above.

- [ ] **Step 6: Run the full suite**

Run: `pwsh -NoProfile -Command 'Invoke-Pester tests/ -Output Detailed'`
Expected: PASS under the installed Pester. Then confirm both engines if available:
Run: `pwsh -NoProfile -Command 'Invoke-Pester tests/Test-DFToolConformance.Tests.ps1, tests/DFConformance.Tests.ps1 -Output Detailed'`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add build/conformance/bat.jsonc build/conformance/glow.jsonc data/tool-conformance.json reports/tool-conformance-issues.md Tools/glow.ps1 docs/external-dependencies.md tests/Test-DFToolConformance.Tests.ps1
git commit -m "feat(conformance): pilot bat + glow — ledger, report, glow adapter link"
```

---

## Documentation updates (fold into Task 7 or a final commit)

Per the repo's pre-commit house rules:

- **README.md** — add a short "Tool conformance (author-time)" subsection under the development/build tooling area noting `build/Test-DFToolConformance.ps1`, `data/tool-conformance.json`, and that conformance is never run at runtime. Do NOT add it to the Exported Cmdlets or Included Tools lists (it exports nothing and adds no tool).
- **CHANGELOG.md** — under `[Unreleased]`, add: `Added: author-time tool-conformance harness (build/Test-DFToolConformance.ps1), versioned ledger (data/tool-conformance.json), and issue report; piloted on bat + glow.`
- **CLAUDE.md** — add a one-line pointer under a suitable heading: conformance probing is author-time only (`build/Test-DFToolConformance.ps1`), ledger at `data/tool-conformance.json`, adapters cite their failing claim id.
- **examples/** — no change (no runtime surface added; grep-verify no conformance references are expected).

Commit docs separately if not folded into Task 7:

```bash
git add README.md CHANGELOG.md CLAUDE.md
git commit -m "docs: note author-time tool-conformance harness"
```

## Verification (whole slice)

```powershell
# Unit + integration, both engines where available
pwsh -NoProfile -Command 'Invoke-Pester tests/DFConformance.Tests.ps1, tests/Test-DFToolConformance.Tests.ps1 -Output Detailed'
# No regressions
pwsh -NoProfile -Command 'Invoke-Pester tests/ -Output Detailed'
# Real generation is idempotent (re-running does not churn manual verdicts)
pwsh -NoProfile -Command './build/Test-DFToolConformance.ps1 -ProbedAt 2026-07-24; git diff --stat data/tool-conformance.json'
```

Confirm: the module never loads conformance data —
`pwsh -NoProfile -Command 'Select-String -Path DotForge.psm1 -Pattern "conformance|Test-DFToolConformance" '` returns nothing.
