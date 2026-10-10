#Requires -Version 7.2
<#
.SYNOPSIS
    Publishes the working tree to the local PowerShell gallery as a dev build, so you can install and try it in a real shell.
.DESCRIPTION
    Your shell runs an installed DotForge, never this checkout. To try a change
    there without a release, publish a dev build here and install it.

    Copies the tracked files (with their uncommitted edits; untracked files are
    left out and listed) to a staging folder, stamps a version that sorts above
    the last release (the next patch, prerelease 'dev' + a timestamp, e.g.
    0.7.1-dev20261010183000), rebuilds the core bundle there, and publishes it
    to -Repository. -Install then installs that exact build for the current
    user. The checkout itself is never changed.

    The repository must be registered for PSResourceGet (Publish-PSResource),
    not only for the older PowerShellGet:
        Microsoft.PowerShell.PSResourceGet\Register-PSResourceRepository -Name LocalGallery -Uri <folder> -Trusted
.PARAMETER Repository
    The PSResourceGet repository to publish to. Default: LocalGallery.
.PARAMETER Install
    Also install the published build for the current user (Install-PSResource -Reinstall).
.EXAMPLE
    pwsh -NoProfile -File build/Publish-DFLocal.ps1 -Install

    Publishes the working tree as a dev build and installs it; the next new
    shell loads it.
#>
param(
    [string]$Repository = 'LocalGallery',
    [switch]$Install
)
$ErrorActionPreference = 'Stop'
# Module-qualified: an old PowerShellGet 3.0 beta exports the same command names
# with its own (separate) repository list, and can shadow PSResourceGet.
$psrg = 'Microsoft.PowerShell.PSResourceGet'
Import-Module $psrg
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

if (-not (& "$psrg\Get-PSResourceRepository" -Name $Repository -ErrorAction Ignore)) {
    throw "Repository '$Repository' isn't registered for PSResourceGet. Register it with: Register-PSResourceRepository -Name $Repository -Uri <folder> -Trusted"
}

$untracked = @(git -C $repo ls-files --others --exclude-standard)
if ($untracked) { Write-Warning "Not included (untracked, add them to git first): $($untracked -join ', ')" }

$manifest = Import-PowerShellDataFile (Join-Path $repo 'DotForge.psd1')
$base = [version]$manifest.ModuleVersion
$version = '{0}.{1}.{2}' -f $base.Major, $base.Minor, ($base.Build + 1)
$prerelease = 'dev' + (Get-Date -Format 'yyyyMMddHHmmss')

# The folder name must equal the module name: Publish-PSResource looks for <folder>.psd1.
$stage = Join-Path ([IO.Path]::GetTempPath()) "dotforge-local-$(Get-Random)"
$export = Join-Path $stage 'DotForge'
try {
    foreach ($file in @(git -C $repo ls-files)) {
        $source = Join-Path $repo $file
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { continue }   # deleted in the working tree
        $target = Join-Path $export $file
        $null = New-Item -ItemType Directory -Force (Split-Path $target -Parent)
        Copy-Item -LiteralPath $source -Destination $target
    }

    # Stamp the dev version into all three manifests (they must agree).
    foreach ($psd1 in @(Join-Path $export 'DotForge.psd1') + @(Get-ChildItem (Join-Path $export 'Modules') -Filter '*.psd1' -Recurse | ForEach-Object FullName)) {
        $text = (Get-Content $psd1 -Raw) -replace "ModuleVersion\s*=\s*'[^']*'", "ModuleVersion     = '$version'"
        if ($psd1 -like '*\DotForge\DotForge.psd1') { $text = $text -replace "Prerelease\s*=\s*'[^']*'", "Prerelease   = '$prerelease'" }
        Set-Content -Path $psd1 -Value $text -NoNewline
    }
    $null = & (Join-Path $export 'build' 'Build-DFCoreBundle.ps1') 6>$null

    & "$psrg\Publish-PSResource" -Path $export -Repository $Repository
    "Published DotForge $version-$prerelease to $Repository"

    if ($Install) {
        & "$psrg\Install-PSResource" -Name DotForge -Repository $Repository -Version "$version-$prerelease" -Prerelease -TrustRepository -Reinstall -Scope CurrentUser
        "Installed DotForge $version-$prerelease; open a new shell to load it"
    }
} finally {
    Remove-Item $stage -Recurse -Force -ErrorAction Ignore
}
