# Companion for delta — deploys the bundled catppuccin/delta theme file so the
# feature named by DELTA_FEATURES (set from the theme block in Tools/delta.json)
# resolves to a real [delta "..."] block instead of a dead pointer.
# delta features are user-defined config names, so there is no built-in list to
# validate against; an unknown feature is silently ignored by delta. See
# docs/superpowers/specs/2026-09-04-delta-catppuccin-design.md and
# docs/external-dependencies.md.
#
# Writes: $XDG_CONFIG_HOME\delta\catppuccin.gitconfig
# (rewritten whenever the bundled copy changes, so don't edit it in place). The
# git-config include that activates it is added once by delta.setup.ps1.

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
        Set-Content -Path $_dest -Value $_new -Encoding UTF8 -NoNewline   # byte-identical, so the compare above matches next time
    }
}
