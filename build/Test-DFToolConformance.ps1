#Requires -Version 7.0
<#
.SYNOPSIS
    Author-time tool-conformance harness. Reads build/conformance/*.jsonc probe
    descriptors, runs each claim's probe against the real tool, and writes the
    versioned ledger (data/tool-conformance.json) plus the issue report
    (reports/tool-conformance-issues.md). NEVER loaded by the DotForge module.
.PARAMETER ConformanceDir
    Directory of *.jsonc probe descriptors (default: build/conformance).
.PARAMETER OutPath
    Ledger output (default: data/tool-conformance.json).
.PARAMETER ReportPath
    Issue-report output (default: reports/tool-conformance-issues.md).
.PARAMETER Tool
    Limit to the named tools (fragment base names); default = all fragments.
.PARAMETER ProbedAt
    Author-supplied date stamp recorded in each record; the harness never reads
    the clock itself. Omit to leave probedAt out.
.PARAMETER SpawnTool
    Override the tool-spawning seam. Tests inject a canned scriptblock; the
    default launches the real executable in an isolated environment. Contract:
    & $SpawnTool $Exe $Argv $EnvMap $Cwd -> @{ ExitCode; StdOut; StdErr; Absent }.
.EXAMPLE
    ./build/Test-DFToolConformance.ps1 -ProbedAt 2026-07-24 -Verbose
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

    # Find the first claim carrying a spawn array; its [0] is the executable.
    # (A ForEach-Object pipeline would unroll the arrays and flatten to strings,
    # so Select -First 1 would pick 'bat' and $exe[0] would be the char 'b'.)
    $firstSpawn = $null
    foreach ($claim in $frag.claims) {
        $s = $claim.probe.PSObject.Properties['spawn']?.Value
        if ($s) { $firstSpawn = $s; break }
    }
    $exe = if ($firstSpawn) { $firstSpawn[0] } else { $toolName }
    $verArgs = if ($frag.PSObject.Properties['versionArgs']) { @($frag.versionArgs) } else { @('--version') }
    $version = Get-DFToolVersion -Exe $exe -VersionArgs $verArgs -SpawnTool $SpawnTool

    $existingRec = if ($existingLedger -and $existingLedger.PSObject.Properties[$toolName]) {
        $existingLedger.$toolName } else { $null }

    $fresh = foreach ($claim in $frag.claims) {
        # Only spawn/code claims need the tool. Manual claims are descriptor-derived,
        # so they are evaluated even when the tool is absent (never faked to 'unknown').
        $needsTool = $claim.probe.kind -in @('env-then-spawn','flag-then-spawn','code')
        if ($null -eq $version -and $needsTool) {
            @{ id=$claim.id; verdict='unknown'; kind=$claim.probe.kind; evidence='tool absent'; retest=$null }
        } else {
            $scratch = Join-Path ([System.IO.Path]::GetTempPath()) ("dfconf-" + [guid]::NewGuid().Guid)
            New-Item -ItemType Directory -Path $scratch -Force | Out-Null
            try {
                Invoke-DFConformanceProbe -Claim $claim -Scratch $scratch -ProbesDir $probesDir -SpawnTool $SpawnTool
            } finally { Remove-Item $scratch -Recurse -Force -ErrorAction Ignore }
        }
    }

    # When the tool is absent, keep the prior record's version so the verdicts
    # Merge preserves below stay version-consistent (rather than stamping 'unknown'
    # over claims that were really tested at the prior version).
    $effectiveVersion = if ($null -ne $version) { $version }
                        elseif ($existingRec) { ($existingRec.PSObject.Properties['versionTested']?.Value) ?? 'unknown' }
                        else { 'unknown' }
    $merged = Merge-DFConformanceRecord -Existing $existingRec -FreshClaims @($fresh) -Version $effectiveVersion
    $allNotes += $merged.Notes

    $rec = [ordered]@{ versionTested = $effectiveVersion }
    if ($ProbedAt) { $rec.probedAt = $ProbedAt }
    # Emit claims with a canonical key order so the committed JSON is stable across
    # regenerations (a plain hashtable enumerates keys non-deterministically).
    $rec.claims = @($merged.Claims | ForEach-Object {
        $o = [ordered]@{ id = $_.id; verdict = $_.verdict; kind = $_.kind; evidence = $_.evidence }
        if ($_.ContainsKey('retest') -and $null -ne $_.retest) { $o.retest = $_.retest }
        $o
    })
    $ledger[$toolName] = $rec
}

# Validate before writing; a schema violation is an author bug, fail loudly.
$ledgerObj = $ledger | ConvertTo-Json -Depth 10 | ConvertFrom-Json
Test-DFConformanceLedgerSchema -Ledger $ledgerObj

New-Item -ItemType Directory -Path (Split-Path $OutPath) -Force | Out-Null
$ledger | ConvertTo-Json -Depth 10 | Set-Content -Path $OutPath

$links = @(Get-DFConformanceAdapterLink -ToolsPath (Join-Path $PSScriptRoot '../Tools'))
New-Item -ItemType Directory -Path (Split-Path $ReportPath) -Force | Out-Null
# Convert the ordered ledger to a plain hashtable for the report renderer.
$ledgerHash = @{}; foreach ($k in $ledger.Keys) { $ledgerHash[$k] = $ledger[$k] }
Write-DFConformanceReport -Ledger $ledgerHash -AdapterLinks $links -Path $ReportPath

foreach ($n in $allNotes) { Write-Warning $n }
Write-Verbose "Conformance ledger written to $OutPath"
