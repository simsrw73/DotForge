# Companion for vivid — resolve the configured theme, generate (or reuse a
# cached) LS_COLORS value, and apply it to the session. Caching uses
# Get-DFFingerprintCache (Shared/Get-DFFingerprintCache.ps1): the fingerprint
# is the theme name plus the filetypes database's last-write time, so a theme
# change or an edit to the database invalidates the cache, and otherwise vivid
# isn't spawned again (~42ms measured locally — worth avoiding on every start).
# The database is the seeded $XDG_CONFIG_HOME\vivid\filetypes.yml, trimmed so
# LS_COLORS stays under 8,191 characters; without it, vivid's built-in one.
#
# Invoke-DFApplyLSColorsTheme is a function:global: (callable after
# Register-DFTool returns, and from the fls picker). Private functions can't be
# called *by name* from such a closure, but a scriptblock captured here keeps
# its module binding, so $_fingerprintCache below works. (An earlier note here called
# this a hard constraint; capturing the scriptblock is the way around it.)
#
# Theme: the theme block in Tools/vivid.json (Get-DFToolTheme).
# Sets: LS_COLORS (read by eza, lsd and other listing tools).
# Writes: $XDG_CACHE_HOME\dotforge\ls-colors.txt and ls-colors.key.

$_fingerprintCache = ${function:Get-DFFingerprintCache}
$_xdgPath = ${function:Get-DFXdgPath}
$_setEnv = ${function:Set-DFEnv}

Set-Item -Path 'function:global:Invoke-DFApplyLSColorsTheme' -Value ({
    <#
    .SYNOPSIS
        Resolves and applies an LS_COLORS value for the named vivid theme.
    .DESCRIPTION
        Sets $Env:LS_COLORS for the current session from vivid generate <Name>,
        using the file types in $XDG_CONFIG_HOME\vivid\filetypes.yml when it
        exists (DotForge seeds a trimmed copy), else vivid's built-in list.
        The generated value is cached in $XDG_CACHE_HOME\dotforge\ls-colors.txt,
        keyed by theme name and that file's last write, so later sessions skip
        running vivid. A theme vivid doesn't know warns and changes nothing.

        Defined by DotForge's vivid companion, which calls it at startup with
        $DFConfig.VividTheme, then $DFConfig.Theme, then catppuccin-mocha.
    .PARAMETER Name
        A vivid theme name; list them with vivid themes.
    .PARAMETER Force
        Bypass the cache and regenerate even when the theme name matches
        what's cached — use after a vivid upgrade that may have shifted a
        theme's palette.
    .PARAMETER Implicit
        Used by the companion at startup when the theme came from $DFConfig.Theme
        or the default: an LS_COLORS you set outside DotForge is then kept.
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
        [switch]$Force,
        [switch]$Implicit
    )

    # Keyed by theme name and the database's last write: a change to either regenerates.
    $database = Join-Path (& $_xdgPath Config) 'vivid' 'filetypes.yml'
    $databaseArgs = @()
    $stamp = 'builtin'
    if (Test-Path -LiteralPath $database -PathType Leaf) {
        $databaseArgs = @('-d', $database)
        $stamp = (Get-Item -LiteralPath $database).LastWriteTimeUtc.Ticks
    }
    $value = & $_fingerprintCache -Name 'ls-colors' -Fingerprint "$Name|$stamp" -Force:$Force -Generate {
        $raw = & vivid @databaseArgs generate $Name 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "DotForge: vivid theme '$Name' failed — $($raw.Trim())"
            return
        }
        $raw
    }
    if (-not $value) { return }

    $explicit = if (-not $Implicit) { "vivid theme '$Name' was applied" }
    & $_setEnv -Name 'LS_COLORS' -Value $value -Tool 'vivid' -ExplicitReason $explicit
}.GetNewClosure())

# Apply the session theme (Tools/vivid.json theme block: VividTheme -> Theme -> default).
$_theme = Get-DFToolTheme -Tool $DFCurrentTool
Invoke-DFApplyLSColorsTheme -Name $_theme.Native -Implicit:(-not $_theme.Explicit)

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
