#Requires -Version 7.2

function Get-DFWingetRows {
    param([pscustomobject]$Result, [switch]$Outdated)
    if ($Result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($Result.Output)) { return }
    $header = $null
    foreach ($line in $Result.Output -split "`r?`n") {
        if ($line -match '^Name\s+Id\s+Version') { $header = $line; continue }
        if (-not $header -or $line -match '^-+' -or $line -match '^\d+ upgrades available') { continue }
        $idAt = $header.IndexOf('Id'); $versionAt = $header.IndexOf('Version')
        if ($line.Length -le $idAt) { continue }
        $id = (($line.Substring($idAt, [Math]::Min($versionAt - $idAt, $line.Length - $idAt))).Trim())
        [string[]]$versions = if ($line.Length -gt $versionAt) { @($line.Substring($versionAt).Trim() -split '\s{2,}') } else { @() }
        if ($id -and $versions.Count -ge 1 -and $versions[0]) {
            [pscustomobject]@{ Id = $id; Installed = $versions[0]; Available = $(if ($Outdated -and $versions.Count -gt 1) { $versions[1] } else { $null }) }
        }
    }
}

function Get-DFWingetInstalled {
    <#
    .SYNOPSIS
        Lists packages installed by WinGet.
    .DESCRIPTION
        Uses Microsoft.WinGet.Client when available; otherwise parses the WinGet list table through DotForge's manager command seam.
    .PARAMETER Manager
        The WinGet manager tool record.
    .EXAMPLE
        Get-DFWingetInstalled -Manager $manager

        Returns WinGet package ids and installed versions.
    .OUTPUTS
        PSCustomObject with Id, Installed, and Available.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][pscustomobject]$Manager)
    if (Get-Command Get-WinGetPackage -ErrorAction Ignore) {
        try { Get-WinGetPackage 2>$null | Where-Object Source -eq 'winget' | ForEach-Object { [pscustomobject]@{ Id = [string]$_.Id; Installed = [string]$_.InstalledVersion; Available = $null } }; return } catch { return }
    }
    Get-DFWingetRows (Invoke-DFManagerCommand -Operation list -Manager $Manager -Argv @('winget', 'list', '--source', 'winget'))
}

function Get-DFWingetOutdated {
    <#
    .SYNOPSIS
        Lists WinGet packages with available updates.
    .DESCRIPTION
        Uses Microsoft.WinGet.Client when available; otherwise parses the WinGet upgrade table through DotForge's manager command seam.
    .PARAMETER Manager
        The WinGet manager tool record.
    .EXAMPLE
        Get-DFWingetOutdated -Manager $manager

        Returns WinGet package ids with installed and available versions.
    .OUTPUTS
        PSCustomObject with Id, Installed, and Available.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][pscustomobject]$Manager)
    if (Get-Command Get-WinGetPackage -ErrorAction Ignore) {
        try { Get-WinGetPackage 2>$null | Where-Object { $_.Source -eq 'winget' -and $_.IsUpdateAvailable } | ForEach-Object { [pscustomobject]@{ Id = [string]$_.Id; Installed = [string]$_.InstalledVersion; Available = [string]@($_.AvailableVersions)[0] } }; return } catch { return }
    }
    Get-DFWingetRows (Invoke-DFManagerCommand -Operation outdated -Manager $Manager -Argv @('winget', 'upgrade', '--source', 'winget')) -Outdated
}
