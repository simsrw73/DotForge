#Requires -Version 7.2

# Names in the Windows Fonts registry keys: "<Face> <Style> (TrueType)", or, for a
# font registered by its file, "<FaceNoSpaces>-<Style> (TrueType)". Shared because the
# core detects Nerd Fonts and Install-DFNerdFont (DotForge.Helpers) registers them.

function Test-DFNerdFontName {
    <#
    .SYNOPSIS
        True when a Fonts registry value name is a Nerd Font's.
    .DESCRIPTION
        Matches, ignoring case and spaces, "NerdFont" anywhere, or a name ending in
        NF, NFM or NFP (the short family names Nerd Fonts uses, e.g. "CaskaydiaCove
        NF") before an optional style and the "(TrueType)"/"(OpenType)" suffix.
    .PARAMETER Name
        The registry value name.
    .OUTPUTS
        System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Name)
    $bare = $Name -replace '\s*\((TrueType|OpenType)\)\s*$', ''
    if (($bare -replace '\s', '') -match 'NerdFont') { return $true }
    $bare -match '(^|[\s-])NF[MP]?(\s|-|$)'
}

function ConvertTo-DFFontFaceName {
    <#
    .SYNOPSIS
        The family name a terminal lists for a Fonts registry value name or font file name.
    .DESCRIPTION
        Drops the "(TrueType)" suffix, a file extension and the style ("Regular",
        "BoldItalic", ...), and spaces a compact Nerd Font name: "HackNerdFontMono-Bold"
        becomes "Hack Nerd Font Mono".
    .PARAMETER Name
        A registry value name or a font file name.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name)
    $face = $Name -replace '\s*\((TrueType|OpenType)\)\s*$', '' -replace '\.(ttf|otf)$', ''
    # A file-style name: the style follows the last '-'.
    if ($face -notmatch '\s' -and $face -match '^(.+)-[^-]+$') { $face = $Matches[1] }
    $face = $face -creplace '(?<=\S)NerdFont(?=Mono|Propo|$)', ' Nerd Font' -creplace 'Nerd Font(Mono|Propo)$', 'Nerd Font $1'
    $styles = 'Regular|Bold|Italic|BoldItalic|Light|LightItalic|Medium|MediumItalic|SemiBold|SemiBoldItalic|ExtraLight|ExtraLightItalic|ExtraBold|ExtraBoldItalic|Thin|ThinItalic|Black|BlackItalic|SemiLight|SemiLightItalic|Retina|Book|Oblique'
    ($face -replace "(\s+($styles))+$", '').Trim()
}
