# Companion for glow — the fgl Markdown picker.
#
# glow's config (GLOW_CONFIG_HOME), style (theme block: GlowTheme -> Theme -> default,
# resolved to a style file in $XDG_CONFIG_HOME\glow	hemes or Tools\glow, else one of
# glow's built-in names) and its -s wrapper are declared in Tools/glow.json. -s is the
# only way the style reaches glow: GLAMOUR_STYLE is never read, and GLOW_STYLE loses to
# glow's non-TTY downgrade (still true in 3.0.0). See docs/external-dependencies.md.
#
# Defines: Read-MarkdownFile (alias fgl).

# A captured scriptblock keeps its module binding, so the closure below can call it.
$_themeOf = ${function:Get-DFSessionThemeValue}

Set-Item -Path 'function:global:Read-MarkdownFile' -Value ({
    <#
    .SYNOPSIS
        Fuzzy-picks a Markdown file below a folder and reads it in glow's pager.
    .DESCRIPTION
        Lists *.md files below -Path (with fd when it is installed, else
        Get-ChildItem), previews each rendered in the session's glow style
        (Set-DFToolTheme glow <style> switches it), and opens the chosen one with glow -p.

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
    $style = & $_themeOf 'glow'
    if (-not $style) { $style = 'auto' }
    $list = if (Get-Command fd -ErrorAction Ignore) { { fd --type f --extension md . $Path }.GetNewClosure() }
        else { { Get-ChildItem -LiteralPath $Path -Recurse -File -Filter '*.md' -ErrorAction Ignore | ForEach-Object FullName }.GetNewClosure() }
    Invoke-DFPicker -List $list -Preview "glow.exe -s ""$style"" {}" `
        -Header 'Select Markdown file  [Enter to read it in glow]' -Action { param($file) glow -p $file }
}.GetNewClosure())
Set-Alias -Name fgl -Value Read-MarkdownFile -Scope Global -Force
