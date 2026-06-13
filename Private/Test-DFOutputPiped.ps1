#Requires -Version 7.0

function Test-DFOutputPiped {
    <#
    .SYNOPSIS
        Reports whether a function's output is being piped or redirected rather than
        going straight to an interactive terminal.
    .DESCRIPTION
        Returns $true when either of the following holds for the supplied caller
        invocation:
          * the caller is not the last element of its pipeline
            (PipelinePosition -lt PipelineLength) — e.g. `Get-DFEnv | Where-Object`; or
          * the process's stdout is redirected ([Console]::IsOutputRedirected) —
            e.g. `Get-DFEnv > out.txt` or piping to an external program.

        Display helpers use this to suppress ANSI color when their output is being
        consumed by another command, so downstream string matching and captured
        files stay free of escape sequences. It exists as a private wrapper so tests
        can mock the decision without manipulating the real pipeline or stdout.
    .PARAMETER Invocation
        The caller's $MyInvocation. The pipeline position/length are read from this
        object, so it must be the caller's own invocation, not this function's.
    .EXAMPLE
        if (-not (Test-DFOutputPiped -Invocation $MyInvocation)) { <emit color> }
        Colorizes only when output is bound for an interactive terminal.
    .OUTPUTS
        System.Boolean — $true when output is piped or redirected.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.InvocationInfo]$Invocation
    )
    ($Invocation.PipelinePosition -lt $Invocation.PipelineLength) -or
        [Console]::IsOutputRedirected
}
