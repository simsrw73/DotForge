# Companion for fastfetch -- wraps the executable so the seeded config reaches it via
# an explicit --config flag, since fastfetch does not honor $XDG_CONFIG_HOME on
# Windows (verified against fastfetch 2.68.1): --list-config-paths ignores it
# entirely and only checks a hardcoded list of Win32 known-folder paths, the first of
# which ($HOME\.config\fastfetch\) happens to coincide with DotForge's own
# XDG_CONFIG_HOME default -- a relocated XDG_CONFIG_HOME breaks discovery silently
# without this wrapper.
# adapter for fastfetch/honors-env:XDG_CONFIG_HOME
# See docs/external-dependencies.md.

$_settings = $DFCurrentTool.PSObject.Properties['settings']?.Value
$_cfgRaw   = $_settings.PSObject.Properties['configPath']?.Value ?? '${XDG_CONFIG_HOME}/fastfetch/config.jsonc'
$_cfg      = Expand-DFXdgPath $_cfgRaw

New-DFDirectory (Split-Path $_cfg) | Out-Null

if (-not (Test-Path $_cfg)) {
    $_content = $_settings.PSObject.Properties['configContent']?.Value
    if ($_content) {
        Set-Content -Path $_cfg -Value $_content -Encoding UTF8
    }
}

Set-Item -Path 'function:global:fastfetch' -Value ({
    <#
    .SYNOPSIS
        Runs fastfetch with DotForge's config file.
    .DESCRIPTION
        Wraps fastfetch.exe and always passes --config <path>, because fastfetch
        ignores XDG_CONFIG_HOME on Windows. The path comes from
        settings.configPath in fastfetch.json (default
        $XDG_CONFIG_HOME\fastfetch\config.jsonc). On first registration the
        companion seeds that file from settings.configContent if it doesn't
        exist; after that the file is yours to edit and is never overwritten.

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
    if ($MyInvocation.ExpectingInput) {
        $input | & fastfetch.exe --config $_cfg @args
    } else {
        & fastfetch.exe --config $_cfg @args
    }
}.GetNewClosure())
