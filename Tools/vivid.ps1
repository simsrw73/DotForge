# Companion for vivid — resolve the configured theme, generate (or reuse a
# cached) LS_COLORS value, and apply it to the session. Caching mirrors
# Private/Get-DFHelpTopicList.ps1's file-plus-fingerprint pattern: the
# fingerprint is just the resolved theme name, so a theme change invalidates
# the cache and a stable theme reuses it without spawning vivid again
# (~42ms measured locally — worth avoiding on every shell startup).
#
# Invoke-DFApplyLSColorsTheme is a function:global: (callable after
# Register-DFTool returns, and from the fls picker). Private functions can't be
# called *by name* from such a closure, but a scriptblock captured here keeps
# its module binding, so $_xdgPath below works. (An earlier note here called
# this a hard constraint; capturing the scriptblock is the way around it.)
#
# Reads: $DFConfig.VividTheme, then $DFConfig.Theme, then settings.theme in vivid.json.
# Sets: LS_COLORS (read by eza, lsd and other listing tools).
# Writes: $XDG_CACHE_HOME\dotforge\ls-colors.txt and ls-colors.key.

$_xdgPath = ${function:Get-DFXdgPath}

Set-Item -Path 'function:global:Invoke-DFApplyLSColorsTheme' -Value ({
    <#
    .SYNOPSIS
        Resolves and applies an LS_COLORS value for the named vivid theme.
    .DESCRIPTION
        Sets $Env:LS_COLORS for the current session from vivid generate <Name>.
        The generated value is cached in $XDG_CACHE_HOME\dotforge\ls-colors.txt,
        keyed by theme name, so later sessions with the same theme skip
        running vivid. A theme vivid doesn't know warns and changes nothing.

        Defined by DotForge's vivid companion, which calls it at startup with
        $DFConfig.VividTheme, then $DFConfig.Theme, then catppuccin-mocha.
    .PARAMETER Name
        A vivid theme name; list them with vivid themes.
    .PARAMETER Force
        Bypass the cache and regenerate even when the theme name matches
        what's cached — use after a vivid upgrade that may have shifted a
        theme's palette.
    .EXAMPLE
        Invoke-DFApplyLSColorsTheme -Name nord

        Switches directory-listing colors to vivid's nord theme for this session.
    .EXAMPLE
        Invoke-DFApplyLSColorsTheme -Name catppuccin-mocha -Force

        Regenerates the cached value, e.g. after upgrading vivid.
    .OUTPUTS
        None. Sets $Env:LS_COLORS and may write the cache files.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/tools.md
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [switch]$Force
    )

    $cacheDir  = Join-Path (& $_xdgPath Cache) 'dotforge'
    $cacheFile = Join-Path $cacheDir 'ls-colors.txt'
    $keyFile   = Join-Path $cacheDir 'ls-colors.key'

    $cacheValid = -not $Force -and (Test-Path $cacheFile) -and (Test-Path $keyFile) -and
                  ((Get-Content $keyFile -Raw).Trim() -eq $Name)

    if ($cacheValid) {
        $value = (Get-Content $cacheFile -Raw).Trim()
    } else {
        $raw = & vivid generate $Name 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "DotForge: vivid theme '$Name' failed — $($raw.Trim())"
            return
        }
        $value = $raw.Trim()

        New-DFDirectory $cacheDir
        Set-Content -Path $keyFile   -Value $Name  -Encoding UTF8
        Set-Content -Path $cacheFile -Value $value -Encoding UTF8
    }

    [System.Environment]::SetEnvironmentVariable('LS_COLORS', $value, 'Process')
}.GetNewClosure())

# Resolve: per-tool VividTheme -> shared Theme -> tool JSON default.
$_settings = $DFCurrentTool.settings
$_default  = $_settings.PSObject.Properties['theme']?.Value ?? 'catppuccin-mocha'
$_theme    = Get-DFConfiguredTheme -ToolKey 'VividTheme' -Default $_default
$_theme    = Resolve-DFThemeName -Name $_theme -ThemeMap $DFCurrentTool.themeMap

Invoke-DFApplyLSColorsTheme -Name $_theme

# Live picker: list vivid's own themes, preview each via `vivid preview`,
# apply the chosen one immediately (same cache/apply path as registration).
Set-Item -Path 'function:global:Select-LSColorsTheme' -Value ({
    <#
    .SYNOPSIS
        Fuzzy-picks a vivid LS_COLORS theme with a live preview and applies it to this session.
    .DESCRIPTION
        Lists vivid themes in fzf, previewing each with vivid preview. Enter
        applies the selection through Invoke-DFApplyLSColorsTheme for the
        current session only, and prints how to keep it: set
        $DFConfig['VividTheme'] in your profile. Esc changes nothing.

        Defined by DotForge's vivid companion; requires fzf (or $Env:Picker).
    .EXAMPLE
        fls

        Opens the theme picker; Enter applies the highlighted theme.
    .OUTPUTS
        None. Writes a confirmation line to the host.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/tools.md
    #>
    [CmdletBinding()]
    param()

    Invoke-DFPicker `
        -List    { vivid themes } `
        -Header  'Select LS_COLORS theme  [Enter to apply for this session]' `
        -Preview 'vivid preview {}' `
        -Action  {
            param($n)
            Invoke-DFApplyLSColorsTheme -Name $n
            Write-Host "Theme applied: $n  (to persist: set `$Global:DFConfig['VividTheme'] = '$n')" -ForegroundColor Green
        }
}.GetNewClosure())
Set-Alias -Name fls -Value Select-LSColorsTheme -Scope Global -Force
