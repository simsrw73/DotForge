#Requires -Version 7.0
<#
.SYNOPSIS
    Stages and publishes DotForge to the PowerShell Gallery.
.DESCRIPTION
    Copies only the module files (no tests, docs, or dev tooling) to a temp
    staging directory, then publishes from there. Cleans up the stage dir
    whether or not the publish succeeds.
.PARAMETER ApiKey
    Your PSGallery NuGet API key.
.PARAMETER WhatIf
    Stage the directory and list what would be published, but do not submit.
.EXAMPLE
    .\Publish-DotForge.ps1 -ApiKey $env:PSGALLERY_KEY
    Publishes to PSGallery.
.EXAMPLE
    .\Publish-DotForge.ps1 -ApiKey unused -DryRun
    Lists the files that would be included in the package.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$ApiKey,
    [switch]$DryRun
)

$moduleRoot = $PSScriptRoot
$stageDir   = Join-Path $env:TEMP "DotForge-stage-$(Get-Date -Format 'yyyyMMddHHmmss')"

try {
    New-Item -ItemType Directory -Path $stageDir | Out-Null

    foreach ($item in @('DotForge.psd1','DotForge.psm1','Public','Private','Tools','LICENSE','README.md','CHANGELOG.md')) {
        Copy-Item (Join-Path $moduleRoot $item) -Destination $stageDir -Recurse
    }

    if ($DryRun) {
        Write-Host "Stage dir: $stageDir" -ForegroundColor Cyan
        Write-Host 'Files that would be published:' -ForegroundColor Yellow
        Get-ChildItem $stageDir -Recurse -File | ForEach-Object {
            $_.FullName.Replace($stageDir + '\', '')
        }
        return
    }

    Publish-Module -Path $stageDir -NuGetApiKey $ApiKey
    Write-Host 'Published to PSGallery.' -ForegroundColor Green
} finally {
    Remove-Item $stageDir -Recurse -Force -ErrorAction Ignore
}
