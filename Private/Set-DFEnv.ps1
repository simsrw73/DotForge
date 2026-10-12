#Requires -Version 7.2

function Get-DFEnvState {
    <#
    .SYNOPSIS
        Returns this session's record of the environment variables DotForge wrote, warned about and kept.
    .DESCRIPTION
        Kept in a session global, not a $script: variable, so Import-Module
        DotForge -Force doesn't forget which values DotForge itself wrote.
        Written maps variable -> the value DotForge last wrote: a current value
        that differs was set outside DotForge (profile, parent shell, system
        environment). Warned holds the conflicts already reported this session.
        Kept maps tool -> variable -> a note naming the outside value kept over
        what the tool wanted (Get-DFEnvKeptNote).
    .OUTPUTS
        System.Collections.Hashtable. @{ Written = @{}; Warned = @{}; Kept = @{} }.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    if ($global:DFEnvState -isnot [hashtable]) {
        $global:DFEnvState = @{ Written = @{}; Warned = @{}; Kept = @{} }
    }
    $global:DFEnvState
}

function Set-DFEnv {
    <#
    .SYNOPSIS
        Sets an environment variable for a tool, without overriding a value the user set outside DotForge.
    .DESCRIPTION
        The one precedence rule for every variable DotForge writes (xdg.vars,
        env, theme.env, role env, theme apply functions):
          1. The current value already equals -Value: nothing to do.
          2. The variable is unset, or still holds what DotForge last wrote: write it.
          3. It was set outside DotForge: keep it and note that for -Tool's
             status, unless -ExplicitReason says the user chose this value in
             DotForge's config (or by running a command). Then overwrite it and
             warn, once per session for each conflict, naming both settings.
        Writing or matching a variable drops the tool's kept note for it.
    .PARAMETER Name
        The variable.
    .PARAMETER Value
        The value to write (already expanded).
    .PARAMETER Tool
        The tool the value belongs to; a kept value is noted against it.
    .PARAMETER ExplicitReason
        Set when the user chose the value explicitly, e.g.
        "`$DFConfig.Defaults.pager is 'moar'; using moar". It completes the
        warning "<Name> was '<current>' but <reason>."
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][string]$Tool,
        [string]$ExplicitReason
    )
    $state = Get-DFEnvState
    $current = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if ($current -ceq $Value) {
        $state.Written[$Name] = $Value
        if ($state.Kept[$Tool]) { $state.Kept[$Tool].Remove($Name) }
        return
    }
    $setOutside = $current -and $state.Written[$Name] -cne $current
    if ($setOutside) {
        if (-not $ExplicitReason) {
            Write-Verbose "DotForge: keeping $Name='$current' (set outside DotForge) over $Tool's '$Value'."
            if (-not $state.Kept[$Tool]) { $state.Kept[$Tool] = [ordered]@{} }
            $state.Kept[$Tool][$Name] = "$Name kept as set outside DotForge ('$(Format-DFEnvValue $current)'); DotForge wanted '$(Format-DFEnvValue $Value)'"
            return
        }
        # Once per session: `. $PROFILE` re-runs the profile's own assignment,
        # and the same contradiction needs reporting only once.
        $conflict = "$Name|$current|$ExplicitReason"
        if (-not $state.Warned.ContainsKey($conflict)) {
            $state.Warned[$conflict] = $true
            Write-Warning ("DotForge: $Name was '$(Format-DFEnvValue $current)' but $ExplicitReason.`n" +
                '  Remove one of the two settings to silence this.')
        }
    }
    [Environment]::SetEnvironmentVariable($Name, $Value, 'Process')
    $state.Written[$Name] = $Value
    if ($state.Kept[$Tool]) { $state.Kept[$Tool].Remove($Name) }
}

function Get-DFEnvKeptNote {
    <#
    .SYNOPSIS
        Returns the notes for variables kept over what a tool wanted, in the order they were kept.
    .PARAMETER Tool
        The tool name.
    .OUTPUTS
        System.String[].
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$Tool)
    $notes = (Get-DFEnvState).Kept[$Tool]
    if ($notes) { [string[]]@($notes.Values) }
}

function Clear-DFEnvKeptNote {
    <#
    .SYNOPSIS
        Forgets a tool's kept-variable notes; each registration of the tool starts with this.
    .PARAMETER Tool
        The tool name.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Tool)
    (Get-DFEnvState).Kept.Remove($Tool)
}

function Format-DFEnvValue {
    <#
    .SYNOPSIS
        Shortens a variable's value for a message: over 60 characters keeps the first 57 and adds "...".
    .PARAMETER Value
        The value.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][AllowNull()][string]$Value)
    if ($Value.Length -gt 60) { $Value.Substring(0, 57) + '...' } else { $Value }
}
