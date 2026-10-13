# Companion for fastfetch -- builds the fastfetch wrapper declared in Tools/fastfetch.json,
# adding the startup banner's placeholders. The wrapper passes the seeded config via
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
# The startup banner's placeholders (@DF:publicip@, @DF:drives@) are filled from
# the banner cache when fastfetch runs by hand; the banner part knows the colors.
$_ffPart     = . (Join-Path $PSScriptRoot 'fastfetch.banner.ps1')
$_ffStyleOf  = $_ffPart.Style
$_ffTool     = $DFCurrentTool
$_ffComplete = ${function:Complete-DFBannerBody}

# The themed default config is seeded once by the setup step (setup.seed in
# fastfetch.json), not here: a config the user deletes stays deleted.

# The --config flag comes from the wrapper block in Tools/fastfetch.json; this adds
# the banner's placeholders (@DF:publicip@, @DF:drives@), filled from the banner
# cache, and keeps colors when the output goes to the screen (fastfetch drops them
# when captured).
New-DFToolWrapper -Tool $DFCurrentTool -Description ('When the config holds @DF: placeholders (the startup banner''s ' +
    'public IP and drives), they are filled from the banner cache. If you delete the config, fastfetch runs with its own defaults.') -Invoke {
    param($exe, [string[]]$declared, [object[]]$userArgs, $invocation)
    $placeholders = $declared.Count -and (Select-String -LiteralPath $_cfg -Pattern '@DF:' -SimpleMatch -Quiet)
    if (-not $placeholders) { & $exe @declared @userArgs; return }
    $color = if ($invocation.PipelinePosition -lt $invocation.PipelineLength -or [Console]::IsOutputRedirected) { @() } else { @('--pipe', 'false') }
    $body = @(& $exe @declared @color @userArgs)
    $styleValues = try { & $_ffStyleOf ([pscustomobject]@{ Tool = $_ffTool }) } catch { @{} }
    & $_ffComplete -Body $body -StyleValues $styleValues
}.GetNewClosure()
