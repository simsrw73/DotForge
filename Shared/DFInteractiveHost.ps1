#Requires -Version 7.2

# Shared: Install-DFTool, the banner and Install-DFNerdFont (DotForge.Helpers) all ask it.

function Test-DFInteractiveHost {
    <#
    .SYNOPSIS
        Whether there is a person to ask: an interactive console host whose input isn't redirected, not started with -NonInteractive.
    .DESCRIPTION
        A scheduled task or CI step started as `pwsh -NonInteractive -File x.ps1`
        has a real console, but Read-Host throws there, so the command line is
        checked too (-NonInteractive, or any prefix of it such as -noni).
    .PARAMETER CommandLine
        The process's arguments. Default: [Environment]::GetCommandLineArgs().
    .OUTPUTS
        System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string[]]$CommandLine = [Environment]::GetCommandLineArgs())
    $nonInteractive = @($CommandLine | Where-Object { $_ -match '^[-/]noni' -and 'nonInteractive'.StartsWith($_.Substring(1), [StringComparison]::OrdinalIgnoreCase) })
    if ($nonInteractive) { return $false }
    [Environment]::UserInteractive -and $Host.Name -eq 'ConsoleHost' -and -not [Console]::IsInputRedirected
}
