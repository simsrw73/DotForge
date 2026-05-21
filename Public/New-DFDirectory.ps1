#Requires -Version 7.0

function New-DFDirectory {
    <#
    .SYNOPSIS
        Creates a directory if it does not exist. Idempotent and silent.
    .PARAMETER Path
        Directory path to create. Empty or null values are silently skipped.
    .DESCRIPTION
        Wraps New-Item -ItemType Directory -Force. Silently succeeds if the
        directory already exists. Null or empty paths are silently skipped.
        All DotForge directory creation uses this function.
    .EXAMPLE
        New-DFDirectory "$Env:XDG_CONFIG_HOME/mytool"
        Creates the directory (and any missing parents) or does nothing if it exists.
    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    param([string]$Path)

    if ($Path) {
        New-Item -ItemType Directory -Force -Path $Path -ErrorAction SilentlyContinue | Out-Null
    }
}
