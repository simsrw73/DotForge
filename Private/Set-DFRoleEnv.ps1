#Requires -Version 7.0

function Get-DFRoleEnvState {
    <#
    .SYNOPSIS
        Returns this session's record of role variables DotForge wrote and conflicts it warned about.
    .DESCRIPTION
        Kept in a session global, not a $script: variable, so Import-Module
        DotForge -Force doesn't forget which values DotForge itself wrote.
        Written maps variable -> the value DotForge last wrote: a current value
        that differs was set outside DotForge (profile, parent shell, system
        environment). Warned holds the conflicts already reported this session.
    .OUTPUTS
        System.Collections.Hashtable. @{ Written = @{}; Warned = @{} }.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    if ($global:DFRoleEnvState -isnot [hashtable]) {
        $global:DFRoleEnvState = @{ Written = @{}; Warned = @{} }
    }
    $global:DFRoleEnvState
}

function Set-DFRoleEnv {
    <#
    .SYNOPSIS
        Sets a role's reserved environment variable for the role's winner, without overriding the user's own choice.
    .DESCRIPTION
        Precedence, highest first: an explicit $DFConfig.Defaults choice
        (-Reason Defaults); then a value set outside DotForge; then an
        auto-picked winner (-Reason priority or sole). When a Defaults choice
        replaces a different outside value, warns with both settings, once per
        session for each conflict: the user's config contradicts itself. A
        value equal to -Value is left as is. Called only by core, from a role
        block's declarative env. What DotForge wrote is kept in
        Get-DFRoleEnvState.
    .PARAMETER Name
        The variable.
    .PARAMETER Value
        The winner's value (already expanded).
    .PARAMETER Role
        The role name, for the warning.
    .PARAMETER Winner
        The winning tool, for the warning.
    .PARAMETER Reason
        How the winner was chosen: Defaults, priority or sole.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][string]$Role,
        [Parameter(Mandatory)][string]$Winner,
        [Parameter(Mandatory)][ValidateSet('Defaults', 'priority', 'sole')][string]$Reason
    )
    $state = Get-DFRoleEnvState
    $current = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if ($current -ceq $Value) {
        $state.Written[$Name] = $Value
        return
    }
    $setOutside = $current -and $state.Written[$Name] -cne $current
    if ($setOutside) {
        if ($Reason -ne 'Defaults') {
            Write-Verbose "DotForge: keeping $Name='$current' (set outside DotForge) over $Role winner $Winner."
            return
        }
        # Once per session: `. $PROFILE` re-runs the profile's own assignment,
        # and the same contradiction needs reporting only once.
        $conflict = "$Name|$current|$Winner"
        if (-not $state.Warned.ContainsKey($conflict)) {
            $state.Warned[$conflict] = $true
            Write-Warning ("DotForge: $Name was '$current' but `$DFConfig.Defaults.$Role is '$Winner'; using $Winner.`n" +
                '  Remove one of the two settings to silence this.')
        }
    }
    [Environment]::SetEnvironmentVariable($Name, $Value, 'Process')
    $state.Written[$Name] = $Value
}
