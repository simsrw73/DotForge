#Requires -Version 7.0
<#
.SYNOPSIS
    Runs the Pester suite the way "green" is defined in docs/TESTING.md, and fails when it isn't.
.DESCRIPTION
    Points every XDG_*_HOME at a fresh, empty sentinel folder, runs the tests,
    and reports passed/failed tests, failed containers (a file that fails
    discovery is neither passed nor failed), and any file the run wrote into a
    sentinel folder (a test that escaped its $TestDrive isolation). Runs with
    $ErrorActionPreference = 'Stop', as GitHub Actions does. Exits 1 on
    any failure, failed container or sentinel file, so CI and agents can gate
    on it. Run it from `pwsh -NoProfile`.
.PARAMETER Path
    Test files or folders. Default: the whole tests/ folder.
.PARAMETER Output
    Pester output verbosity. Default: None (summary only).
.EXAMPLE
    pwsh -NoProfile -File build/Test-DFFull.ps1

    The full suite with sentinel XDG folders: the gate before a merge.
.EXAMPLE
    pwsh -NoProfile -Command "./build/Test-DFFull.ps1 -Path tests/Start-DFSession.Tests.ps1, tests/Requires.Tests.ps1"

    Only the files that cover the code you changed, with the same checks.
#>
param(
    [string[]]$Path = @(Join-Path $PSScriptRoot '../tests'),
    [ValidateSet('None', 'Normal', 'Detailed', 'Diagnostic')][string]$Output = 'None'
)

# GitHub's pwsh steps run with $ErrorActionPreference = 'Stop'; do the same so a local run
# fails where CI does (and so tests cover profiles that set it).
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$sentinel = Join-Path ([System.IO.Path]::GetTempPath()) "dotforge-sentinel-$(Get-Random)"
foreach ($kind in 'CONFIG', 'CACHE', 'DATA', 'STATE') {
    $folder = Join-Path $sentinel $kind
    New-Item -ItemType Directory $folder -Force | Out-Null
    Set-Item "Env:XDG_$($kind)_HOME" $folder
}

Push-Location $repo
try {
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $result = Invoke-Pester -Path $Path -PassThru -Output $Output
    $written = @(Get-ChildItem $sentinel -Recurse -File)

    "Passed $($result.PassedCount) Failed $($result.FailedCount) Skipped $($result.SkippedCount) " +
    "FailedContainers $($result.FailedContainersCount) SentinelFiles $($written.Count) " +
    "($([int]$clock.Elapsed.TotalSeconds) s)"
    foreach ($container in $result.FailedContainers) { "FAILED CONTAINER: $($container.Item)" }
    foreach ($test in $result.Failed) { "FAILED: $($test.ExpandedPath)`n    $($test.ErrorRecord[0].Exception.Message)" }
    foreach ($file in $written | Select-Object -First 20) { "WROTE OUTSIDE `$TestDrive: $($file.FullName)" }

    $green = $result.FailedCount -eq 0 -and $result.FailedContainersCount -eq 0 -and $written.Count -eq 0
    if (-not $green) { exit 1 }
} finally {
    Pop-Location
    Remove-Item $sentinel -Recurse -Force -ErrorAction Ignore
}
