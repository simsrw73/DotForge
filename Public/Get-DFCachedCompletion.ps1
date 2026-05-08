#Requires -Version 7.0

function Get-DFCachedCompletion {
    <#
    .SYNOPSIS
        Mtime-based completion script caching.
        Only regenerates when the tool binary is newer than the cached .ps1 file.
    .PARAMETER CacheKey
        Unique key for this tool's cache file (e.g. 'rg', 'chezmoi').
    .PARAMETER ExePath
        Full path to the tool's executable. Used for mtime comparison.
    .PARAMETER Generate
        Scriptblock that produces the completion script text.
        Only called when the cache is stale or absent.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CacheKey,
        [Parameter(Mandatory)][string]$ExePath,
        [Parameter(Mandatory)][scriptblock]$Generate
    )

    if (-not $Env:XDG_CACHE_HOME) {
        Write-Warning 'DotForge: $Env:XDG_CACHE_HOME is not set. Call Initialize-DFEnvironment first.'
        return
    }

    $cacheDir  = Join-Path $Env:XDG_CACHE_HOME 'dotforge' 'completions'
    $cacheFile = Join-Path $cacheDir "$CacheKey.ps1"
    $cacheItem = Get-Item $cacheFile -ErrorAction Ignore
    $exeItem   = Get-Item $ExePath   -ErrorAction Ignore

    $upToDate = $cacheItem -and $exeItem -and
                ($cacheItem.LastWriteTime -gt $exeItem.LastWriteTime)

    if (-not $upToDate) {
        New-DFDirectory $cacheDir
        $content = & $Generate
        if ($content) {
            Set-Content -Path $cacheFile -Value $content -Encoding UTF8
        }
        $cacheItem = Get-Item $cacheFile -ErrorAction Ignore
    }

    if ($cacheItem) { . $cacheFile }
}
