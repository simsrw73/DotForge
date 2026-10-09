#Requires -Version 7.0

function Test-DFElevated {
    <#
    .SYNOPSIS
        Whether this shell runs elevated (as administrator).
    .OUTPUTS
        System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if (-not $IsWindows) { return (id -u 2>$null) -eq '0' }
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

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

function Read-DFInstallChoice {
    <#
    .SYNOPSIS
        Asks one install question, showing the default; Enter keeps it.
    .PARAMETER Prompt
        The question.
    .PARAMETER Options
        The allowed answers.
    .PARAMETER Default
        The answer Enter gives.
    .OUTPUTS
        System.String. One of -Options.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Prompt, [Parameter(Mandatory)][string[]]$Options, [Parameter(Mandatory)][string]$Default)
    while ($true) {
        $a = Read-Host "$Prompt [$($Options -join '/')] (Enter = $Default)"
        if (-not $a) { return $Default }
        $hit = $Options | Where-Object { $_ -eq $a.Trim() } | Select-Object -First 1
        if ($hit) { return $hit }
        Write-Host "  Choose one of: $($Options -join ', ')"
    }
}
