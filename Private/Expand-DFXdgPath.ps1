#Requires -Version 7.0

function script:Expand-DFXdgPath {
    <#
    .SYNOPSIS
        Expands ${XDG_*} placeholder tokens in a template string to their
        actual environment variable values.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Template)

    $expanded = $Template `
        -creplace '\$\{XDG_CONFIG_HOME\}', $Env:XDG_CONFIG_HOME `
        -creplace '\$\{XDG_DATA_HOME\}',   $Env:XDG_DATA_HOME `
        -creplace '\$\{XDG_STATE_HOME\}',  $Env:XDG_STATE_HOME `
        -creplace '\$\{XDG_CACHE_HOME\}',  $Env:XDG_CACHE_HOME

    # Normalize ONLY when an XDG token was present: a token-bearing value is always a
    # filesystem path. Token-less values are literal flag strings (LESS, FZF_*, ...)
    # and must pass through byte-for-byte. See docs/external-dependencies.md.
    if ($Template -cmatch '\$\{XDG_(CONFIG|DATA|STATE|CACHE)_HOME\}') {
        return ConvertTo-DFPath $expanded
    }
    $expanded
}
