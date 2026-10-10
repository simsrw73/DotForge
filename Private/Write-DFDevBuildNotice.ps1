#Requires -Version 7.2

function Write-DFDevBuildNotice {
    <#
    .SYNOPSIS
        Says, when a session starts, that this DotForge is a private developer build.
    .DESCRIPTION
        Dev builds come from build/Publish-DFLocal.ps1 (version <next patch>-dev<timestamp>,
        installed from a local gallery). One line at session start keeps you from
        forgetting you are running one. Gallery releases (stable or 'preview') and
        DotForge run from source files (no module, as in tests) say nothing.
    .PARAMETER Version
        The module version. Default: the loaded DotForge module's.
    .PARAMETER Prerelease
        The prerelease label. Default: the loaded DotForge module's.
    .PARAMETER Location
        Where the module is installed. Default: the loaded DotForge module's folder.
    .OUTPUTS
        None. Writes one line to the host.
    #>
    [CmdletBinding()]
    param(
        [string]$Version = $ExecutionContext.SessionState.Module.Version,
        [string]$Prerelease = $ExecutionContext.SessionState.Module.PrivateData.PSData.Prerelease,
        [string]$Location = $ExecutionContext.SessionState.Module.ModuleBase
    )
    if ($Prerelease -notlike 'dev*') { return }
    Write-Host "DotForge $Version-$Prerelease`: developer build, not a Gallery release ($Location)" -ForegroundColor DarkYellow
}
