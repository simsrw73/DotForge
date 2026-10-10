#Requires -Version 7.2

function New-DFDirectory {
    <#
    .SYNOPSIS
        Creates a directory if it does not exist. Idempotent.
    .DESCRIPTION
        Wraps New-Item -ItemType Directory -Force, creating any missing parent
        directories. Succeeds silently if the directory already exists; emits a
        warning if creation fails. An absolute path is canonicalized with
        ConvertTo-DFPath first; a relative path is created relative to the
        current location. Null or empty paths are skipped. All DotForge
        directory creation uses this function.
    .PARAMETER Path
        Directory path to create. Empty or null values
        are skipped.
    .EXAMPLE
        New-DFDirectory "$Env:XDG_CONFIG_HOME/mytool"

        Creates the directory (and any missing parents) or does nothing if it exists.
    .OUTPUTS
        None. Creates the directory on disk.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/pickers-and-helpers.md
    #>
    [CmdletBinding()]
    param([string]$Path)

    if ($Path) {
        # Canonicalize an absolute path (collapses .., native separators); leave a
        # relative path untouched so creating a relative dir stays valid and silent.
        if ([System.IO.Path]::IsPathRooted($Path)) { $Path = ConvertTo-DFPath $Path }
        try {
            New-Item -ItemType Directory -Force -Path $Path -ErrorAction Stop | Out-Null
            if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
                throw [System.IO.IOException]::new("Cannot create '$Path' because a file or directory with the same name already exists.")
            }
        }
        catch {
            Write-Warning "DotForge: couldn't create '$Path': $($_.Exception.Message)"
        }
    }
}
