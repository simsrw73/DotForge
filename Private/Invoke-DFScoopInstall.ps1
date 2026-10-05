#Requires -Version 7.0

function Invoke-DFScoopInstall {
    <#
    .SYNOPSIS
        Installs a scoop package, first adding the tool's third-party bucket when it declares one.
    .DESCRIPTION
        With -Bucket ({ name; url } from the tool's scoopBucket field): adds the
        bucket when scoop bucket list doesn't show it, printing what it added,
        then installs <name>/<id> so a same-named package in another bucket
        can't win. A failed add warns and installs nothing. Sets
        $global:LASTEXITCODE (0 = installed) like Install-DFTool's other
        manager branches.
    .PARAMETER Id
        The package id (packages.scoop).
    .PARAMETER Bucket
        The tool's scoopBucket object, or $null.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [AllowNull()][object]$Bucket
    )
    if ($Bucket) {
        $listed = @(scoop bucket list 2>$null | ForEach-Object { if ($_ -is [string]) { ($_ -split '\s+')[0] } else { $_.Name } })
        if ($Bucket.name -notin $listed) {
            $null = scoop bucket add $Bucket.name $Bucket.url 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "DotForge: could not add scoop bucket '$($Bucket.name)' ($($Bucket.url))."
                $global:LASTEXITCODE = 1
                return
            }
            Write-Host "DotForge: added scoop bucket '$($Bucket.name)' ($($Bucket.url))"
        }
        $Id = "$($Bucket.name)/$Id"
    }
    $null = scoop install $Id 2>&1
}
