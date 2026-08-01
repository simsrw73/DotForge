#Requires -Version 7.0

function script:ConvertTo-DFPath {
    <#
    .SYNOPSIS
        Canonicalizes an absolute path: native separators, no ./.., no trailing
        separator, with a leading ~ expanded to $HOME.
    .DESCRIPTION
        The single path-normalization primitive for DotForge. Returns
        [System.IO.Path]::GetFullPath's canonical form with a root-aware
        trailing-separator strip. Null/empty pass through untouched. A relative
        path is a probable bug: it is returned unchanged with a warning, never
        silently bound to the current directory. Works on paths that do not exist
        yet (no filesystem access, except that an existing 8.3 short-name segment
        is expanded to its long form).
    .PARAMETER Path
        The path to canonicalize.
    .OUTPUTS
        [string] the canonical path, or the input unchanged for null/empty/relative.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][string]$Path)

    if ([string]::IsNullOrEmpty($Path)) { return $Path }

    # Expand a leading ~ (whole path, or immediately followed by a separator) to
    # $HOME. Never a ~ elsewhere — that would corrupt Windows 8.3 short names
    # (C:\PROGRA~1) or a literal filename.
    if ($Path -eq '~' -or $Path -match '^~[\\/]') {
        $Path = $HOME + $Path.Substring(1)
    }

    if (-not [System.IO.Path]::IsPathRooted($Path)) {
        Write-Warning "ConvertTo-DFPath: '$Path' is not an absolute path — returned unchanged."
        return $Path
    }

    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $root.Length) {
        $full = $full.TrimEnd([System.IO.Path]::DirectorySeparatorChar,
                              [System.IO.Path]::AltDirectorySeparatorChar)
    }
    $full
}
