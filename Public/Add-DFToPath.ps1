#Requires -Version 7.0

function Add-DFToPath {
    <#
    .SYNOPSIS
        Adds a directory to $Env:Path with normalization and deduplication.
    .PARAMETER Dir
        Absolute path to add. Relative paths are rejected with a warning.
    .PARAMETER Prepend
        Add to the front of PATH instead of the end.
    .DESCRIPTION
        Normalizes the path, deduplicates against all existing PATH entries, and
        appends if not already present, or prepends while moving an existing
        entry to the front. Relative paths are rejected with a warning. All
        DotForge PATH additions use this function.
    .EXAMPLE
        Add-DFToPath 'C:\tools\bin'
        Appends C:\tools\bin to the current session PATH if not already present.
    .EXAMPLE
        Add-DFToPath 'C:\tools\bin' -Prepend
        Inserts C:\tools\bin at the front of PATH so it takes priority.
    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Dir,
        [switch]$Prepend
    )

    if (-not $Dir) { return }

    if (-not [IO.Path]::IsPathRooted($Dir)) {
        Write-Warning "Add-DFToPath: '$Dir' is not an absolute path — skipped."
        return
    }

    $normalized = [IO.Path]::GetFullPath($Dir)

    $existing = ($Env:Path -split [IO.Path]::PathSeparator) |
        Where-Object { $_ -and [IO.Path]::IsPathRooted($_) } |
        ForEach-Object { try { [IO.Path]::GetFullPath($_) } catch { $_ } }

    if ($Prepend) {
        $remaining = ($Env:Path -split [IO.Path]::PathSeparator) | Where-Object {
            if (-not $_ -or -not [IO.Path]::IsPathRooted($_)) { return $true }
            try { [IO.Path]::GetFullPath($_) -ne $normalized } catch { $true }
        }
        $Env:Path = (@($normalized) + @($remaining)) -join [IO.Path]::PathSeparator
        return
    }

    if ($normalized -notin $existing) {
        $Env:Path += [IO.Path]::PathSeparator + $normalized
    }
}
