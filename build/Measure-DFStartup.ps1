#Requires -Version 7.2
<#
.SYNOPSIS
    Manual dev tool: measures the wall-clock cost of Start-DFSession on
    this machine, to compare before/after a performance change.
.DESCRIPTION
    Imports a fresh copy of the DotForge module, then times several consecutive
    Start-DFSession calls with the selected opt-in tool profile
    calls and reports min/mean/max in milliseconds. Not run in CI: timings
    depend on which tools are actually installed and on this machine's disk,
    so there is no meaningful pass/fail threshold to assert.
.PARAMETER Iterations
    How many timed Start-DFSession calls to run. Defaults to 5.
.EXAMPLE
    pwsh -NoProfile -File build/Measure-DFStartup.ps1
    Prints a min/mean/max report to the host.
.EXAMPLE
    pwsh -NoProfile -File build/Measure-DFStartup.ps1 -Iterations 10
    Runs 10 timed iterations instead of the default 5.
#>
[CmdletBinding()]
param([int]$Iterations = 5)

Import-Module (Join-Path $PSScriptRoot '../DotForge.psd1') -Force
$config = @{ Tools = @('+core') }

$timings = 1..$Iterations | ForEach-Object {
    (Measure-Command { Start-DFSession -Config $config }).TotalMilliseconds
}

[pscustomobject]@{
    Iterations = $Iterations
    MinMs      = [math]::Round(($timings | Measure-Object -Minimum).Minimum, 1)
    MeanMs     = [math]::Round(($timings | Measure-Object -Average).Average, 1)
    MaxMs      = [math]::Round(($timings | Measure-Object -Maximum).Maximum, 1)
} | Format-List
