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

function Test-DFColorOutput {
    <#
    .SYNOPSIS
        Decides whether a display command should emit ANSI color.
    .DESCRIPTION
        Color is used only when $Env:NO_COLOR is unset, the host supports
        virtual-terminal sequences, and (when -Invocation is given) the
        caller's output isn't being piped or redirected. The one place every
        colorizing command makes this decision.
    .PARAMETER Invocation
        The caller's $MyInvocation, to also turn color off when output is piped.
    .OUTPUTS
        System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([System.Management.Automation.InvocationInfo]$Invocation)
    if ($Env:NO_COLOR -or -not $Host.UI.SupportsVirtualTerminal) { return $false }
    -not ($Invocation -and (Test-DFOutputPiped -Invocation $Invocation))
}

function Get-DFAnsiPalette {
    <#
    .SYNOPSIS
        Returns DotForge's ANSI styles, or empty strings for every style when color is off.
    .DESCRIPTION
        Formatters interpolate these unconditionally, so plain output needs no
        separate code path. Title is bold cyan, Accent bold yellow, Faint dim
        (it adapts to the terminal's theme), Green green, Reset resets.
    .PARAMETER Color
        Whether to return real escape sequences (usually Test-DFColorOutput).
    .OUTPUTS
        System.Collections.Hashtable.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][bool]$Color)
    if (-not $Color) { return @{ Title = ''; Accent = ''; Faint = ''; Green = ''; Reset = '' } }
    @{ Title = "`e[1;36m"; Accent = "`e[1;33m"; Faint = "`e[2m"; Green = "`e[32m"; Reset = "`e[0m" }
}
