#Requires -Version 7.2
# Where the package-universe pipeline keeps its working data: outside every checkout,
# in DotForge's XDG cache folder. A winget-pkgs clone inside the repo made recursive
# tools (Get-ChildItem -Recurse, grep -r, Publish-PSResource) and agents wander into
# hundreds of thousands of files.

. (Join-Path $PSScriptRoot '..' '..' 'Shared' 'ConvertTo-DFPath.ps1')

function Get-DFPackageUniverseRoot {
    <#
    .SYNOPSIS
        The package-universe working folder: $XDG_CACHE_HOME/dotforge/package-universe.
    .DESCRIPTION
        Holds universe.db, the run logs and the winget-pkgs clone. Not created here;
        the build scripts create what they write.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    Join-Path (Get-DFXdgPath Cache) 'dotforge' 'package-universe'
}
