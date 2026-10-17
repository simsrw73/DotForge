# Companion for skim (sk) — applies its color theme, loads its PowerShell
# completions, and binds Ctrl+R / Ctrl+T through the shared handler when skim
# wins history-search / path-insert (PSFzf, television and fzf outrank it).
# skim reads SKIM_DEFAULT_OPTIONS like fzf's FZF_DEFAULT_OPTS (verified with sk
# 5.7.4; not in its README, see docs/external-dependencies.md).
#
# Theme: the theme block in Tools/skim.json (Get-DFToolTheme).
# Theme files: $XDG_CONFIG_HOME\skim\themes\<name>.json, else bundled Tools\skim\.
# Sets: SKIM_DEFAULT_OPTIONS. Writes no files.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingInvokeExpression', '')]
param()

$_bundledDir = Join-Path $PSScriptRoot 'skim'
# Private helpers can't be called by name from a function:global: closure; captured scriptblocks can.
$_resolveThemeFile = ${function:Resolve-DFThemeFile}
$_colorOption = ${function:ConvertTo-DFColorOption}
$_setEnv = ${function:Set-DFEnv}

Set-Item -Path 'function:global:Invoke-DFApplySkimTheme' -Value ({
    <#
    .SYNOPSIS
        Applies a skim color theme to this session by appending a --color option to SKIM_DEFAULT_OPTIONS.
    .DESCRIPTION
        Resolves -Name to a theme file: an absolute path is used as is,
        otherwise $XDG_CONFIG_HOME\skim\themes\<Name>.json, then DotForge's
        bundled Tools\skim\<Name>.json. The file's "colors" object of skim
        color elements (fg, bg, matched, current, current_bg, ...) becomes one
        --color=name:value,... option appended to $Env:SKIM_DEFAULT_OPTIONS.
        skim merges repeated --color options in order, so the last theme
        applied wins. Invalid entries are skipped with a warning; an unknown
        theme name warns and changes nothing.
    .PARAMETER Name
        A theme name (e.g. catppuccin-mocha) or the full path to a theme JSON file.
    .PARAMETER Implicit
        Used by the companion at startup when the theme came from Theme or the
        default: a SKIM_DEFAULT_OPTIONS you set outside DotForge is then kept as
        is. Without it, the colors are appended to it.
    .EXAMPLE
        Invoke-DFApplySkimTheme -Name catppuccin-latte

        Switches skim to the bundled Catppuccin Latte colors for this session.
    .OUTPUTS
        None. Changes $Env:SKIM_DEFAULT_OPTIONS for the current session.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/tools.md
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [switch]$Implicit)
    $path = & $_resolveThemeFile -Tool 'skim' -Name $Name -BundledDir $_bundledDir
    if (-not $path) { Write-Warning "DotForge: skim theme '$Name' not found"; return }
    $colorArg = & $_colorOption -Path $path -Tool 'skim'
    if (-not $colorArg) { return }
    $existing = [string]$Env:SKIM_DEFAULT_OPTIONS
    $value = if ($existing) { "$existing`n$colorArg" } else { $colorArg }
    $explicit = if (-not $Implicit) { "skim theme '$Name' was applied" }
    & $_setEnv -Name 'SKIM_DEFAULT_OPTIONS' -Value $value -Tool 'skim' -ExplicitReason $explicit
}.GetNewClosure())

$_theme = Get-DFToolTheme -Tool $DFCurrentTool
Invoke-DFApplySkimTheme -Name $_theme.Native -Implicit:(-not $_theme.Explicit)

# skim's own -Native completer, cached against its binary (verified byte-identical across runs).
$_completions = Get-DFCachedCommandOutput -Name 'skim-completions' -Executable 'sk' -Generate {
    sk --shell power-shell | Out-String
}
if ($_completions) { Invoke-Expression $_completions }

function Initialize-DFRoleHistorySearch {
    param($Tool, $Role)
    Register-DFFuzzyKeyHandler -Engine 'sk' -Key History -Tool $Tool.name
}

function Initialize-DFRolePathInsert {
    param($Tool, $Role)
    Register-DFFuzzyKeyHandler -Engine 'sk' -Key Path -Tool $Tool.name
}
