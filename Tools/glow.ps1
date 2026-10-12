# Companion for glow — wraps the executable so the style reaches it as the -s flag.
#
# Config: glow 3 reads <GLOW_CONFIG_HOME>/glow.yml, which glow.json's xdg.vars points
# at $XDG_CONFIG_HOME\glow; its --config flag has no effect (verified glow 3.0.0, and
# already ineffective in 2.1.2), so nothing here passes it.
# Style: GLAMOUR_STYLE is never read, and GLOW_STYLE loses to glow's non-TTY
# downgrade (still true in 3.0.0), so only -s works, hence this wrapper.
# See docs/external-dependencies.md.
#
# Reads: $DFConfig.GlowTheme, then $DFConfig.Theme, then settings.theme in glow.json.
# Defines: glow (wrapper), Resolve-DFGlowStyle, $global:DFGlowStyle, Read-MarkdownFile (alias fgl).

# 1. Settings from tool JSON. Theme: per-tool GlowTheme -> shared Theme -> JSON default.
$_settings = $DFCurrentTool.settings
$_default  = $_settings.PSObject.Properties['theme']?.Value ?? 'catppuccin-mocha'
$_theme    = Get-DFConfiguredTheme -ToolKey 'GlowTheme' -Default $_default
$_theme    = Resolve-DFThemeName -Name $_theme -ThemeMap $DFCurrentTool.themeMap

# 2. Register Resolve-DFGlowStyle (captures $_bundledDir via closure)
$_bundledDir = Join-Path $PSScriptRoot 'glow'
# Private helpers can't be called by name from a function:global: closure, but a
# captured scriptblock keeps its module binding, so capture them here.
$_resolveThemeFile = ${function:Resolve-DFThemeFile}

Set-Item -Path 'function:global:Resolve-DFGlowStyle' -Value ({
    <#
    .SYNOPSIS
        Resolves a glow style name to the value handed to glow's -s flag.
    .DESCRIPTION
        Tries, in order: -Name as a full path to an existing file; then
        $XDG_CONFIG_HOME\glow\themes\<Name>.json; then DotForge's bundled
        Tools\glow\<Name>.json (catppuccin-mocha ships there); then glow's own
        built-in styles (auto, dark, light, dracula, pink, notty, ascii,
        tokyo-night), returned as the bare name. Anything else warns and
        returns 'auto', because glow exits with an error on an unknown style.

        Defined by DotForge's glow companion. To switch the style for the rest
        of the session, assign the result to $global:DFGlowStyle.
    .PARAMETER Name
        A style name or the full path to a glamour style JSON file.
    .EXAMPLE
        $global:DFGlowStyle = Resolve-DFGlowStyle -Name dracula

        Switches every later glow call in this session to the dracula style.
    .OUTPUTS
        System.String. A style file path or a glow built-in style name.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/tools.md
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name)

    # glow's own style names — passed through verbatim when no file matches.
    $builtin = @('auto', 'dark', 'light', 'dracula', 'pink', 'notty', 'ascii', 'tokyo-night')

    $file = & $_resolveThemeFile -Tool 'glow' -Name $Name -BundledDir $_bundledDir
    if ($file) { return $file }
    if ($Name -in $builtin) { return $Name }

    # Never return an unresolved path: glow exits 1 with "specified style does not
    # exist" rather than degrading, which would break the command outright.
    Write-Warning "DotForge: glow style '$Name' not found — falling back to 'auto'"
    'auto'
}.GetNewClosure())

# 3. Resolve the initial style. The wrapper reads $DFGlowStyle at call time rather
#    than capturing it, so `$global:DFGlowStyle = 'dracula'` switches theme live.
$global:DFGlowStyle = Resolve-DFGlowStyle -Name $_theme

# 4. Wrap the executable. A simple (non-advanced) function keeps @args available so
#    glow's own flags pass through unbound; & glow.exe resolves to the Application,
#    not back into this function. The ExpectingInput branch is required: without it
#    a piped `'# Hi' | glow` hangs, because a function with no process block swallows
#    the pipeline and glow.exe then blocks on the inherited console stdin.
Set-Item -Path 'function:global:glow' -Value ({
    <#
    .SYNOPSIS
        Runs glow with the current session style.
    .DESCRIPTION
        Wraps glow.exe and always passes -s <style>, because glow's GLOW_STYLE
        variable loses to its non-TTY downgrade. Its config comes from
        $XDG_CONFIG_HOME\glow\glow.yml (GLOW_CONFIG_HOME). The style is
        read from $global:DFGlowStyle on every call, so assigning to it switches
        the theme immediately; when it is empty, 'auto' is used. Other
        arguments, glow's subcommands and piped input pass through unchanged.

        Defined by DotForge's glow companion.
    .EXAMPLE
        glow README.md

        Renders a Markdown file with the configured style.
    .EXAMPLE
        Get-Content notes.md | glow

        Renders piped Markdown.
    .OUTPUTS
        System.String. The rendered Markdown.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/tools.md
    #>
    $_s = if ($global:DFGlowStyle) { $global:DFGlowStyle } else { 'auto' }
    if ($MyInvocation.ExpectingInput) {
        $input | & glow.exe -s $_s @args
    } else {
        & glow.exe -s $_s @args
    }
}.GetNewClosure())

# 5. The fgl picker.
Set-Item -Path 'function:global:Read-MarkdownFile' -Value ({
    <#
    .SYNOPSIS
        Fuzzy-picks a Markdown file below a folder and reads it in glow's pager.
    .DESCRIPTION
        Lists *.md files below -Path (with fd when it is installed, else
        Get-ChildItem), previews each rendered in the session's glow style
        ($global:DFGlowStyle), and opens the chosen one with glow -p.

        Defined by DotForge's glow companion. Requires fzf (or $Env:Picker).
    .PARAMETER Path
        The folder to search. Default: the current folder.
    .EXAMPLE
        fgl docs

        Picks a Markdown file under docs and reads it in glow.
    .OUTPUTS
        None.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/tools.md
    #>
    [CmdletBinding()]
    param([Parameter(Position = 0)][string]$Path = '.')
    $style = if ($global:DFGlowStyle) { $global:DFGlowStyle } else { 'auto' }
    $list = if (Get-Command fd -ErrorAction Ignore) { { fd --type f --extension md . $Path }.GetNewClosure() }
        else { { Get-ChildItem -LiteralPath $Path -Recurse -File -Filter '*.md' -ErrorAction Ignore | ForEach-Object FullName }.GetNewClosure() }
    Invoke-DFPicker -List $list -Preview "glow.exe -s ""$style"" {}" `
        -Header 'Select Markdown file  [Enter to read it in glow]' -Action { param($file) glow -p $file }
}.GetNewClosure())
Set-Alias -Name fgl -Value Read-MarkdownFile -Scope Global -Force
