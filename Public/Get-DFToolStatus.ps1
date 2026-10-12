#Requires -Version 7.2

function Get-DFToolStatus {
    <#
    .SYNOPSIS
        Shows what this session's Start-DFSession decided for each requested tool.
    .DESCRIPTION
        One object per requested (or excluded) tool:
            Name         the tool
            State        Active, Missing (not installed), Blocked (installed,
                         but a tool it requires isn't active), Failed (setup or
                         activation threw), Excluded (by ExcludeTools), or
                         Conflict (its old config location holds your config;
                         see Resolve-DFToolConflict)
            RequestedBy  Tools, the +group that requested it, or Register-DFTool
            Roles        roles it won this session, e.g. prompt
            Detail       why it is Missing, Failed or in Conflict, or the tool standing in for it
        It reports what already happened, so it is instant. Pipe -Missing
        into Install-DFTool to install those tools.
    .PARAMETER Name
        Only these tools.
    .PARAMETER Missing
        Only tools that aren't installed.
    .PARAMETER Failed
        Only tools that failed to load.
    .PARAMETER Conflict
        Only tools left inactive because their old config location holds your
        config. Resolve-DFToolConflict hands one over to DotForge.
    .EXAMPLE
        Get-DFToolStatus

        Lists every requested tool and what happened to it.
    .EXAMPLE
        Get-DFToolStatus -Missing

        Lists the requested tools that aren't installed; Install-DFTool -Missing installs them.
    .EXAMPLE
        Get-DFToolStatus -Conflict

        Lists the requested tools DotForge left alone because your existing config would be hidden.
    .OUTPUTS
        DotForge.ToolStatus objects.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)][string[]]$Name,
        [switch]$Missing,
        [switch]$Failed,
        [switch]$Conflict
    )
    if (-not $script:DFSessionStatus) {
        Write-Warning 'DotForge: no session yet. Start-DFSession -Config @{ Tools = @(...) } configures the tools you request.'
        return
    }
    Add-DFInstallHint
    foreach ($s in $script:DFSessionStatus.Values) {
        if ($Name -and $s.Name -notin $Name) { continue }
        if ($Missing -and $s.State -ne 'Missing') { continue }
        if ($Failed -and $s.State -ne 'Failed') { continue }
        if ($Conflict -and $s.State -ne 'Conflict') { continue }
        $s
    }
}
