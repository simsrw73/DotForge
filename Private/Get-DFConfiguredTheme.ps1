#Requires -Version 7.2

function Get-DFConfiguredTheme {
    <#
    .SYNOPSIS
        Resolves a tool's theme name from the session config, honoring a per-tool key,
        then a shared 'Theme' key, then a caller default.
    .DESCRIPTION
        The fallback chain shared by every themed DotForge tool:
          1. Get-DFConfig $ToolKey   (e.g. 'GlowTheme', 'MdvTheme')
          2. Get-DFConfig Theme      (the cross-tool key)
          3. $Default                     (the tool's built-in default; may be $null)
        Family-name -> tool-dialect mapping (e.g. 'catppuccin' -> 'catppuccin-mocha')
        is deliberately NOT done here — it differs per tool and stays in each sidecar.
    .PARAMETER ToolKey
        The per-tool config key to check first (e.g. 'MdcatTheme').
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

    $perTool = Get-DFConfig $ToolKey
    if ($perTool) { return $perTool }
    $shared = Get-DFConfig Theme
    if ($shared) { return $shared }
    $Default
}

function Resolve-DFThemeFile {
    <#
    .SYNOPSIS
        Finds a tool's theme file: an absolute path, the user's themes folder, or the bundled copy.
    .DESCRIPTION
        Looks, in order, for -Name as an existing absolute file path; then
        <XDG config>\<Tool>\themes\<Name>.json; then <BundledDir>\<Name>.json.
        Returns the first that exists, or $null. Used by the fzf, psreadline and
        glow companions, which capture it with ${function:Resolve-DFThemeFile}
        so their global functions can call it.
    .PARAMETER Tool
        The tool's folder name under XDG config (e.g. 'fzf').
    .PARAMETER Name
        A theme name or an absolute path to a theme file.
    .PARAMETER BundledDir
        The companion's bundled themes folder (e.g. Tools\fzf).
    .OUTPUTS
        System.String, or $null when nothing is found.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Tool,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$BundledDir
    )
    if ([System.IO.Path]::IsPathRooted($Name)) {
        return (Test-Path $Name -PathType Leaf) ? $Name : $null
    }
    foreach ($candidate in (Join-Path (Get-DFXdgPath Config) $Tool 'themes' "$Name.json"), (Join-Path $BundledDir "$Name.json")) {
        if (Test-Path $candidate -PathType Leaf) { return $candidate }
    }
    $null
}
