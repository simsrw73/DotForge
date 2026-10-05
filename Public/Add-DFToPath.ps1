#Requires -Version 7.0

function Add-DFToPath {
    <#
    .SYNOPSIS
        Adds a directory to $Env:Path with normalization and deduplication.
    .DESCRIPTION
        Normalizes the path with ConvertTo-DFPath (native separators, no '.'/'..',
        no trailing separator), deduplicates it against every existing PATH entry
        (compared in the same normalized form), and appends it when not already
        present. With -Prepend it is placed first, and any existing copy further
        down is removed so the directory appears exactly once.

        Only the current session's $Env:Path changes; nothing is written to the
        user or machine PATH in the registry. To keep the change, call this from
        your profile. The directory does not need to exist.

        Relative paths, including '~\...', are rejected with a warning rather than
        resolved against the current directory: pass "$HOME\..." instead. An empty
        value is silently ignored. All DotForge PATH additions use this function.
    .PARAMETER Dir
        Absolute path of the directory to add. Empty or null does nothing; a
        relative path writes a warning and does nothing.
    .PARAMETER Prepend
        Put the directory at the front of PATH, so its executables win over
        same-named ones later in PATH. Default: append to the end.
    .EXAMPLE
        Add-DFToPath 'C:\tools\bin'

        Appends C:\tools\bin to the current session PATH if not already present.
    .EXAMPLE
        Add-DFToPath 'C:\tools\bin' -Prepend

        Inserts C:\tools\bin at the front of PATH so it takes priority.
    .OUTPUTS
        None. Changes $Env:Path for the current session.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/pickers-and-helpers.md
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

    $normalized = ConvertTo-DFPath $Dir

    $existing = ($Env:Path -split [IO.Path]::PathSeparator) |
        Where-Object { $_ -and [IO.Path]::IsPathRooted($_) } |
        ForEach-Object { try { ConvertTo-DFPath $_ } catch { $_ } }

    if ($Prepend) {
        $remaining = ($Env:Path -split [IO.Path]::PathSeparator) | Where-Object {
            if (-not $_ -or -not [IO.Path]::IsPathRooted($_)) { return $true }
            try { (ConvertTo-DFPath $_) -ne $normalized } catch { $true }
        }
        $Env:Path = (@($normalized) + @($remaining)) -join [IO.Path]::PathSeparator
        return
    }

    if ($normalized -notin $existing) {
        $Env:Path += [IO.Path]::PathSeparator + $normalized
    }
}
