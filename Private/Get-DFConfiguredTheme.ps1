#Requires -Version 7.0

function script:Get-DFConfiguredTheme {
    <#
    .SYNOPSIS
        Resolves a tool's theme name from $DFConfig, honoring a per-tool key,
        then a shared 'Theme' key, then a caller default.
    .DESCRIPTION
        The fallback chain shared by every themed DotForge tool:
          1. $Global:DFConfig[$ToolKey]   (e.g. 'GlowTheme', 'MdvTheme')
          2. $Global:DFConfig['Theme']    (the cross-tool key)
          3. $Default                     (the tool's built-in default; may be $null)
        Family-name -> tool-dialect mapping (e.g. 'catppuccin' -> 'catppuccin-mocha')
        is deliberately NOT done here — it differs per tool and stays in each sidecar.
        Tests the VALUE of $DFConfig, not the variable's existence: `$DFConfig = $null`
        leaves the variable defined and indexing into it throws.
    .PARAMETER ToolKey
        The per-tool $DFConfig key to check first (e.g. 'MdcatTheme').
    .PARAMETER Default
        Value returned when neither the per-tool key nor 'Theme' is set. Defaults to $null.
    .OUTPUTS
        [string] the resolved theme name, or $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$ToolKey,
        [string]$Default
    )

    if ($null -ne $Global:DFConfig) {
        $perTool = $Global:DFConfig[$ToolKey]
        if ($perTool) { return $perTool }
        $shared = $Global:DFConfig['Theme']
        if ($shared) { return $shared }
    }
    $Default
}
