#Requires -Version 7.0
# Build scripts dot-source DotForge's source files directly (private functions
# aren't exported). This lists them in load order: Shared/, the core's Private/
# and Public/, then each on-demand module's. Dot-source the result in the
# caller's scope:  foreach ($f in Get-DFSourceFile) { . $f }

function Get-DFSourceFile {
    <#
    .SYNOPSIS
        Every DotForge source file, in load order, for build scripts to dot-source.
    .PARAMETER Root
        The repository root. Default: the parent of build/.
    .OUTPUTS
        System.String[]. Absolute paths.
    #>
    param([string]$Root = (Split-Path $PSScriptRoot -Parent))
    $dirs = @('Shared', 'Private', 'Public' | ForEach-Object { Join-Path $Root $_ })
    foreach ($m in 'DotForge.Catalog', 'DotForge.Helpers') { foreach ($d in 'Private', 'Public') { $dirs += Join-Path $Root 'Modules' $m $d } }
    foreach ($d in $dirs) { (Get-ChildItem -Path $d -Filter '*.ps1').FullName }
}
