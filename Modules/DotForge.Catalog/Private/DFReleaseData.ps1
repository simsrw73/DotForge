#Requires -Version 7.0

# "Release data": a JSON file that ships in data/, can be superseded by a newer
# copy downloaded from the latest DotForge release into <XDG data>\dotforge\,
# is schema-validated, falls back to the shipped copy if the downloaded one is
# unusable, and warns once per session if neither loads. tool-categories.json
# and tool-identities.json are both release data; each has its own validator
# (Test-DFCategoryDbSchema, Test-DFToolIdentityGuideSchema) and its own index
# builder (Get-DFCategoryDb, Get-DFToolIdentityGuide), and shares everything
# else here.

$script:DFReleaseDataWarned = @{}

function Invoke-DFReleaseAssetDownload {
    <#
    .SYNOPSIS
        Downloads and parses one JSON asset from the latest DotForge release.
    .DESCRIPTION
        The network seam for release data, so tests mock this one function.
    .PARAMETER FileName
        The asset name, e.g. 'tool-categories.json'.
    .OUTPUTS
        PSCustomObject. The parsed JSON.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$FileName)
    Invoke-RestMethod -Uri "https://github.com/simsrw73/DotForge/releases/latest/download/$FileName" -TimeoutSec 15
}

function Read-DFReleaseData {
    <#
    .SYNOPSIS
        Loads a release data file: the downloaded copy if it is newer and valid, otherwise the shipped one.
    .DESCRIPTION
        The downloaded copy (<XDG data>\dotforge\<FileName>) is used when its
        "updated" date is later than the shipped copy's. A downloaded copy that
        fails to parse or validate falls back to the shipped copy. When neither
        loads, warns once per session per file and returns $null. Never throws.
    .PARAMETER FileName
        The data file name, e.g. 'tool-categories.json'.
    .PARAMETER ShippedPath
        The shipped copy. Default: data\<FileName> in the module.
    .PARAMETER Validator
        Name of the schema validator: a command taking -Database and -Errors ([ref]).
    .PARAMETER Label
        Human name for messages, e.g. 'category database'.
    .PARAMETER UnavailableMessage
        The once-per-session warning when nothing loads.
    .OUTPUTS
        PSCustomObject (the raw document), or $null.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FileName,
        [string]$ShippedPath = (Join-Path $PSScriptRoot '..' '..' '..' 'data' $FileName),   # Modules/DotForge.Catalog/Private -> repo root
        [Parameter(Mandatory)][string]$Validator,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$UnavailableMessage
    )

    $tryLoad = {
        param($p)
        if (-not (Test-Path $p)) { return $null }
        try {
            $doc = Get-Content $p -Raw | ConvertFrom-Json
            $errs = $null
            if (& $Validator -Database $doc -Errors ([ref]$errs)) { return $doc }
            Write-Verbose "DotForge: $Label at '$p' failed schema validation: $($errs -join '; ')"
        } catch {
            Write-Verbose "DotForge: unreadable $Label '$p': $_"
        }
        $null
    }

    # A downloaded copy wins only when it's newer than the shipped one; if it
    # then turns out unusable, fall back to the shipped copy.
    $downloaded = Join-Path (Get-DFXdgPath Data) 'dotforge' $FileName
    $raw = $null
    if (Test-Path $downloaded) {
        try {
            $shippedUpdated = (Test-Path $ShippedPath) ? (Get-Content $ShippedPath -Raw | ConvertFrom-Json).updated : $null
            $downloadedUpdated = (Get-Content $downloaded -Raw | ConvertFrom-Json).updated
            if (-not $shippedUpdated -or [datetime]$downloadedUpdated -gt [datetime]$shippedUpdated) {
                $raw = & $tryLoad $downloaded
            }
        } catch {
            Write-Verbose "DotForge: unreadable downloaded $Label '$downloaded', using shipped: $_"
        }
    }
    if (-not $raw) { $raw = & $tryLoad $ShippedPath }

    if (-not $raw -and -not $script:DFReleaseDataWarned[$FileName]) {
        Write-Warning "DotForge: $UnavailableMessage"
        $script:DFReleaseDataWarned[$FileName] = $true
    }
    $raw
}

function Update-DFReleaseData {
    <#
    .SYNOPSIS
        Downloads the latest copy of a release data file, validates it, and writes it atomically.
    .DESCRIPTION
        Shared body of Update-DFCategoryDb and Update-DFToolIdentityGuide. A
        failed download or validation warns and leaves any existing copy
        untouched. Asks the calling cmdlet's ShouldProcess, so -WhatIf and
        -Confirm on the public command apply.
    .PARAMETER FileName
        The asset and file name, e.g. 'tool-categories.json'.
    .PARAMETER Validator
        Name of the schema validator: a command taking -Database and -Errors ([ref]).
    .PARAMETER Label
        Human name for messages, e.g. 'category database'.
    .PARAMETER Cmdlet
        The public cmdlet's $PSCmdlet, for ShouldProcess.
    .OUTPUTS
        None. Writes one line to the host on success.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][string]$Validator,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][System.Management.Automation.PSCmdlet]$Cmdlet
    )
    try {
        $doc = Invoke-DFReleaseAssetDownload $FileName
    } catch {
        Write-Warning "DotForge: failed to download $Label`: $_"
        return
    }
    $errs = $null
    if (-not (& $Validator -Database $doc -Errors ([ref]$errs))) {
        Write-Warning "DotForge: downloaded $Label failed validation, keeping the existing copy: $($errs -join '; ')"
        return
    }
    $destPath = Join-Path (Get-DFXdgPath Data) 'dotforge' $FileName
    if ($Cmdlet.ShouldProcess($destPath, "Update $Label")) {
        Write-DFFileAtomic -Path $destPath -Value ($doc | ConvertTo-Json -Depth 8)
        Write-Host "Updated $Label at $destPath ($(@($doc.tools.PSObject.Properties.Name).Count) tools)."
    }
}
