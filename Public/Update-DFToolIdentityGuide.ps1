#Requires -Version 7.0

function Update-DFToolIdentityGuide {
    <#
    .SYNOPSIS
        Downloads the latest published trifle tool-identity guide and
        installs it under $XDG_DATA_HOME/dotforge/, taking precedence over
        the module's shipped copy on the next load.
    .DESCRIPTION
        Purely opt-in — never runs implicitly, not part of Update-DFPackageCache,
        not triggered by any trifle/ftrifle call. Cross-catalog identity
        resolution stays fully usable offline with the shipped seed guide by
        default (and always falls back further to the live Tools/*.json
        mechanism regardless of guide state). Validates the download before
        writing; a failed download or a failed validation leaves any existing
        refreshed copy untouched and warns instead of throwing.
    .EXAMPLE
        Update-DFToolIdentityGuide
        Fetches and installs the latest published tool-identity guide.
    .EXAMPLE
        Update-DFToolIdentityGuide -WhatIf
        Shows what would be written without touching disk.
    .OUTPUTS
        None.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $uri = 'https://github.com/simsrw73/DotForge/releases/latest/download/tool-identities.json'
    try {
        $doc = Invoke-DFToolIdentityGuideDownload -Uri $uri
    } catch {
        Write-Warning "DotForge: failed to download tool-identity guide: $_"
        return
    }

    $errs = $null
    if (-not (Test-DFToolIdentityGuideSchema -Database $doc -Errors ([ref]$errs))) {
        Write-Warning "DotForge: downloaded tool-identity guide failed validation, keeping the existing copy: $($errs -join '; ')"
        return
    }

    if (-not $Env:XDG_DATA_HOME) {
        Write-Warning 'DotForge: $Env:XDG_DATA_HOME is not set. Call Initialize-DFEnvironment first.'
        return
    }

    $destDir = Join-Path $Env:XDG_DATA_HOME 'dotforge'
    $destPath = Join-Path $destDir 'tool-identities.json'

    if ($PSCmdlet.ShouldProcess($destPath, 'Update tool-identity guide')) {
        New-DFDirectory $destDir
        $tmp = "$destPath.tmp.$PID"
        $doc | ConvertTo-Json -Depth 8 | Set-Content -Path $tmp -Encoding UTF8
        Move-Item -Path $tmp -Destination $destPath -Force
        $toolCount = @($doc.tools.PSObject.Properties.Name).Count
        Write-Host "Updated tool-identity guide at $destPath ($toolCount tools)."
    }
}
