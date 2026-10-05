#Requires -Version 7.0

function Get-DFRole {
    <#
    .SYNOPSIS
        Lists DotForge's tool roles, which tools fill each, and which one is active.
    .DESCRIPTION
        A role is a job several tools can do, such as pager or prompt. For a
        single role, one installed tool wins: the one named in
        $DFConfig.Defaults, otherwise the highest-priority installed tool. Only
        the winner sets the role's variables and aliases and installs its shell
        hooks. A category role only groups tools; every member works as usual.

        Winners are computed the way Register-DFTool -All would compute them
        now: from installed tools, minus $DFConfig.SkipTools. Overridden lists
        role variables whose current value is not the winner's, such as a PAGER
        you set yourself, which DotForge keeps unless you also name a tool in
        $DFConfig.Defaults. Read-only; changes nothing.
    .PARAMETER Name
        Role names to show. All roles when omitted.
    .PARAMETER ToolsPath
        Read tool records from this directory instead of the module's Tools
        folder. Intended for tests.
    .EXAMPLE
        Get-DFRole | Format-Table Name, Kind, Winner, Reason, Candidates

        Shows every role and the tool that fills it on this machine.
    .EXAMPLE
        Get-DFRole pager | Select-Object -ExpandProperty Overridden

        Shows whether a pager variable you set outside DotForge is overriding the pager role's winner.
    .OUTPUTS
        DotForge.Role. Name, Kind, Exclusive, Description, Members, Candidates, Winner, Reason, Overridden.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/configuration.md
    #>
    [CmdletBinding()]
    [OutputType('DotForge.Role')]
    param(
        [Parameter(Position = 0)][string[]]$Name,
        [string]$ToolsPath
    )
    $dbArgs = if ($ToolsPath) { @{ ToolsPath = $ToolsPath } } else { @{} }
    $db = Import-DFToolDb @dbArgs
    $roleDb = Get-DFRoleDb
    $set = @(Get-DFRegistrationSet -ToolDb $db -All)
    $winners = Get-DFRoleWinners -ToolDb $db -Tools $set -RoleDb $roleDb

    foreach ($role in $roleDb.Values | Sort-Object name) {
        if ($Name -and $role.name -notin $Name) { continue }
        $members = @($db.Values | Where-Object { $_.roles.PSObject.Properties[$role.name] } | ForEach-Object name | Sort-Object)
        $w = $winners[$role.name]
        $overridden = @(if ($w) {
            $block = $db[$w.Winner].roles.($role.name)
            if ($block.env) {
                foreach ($var in $block.env.PSObject.Properties) {
                    $current = [Environment]::GetEnvironmentVariable($var.Name, 'Process')
                    if ($current -and $current -cne (Expand-DFXdgPath $var.Value)) {
                        [pscustomobject]@{ Name = $var.Name; Value = $current; Source = 'outside DotForge' }
                    }
                }
            }
        })
        $candidates = if ($w) { $w.Candidates } else {
            [string[]]@($set | Where-Object { $_.name -in $members -and (Test-DFToolAvailable -Executable $_.executable -Type $_.type) } | ForEach-Object name | Sort-Object)
        }
        [pscustomobject]@{
            PSTypeName  = 'DotForge.Role'
            Name        = $role.name
            Kind        = $role.kind
            Exclusive   = $role.exclusive
            Description = $role.description
            Members     = [string[]]$members
            Candidates  = [string[]]@($candidates)
            Winner      = ${w}?.Winner
            Reason      = ${w}?.Reason
            Overridden  = $overridden
        }
    }
}
