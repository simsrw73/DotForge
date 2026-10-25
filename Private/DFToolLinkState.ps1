#Requires -Version 7.2

# This session's links per tool (Test-DFToolOwnership sets them; registration reads them).
# Session state, so it lives in the core, not Shared/.

function Set-DFToolLinkState {
    <#
    .SYNOPSIS
        Records, for this session, the links a tool's ownership check made or kept (registration reads them).
    .PARAMETER Name
        The tool.
    .PARAMETER Links
        Its ownership entry's links (key, path, target, made); empty when it has none.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [AllowEmptyCollection()][object[]]$Links = @())
    if ($script:DFToolLinks -isnot [hashtable]) { $script:DFToolLinks = @{} }
    $script:DFToolLinks[$Name] = @($Links)
}

function Get-DFToolLinkedVar {
    <#
    .SYNOPSIS
        The variables of a tool that point at linked existing data, which registration must not set.
    .PARAMETER Name
        The tool.
    .OUTPUTS
        System.String[].
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$Name)
    if ($script:DFToolLinks -isnot [hashtable] -or -not $script:DFToolLinks.ContainsKey($Name)) { return [string[]]@() }
    [string[]]@($script:DFToolLinks[$Name] | ForEach-Object key | Where-Object { $_ -cnotmatch '^\$\{' })
}

function Test-DFInLinkedPath {
    <#
    .SYNOPSIS
        Whether a path is a tool's linked XDG location or inside it (DotForge never writes there: it's the user's existing data).
    .PARAMETER Name
        The tool.
    .PARAMETER Path
        A canonical path.
    .OUTPUTS
        System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Path)
    if ($script:DFToolLinks -isnot [hashtable] -or -not $script:DFToolLinks.ContainsKey($Name)) { return $false }
    $sep = [IO.Path]::DirectorySeparatorChar
    foreach ($link in $script:DFToolLinks[$Name]) {
        if ($Path -eq $link.path -or $Path.StartsWith($link.path + $sep, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    $false
}
