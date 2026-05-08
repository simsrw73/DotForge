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

    $Template `
        -creplace '\$\{XDG_CONFIG_HOME\}', $Env:XDG_CONFIG_HOME `
        -creplace '\$\{XDG_DATA_HOME\}',   $Env:XDG_DATA_HOME `
        -creplace '\$\{XDG_STATE_HOME\}',  $Env:XDG_STATE_HOME `
        -creplace '\$\{XDG_CACHE_HOME\}',  $Env:XDG_CACHE_HOME
}
