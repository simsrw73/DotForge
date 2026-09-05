#Requires -Version 7.0

function Resolve-DFThemeName {
    <#
    .SYNOPSIS
        Translates a canonical theme family name to a tool's native dialect
        using that tool's own themeMap. A pure, file-free translator.
    .DESCRIPTION
        If $ThemeMap contains a key equal to $Name (case-insensitive), returns
        the mapped dialect. Otherwise returns $Name unchanged — so a per-tool
        override that is the tool's own native name, or any non-canonical value,
        passes through to the sidecar's own built-in validation. A $null or
        empty map always passes through. The resolver never validates or falls
        back; that stays in the sidecars.
    .PARAMETER Name
        The configured theme name (from Get-DFConfiguredTheme's chain).
    .PARAMETER ThemeMap
        The target tool's themeMap object (canonical -> dialect), typically
        $DFCurrentTool.themeMap. May be $null.
    .OUTPUTS
        [string] the tool's dialect, or $Name unchanged.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Name,
        [pscustomobject]$ThemeMap
    )

    if ($null -ne $ThemeMap) {
        $prop = $ThemeMap.PSObject.Properties | Where-Object { $_.Name -ieq $Name } | Select-Object -First 1
        if ($prop) { return [string]$prop.Value }
    }
    $Name
}
