#Requires -Version 7.0

function Get-DFCachedCommandOutput {
    <#
    .SYNOPSIS
        Returns the cached stdout of a deterministic external command,
        regenerating only when the resolved executable itself has changed.
    .DESCRIPTION
        For companions like carapace/zoxide/mdcat/scoop-search whose init
        output is a pure function of the tool's own build -- verified
        byte-identical across repeated runs (see
        docs/superpowers/specs/2026-09-05-startup-perf-audit.md) -- with no
        session input to fingerprint on (unlike vivid's theme name, see
        Tools/vivid.ps1). The fingerprint is the resolved executable's path
        plus its LastWriteTimeUtc: a file stat, not a process spawn, so the
        cache-hit path never pays for a version check. A tool upgrade
        (which rewrites the file) or a switch to a differently-located
        binary both correctly invalidate the cache.

        Falls back to always calling -Generate, uncached, when
        $Env:XDG_CACHE_HOME is unset, -Executable does not resolve, or it
        resolves to something with no backing file (a function or alias
        stand-in, e.g. how tests/scoop.Tests.ps1 stubs scoop-search --
        Get-Command's .Source on a function is not a usable file path) --
        these companions register real functionality (completions, cd
        hooks), so degrading to "slower but correct" beats "skip it
        entirely" the way Tools/vivid.ps1's cosmetic LS_COLORS cache does.

        Never caches a falsy result (empty string or $null) -- a transient
        failure is retried next session rather than remembered.
    .PARAMETER Name
        Cache key, distinct per companion (e.g. 'carapace-init'). Backs the
        files $XDG_CACHE_HOME/dotforge/<Name>.txt and <Name>.key.
    .PARAMETER Executable
        The command name to resolve and fingerprint (e.g. 'carapace').
    .PARAMETER Generate
        Scriptblock producing the real output on a cache miss.
    .PARAMETER Force
        Bypass the cache and regenerate unconditionally.
    .EXAMPLE
        Get-DFCachedCommandOutput -Name 'carapace-init' -Executable 'carapace' -Generate {
            carapace _carapace powershell | Out-String
        }
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][scriptblock]$Generate,
        [switch]$Force
    )

    $cmd = Get-Command $Executable -ErrorAction Ignore
    if (-not $Env:XDG_CACHE_HOME -or -not $cmd -or -not $cmd.Source -or -not (Test-Path $cmd.Source -PathType Leaf)) {
        return & $Generate
    }

    $cacheDir  = Join-Path $Env:XDG_CACHE_HOME 'dotforge'
    $cacheFile = Join-Path $cacheDir "$Name.txt"
    $keyFile   = Join-Path $cacheDir "$Name.key"
    $fingerprint = "$($cmd.Source)|$((Get-Item $cmd.Source).LastWriteTimeUtc.Ticks)"

    $cacheValid = -not $Force -and (Test-Path $cacheFile -PathType Leaf) -and (Test-Path $keyFile -PathType Leaf) -and
                  ((Get-Content $keyFile -Raw).Trim() -eq $fingerprint)

    if ($cacheValid) {
        return (Get-Content $cacheFile -Raw).Trim()
    }

    $value = (& $Generate)
    if ($value) { $value = $value.Trim() }
    if ($value) {
        New-DFDirectory $cacheDir
        Set-Content -Path $keyFile   -Value $fingerprint -Encoding UTF8
        Set-Content -Path $cacheFile -Value $value        -Encoding UTF8
    }
    return $value
}
