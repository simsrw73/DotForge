# One-time setup for mdv -- seed a themed config.yaml, since mdv has no config
# auto-discovery and no theme env var (verified against mdv 4.2.1). Its config
# is found only via MDV_CONFIG_PATH (set declaratively by Tools/mdv.json's env
# method, which runs before this) pointing at a dir holding config.yaml.
#
# Runs at most once ever, gated by Invoke-DFToolCompanion on
# Get-DFToolSetupState. This used to be a per-session check in Tools/mdv.ps1
# (Test-Path $cfgFile, write only if absent) -- that couldn't distinguish
# "never ran" from "ran once, user deleted it on purpose," so deleting the
# seeded file to opt out got it silently reasserted next session. The
# one-time-setup primitive fixes that: the presence check below only ever
# runs on this script's one guaranteed execution, so a later deletion sticks.
# See docs/superpowers/specs/2026-09-04-tool-setup-lifecycle-design.md.

$_settings = $DFCurrentTool.PSObject.Properties['settings']?.Value
$_default  = $_settings.PSObject.Properties['theme']?.Value ?? 'catppuccin-mocha'
$_name     = Get-DFConfiguredTheme -ToolKey 'MdvTheme' -Default $_default
$_name     = Resolve-DFThemeName -Name $_name -ThemeMap ($DFCurrentTool.PSObject.Properties['themeMap']?.Value)

$_valid = @(
    'terminal', 'solarized-dark', 'nord', 'tokyonight',
    'kanagawa', 'gruvbox', 'monokai', 'material-ocean', 'catppuccin'
)
if ($_name -notin $_valid) {
    Write-Warning "DotForge: mdv theme '$_name' not recognized — falling back to 'terminal'"
    $_name = 'terminal'
}

$_cfgDir  = if ($Env:MDV_CONFIG_PATH) { $Env:MDV_CONFIG_PATH }
            else { Expand-DFXdgPath '${XDG_CONFIG_HOME}/mdv' }
$_cfgFile = Join-Path $_cfgDir 'config.yaml'
if (-not (Test-Path $_cfgFile -PathType Leaf)) {
    Set-Content -Path $_cfgFile -Value "theme: `"$_name`"" -Encoding UTF8
    Write-Verbose "DotForge: seeded mdv config at $_cfgFile (theme: $_name)"
}

Complete-DFToolSetup -Name 'mdv' -Actions @(
    @{ type = 'seedConfig'; path = $_cfgFile }
)
