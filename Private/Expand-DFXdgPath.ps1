#Requires -Version 7.0

function Expand-DFXdgPath {
    <#
    .SYNOPSIS
        Expands ${XDG_*} placeholder tokens in a template string to their
        actual environment variable values.
    .DESCRIPTION
        Replaces ${XDG_CONFIG_HOME}, ${XDG_DATA_HOME}, ${XDG_STATE_HOME} and
        ${XDG_CACHE_HOME} (case-sensitive) with the current env var values.
        A template that contained a token is a path, so the result is
        canonicalized with ConvertTo-DFPath. A template with no token (flag
        strings like LESS or FZF_DEFAULT_OPTS) is returned byte-for-byte.
        Used for every value in a tool's xdg.vars and env blocks.
    .PARAMETER Template
        The string to expand, e.g. '${XDG_CONFIG_HOME}/bat'.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Template)

    $expanded = $Template `
        -creplace '\$\{XDG_CONFIG_HOME\}', { Get-DFXdgPath Config } `
        -creplace '\$\{XDG_DATA_HOME\}',   { Get-DFXdgPath Data } `
        -creplace '\$\{XDG_STATE_HOME\}',  { Get-DFXdgPath State } `
        -creplace '\$\{XDG_CACHE_HOME\}',  { Get-DFXdgPath Cache }

    # Normalize ONLY when an XDG token was present: a token-bearing value is always a
    # filesystem path. Token-less values are literal flag strings (LESS, FZF_*, ...)
    # and must pass through byte-for-byte. See docs/external-dependencies.md.
    if ($Template -cmatch '\$\{XDG_(CONFIG|DATA|STATE|CACHE)_HOME\}') {
        return ConvertTo-DFPath $expanded
    }
    $expanded
}
