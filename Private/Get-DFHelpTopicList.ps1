#Requires -Version 7.0

function Get-DFHelpTopicList {
    <#
    .SYNOPSIS
        Returns all available PS help topics as Name<TAB>Category lines.
        Caches to XDG_CACHE_HOME/dotforge and invalidates when the installed module set changes.
    .PARAMETER Force
        Bypass the cache and regenerate from Get-Help *.
    #>
    [CmdletBinding()]
    param(
        [switch]$Force
    )

    if (-not $Env:XDG_CACHE_HOME) {
        Write-Warning 'DotForge: $Env:XDG_CACHE_HOME is not set. Call Initialize-DFEnvironment first.'
        return
    }

    $cacheDir    = Join-Path $Env:XDG_CACHE_HOME 'dotforge'
    $cacheFile   = Join-Path $cacheDir 'help-topics.txt'
    $keyFile     = Join-Path $cacheDir 'help-topics.key'

    $fingerprint = Get-Module -ListAvailable |
                   Sort-Object Name, Version |
                   ForEach-Object { "$($_.Name):$($_.Version)" } |
                   Join-String -Separator ','

    $cacheValid  = -not $Force -and
                   (Test-Path $cacheFile) -and
                   (Test-Path $keyFile)   -and
                   ((Get-Content $keyFile -Raw).Trim() -eq $fingerprint)

    if ($cacheValid) {
        return Get-Content $cacheFile
    }

    $topics = Get-Help * -ErrorAction SilentlyContinue |
              Where-Object { $_.Name } |
              Sort-Object Name |
              ForEach-Object { "$($_.Name)`t$($_.Category)" }

    New-DFDirectory $cacheDir
    Set-Content -Path $keyFile   -Value $fingerprint -Encoding UTF8
    Set-Content -Path $cacheFile -Value $topics      -Encoding UTF8

    $topics
}
