#Requires -Version 7.0
<#
.SYNOPSIS
    Manual dev tool: measures the wall-clock cost of Register-DFTool -All on
    this machine, to compare before/after a performance change.
.DESCRIPTION
    Imports a fresh copy of the DotForge module, runs Initialize-DFEnvironment
    once (untimed setup), then times several consecutive Register-DFTool -All
    calls and reports min/mean/max in milliseconds. Not run in CI: timings
    depend on which tools are actually installed and on this machine's disk,
    so there is no meaningful pass/fail threshold to assert.
.PARAMETER Iterations
    How many timed Register-DFTool -All calls to run. Defaults to 5.
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
Initialize-DFEnvironment | Out-Null

$timings = 1..$Iterations | ForEach-Object {
    (Measure-Command { Register-DFTool -All }).TotalMilliseconds
}

[pscustomobject]@{
    Iterations = $Iterations
    MinMs      = [math]::Round(($timings | Measure-Object -Minimum).Minimum, 1)
    MeanMs     = [math]::Round(($timings | Measure-Object -Average).Average, 1)
    MaxMs      = [math]::Round(($timings | Measure-Object -Maximum).Maximum, 1)
} | Format-List
