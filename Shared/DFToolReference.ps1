function ConvertFrom-DFToolReference {
    <#
    .SYNOPSIS
        Reads one entry of a tool record's requires or after list: a tool name, or role:<name>.
    .DESCRIPTION
        The one definition of the reference syntax. A name starts with a letter or
        digit and continues with letters, digits, '.', '_' or '-'. The role: prefix
        is case-insensitive, as it always was.
    .PARAMETER Reference
        The entry, e.g. 'fzf' or 'role:js-runtime'.
    .EXAMPLE
        ConvertFrom-DFToolReference -Reference 'role:js-runtime'

        Returns Kind 'Role', Name 'js-runtime'.
    .OUTPUTS
        pscustomobject with Kind ('Tool' or 'Role') and Name; nothing when the entry is malformed.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowEmptyString()][AllowNull()][string]$Reference)
    if ($Reference -notmatch '^(?<role>role:)?(?<name>[A-Za-z0-9][A-Za-z0-9._-]*)$') { return }
    [pscustomobject]@{
        Kind = if ($Matches['role']) { 'Role' } else { 'Tool' }
        Name = $Matches['name']
    }
}

function Get-DFRoleMember {
    <#
    .SYNOPSIS
        Returns the tool records, of those given, that join a role.
    .DESCRIPTION
        The one home for "the members of a role" among a set of records (the
        requested tools, the active ones, or every record). Sorted by name.
    .PARAMETER Role
        The role name, e.g. 'js-runtime'.
    .PARAMETER Tools
        The tool records to look through.
    .EXAMPLE
        Get-DFRoleMember -Role 'pager' -Tools $toolDb.Values

        The requested tools that can be the pager.
    .OUTPUTS
        The member records.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Role,
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowNull()][object[]]$Tools
    )
    @($Tools | Where-Object { $_ -and $_.roles -and $_.roles.PSObject.Properties[$Role] }) | Sort-Object name
}
