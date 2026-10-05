#Requires -Version 7.0

function Get-DFConfiguredTheme {
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

    $perTool = Get-DFConfig $ToolKey
    if ($perTool) { return $perTool }
    $shared = Get-DFConfig Theme
    if ($shared) { return $shared }
    $Default
}

function Get-DFConfig {
    <#
    .SYNOPSIS
        Reads one $DFConfig setting, or returns -Default when it isn't set.
    .DESCRIPTION
        The single null-safe read of the user's $Global:DFConfig hashtable.
        $DFConfig may be missing, $null, or lack the key; all three return
        -Default. A configured $false is returned as is. Like any PowerShell
        command, an array value is written to the pipeline element by element,
        so read list settings with @(Get-DFConfig SkipTools).
    .PARAMETER Key
        The setting name, e.g. 'SkipTools'.
    .PARAMETER Default
        Returned when the setting isn't configured. Default: $null.
    .OUTPUTS
        System.Object.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Key,
        [Parameter(Position = 1)]$Default = $null
    )
    $config = Get-Variable -Name DFConfig -Scope Global -ValueOnly -ErrorAction Ignore
    if ($config -is [System.Collections.IDictionary] -and $config.Contains($Key) -and $null -ne $config[$Key]) {
        return $config[$Key]
    }
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
