# Companion for fzf — resolve and apply the configured color theme.
# fzf's own --color flag natively takes key:hex pairs, so no format conversion
# is needed here (unlike psreadline, which converts hex to ANSI escapes).
# The base options live in the seeded fzfrc (FZF_DEFAULT_OPTS_FILE, read first);
# FZF_DEFAULT_OPTS holds only the --color option applied here. A later theme
# replaces the option DotForge wrote last (remembered across registrations in
# $script:DFFzfColorLine), removed by exact text so the user's own options and
# PSFzf's --ansi stay.
#
# Theme: the theme block in Tools/fzf.json (Get-DFToolTheme).
# Theme files: $XDG_CONFIG_HOME\fzf\themes\<name>.json, else bundled Tools\fzf\.
# Sets: FZF_DEFAULT_OPTS. Writes no files (the fzfrc is a setup.seed).
# Binds Ctrl+R / Ctrl+T through the shared handler when fzf wins history-search /
# path-insert (PSFzf outranks it).

$_bundledDir = Join-Path $PSScriptRoot 'fzf'
# Private helpers can't be called by name from a function:global: closure, but a
# captured scriptblock keeps its module binding, so capture them here.
$_resolveThemeFile = ${function:Resolve-DFThemeFile}
$_setEnv = ${function:Set-DFEnv}
$_colorOption = ${function:ConvertTo-DFColorOption}
# One table for the module's lifetime: a closure-local variable would reset on every Register-DFTool.
if (-not (Get-Variable -Name DFFzfColorLine -Scope Script -ErrorAction Ignore)) { $script:DFFzfColorLine = @{ Line = $null } }
$_colorLine = $script:DFFzfColorLine

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
        session. It replaces the --color option it wrote last; any other text
        in the variable (yours, PSFzf's --ansi) stays.

        Every entry is checked against fzf's --color grammar (hex like #1e1e2e,
        -1, 0-255, default, or a color name, each optionally followed by
        :bold, :underline and similar), and invalid entries are skipped with a
        warning. An unknown theme name warns and changes nothing.

        Defined by DotForge's fzf companion, which calls it at startup with
        $DFConfig.FzfTheme, then $DFConfig.Theme, then catppuccin-mocha.
    .PARAMETER Name
        A theme name (e.g. catppuccin-mocha) or the full path to a theme JSON file.
    .PARAMETER Implicit
        Used by the companion at startup when the theme came from $DFConfig.Theme
        or the default: an FZF_DEFAULT_OPTS you set outside DotForge is then kept
        as is. Without it (calling the function yourself, or an explicit
        FzfTheme), the colors are appended to it.
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
    param([Parameter(Mandatory)][string]$Name, [switch]$Implicit)

    $path = & $_resolveThemeFile -Tool 'fzf' -Name $Name -BundledDir $_bundledDir
    if (-not $path) {
        Write-Warning "DotForge: fzf theme '$Name' not found"
        return
    }

    # ConvertTo-DFColorOption accepts only fzf's color grammar, so a theme file can't inject an option.
    $colorArg = & $_colorOption -Path $path -Tool 'fzf'
    if (-not $colorArg) { return }
    $existing = [string]$Env:FZF_DEFAULT_OPTS
    if ($_colorLine.Line) { $existing = $existing.Replace($_colorLine.Line, '') }
    $existing = @($existing -split '\r?\n' | ForEach-Object Trim | Where-Object { $_ }) -join "`n"
    $value = if ($existing) { "$existing`n$colorArg" } else { $colorArg }
    $explicit = if (-not $Implicit) { "fzf theme '$Name' was applied" }
    & $_setEnv -Name 'FZF_DEFAULT_OPTS' -Value $value -Tool 'fzf' -ExplicitReason $explicit
    $_colorLine.Line = $colorArg
}.GetNewClosure())

# Apply the session theme (Tools/fzf.json theme block: FzfTheme -> Theme -> default).
$_theme = Get-DFToolTheme -Tool $DFCurrentTool
Invoke-DFApplyFzfTheme -Name $_theme.Native -Implicit:(-not $_theme.Explicit)

function Initialize-DFRoleHistorySearch {
    param($Tool, $Role)
    Register-DFFuzzyKeyHandler -Engine 'fzf' -Key History -Tool $Tool.name
}

function Initialize-DFRolePathInsert {
    param($Tool, $Role)
    Register-DFFuzzyKeyHandler -Engine 'fzf' -Key Path -Tool $Tool.name
}

function Initialize-DFRoleDirectoryJump {
    param($Tool, $Role)
    # Alt+C draws zoxide's folders in this theme's prompt color.
    $themeFile = if ($_theme -and $_theme.Native) { & $_resolveThemeFile -Tool 'fzf' -Name $_theme.Native -BundledDir $_bundledDir }
    $accent = if ($themeFile -and (Test-Path -LiteralPath $themeFile -PathType Leaf)) {
        try { (Get-Content -LiteralPath $themeFile -Raw | ConvertFrom-Json).colors.prompt } catch { $null }
    }
    Register-DFFuzzyKeyHandler -Engine 'fzf' -Key Directory -Tool $Tool.name -Accent $accent
}
