#Requires -Version 7.0

function Add-DFScoopBucket {
    <#
    .SYNOPSIS
        Makes sure a tool's third-party scoop bucket is added; returns whether the install can go ahead.
    .DESCRIPTION
        Adds the bucket ({ name; url } from the tool's scoopBucket field) when
        scoop bucket list doesn't show it, printing what it added on its own
        line. If the add fails, the list is checked again: the first list can
        fail or come back empty while the bucket exists, and scoop then refuses
        to add it twice. Only a bucket that is still missing warns and returns
        $false. Install-DFTool then installs <name>/<id>.
    .PARAMETER Bucket
        The tool's scoopBucket object.
    .OUTPUTS
        System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][object]$Bucket)

    $isListed = {
        $names = @(scoop bucket list 2>$null | ForEach-Object { if ($_ -is [string]) { ($_ -split '\s+')[0] } else { $_.Name } })
        $Bucket.name -in $names
    }
    if (& $isListed) { return $true }

    $null = scoop bucket add $Bucket.name $Bucket.url 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "DotForge: added scoop bucket '$($Bucket.name)' ($($Bucket.url))"
        return $true
    }
    if (& $isListed) { return $true }
    Write-Warning "DotForge: could not add scoop bucket '$($Bucket.name)' ($($Bucket.url))."
    $false
}
