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
    if ($MyInvocation.ExpectingInput) {
        $input | & fastfetch.exe --config $_cfg @args
    } else {
        & fastfetch.exe --config $_cfg @args
    }
}.GetNewClosure())
