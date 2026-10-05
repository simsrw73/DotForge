# Companion for fzf — resolve and apply the configured color theme.
# fzf's own --color flag natively takes key:hex pairs, so no format conversion
# is needed here (unlike psreadline, which converts hex to ANSI escapes).
# Register-DFTool's env-block step already (re)sets $Env:FZF_DEFAULT_OPTS from
# fzf.json's non-color flags on every call, before this companion runs, so
# appending the resolved --color=... string here is always idempotent.
#
# Reads: $DFConfig.FzfTheme, then $DFConfig.Theme, then 'catppuccin-mocha'.
# Theme files: $XDG_CONFIG_HOME\fzf\themes\<name>.json, else bundled Tools\fzf\.
# Sets: FZF_DEFAULT_OPTS. Writes no files.

$_bundledDir = Join-Path $PSScriptRoot 'fzf'
# Private helpers can't be called by name from a function:global: closure, but a
# captured scriptblock keeps its module binding, so capture them here.
$_resolveThemeFile = ${function:Resolve-DFThemeFile}

Set-Item -Path 'function:global:Invoke-DFApplyFzfTheme' -Value ({
    <#
    .SYNOPSIS
        Applies an fzf color theme to this session by appending a --color option to FZF_DEFAULT_OPTS.
    .DESCRIPTION
        Resolves -Name to a theme file: an absolute path is used as is,
        otherwise $XDG_CONFIG_HOME\fzf\themes\<Name>.json, then DotForge's
        bundled Tools\fzf\<Name>.json. The file's "colors" object of fzf color
        names and values becomes one --color=name:value,... option appended to
        $Env:FZF_DEFAULT_OPTS, so it applies to every later fzf call in the
        session. Each call appends another --color option; fzf applies them in
        order, so the last theme applied wins.

        Every entry is checked against fzf's --color grammar (hex like #1e1e2e,
        -1, 0-255, default, or a color name, each optionally followed by
        :bold, :underline and similar), and invalid entries are skipped with a
        warning. An unknown theme name warns and changes nothing.

        Defined by DotForge's fzf companion, which calls it at startup with
        $DFConfig.FzfTheme, then $DFConfig.Theme, then catppuccin-mocha.
    .PARAMETER Name
        A theme name (e.g. catppuccin-mocha) or the full path to a theme JSON file.
    .EXAMPLE
        Invoke-DFApplyFzfTheme -Name catppuccin-mocha

        Applies the bundled Catppuccin Mocha colors to fzf for this session.
    .EXAMPLE
        Invoke-DFApplyFzfTheme -Name "$HOME\dotfiles\fzf-gruvbox.json"

        Applies a theme file you wrote, e.g. { "colors": { "bg": "#282828", "fg": "#ebdbb2" } }.
    .OUTPUTS
        None. Changes $Env:FZF_DEFAULT_OPTS for the current session.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/tools.md
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    $path = & $_resolveThemeFile -Tool 'fzf' -Name $Name -BundledDir $_bundledDir
    if (-not $path) {
        Write-Warning "DotForge: fzf theme '$Name' not found"
        return
    }

    $theme = Get-Content $path -Raw | ConvertFrom-Json
    $colorsProp = $theme.PSObject.Properties['colors']?.Value
    if (-not $colorsProp) { return }

    # A theme file's key/value pair becomes a raw, unquoted token in
    # FZF_DEFAULT_OPTS, which fzf tokenizes as additional CLI flags -- an
    # unvalidated value (e.g. containing a newline) could inject an extra
    # flag such as --bind=execute(...). Only accept fzf's own documented
    # --color value grammar (hex, -1, 0-255, 'default', a color name, each
    # optionally chained with :modifier); anything else is skipped with a
    # warning, matching Tools/psreadline.ps1's identical hex-validation guard.
    $validKey   = '^[A-Za-z][A-Za-z0-9_-]*\+?$'
    $validValue = '^(#[0-9A-Fa-f]{3,8}|-1|[0-9]{1,3}|default|[A-Za-z]+(:(bold|underline|reverse|italic|dim|strikethrough))*)$'
    $pairs = @($colorsProp.PSObject.Properties | ForEach-Object {
        if ($_.Name -cmatch $validKey -and [string]$_.Value -cmatch $validValue) {
            "$($_.Name):$($_.Value)"
        } else {
            Write-Warning "DotForge: invalid fzf color entry '$($_.Name)':'$($_.Value)' — skipping"
        }
    })
    if ($pairs.Count -eq 0) { return }

    $colorArg = '--color=' + ($pairs -join ',')
    $existing = [string]$Env:FZF_DEFAULT_OPTS
    $Env:FZF_DEFAULT_OPTS = if ($existing) { "$existing`n$colorArg" } else { $colorArg }
}.GetNewClosure())

# Apply initial theme: per-tool FzfTheme -> shared Theme -> 'catppuccin-mocha'.
$_themeSetting = Get-DFConfiguredTheme -ToolKey 'FzfTheme' -Default 'catppuccin-mocha'
$_themeSetting = Resolve-DFThemeName -Name $_themeSetting -ThemeMap $DFCurrentTool.themeMap
Invoke-DFApplyFzfTheme -Name $_themeSetting
