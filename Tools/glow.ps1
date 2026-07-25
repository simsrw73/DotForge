# Companion for glow — wraps the executable so style and config reach it as CLI
# flags instead of environment variables.
#
# glow honors no XDG environment variable (verified against glow 2.1.2):
#   * GLOW_CONFIG_DIR / GLOW_CONFIG_HOME / GLOW_CONFIG / GLOW_CONFIG_FILE are all
#     ignored — the config path comes from a Win32 known-folder lookup, so it does
#     not move even when APPDATA/LOCALAPPDATA are redirected.
#   * GLAMOUR_STYLE is never read at all.
#   * GLOW_STYLE is parsed, but loses to glow's non-TTY downgrade, so it silently
#     fails to apply.
# Only the --config and -s flags work reliably, hence this wrapper.
# adapter for glow/honors-env:GLOW_CONFIG_DIR
# See docs/external-dependencies.md.

# 1. Settings from tool JSON. Theme: per-tool GlowTheme -> shared Theme -> JSON default.
$_settings = $DFCurrentTool.PSObject.Properties['settings']?.Value
$_default  = $_settings.PSObject.Properties['theme']?.Value ?? 'catppuccin-mocha'
$_theme    = Get-DFConfiguredTheme -ToolKey 'GlowTheme' -Default $_default
$_cfgRaw   = $_settings.PSObject.Properties['configFile']?.Value ?? '${XDG_CONFIG_HOME}/glow/glow.yml'
$_cfg      = Expand-DFXdgPath $_cfgRaw

New-DFDirectory (Split-Path $_cfg) | Out-Null

# 2. Register Resolve-DFGlowStyle (captures $_bundledDir via closure)
$_bundledDir = Join-Path $PSScriptRoot 'glow'

Set-Item -Path 'function:global:Resolve-DFGlowStyle' -Value ({
    <#
    .SYNOPSIS
        Resolves a glow style name to the value handed to glow's -s flag.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name)

    # Family alias: the shared 'catppuccin' key means glow's bundled mocha flavour.
    if ($Name -eq 'catppuccin') { $Name = 'catppuccin-mocha' }

    # glow's own style names — passed through verbatim when no file matches.
    $builtin = @('auto', 'dark', 'light', 'dracula', 'pink', 'notty', 'ascii', 'tokyo-night')

    if ([System.IO.Path]::IsPathRooted($Name)) {
        if (Test-Path $Name -PathType Leaf) { return $Name }
    } else {
        if ($Env:XDG_CONFIG_HOME) {
            $p = Join-Path $Env:XDG_CONFIG_HOME 'glow' 'themes' "$Name.json"
            if (Test-Path $p -PathType Leaf) { return $p }
        }
        $p = Join-Path $_bundledDir "$Name.json"
        if (Test-Path $p -PathType Leaf) { return $p }
        if ($Name -in $builtin) { return $Name }
    }

    # Never return an unresolved path: glow exits 1 with "specified style does not
    # exist" rather than degrading, which would break the command outright.
    Write-Warning "DotForge: glow style '$Name' not found — falling back to 'auto'"
    'auto'
}.GetNewClosure())

# 3. Resolve the initial style. The wrapper reads $DFGlowStyle at call time rather
#    than capturing it, so `$global:DFGlowStyle = 'dracula'` switches theme live.
$global:DFGlowStyle = Resolve-DFGlowStyle -Name $_theme

# 4. Wrap the executable. A simple (non-advanced) function keeps @args available so
#    glow's own flags pass through unbound; & glow.exe resolves to the Application,
#    not back into this function. The ExpectingInput branch is required: without it
#    a piped `'# Hi' | glow` hangs, because a function with no process block swallows
#    the pipeline and glow.exe then blocks on the inherited console stdin.
Set-Item -Path 'function:global:glow' -Value ({
    $_s = if ($global:DFGlowStyle) { $global:DFGlowStyle } else { 'auto' }
    if ($MyInvocation.ExpectingInput) {
        $input | & glow.exe --config $_cfg -s $_s @args
    } else {
        & glow.exe --config $_cfg -s $_s @args
    }
}.GetNewClosure())
