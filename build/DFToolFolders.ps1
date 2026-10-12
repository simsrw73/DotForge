#Requires -Version 7.2
# Folders a real tool creates in the user's own folders: one named after a DotForge
# tool in %APPDATA% / %LOCALAPPDATA%, or in the home folder with or without a dot.
# Some tools (glow) find these through a Windows API that ignores environment
# variables, so running the real tool writes there however XDG is redirected.
# Used by build/Test-DFFull.ps1 (fails on new ones) and build/Test-DFToolConformance.ps1
# (removes the ones its probes created).

function Get-DFUserToolFolder {
    <#
    .SYNOPSIS
        The folders named after a DotForge tool in %APPDATA%, %LOCALAPPDATA% and the home folder.
    .PARAMETER ToolsPath
        The Tools folder whose *.json names count.
    .OUTPUTS
        System.String[]: full paths.
    #>
    param([Parameter(Mandatory)][string]$ToolsPath)
    $names = @(Get-ChildItem $ToolsPath -Filter '*.json' | ForEach-Object BaseName)
    $found = foreach ($root in @($env:APPDATA, $env:LOCALAPPDATA) | Where-Object { $_ -and (Test-Path $_) }) {
        Get-ChildItem $root -Directory -Force -ErrorAction Ignore | Where-Object Name -in $names | ForEach-Object FullName
    }
    $found += Get-ChildItem $HOME -Directory -Force -ErrorAction Ignore |
        Where-Object { $_.Name.TrimStart('.') -in $names } | ForEach-Object FullName
    @($found)
}
