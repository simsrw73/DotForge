Describe 'Test-DFToolConformance harness' {
    BeforeEach {
        $script:confDir = Join-Path $TestDrive ([guid]::NewGuid().Guid)
        $script:probes  = Join-Path $script:confDir 'probes'
        New-Item -ItemType Directory -Path $script:probes -Force | Out-Null
        $script:out = Join-Path $script:confDir 'ledger.json'
        $script:rpt = Join-Path $script:confDir 'issues.md'
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
        # The seam checks $e so a broken exe-extraction (e.g. 'b' instead of 'bat')
        # reports Absent and the pass assertion fails — guards that regression.
        $spawn = { param($e,$a,$env,$cwd)
            if ($e -ne 'bat') { return @{ Absent=$true; ExitCode=-1; StdOut=''; StdErr='' } }
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
        # The seam checks $e so a broken exe-extraction (e.g. 'b' instead of 'bat')
        # reports Absent and the pass assertion fails — guards that regression.
        $spawn = { param($e,$a,$env,$cwd)
            if ($e -ne 'bat') { return @{ Absent=$true; ExitCode=-1; StdOut=''; StdErr='' } }
            if ($a -contains '--version') { return @{ ExitCode=0; StdOut='bat 0.24.0'; StdErr=''; Absent=$false } }
            @{ ExitCode=0; StdOut="$($env.BAT_CONFIG_PATH)"; StdErr=''; Absent=$false } }
        & "$PSScriptRoot/../build/Test-DFToolConformance.ps1" -ConformanceDir $script:confDir `
            -OutPath $script:out -ReportPath $script:rpt -ProbedAt '2026-07-24' -SpawnTool $spawn
        Test-Path $script:rpt | Should -BeTrue
    }
}

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
        foreach ($link in @(Get-DFConformanceAdapterLink -ToolsPath "$PSScriptRoot/../Tools")) {
            $ids.ContainsKey($link.Claim) | Should -BeTrue -Because "adapter references $($link.Claim)"
        }
    }
}
