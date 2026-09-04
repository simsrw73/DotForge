# Companion for bat — override BAT_THEME only when $DFConfig specifies a
# theme different from the JSON default. bat validates BAT_THEME itself
# (an unrecognized name warns to stderr and falls back to its own default,
# exit 0 — verified against bat 0.26.1), so no DotForge-side whitelist is
# needed here, unlike mdcat.

$_name = Get-DFConfiguredTheme -ToolKey 'BatTheme'
if ($_name) {
    $_name = Resolve-DFThemeName -Name $_name -ThemeMap ($DFCurrentTool.PSObject.Properties['themeMap']?.Value)
    [System.Environment]::SetEnvironmentVariable('BAT_THEME', $_name, 'Process')
}
