#Requires -Version 7.0

function Resolve-DFCliHelpFlag {
    <#
    .SYNOPSIS
        Detects the help flag for an external command and caches the result.
    .DESCRIPTION
        Returns a cached flag from $XDG_CACHE_HOME/dotforge/cli-help-flags.json when present
        (unless -Force). Otherwise tries --help, -help, -?, help, -h (in that order; -h last
        because it collides with real flags) and accepts the first candidate whose output
        looks like help and is not an unknown-option error, caching the winner. Returns the
        best-output candidate uncached when none validate cleanly, or $null when every
        candidate produced no output.
    .PARAMETER Name
        The command name to resolve a help flag for.
    .PARAMETER Force
        Ignore (and overwrite) any cached flag and re-detect.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Name,

        [switch]$Force
    )

    $cacheDir  = if ($Env:XDG_CACHE_HOME) { Join-Path $Env:XDG_CACHE_HOME 'dotforge' } else { $null }
    $cacheFile = if ($cacheDir) { Join-Path $cacheDir 'cli-help-flags.json' } else { $null }

    $cache = @{}
    if ($cacheFile -and (Test-Path $cacheFile)) {
        try {
            $loaded = Get-Content $cacheFile -Raw | ConvertFrom-Json -AsHashtable
            if ($loaded) { $cache = $loaded }
        } catch { $cache = @{} }
    }
    if (-not $Force -and $cache.ContainsKey($Name)) {
        return $cache[$Name]
    }

    $candidates = '--help', '-help', '-?', 'help', '-h'
    $best = $null
    $bestLines = -1

    foreach ($flag in $candidates) {
        $text = (Invoke-DFCommandCapture -Name $Name -Arguments @($flag)).Text
        if ([string]::IsNullOrWhiteSpace($text)) { continue }

        $isError = ($text -match '(?i)(unknown|unrecognized|invalid|unexpected)\b.{0,30}\b(option|flag|argument|switch|command)') -or
                   ($text -match '(?im)^error\b')
        $lineCount = ($text -split "`r?`n").Where({ $_.Trim() }).Count
        $looksHelp = ($lineCount -ge 3) -or
                     ($text -match '(?im)^\s*(usage|options|commands|flags|synopsis)\b')

        if ($looksHelp -and -not $isError) {
            if ($cacheFile) {
                New-DFDirectory $cacheDir
                $cache[$Name] = $flag
                $cache | ConvertTo-Json | Set-Content -Path $cacheFile -Encoding UTF8
            }
            return $flag
        }

        if ($lineCount -gt $bestLines) { $bestLines = $lineCount; $best = $flag }
    }

    return $best
}
