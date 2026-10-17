#Requires -Version 7.2

function Get-DFRoleDeclaration {
    <#
    .SYNOPSIS
        Reads one field of a role block from the tool that fills the role this session.
    .DESCRIPTION
        For a single role, the session winner's roles.<Role>.<Field>. For a
        category role, the first active member (by name) that declares the
        field. So a tool says what it offers in its own record (zoxide's
        ranked folders, fd's folder scan), and core reads it without naming
        the tool. Returns nothing when no tool in the session declares it.
        Never throws.
    .PARAMETER Role
        The role name, e.g. 'navigation'.
    .PARAMETER Field
        The role-block field, e.g. 'directories'.
    .OUTPUTS
        The field's value, or nothing.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Role, [Parameter(Mandatory)][string]$Field)
    $definition = (Get-DFRoleDb)[$Role]
    if (-not $definition) { return }
    $records = if ($definition.kind -eq 'single') {
        $winner = if ($script:DFSessionRoleWinners) { $script:DFSessionRoleWinners[$Role] }
        if ($winner -and $winner.Winner) { $script:DFSessionToolDb[[string]$winner.Winner] }
    } else {
        $active = @(foreach ($name in @($script:DFSessionToolDb.Keys)) { if (Test-DFToolActive -Name $name) { $script:DFSessionToolDb[$name] } })
        Get-DFRoleMember -Role $Role -Tools $active
    }
    foreach ($record in @($records)) {
        $block = $record.roles.PSObject.Properties[$Role]?.Value
        $value = if ($block) { $block.PSObject.Properties[$Field]?.Value }
        if ($null -ne $value) { return $value }
    }
}
