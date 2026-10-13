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
#
# Theme: the theme block in Tools/mdv.json (Get-DFToolTheme).
# Writes: $MDV_CONFIG_PATH\config.yaml (default $XDG_CONFIG_HOME\mdv\config.yaml),
# only if it doesn't exist. To change the theme later, edit that file. To reseed
# it, delete it and remove the "mdv" entry from
# $XDG_STATE_HOME\dotforge\setup-state.json. To skip: $DFConfig.SkipSetup = @('mdv').

# The theme block in Tools/mdv.json resolves MdvTheme -> Theme -> default, maps
# the canonical name and falls back to 'terminal' for a name mdv doesn't know.
$_name = (Get-DFToolTheme -Tool $DFCurrentTool).Value

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
