#Requires -Version 7.2

function Write-DFFileAtomic {
    <#
    .SYNOPSIS
        Writes text to a file atomically: to a temp file beside it, then renamed over it.
    .DESCRIPTION
        Readers never see a half-written file, and two writers (an interactive
        session and Update-DFPackageCache, say) can't interleave: the last
        rename wins and both results are valid files. Creates the parent folder
        if needed. Used for every cache and state file DotForge writes.
    .PARAMETER Path
        The destination file.
    .PARAMETER Value
        The text to write (UTF-8).
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value
    )
    New-DFDirectory (Split-Path $Path -Parent)
    $tmp = "$Path.tmp.$PID"
    Set-Content -Path $tmp -Value $Value -Encoding UTF8
    Move-Item -Path $tmp -Destination $Path -Force
}
