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
    if ($v -cmatch '\$\{XDG_(CONFIG|DATA|STATE|CACHE)_HOME\}') { $v = Expand-DFXdgPath $v }
    $v
}

function Test-DFConformanceDescriptor {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Fragment)
    $tool = $Fragment.PSObject.Properties['tool']?.Value
    if (-not $tool -or $tool -isnot [string]) {
        throw "DFConformance: fragment missing a string 'tool' field."
    }
    $claims = $Fragment.PSObject.Properties['claims']?.Value
    if ($null -eq $claims) { throw "DFConformance: '$tool' has no 'claims' array." }
    foreach ($c in $claims) {
        $id = $c.PSObject.Properties['id']?.Value
        if (-not $id -or $id -cnotmatch $script:DFConfClaimGrammar) {
            throw "DFConformance: claim id '$id' violates the id grammar."
        }
        $probe = $c.PSObject.Properties['probe']?.Value
        $kind = if ($null -ne $probe) { $probe.PSObject.Properties['kind']?.Value } else { $null }
        if (-not $probe -or $kind -notin $script:DFConfKinds) {
            throw "DFConformance: claim '$id' has an unknown probe kind '$kind'."
        }
        switch ($kind) {
            { $_ -in $script:DFConfSpawnKinds } {
                $spawn = $probe.PSObject.Properties['spawn']?.Value
                if (-not $spawn) { throw "DFConformance: claim '$id' ($_) needs a 'spawn' array." }
                $exp = $probe.PSObject.Properties['expect']?.Value
                $set = @('match','notMatch','contains','notContains') |
                    Where-Object { $exp -and $null -ne $exp.PSObject.Properties[$_] }
                if (@($set).Count -ne 1) {
                    throw "DFConformance: claim '$id' needs exactly one 'expect' rule (got $(@($set).Count))."
                }
            }
            'manual' {
                $probeRetest = $probe.PSObject.Properties['retest']?.Value
                $claimRetest = $c.PSObject.Properties['retest']?.Value
                if (-not $probeRetest -and -not $claimRetest) {
                    throw "DFConformance: manual claim '$id' needs a 'retest' string."
                }
            }
            'code' {
                $ref = $probe.PSObject.Properties['ref']?.Value
                if (-not $ref) { throw "DFConformance: code claim '$id' needs a 'ref'." }
            }
        }
    }
}

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
    [CmdletBinding()] [OutputType([bool])]
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
            # Select-Object -Skip 1 (not [1..Count-1]) so a single-element spawn array
            # yields @() instead of the range 1..0 = @(1,0) indexing out of bounds under StrictMode.
            $argv = @($probe.spawn | Select-Object -Skip 1 |
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

function Merge-DFConformanceRecord {
    [CmdletBinding()] [OutputType([hashtable])]
    param([pscustomobject]$Existing,
          [Parameter(Mandatory)][hashtable[]]$FreshClaims,
          [Parameter(Mandatory)][string]$Version)
    $notes = @()
    $prev = @{}
    $existingClaims = if ($Existing) { $Existing.PSObject.Properties['claims']?.Value } else { $null }
    if ($existingClaims) {
        foreach ($c in $existingClaims) { $prev[$c.id] = $c }
    }
    $prevVersion = if ($Existing) { $Existing.PSObject.Properties['versionTested']?.Value } else { $null }

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
        if (-not ($rec.PSObject.Properties['versionTested']?.Value)) {
            throw "DFConformance: '$($tool.Name)' missing versionTested." }
        foreach ($c in ($rec.PSObject.Properties['claims']?.Value)) {
            $id = $c.PSObject.Properties['id']?.Value
            if (-not $id -or $id -cnotmatch $script:DFConfClaimGrammar) {
                throw "DFConformance: ledger claim id '$id' violates the grammar." }
            $verdict = $c.PSObject.Properties['verdict']?.Value
            if ($verdict -notin $script:DFConfVerdicts) {
                throw "DFConformance: ledger claim '$id' has an invalid verdict '$verdict'." }
            $retest = $c.PSObject.Properties['retest']?.Value
            if ($verdict -eq 'manual' -and -not $retest) {
                throw "DFConformance: manual ledger claim '$id' needs a retest string." }
        }
    }
}

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
    # Callers wrap in @(...) — return the array plain (empty emits nothing, a
    # single hit unrolls to one item, both correct once @()-wrapped).
    $links
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
