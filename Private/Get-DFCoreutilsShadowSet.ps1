#Requires -Version 7.0

function Get-DFCoreutilsShadowSet {
    <#
    .SYNOPSIS
        Returns the command names the coreutils readline hook rewrites in this host,
        or an empty array when no hook applies here.
    .PARAMETER ProfilePath
        Profile files to scan for a not-yet-loaded hook. Defaults to the two the
        coreutils installer targets. Tests pass an explicit path.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([string[]]$ProfilePath)

    # Coreutils for Windows injects a PSConsoleHostReadLine override into a profile.
    # That hook rewrites matching command names to '<name>.cmd' BEFORE PowerShell
    # resolves them, so no alias, function, or -Force can win — the name is gone before
    # resolution starts. It also means Get-Command still reports DotForge's version, so
    # the conflict is invisible to normal probing.

    # 1. Authoritative: the hook has already run, so read the exact set it consults.
    #    O(1), in-memory, and true only where the hook actually loaded.
    $var = Get-Variable -Name '__COREUTILS__' -Scope Global -ErrorAction Ignore
    if ($var -and $var.Value) { return [string[]]@($var.Value) }

    # 2. The hook has not run YET. This is the normal case, not an edge case: profiles
    #    load CurrentUserAllHosts (where Register-DFTool -All typically lives) BEFORE
    #    CurrentUserCurrentHost (where the installer writes the hook). Relying on the
    #    variable alone makes this check dead code in a real profile.
    #
    #    Scanning $PROFILE.*CurrentHost keeps the host-accuracy that made the variable
    #    attractive: those paths are per-host, so a host the installer never touched
    #    (VS Code reads Microsoft.VSCode_profile.ps1) finds no marker and correctly
    #    reports no conflict. Reading the registry or shelling out to
    #    'coreutils-manager status' (~22ms) would report machine state instead and
    #    raise false conflicts in such hosts.
    if (-not $PSBoundParameters.ContainsKey('ProfilePath')) {
        $ProfilePath = @($PROFILE.CurrentUserCurrentHost, $PROFILE.AllUsersCurrentHost)
    }

    # Section marker written by the installer around its injected block.
    $marker = '60b36fc6-2d59-49df-be51-28dd2f4c3c9a'

    foreach ($path in @($ProfilePath | Where-Object { $_ })) {
        if (-not (Test-Path $path -PathType Leaf)) { continue }
        $text = Get-Content $path -Raw -ErrorAction Ignore
        if (-not $text -or $text -notmatch $marker) { continue }

        # Parse the enabled list out of the injected block. Do NOT match against the
        # hook function's own definition instead: the command array lives at profile
        # top level, outside PSConsoleHostReadLine, and the function body only holds
        # the 'ls'/'la' literals of its switch statement — matching there reports the
        # exact inverse of the truth.
        $m = [regex]::Match($text, "(?s)__COREUTILS__\s*=.*?@\((.*?)\)")
        if (-not $m.Success) { continue }

        $names = $m.Groups[1].Value -split ',' |
            ForEach-Object { $_.Trim().Trim("'", '"') } |
            Where-Object { $_ }
        if ($names) { return [string[]]@($names) }
    }

    # Nothing here recognises coreutils, or its generated shape changed. Either way the
    # conflict check silently disables itself — deliberate: this is a diagnostic, never
    # a correctness dependency.
    return @()
}
