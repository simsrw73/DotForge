# Companion for fzf — resolve and apply the configured color theme.
# fzf's own --color flag natively takes key:hex pairs, so no format conversion
# is needed here (unlike psreadline, which converts hex to ANSI escapes).
# Register-DFTool's env-block step already (re)sets $Env:FZF_DEFAULT_OPTS from
# fzf.json's non-color flags on every call, before this companion runs, so
# appending the resolved --color=... string here is always idempotent.

$_bundledDir = Join-Path $PSScriptRoot 'fzf'

Set-Item -Path 'function:global:Invoke-DFApplyFzfTheme' -Value ({
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    # Resolve path: absolute path passthrough, XDG user dir, then bundled
    $path = $null
    if ([System.IO.Path]::IsPathRooted($Name)) {
        $path = $Name
    } else {
        if ($Env:XDG_CONFIG_HOME) {
            $p = Join-Path $Env:XDG_CONFIG_HOME 'fzf' 'themes' "$Name.json"
            if (Test-Path $p) { $path = $p }
        }
        if (-not $path) {
            $p = Join-Path $_bundledDir "$Name.json"
            if (Test-Path $p) { $path = $p }
        }
    }
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
$_themeSetting = Resolve-DFThemeName -Name $_themeSetting -ThemeMap ($DFCurrentTool.PSObject.Properties['themeMap']?.Value)
Invoke-DFApplyFzfTheme -Name $_themeSetting
