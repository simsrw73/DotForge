# Companion for gum — applies its color theme through gum's GUM_* variables
# (gum has no config file). Only colors: gum is a scripting toolkit, and scripts
# expect its stock behavior.
#
# Theme: the theme block in Tools/gum.json (Get-DFToolTheme).
# Theme files: $XDG_CONFIG_HOME\gum\themes\<name>.json, else bundled Tools\gum\.
# Sets: GUM_*_FOREGROUND / GUM_*_BACKGROUND. Writes no files.

$_bundledDir = Join-Path $PSScriptRoot 'gum'
# Private helpers can't be called by name from a function:global: closure; captured scriptblocks can.
$_resolveThemeFile = ${function:Resolve-DFThemeFile}
$_setEnv = ${function:Set-DFEnv}

Set-Item -Path 'function:global:Invoke-DFApplyGumTheme' -Value ({
    <#
    .SYNOPSIS
        Applies a gum color theme to this session through gum's GUM_* color variables.
    .DESCRIPTION
        Resolves -Name to a theme file: an absolute path is used as is,
        otherwise $XDG_CONFIG_HOME\gum\themes\<Name>.json, then DotForge's
        bundled Tools\gum\<Name>.json. Each entry of the file's "env" object
        (a GUM_* variable and a #rrggbb color) is set for this session; a
        variable you set outside DotForge is kept unless you call this
        yourself. Entries that aren't GUM_* variables with a hex color are
        skipped with a warning.
    .PARAMETER Name
        A theme name (e.g. catppuccin-mocha) or the full path to a theme JSON file.
    .PARAMETER Implicit
        Used by the companion at startup when the theme came from Theme or the
        default: a GUM_* variable you set outside DotForge is then kept as is.
    .EXAMPLE
        Invoke-DFApplyGumTheme -Name catppuccin-frappe

        Switches gum to the bundled Catppuccin Frappé colors for this session.
    .OUTPUTS
        None. Changes GUM_* environment variables for the current session.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/tools.md
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [switch]$Implicit)
    $path = & $_resolveThemeFile -Tool 'gum' -Name $Name -BundledDir $_bundledDir
    if (-not $path) { Write-Warning "DotForge: gum theme '$Name' not found"; return }
    $vars = (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).PSObject.Properties['env']?.Value
    if (-not $vars) { return }
    $explicit = if (-not $Implicit) { "gum theme '$Name' was applied" }
    foreach ($entry in $vars.PSObject.Properties) {
        if ($entry.Name -cnotmatch '^GUM_[A-Z_]+$' -or [string]$entry.Value -notmatch '^#[0-9A-Fa-f]{6}$') {
            Write-Warning "DotForge: invalid gum theme entry '$($entry.Name)':'$($entry.Value)' — skipping"
            continue
        }
        & $_setEnv -Name $entry.Name -Value ([string]$entry.Value) -Tool 'gum' -ExplicitReason $explicit
    }
}.GetNewClosure())

$_theme = Get-DFToolTheme -Tool $DFCurrentTool
Invoke-DFApplyGumTheme -Name $_theme.Native -Implicit:(-not $_theme.Explicit)
