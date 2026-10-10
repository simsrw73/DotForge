#Requires -Version 7.2
<#
.SYNOPSIS
    Installs the modules needed to develop and test DotForge, at the versions in build/requirements.psd1.
.DESCRIPTION
    For each module in build/requirements.psd1, installs that exact version from
    the PowerShell Gallery for the current user unless it is already installed.
    Other versions already installed are left alone. CI runs this before the tests.
.PARAMETER Path
    The requirements file. Default: build/requirements.psd1.
.EXAMPLE
    pwsh -NoProfile -File build/Install-DFDevDependencies.ps1

    Installs Pester, PSSQLite and powershell-yaml at the pinned versions, then
    the tests can run.
#>
param([string]$Path = (Join-Path $PSScriptRoot 'requirements.psd1'))

$requirements = Import-PowerShellDataFile -Path $Path
foreach ($name in $requirements.Keys | Sort-Object) {
    $version = $requirements[$name]
    $installed = Get-Module -ListAvailable -Name $name | Where-Object { $_.Version -eq [version]$version }
    if ($installed) {
        "$name $version is installed"
        continue
    }
    Install-PSResource -Name $name -Version $version -Repository PSGallery -TrustRepository -Scope CurrentUser -ErrorAction Stop
    "$name $version installed"
}
