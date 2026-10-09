# Companion for fastfetch -- wraps the executable so the seeded config reaches it via
# an explicit --config flag, since fastfetch does not honor $XDG_CONFIG_HOME on
# Windows (verified against fastfetch 2.68.1): --list-config-paths ignores it
# entirely and only checks a hardcoded list of Win32 known-folder paths, the first of
# which ($HOME\.config\fastfetch\) happens to coincide with DotForge's own
# XDG_CONFIG_HOME default -- a relocated XDG_CONFIG_HOME breaks discovery silently
# without this wrapper.
# adapter for fastfetch/honors-env:XDG_CONFIG_HOME
# See docs/external-dependencies.md.

$_settings = $DFCurrentTool.settings
$_cfgRaw   = $_settings.PSObject.Properties['configPath']?.Value ?? '${XDG_CONFIG_HOME}/fastfetch/config.jsonc'
$_cfg      = Expand-DFXdgPath $_cfgRaw

# The themed default config is seeded once by the setup step (setup.seed in
# fastfetch.json), not here: a config the user deletes stays deleted.

Set-Item -Path 'function:global:fastfetch' -Value ({
    <#
    .SYNOPSIS
        Runs fastfetch with DotForge's config file.
    .DESCRIPTION
        Wraps fastfetch.exe and passes --config <path>, because fastfetch
        ignores XDG_CONFIG_HOME on Windows. The path comes from
        settings.configPath in fastfetch.json (default
        $XDG_CONFIG_HOME\fastfetch\config.jsonc). DotForge's one-time setup
        seeds that file with a themed default; after that it is yours to edit
        and is never overwritten. If you delete it, fastfetch runs with its
        own defaults (no --config is passed).

        All other arguments, and piped input, are passed to fastfetch unchanged.
        Defined by DotForge's fastfetch companion.
    .EXAMPLE
        fastfetch

        Prints the system-info banner using DotForge's config.
    .EXAMPLE
        fastfetch --logo none

        Passes an extra fastfetch option through.
    .OUTPUTS
        System.String. fastfetch's output.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/tools.md
    #>
    $cfgArgs = if (Test-Path -LiteralPath $_cfg -PathType Leaf) { '--config', $_cfg } else { @() }
    if ($MyInvocation.ExpectingInput) {
        $input | & fastfetch.exe @cfgArgs @args
    } else {
        & fastfetch.exe @cfgArgs @args
    }
}.GetNewClosure())
