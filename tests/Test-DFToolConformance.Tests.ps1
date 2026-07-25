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
