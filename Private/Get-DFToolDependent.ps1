#Requires -Version 7.2

function Get-DFToolDependent {
    <#
    .SYNOPSIS
        The active tools that can't work without a tool: they require it, or require a role it is the only active member of.
    .DESCRIPTION
        Only active tools count. A tool requiring "role:<r>" depends on the
        tool when the tool is the only active member of <r>; with another
        active member, the role stays filled. With -Transitive, follows the
        requires chains and returns every dependent, deepest first, so
        removing them in that order never leaves a tool without what it needs.
    .PARAMETER Name
        The tool.
    .PARAMETER ToolDb
        Name -> tool record.
    .PARAMETER Active
        Names of the session's active tools.
    .PARAMETER Transitive
        Follow requires chains.
    .OUTPUTS
        System.String[]. Tool names.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][hashtable]$ToolDb,
        [string[]]$Active = @(),
        [switch]$Transitive
    )
    $direct = {
        param($target)
        $record = $ToolDb[$target]
        $soleRoles = @(if ($record) {
            foreach ($role in $record.roles.PSObject.Properties.Name) {
                $members = @($Active | Where-Object { $ToolDb[$_] -and $ToolDb[$_].roles.PSObject.Properties[$role] })
                if ($members.Count -eq 1) { "role:$role" }
            }
        })
        foreach ($other in $Active) {
            if ($other -eq $target -or -not $ToolDb[$other]) { continue }
            $needs = @($ToolDb[$other].requires)
            if ($target -in $needs -or @($needs | Where-Object { $_ -in $soleRoles }).Count) { $other }
        }
    }
    if (-not $Transitive) { return [string[]]@(& $direct $Name) }

    # Post-order walk: a dependent's own dependents come before it.
    $ordered = [System.Collections.Generic.List[string]]::new()
    $visit = $null
    $visit = {
        param($target, $path)
        foreach ($dependent in & $direct $target) {
            if ($dependent -in $path -or $ordered.Contains($dependent)) { continue }
            & $visit $dependent (@($path) + $dependent)
            $ordered.Add($dependent)
        }
    }
    & $visit $Name @($Name)
    [string[]]$ordered.ToArray()
}
