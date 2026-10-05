#Requires -Version 7.0

function Update-DFCategoryDb {
    <#
    .SYNOPSIS
        Downloads the latest published trifle category database and installs
        it under $XDG_DATA_HOME/dotforge/, taking precedence over the module's
        shipped copy on the next load.
    .DESCRIPTION
        Purely opt-in — never runs implicitly, not part of Update-DFPackageCache,
        not triggered by any trifle/ftrifle call. Discovery stays fully usable
        offline with the shipped seed data by default. Validates the download
        before writing; a failed download or a failed validation leaves any
        existing refreshed copy untouched and warns instead of throwing.

        Downloads tool-categories.json from the latest DotForge GitHub release
        and writes $XDG_DATA_HOME\dotforge\tool-categories.json (atomically,
        through a temp file). Delete that file to go back to the shipped copy.
        Needs $Env:XDG_DATA_HOME (set by Initialize-DFEnvironment). Supports
        -WhatIf and -Confirm.
        Update-DFCategoryDb
        Fetches and installs the latest published category database.
    .EXAMPLE
        Update-DFCategoryDb -WhatIf

        Shows what would be written without touching disk.
    .OUTPUTS
        None. Writes one line to the host on success.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/package-catalog.md
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $uri = 'https://github.com/simsrw73/DotForge/releases/latest/download/tool-categories.json'
    try {
        $doc = Invoke-DFCategoryDbDownload -Uri $uri
    } catch {
        Write-Warning "DotForge: failed to download category database: $_"
        return
    }

    $errs = $null
    if (-not (Test-DFCategoryDbSchema -Database $doc -Errors ([ref]$errs))) {
        Write-Warning "DotForge: downloaded category database failed validation, keeping the existing copy: $($errs -join '; ')"
        return
    }

    if (-not $Env:XDG_DATA_HOME) {
        Write-Warning 'DotForge: $Env:XDG_DATA_HOME is not set. Call Initialize-DFEnvironment first.'
        return
    }

    $destDir = Join-Path $Env:XDG_DATA_HOME 'dotforge'
    $destPath = Join-Path $destDir 'tool-categories.json'

    if ($PSCmdlet.ShouldProcess($destPath, 'Update category database')) {
        New-DFDirectory $destDir
        $tmp = "$destPath.tmp.$PID"
        $doc | ConvertTo-Json -Depth 8 | Set-Content -Path $tmp -Encoding UTF8
        Move-Item -Path $tmp -Destination $destPath -Force
        $toolCount = @($doc.tools.PSObject.Properties.Name).Count
        Write-Host "Updated category database at $destPath ($toolCount tools)."
    }
}
