#Requires -Version 7.2

function Get-DFFingerprintCache {
    <#
    .SYNOPSIS
        Returns text cached under $XDG_CACHE_HOME\dotforge\<Name>.txt while its fingerprint still matches, otherwise regenerates it.
    .DESCRIPTION
        The one implementation of DotForge's "text plus .key fingerprint" cache,
        used for cached tool init scripts (Get-DFCachedCommandOutput), the help
        topic list and LS_COLORS. The caller decides what invalidates the
        cache by passing a fingerprint string: an executable's identity, the
        installed module set, a theme name.

        A hit needs both files and a key equal to -Fingerprint. On a miss the
        result of -Generate is joined with newlines, trimmed and returned; it
        is written only when non-empty (an empty result is never cached, so a
        transient failure retries next time). Writes go through
        Write-DFFileAtomic, content first and key second: a crash between the
        two leaves an old key, which only costs a regeneration.
    .PARAMETER Name
        Cache entry name; the files are <Name>.txt and <Name>.key. Keep
        existing names stable, since renaming one discards users' caches.
    .PARAMETER Fingerprint
        What the cached text depends on. Must be cheap to compute: callers
        build it on every call.
    .PARAMETER Generate
        Produces the text on a miss. May return a string or lines; $null or
        whitespace means "nothing to cache".
    .PARAMETER Force
        Regenerate even when the fingerprint matches.
    .OUTPUTS
        System.String. The cached or generated text, or $null when -Generate
        produced nothing.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Fingerprint,
        [Parameter(Mandatory)][scriptblock]$Generate,
        [switch]$Force
    )

    $dir       = Join-Path (Get-DFXdgPath Cache) 'dotforge'
    $cacheFile = Join-Path $dir "$Name.txt"
    $keyFile   = Join-Path $dir "$Name.key"

    if (-not $Force -and (Test-Path $cacheFile -PathType Leaf) -and (Test-Path $keyFile -PathType Leaf) -and
        (Get-Content $keyFile -Raw).Trim() -eq $Fingerprint) {
        return (Get-Content $cacheFile -Raw).Trim()
    }

    $value = (@(& $Generate) -join "`n").Trim()
    if (-not $value) { return $null }
    Write-DFFileAtomic -Path $cacheFile -Value $value
    Write-DFFileAtomic -Path $keyFile   -Value $Fingerprint
    $value
}
