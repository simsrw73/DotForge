#Requires -Version 7.2

function Set-DFRoleFallback {
    <#
    .SYNOPSIS
        Applies each single role's fallback env when no tool in the session fills the role.
    .DESCRIPTION
        A role in data/roles.json may name a fallback (pager: PAGER = more). It applies
        only when this activation picked no winner and no member is active in the session
        (a later Register-DFTool -Name for another tool must not undo an earlier winner).
        Written through Set-DFEnv, so a value set outside DotForge is kept.
    .PARAMETER RoleDb
        Get-DFRoleDb.
    .PARAMETER RoleWinners
        This activation's Get-DFRoleWinners result.
    .PARAMETER SessionTools
        The session's tool records (each role's members are found among them).
    .OUTPUTS
        System.String[]: the roles whose fallback was applied.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][hashtable]$RoleDb,
        [Parameter(Mandatory)][hashtable]$RoleWinners,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$SessionTools
    )
    [string[]]@(foreach ($role in $RoleDb.Values) {
        if (-not $role.fallback -or $RoleWinners.ContainsKey($role.name)) { continue }
        $active = @(Get-DFRoleMember -Role $role.name -Tools $SessionTools | Where-Object { Test-DFToolActive $_.name })
        if ($active) { continue }
        foreach ($var in $role.fallback.env.PSObject.Properties) {
            Set-DFEnv -Name $var.Name -Value ([string]$var.Value) -Tool "$($role.name) role"
        }
        $role.name
    })
}
