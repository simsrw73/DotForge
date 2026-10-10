#Requires -Version 7.0
<#
.SYNOPSIS
    Builds Bundle/DotForge.Core.ps1: the startup core (Shared/, Private/, Public/) as one file.
.DESCRIPTION
    Dot-sourcing one file is about 0.3 s faster than dot-sourcing 58. The
    header records a hash of the sources; DotForge.psm1 uses the bundle only
    when that hash matches, and loads the separate files otherwise (an edit not
    yet bundled, or DF_NO_BUNDLE=1 for debugging, since errors inside the bundle
    report bundle line numbers). tests/CoreBundle.Tests.ps1 fails when the
    bundle is stale.
.PARAMETER OutputPath
    Output file (default: Bundle/DotForge.Core.ps1 at the repo root).
.EXAMPLE
    ./build/Build-DFCoreBundle.ps1

    Regenerates Bundle/DotForge.Core.ps1.
#>
[CmdletBinding()]
param([string]$OutputPath)

$repo = Split-Path $PSScriptRoot -Parent
if (-not $OutputPath) { $OutputPath = Join-Path $repo 'Bundle' 'DotForge.Core.ps1' }
. (Join-Path $repo 'Bundle' 'CoreSourceHash.ps1')

$sb = [Text.StringBuilder]::new()
$null = $sb.Append("# DotForge startup core, bundled by build/Build-DFCoreBundle.ps1. Do not edit: edit the sources.`n")
$null = $sb.Append("# sources-sha256: $(Get-DFCoreSourceHash -Root $repo)`n")
foreach ($f in Get-DFCoreSourceFile -Root $repo) {
    $rel = [IO.Path]::GetRelativePath($repo, $f.FullName).Replace('\', '/')
    $null = $sb.Append("`n# ---- $rel`n").Append((Get-DFCoreSourceText -Path $f.FullName).TrimEnd("`n")).Append("`n")
}
[IO.File]::WriteAllText($OutputPath, $sb.ToString(), [Text.UTF8Encoding]::new($false))
Write-Host "Wrote $OutputPath"
