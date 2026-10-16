# Companion for eza — keeps a theme you set up yourself.
#
# Tools/eza.json's theme block points EZA_CONFIG_DIR at a bundled theme folder
# (Tools/eza/<theme>/theme.yml, catppuccin's eza themes) so dates, sizes and
# permissions match the session theme; file names keep vivid's LS_COLORS, which
# eza applies over the theme. On Windows eza reads %APPDATA%\eza\theme.yml when
# EZA_CONFIG_DIR is unset, so if you keep a theme there, DotForge's value is taken
# back and yours stays in effect. See docs/external-dependencies.md.

$_ownTheme = if ($Env:APPDATA) { Join-Path $Env:APPDATA 'eza' 'theme.yml' }
$_ourValue = (Get-DFToolTheme -Tool $DFCurrentTool).Value
if ($_ownTheme -and (Test-Path $_ownTheme -PathType Leaf) -and $_ourValue -and $Env:EZA_CONFIG_DIR -eq $_ourValue) {
    [Environment]::SetEnvironmentVariable('EZA_CONFIG_DIR', $null, 'Process')
    Add-DFToolNote -Tool $DFCurrentTool.name -Note "using your own $_ownTheme (EZA_CONFIG_DIR left unset)"
}
