#Requires -Version 7.2

function Get-DFGroupDb {
    <#
    .SYNOPSIS
        Loads the predefined tool groups (data/groups.json), cached for the session.
    .DESCRIPTION
        Groups are DotForge-owned lists users request as +name in
        Start-DFSession's Tools and ExcludeTools. They are curated data kept in
        one file, a deliberate exception to the plugin rule against central
        tool-keyed lists (docs/plugin-architecture.md). tests/Groups.Tests.ps1
        checks that members exist and that groups don't nest.
    .PARAMETER Path
        Read this file instead of the shipped one. Not cached.
    .OUTPUTS
        System.Collections.Specialized.OrderedDictionary (case-insensitive):
        group name -> @{ Description; Tools }.
    #>
    [CmdletBinding()]
    param([string]$Path)
    if (-not $Path -and $script:DFGroupDb) { return $script:DFGroupDb }
    $file = $Path ? $Path : (Join-Path $PSScriptRoot '..' 'data' 'groups.json')
    $db = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
    $raw = Get-Content $file -Raw | ConvertFrom-Json
    foreach ($g in $raw.PSObject.Properties) {
        $db[$g.Name] = [pscustomobject]@{ Description = [string]$g.Value.description; Tools = [string[]]@($g.Value.tools) }
    }
    if (-not $Path) { $script:DFGroupDb = $db }
    $db
}
