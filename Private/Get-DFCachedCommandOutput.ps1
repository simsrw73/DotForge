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
        -Executable does not resolve, or it
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
    .PARAMETER ExtraKey
        Optional text folded into the fingerprint, for output that also depends
        on something besides the executable (carapace's init also depends on the
        spec files in its specs folder). When it changes, the cache regenerates.
        Keep it cheap to compute: it runs on every call.
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
        [string]$ExtraKey,
        [switch]$Force
    )

    $cmd = Get-Command $Executable -ErrorAction Ignore
    if (-not $cmd -or -not $cmd.Source -or -not (Test-Path $cmd.Source -PathType Leaf)) {
        return & $Generate
    }

    $cacheDir  = Join-Path (Get-DFXdgPath Cache) 'dotforge'
    $cacheFile = Join-Path $cacheDir "$Name.txt"
    $keyFile   = Join-Path $cacheDir "$Name.key"
    $target = Resolve-DFExecutableTarget -Path $cmd.Source
    $fingerprint = "$target|$((Get-Item $target).LastWriteTimeUtc.Ticks)"
    if ($ExtraKey) { $fingerprint += "|$ExtraKey" }

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

function Resolve-DFExecutableTarget {
    <#
    .SYNOPSIS
        Resolves a launcher (scoop shim or filesystem link) to the real
        executable it starts, so its file identity tracks tool upgrades.
    .DESCRIPTION
        A scoop shim (`shims\<name>.exe`) is a generic launcher that scoop
        never rewrites on upgrade -- the tool's identity lives in the sibling
        `<name>.shim` file's `path = "..."` line. Fingerprinting the shim
        itself would leave Get-DFCachedCommandOutput's cache stale across
        upgrades. Symlinks (e.g. winget's Links directory) are followed to
        their final target. Any failure -- unreadable or malformed shim,
        missing target -- degrades silently to the input path. Catalogued in
        docs/external-dependencies.md.
    .PARAMETER Path
        Absolute path of the resolved command (Get-Command's .Source).
    .EXAMPLE
        Resolve-DFExecutableTarget -Path (Get-Command carapace).Source
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)

    try {
        $shim = [IO.Path]::ChangeExtension($Path, '.shim')
        if (Test-Path -LiteralPath $shim -PathType Leaf) {
            foreach ($line in Get-Content -LiteralPath $shim) {
                if ($line -match '^\s*path\s*=\s*"?(.+?)"?\s*$') {
                    $target = ConvertTo-DFPath $Matches[1]
                    if (Test-Path -LiteralPath $target -PathType Leaf) { return $target }
                    break
                }
            }
            return $Path
        }
        $link = [IO.File]::ResolveLinkTarget($Path, $true)
        if ($link -and $link.Exists) { return $link.FullName }
    } catch {
        Write-Verbose "Resolve-DFExecutableTarget: falling back to '$Path': $_"
    }
    $Path
}
