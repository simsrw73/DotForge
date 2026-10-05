#Requires -Version 7.0

function Initialize-DFEnvironment {
    <#
    .SYNOPSIS
        Sets the XDG base-directory variables, creates the directories, and reports the available package managers.
    .DESCRIPTION
        Sets each of these session environment variables only when it is not
        already set, so values from your profile or system always win:

            XDG_CONFIG_HOME   $HOME\.config
            XDG_DATA_HOME     $HOME\.local\share
            XDG_STATE_HOME    $HOME\.local\state
            XDG_CACHE_HOME    $HOME\.cache
            XDG_BIN_HOME      $HOME\.local\bin   (not in the XDG spec; the location is)

        Every value, including one you set yourself, is then canonicalized with
        ConvertTo-DFPath (a leading ~ is expanded, '..' collapsed, native
        separators), and the five directories are created if missing.

        Finally it re-detects which package managers are on PATH (scoop, winget,
        choco) and writes one line to the host: a green "Environment ready" line
        listing them, or a warning when none is found. Install-DFTool needs at
        least one.

        DotForge's own commands use the same defaults whether or not this has
        run (see Get-DFXdgPath); run it so the variables are also exported to
        the tools you start, which read them themselves. Designed to run once
        near the top of a profile. Safe to call again (idempotent). Variables
        are set for the current process only; nothing is written to the
        registry.
    .EXAMPLE
        Initialize-DFEnvironment

        Bootstraps the XDG directories and prints, for example:
        DotForge: Environment ready. Package managers: scoop, winget
    .EXAMPLE
        $Env:XDG_CONFIG_HOME = 'D:\dotfiles\config'
        Initialize-DFEnvironment

        Keeps your own config root and fills in defaults for the other four.
    .OUTPUTS
        None. Sets session environment variables, creates directories, and
        writes a status line to the host.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/getting-started.md
    #>
    [CmdletBinding()]
    param()

    # Export each folder (a value you set is kept, canonicalized; an unset one
    # gets its XDG default from Get-DFXdgPath) so other programs see it too.
    foreach ($kind in 'Config', 'Data', 'State', 'Cache', 'Bin') {
        $path = Get-DFXdgPath $kind
        Set-Item -Path "Env:XDG_$($kind.ToUpperInvariant())_HOME" -Value $path
        New-DFDirectory $path
    }

    $pms = @(Resolve-DFPackageManager -Force | Where-Object { $_ })

    if ($pms.Count -eq 0) {
        Write-Warning 'DotForge: No supported package managers found (scoop, winget, choco). Install one to use Install-DFTool.'
    } else {
        Write-Host "DotForge: Environment ready. Package managers: $($pms -join ', ')" -ForegroundColor Green
    }
}
