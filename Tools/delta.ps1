# Companion for delta — set DELTA_FEATURES from the configured theme so it tracks
# $DFConfig.Theme. delta features are user-defined config names, so there is no
# built-in list to validate against; an unknown feature is silently ignored by
# delta. Rendering catppuccin requires a delta config defining that feature —
# out of DotForge's scope. See docs/external-dependencies.md.

$_theme  = Get-DFConfiguredTheme -ToolKey 'DeltaTheme' -Default 'catppuccin-mocha'
$_native = Resolve-DFThemeName -Name $_theme -ThemeMap ($DFCurrentTool.PSObject.Properties['themeMap']?.Value)
[System.Environment]::SetEnvironmentVariable('DELTA_FEATURES', $_native, 'Process')
