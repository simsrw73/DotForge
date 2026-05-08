#Requires -Version 7.0

function Initialize-DFEnvironment {
    <#
    .SYNOPSIS
        Bootstraps the DotForge environment: sets XDG base directory env vars
        if absent, creates the directories, and reports available package managers.
        Safe to call multiple times (idempotent).
    #>
    [CmdletBinding()]
    param()

    if (-not $Env:XDG_CONFIG_HOME) { $Env:XDG_CONFIG_HOME = Join-Path $home '.config' }
    if (-not $Env:XDG_DATA_HOME)   { $Env:XDG_DATA_HOME   = Join-Path $home '.local' 'share' }
    if (-not $Env:XDG_STATE_HOME)  { $Env:XDG_STATE_HOME  = Join-Path $home '.local' 'state' }
    if (-not $Env:XDG_CACHE_HOME)  { $Env:XDG_CACHE_HOME  = Join-Path $home '.cache' }

    @($Env:XDG_CONFIG_HOME, $Env:XDG_DATA_HOME, $Env:XDG_STATE_HOME, $Env:XDG_CACHE_HOME) |
        ForEach-Object { New-DFDirectory $_ }

    $pms = @(Resolve-DFPackageManager -Force | Where-Object { $_ })

    if ($pms.Count -eq 0) {
        Write-Warning 'DotForge: No supported package managers found (scoop, winget, choco). Install one to use Install-DFTool.'
    } else {
        Write-Host "DotForge: Environment ready. Package managers: $($pms -join ', ')" -ForegroundColor Green
    }
}
