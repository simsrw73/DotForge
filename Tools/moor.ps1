# Companion for moor — sets its options from DotForge's theme when you haven't.
#
# MOOR holds moor's default command-line options. Only set when empty, so a MOOR
# you set yourself always wins. moor's -style names include the canonical
# catppuccin-mocha, so no themeMap is needed; moor falls back to its default
# for a style it doesn't know.
param()

if (-not $Env:MOOR) {
    $_style = Resolve-DFThemeName -Name (Get-DFConfiguredTheme -ToolKey 'MoorTheme' -Default 'catppuccin-mocha') -ThemeMap $DFCurrentTool.themeMap
    $Env:MOOR = "-style $_style -quit-if-one-screen"
    Remove-Variable _style
}
