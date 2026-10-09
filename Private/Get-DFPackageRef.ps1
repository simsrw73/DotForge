#Requires -Version 7.0

function Get-DFPackageRef {
    <#
    .SYNOPSIS
        Reads one packages value: a plain id, or { id, feed }.
    .DESCRIPTION
        A tool's packages map is keyed by source (a system manager or a
        registry). Each value is the package id in that source's default feed,
        or an object naming a feed the manager may have to add first:
        { "id": "ps-dotenv", "feed": { "name": "insomnia", "url": "https://..." } }.
        Every reader of packages goes through this, so a feed object is never
        stringified.
    .PARAMETER Value
        The packages value.
    .OUTPUTS
        PSCustomObject with Id and Feed ($null, or { name; url }); nothing for an empty value.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyString()][object]$Value)
    if ($null -eq $Value -or ($Value -is [string] -and -not $Value)) { return }
    if ($Value -is [string]) { return [pscustomobject]@{ Id = $Value; Feed = $null } }
    [pscustomobject]@{
        Id   = [string]$Value.PSObject.Properties['id']?.Value
        Feed = $Value.PSObject.Properties['feed']?.Value
    }
}
