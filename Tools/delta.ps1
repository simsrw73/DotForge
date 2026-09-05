# Companion for delta — set DELTA_FEATURES from the configured theme so it tracks
# $DFConfig.Theme, and deploy the bundled catppuccin/delta theme file so that
# feature name resolves to a real [delta "..."] block instead of a dead pointer.
# delta features are user-defined config names, so there is no built-in list to
# validate against; an unknown feature is silently ignored by delta. See
# docs/superpowers/specs/2026-09-04-delta-catppuccin-design.md and
# docs/external-dependencies.md.

$_theme  = Get-DFConfiguredTheme -ToolKey 'DeltaTheme' -Default 'catppuccin-mocha'
$_native = Resolve-DFThemeName -Name $_theme -ThemeMap ($DFCurrentTool.PSObject.Properties['themeMap']?.Value)
# Leading '+' makes this additive: DELTA_FEATURES without it *replaces* the
# user's entire git-config `features` list rather than layering on top of it
# (verified directly — see the design spec's Section 0).
[System.Environment]::SetEnvironmentVariable('DELTA_FEATURES', "+$_native", 'Process')

# Deploy the bundled catppuccin/delta theme file (all four flavours) so
# DELTA_FEATURES resolves to something real. Always-refresh, not seed-once —
# this is pure DotForge-shipped content with no user-customization
# expectation, matching Tools/carapace.ps1's bundled-specs pattern: skip the
# write only when the deployed copy is already byte-identical.
$_bundledTheme = Join-Path $PSScriptRoot 'delta' 'catppuccin.gitconfig'
if (Test-Path $_bundledTheme -PathType Leaf) {
    $_themeDir = Expand-DFXdgPath '${XDG_CONFIG_HOME}/delta'
    New-DFDirectory $_themeDir | Out-Null
    $_dest = Join-Path $_themeDir 'catppuccin.gitconfig'
    $_new  = Get-Content $_bundledTheme -Raw
    if (-not (Test-Path $_dest) -or (Get-Content $_dest -Raw) -ne $_new) {
        Set-Content -Path $_dest -Value $_new -Encoding UTF8
    }
}
