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
        -replace '\$\{XDG_CONFIG_HOME\}', $Env:XDG_CONFIG_HOME `
        -replace '\$\{XDG_DATA_HOME\}',   $Env:XDG_DATA_HOME `
        -replace '\$\{XDG_STATE_HOME\}',  $Env:XDG_STATE_HOME `
        -replace '\$\{XDG_CACHE_HOME\}',  $Env:XDG_CACHE_HOME
}
