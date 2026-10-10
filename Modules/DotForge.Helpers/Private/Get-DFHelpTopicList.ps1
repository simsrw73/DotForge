#Requires -Version 7.2

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

    $fingerprint = Get-Module -ListAvailable |
                   Sort-Object Name, Version |
                   ForEach-Object { "$($_.Name):$($_.Version)" } |
                   Join-String -Separator ','

    $text = Get-DFFingerprintCache -Name 'help-topics' -Fingerprint $fingerprint -Force:$Force -Generate {
        Get-Help * -ErrorAction SilentlyContinue |
            Where-Object { $_.Name } |
            Sort-Object Name |
            ForEach-Object { "$($_.Name)`t$($_.Category)" }
    }
    if ($text) { $text -split "`r?`n" }
}
