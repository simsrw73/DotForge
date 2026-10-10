#Requires -Version 7.0
<#
.SYNOPSIS
    Builds data/tool-registry.json: every shipped tool record, validated and normalized.
.DESCRIPTION
    Startup reads tool records through Read-DFToolRecordFile, which uses this
    file's record when the JSON it reads hashes the same, and so skips parsing,
    validating and normalizing it. A record with schema errors or warnings
    fails the build. tests/ToolRegistry.Tests.ps1 fails when this file is stale.
.PARAMETER OutputPath
    Output file (default: data/tool-registry.json at the repo root).
.EXAMPLE
    ./build/Build-DFToolRegistry.ps1

    Regenerates data/tool-registry.json from Tools/*.json.
#>
[CmdletBinding()]
param([string]$OutputPath)

$repo = Split-Path $PSScriptRoot -Parent
if (-not $OutputPath) { $OutputPath = Join-Path $repo 'data' 'tool-registry.json' }
# Private functions aren't exported: load them the way the module does.
Get-ChildItem (Join-Path $repo 'Private') -Filter '*.ps1' | ForEach-Object { . $_.FullName }

$tools = [ordered]@{}
foreach ($f in Get-ChildItem (Join-Path $repo 'Tools') -Filter '*.json' | Sort-Object Name) {
    $text = [IO.File]::ReadAllText($f.FullName)
    $raw = $text | ConvertFrom-Json
    $errs = @(); $warns = @()
    if (-not (Test-DFToolSchema -Tool $raw -Errors ([ref]$errs) -Warnings ([ref]$warns)) -or $warns) {
        throw "Build-DFToolRegistry: $($f.Name): $(@($errs) + @($warns) -join '; ')"
    }
    $tools[$f.BaseName] = [ordered]@{ sha256 = Get-DFToolRecordHash -Text $text; record = ConvertTo-DFToolRecord $raw }
}
$json = [ordered]@{ schemaVersion = 1; tools = $tools } | ConvertTo-Json -Depth 30
[IO.File]::WriteAllText($OutputPath, $json + "`n", [Text.UTF8Encoding]::new($false))
Write-Host "Wrote $OutputPath ($($tools.Count) tools)"
