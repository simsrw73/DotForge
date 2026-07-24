#Requires -Version 7.0

function Initialize-DFEnvironment {
    <#
    .SYNOPSIS
        Bootstraps the DotForge environment: sets XDG base directory env vars
        if absent, creates the directories, and reports available package managers.
        Safe to call multiple times (idempotent).
    .DESCRIPTION
        Sets XDG_CONFIG_HOME, XDG_DATA_HOME, XDG_STATE_HOME, and XDG_CACHE_HOME
        if not already in the environment, creates all four directories, then
        detects available package managers (scoop, winget, choco). Designed to
        run once at the top of a profile before any Register-DFTool call.
    .EXAMPLE
        Initialize-DFEnvironment
        Bootstraps XDG dirs and reports which package managers are available.
    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    param()

    if (-not $Env:XDG_CONFIG_HOME) { $Env:XDG_CONFIG_HOME = Join-Path $home '.config' }
    if (-not $Env:XDG_DATA_HOME)   { $Env:XDG_DATA_HOME   = Join-Path $home '.local' 'share' }
    if (-not $Env:XDG_STATE_HOME)  { $Env:XDG_STATE_HOME  = Join-Path $home '.local' 'state' }
    if (-not $Env:XDG_CACHE_HOME)  { $Env:XDG_CACHE_HOME  = Join-Path $home '.cache' }
    # The variable is not part of the XDG spec, but the location is, so this is useful
    if (-not $Env:XDG_BIN_HOME)  { $Env:XDG_BIN_HOME  = Join-Path $home '.local' 'bin' }

    # Canonicalize each root (expands a user-supplied ~, collapses .., native seps)
    # so every downstream Expand-DFXdgPath substitution starts from a clean path.
    foreach ($_var in 'XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_STATE_HOME', 'XDG_CACHE_HOME', 'XDG_BIN_HOME') {
        $_val = [System.Environment]::GetEnvironmentVariable($_var)
        if ($_val) { Set-Item -Path "Env:$_var" -Value (ConvertTo-DFPath $_val) }
    }

    @($Env:XDG_CONFIG_HOME, $Env:XDG_DATA_HOME, $Env:XDG_STATE_HOME, $Env:XDG_CACHE_HOME, $Env:XDG_BIN_HOME) |
        ForEach-Object { New-DFDirectory $_ }

    $pms = @(Resolve-DFPackageManager -Force | Where-Object { $_ })

    if ($pms.Count -eq 0) {
        Write-Warning 'DotForge: No supported package managers found (scoop, winget, choco). Install one to use Install-DFTool.'
    } else {
        Write-Host "DotForge: Environment ready. Package managers: $($pms -join ', ')" -ForegroundColor Green
    }
}
