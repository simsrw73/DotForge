# Companion for mdv — seed a themed config.yaml, since mdv has no config
# auto-discovery and no theme env var (verified against mdv 4.2.1). Its config
# is found only via MDV_CONFIG_PATH (set by Tools/mdv.json's env method) pointing
# at a dir holding config.yaml. We write that file only when it is absent, so a
# user-edited config is never clobbered — the same restraint as Register-DFTool's
# 'config' method. See docs/external-dependencies.md.

# 1. Theme: per-tool key -> shared Theme -> JSON default 'catppuccin'.
$_settings = $DFCurrentTool.PSObject.Properties['settings']?.Value
$_default  = $_settings.PSObject.Properties['theme']?.Value ?? 'catppuccin'
$_name     = Get-DFConfiguredTheme -ToolKey 'MdvTheme' -Default $_default

# Family alias: mdv ships one catppuccin flavour, so any catppuccin-* -> catppuccin.
if ($_name -like 'catppuccin-*') { $_name = 'catppuccin' }

$_valid = @(
    'terminal', 'solarized-dark', 'nord', 'tokyonight',
    'kanagawa', 'gruvbox', 'monokai', 'material-ocean', 'catppuccin'
)
if ($_name -notin $_valid) {
    Write-Warning "DotForge: mdv theme '$_name' not recognized — falling back to 'terminal'"
    $_name = 'terminal'
}

# 2. Seed config.yaml when absent. MDV_CONFIG_PATH was set by the env method; fall
#    back to the XDG path if it is somehow empty.
#    Normalize path separators for the current platform.
if ($Env:MDV_CONFIG_PATH) {
    $Env:MDV_CONFIG_PATH = $Env:MDV_CONFIG_PATH -replace [regex]::Escape([System.IO.Path]::AltDirectorySeparatorChar), [System.IO.Path]::DirectorySeparatorChar
    $_cfgDir = $Env:MDV_CONFIG_PATH
} else {
    $_cfgDir = Expand-DFXdgPath '${XDG_CONFIG_HOME}/mdv'
}
New-DFDirectory $_cfgDir | Out-Null

$_cfgFile = Join-Path $_cfgDir 'config.yaml'
if (-not (Test-Path $_cfgFile -PathType Leaf)) {
    Set-Content -Path $_cfgFile -Value "theme: `"$_name`"" -Encoding UTF8
    Write-Verbose "DotForge: seeded mdv config at $_cfgFile (theme: $_name)"
}
