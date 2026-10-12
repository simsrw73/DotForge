#Requires -Version 7.2
<#
.SYNOPSIS
    Runs the Pester suite the way "green" is defined in docs/TESTING.md, and fails when it isn't.
.DESCRIPTION
    Points every XDG_*_HOME at a fresh, empty sentinel folder, runs the tests,
    and reports passed/failed tests, failed containers (a file that fails
    discovery is neither passed nor failed), and any file the run wrote into a
    sentinel folder (a test that escaped its $TestDrive isolation). It also
    fails on a stray folder: a folder named after a DotForge tool that
    appears in the real %APPDATA%, %LOCALAPPDATA% or home folder during the
    run. Some tools (glow) find those folders through a Windows API that
    ignores environment variables, so running the real tool in a test writes
    there no matter how the XDG folders are redirected. Runs with
    $ErrorActionPreference = 'Stop', as GitHub Actions does. Exits 1 on any
    failure, failed container, sentinel file or stray folder, so CI and
    agents can gate on it. Run it from `pwsh -NoProfile`.
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

. (Join-Path $PSScriptRoot 'DFToolFolders.ps1')
$toolsPath = Join-Path $repo 'Tools'
$foldersBefore = Get-DFUserToolFolder -ToolsPath $toolsPath

Push-Location $repo
try {
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $result = Invoke-Pester -Path $Path -PassThru -Output $Output
    $written = @(Get-ChildItem $sentinel -Recurse -File)
    $stray = @(Get-DFUserToolFolder -ToolsPath $toolsPath | Where-Object { $_ -notin $foldersBefore })

    "Passed $($result.PassedCount) Failed $($result.FailedCount) Skipped $($result.SkippedCount) " +
    "FailedContainers $($result.FailedContainersCount) SentinelFiles $($written.Count) StrayFolders $($stray.Count) " +
    "($([int]$clock.Elapsed.TotalSeconds) s)"
    foreach ($container in $result.FailedContainers) { "FAILED CONTAINER: $($container.Item)" }
    foreach ($test in $result.Failed) { "FAILED: $($test.ExpandedPath)`n    $($test.ErrorRecord[0].Exception.Message)" }
    foreach ($file in $written | Select-Object -First 20) { "WROTE OUTSIDE `$TestDrive: $($file.FullName)" }
    foreach ($folder in $stray) { "CREATED A REAL TOOL FOLDER: $folder (a test ran the real tool; it is left for you to check)" }

    $green = $result.FailedCount -eq 0 -and $result.FailedContainersCount -eq 0 -and $written.Count -eq 0 -and $stray.Count -eq 0
    if (-not $green) { exit 1 }
} finally {
    Pop-Location
    Remove-Item $sentinel -Recurse -Force -ErrorAction Ignore
}
