#Requires -Version 7.0

function Get-DFToolGroup {
    <#
    .SYNOPSIS
        Lists DotForge's predefined tool groups and their members.
    .DESCRIPTION
        A group is a predefined list of tools you can request as one entry in
        Start-DFSession -Config: Tools = @('+core', '+git') requests every member.
        Groups can also be excluded (ExcludeTools = @('+admin-tools')).
        Use this to see what a group contains before requesting it.
    .PARAMETER Name
        Group names to show, with or without the leading +. Default: all groups.
    .EXAMPLE
        Get-DFToolGroup

        Lists every group with its description and members.
    .EXAMPLE
        Get-DFToolGroup +core | Select-Object -ExpandProperty Tools

        Shows which tools +core requests.
    .OUTPUTS
        DotForge.ToolGroup objects: Name, Description, Tools.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Position = 0)][string[]]$Name)
    $db = Get-DFGroupDb
    $names = if ($Name) { $Name | ForEach-Object { $_.TrimStart('+') } } else { $db.Keys }
    foreach ($n in $names) {
        if (-not $db.Contains($n)) {
            Write-Warning "DotForge: no tool group named '+$n'. Run Get-DFToolGroup to list them."
            continue
        }
        $g = $db[$n]
        $key = @($db.Keys | Where-Object { $_ -eq $n })[0]
        [pscustomobject]@{ PSTypeName = 'DotForge.ToolGroup'; Name = $key; Description = $g.Description; Tools = $g.Tools }
    }
}
