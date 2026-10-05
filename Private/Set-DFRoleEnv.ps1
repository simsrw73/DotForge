#Requires -Version 7.0

# Variable name -> the value DotForge last wrote. A current value that differs
# was set outside DotForge (profile, parent shell, system environment).
$script:DFRoleEnvSet = @{}

function Set-DFRoleEnv {
    <#
    .SYNOPSIS
        Sets a role's reserved environment variable for the role's winner, without overriding the user's own choice.
    .DESCRIPTION
        Precedence, highest first: an explicit $DFConfig.Defaults choice
        (-Reason Defaults); then a value set outside DotForge; then an
        auto-picked winner (-Reason priority or sole). When a Defaults choice
        replaces a different outside value, warns with both settings: the
        user's config contradicts itself. A value equal to -Value is left as
        is. Called only by core, from a role block's declarative env.
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
    $current = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if ($current -ceq $Value) {
        $script:DFRoleEnvSet[$Name] = $Value
        return
    }
    $setOutside = $current -and $script:DFRoleEnvSet[$Name] -cne $current
    if ($setOutside) {
        if ($Reason -ne 'Defaults') {
            Write-Verbose "DotForge: keeping $Name='$current' (set outside DotForge) over $Role winner $Winner."
            return
        }
        Write-Warning ("DotForge: $Name was '$current' but `$DFConfig.Defaults.$Role is '$Winner'; using $Winner.`n" +
            '  Remove one of the two settings to silence this.')
    }
    [Environment]::SetEnvironmentVariable($Name, $Value, 'Process')
    $script:DFRoleEnvSet[$Name] = $Value
}
