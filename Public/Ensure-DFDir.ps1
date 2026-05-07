#Requires -Version 7.0

function Ensure-DFDir {
    <#
    .SYNOPSIS
        Creates a directory if it does not exist. Idempotent and silent.
    .PARAMETER Path
        Directory path to create. Empty or null values are silently skipped.
    #>
    [CmdletBinding()]
    param([string]$Path)

    if ($Path) {
        New-Item -ItemType Directory -Force -Path $Path -ErrorAction SilentlyContinue | Out-Null
    }
}
