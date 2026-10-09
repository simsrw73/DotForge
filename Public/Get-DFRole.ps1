#Requires -Version 7.0

function Get-DFRole {
    <#
    .SYNOPSIS
        Lists DotForge's tool roles, which tools fill each, and which one is active.
    .DESCRIPTION
        A role is a job several tools can do, such as pager or prompt. For a
        single role, one installed tool wins: the one named in Defaults,
        otherwise the highest-priority installed tool. Only
        the winner sets the role's variables and aliases and installs its shell
        hooks. A category role only groups tools; every member works as usual.

        After Start-DFSession, it shows the session's view: members, candidates
        and winners among the tools you requested, as they were decided at
        load. Before a session (or with -ToolsPath) it considers every tool
        DotForge knows. Overridden lists
        role variables whose current value is not the winner's. Source says
        why: 'outside DotForge' is a value such as a PAGER you set yourself,
        which DotForge keeps unless you also name a tool in Defaults;
        'DotForge (earlier winner)' is a value DotForge wrote for a different
        winner earlier in this session. Read-only; changes nothing.
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
    $roleDb = Get-DFRoleDb
    if ($script:DFSessionRoleWinners -and -not $ToolsPath) {
        # In a session: the session's own view, among the tools you requested.
        # No extra records are read, and it matches what is actually active.
        $db = $script:DFSessionToolDb
        $set = @($db.Values)
        $winners = $script:DFSessionRoleWinners
    } else {
        $dbArgs = if ($ToolsPath) { @{ ToolsPath = $ToolsPath } } else { @{} }
        $db = Import-DFToolDb @dbArgs
        $set = @($db.Values)
        $winners = Get-DFRoleWinners -ToolDb $db -Tools $set -RoleDb $roleDb
    }

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
                        $source = if ((Get-DFRoleEnvState).Written[$var.Name] -ceq $current) { 'DotForge (earlier winner)' } else { 'outside DotForge' }
                        [pscustomobject]@{ Name = $var.Name; Value = $current; Source = $source }
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
