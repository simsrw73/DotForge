#Requires -Version 7.2

function Invoke-DFManagerBatch {
    <#
    .SYNOPSIS
        Runs one install, update or remove for a set of package ids through one manager, and returns a result per id.
    .DESCRIPTION
        The shared executor for Install-DFTool, Update-DFTool and Remove-DFTool.
        The operation comes from the manager's installs block: install is its
        install argv, or its function and args; update and remove are an argv
        or { function; args }. An argv's {id} expands to the ids; a function
        argument that is exactly '{id}' becomes the ids. A manager that batches
        gets one call for every id, otherwise one call per id; in a batched
        call every id gets the call's exit code and output, so callers check
        each tool afterwards. A manager that doesn't declare the operation is
        never called: each id gets ExitCode -1 and "can't <op> through <manager>".
    .PARAMETER Operation
        install, update or remove.
    .PARAMETER Manager
        The manager's tool record.
    .PARAMETER Block
        The manager's installs block for the source (Get-DFInstallBlock).
    .PARAMETER Ids
        Package ids, already feed-qualified where the manager needs it.
    .PARAMETER Elevation
        From Get-DFElevationMethod, for a block that needs administrator rights.
    .OUTPUTS
        PSCustomObject per id: Id, ExitCode, Output.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateSet('install', 'update', 'remove')][string]$Operation,
        [Parameter(Mandatory)][pscustomobject]$Manager,
        [Parameter(Mandatory)][pscustomobject]$Block,
        [Parameter(Mandatory)][string[]]$Ids,
        [pscustomobject]$Elevation
    )
    $spec = if ($Operation -eq 'install') {
        if ($Block.install) { $Block.install } elseif ($Block.function) { [pscustomobject]@{ function = $Block.function; args = $Block.args } }
    } else { $Block.$Operation }
    if (-not $spec) {
        foreach ($id in $Ids) { [pscustomobject]@{ Id = $id; ExitCode = -1; Output = "can't $Operation through $($Manager.name)" } }
        return
    }
    # (A List, not `if { ,$Ids }`: statement output would unroll the wrapper.)
    $groups = [System.Collections.Generic.List[string[]]]::new()
    if ($Block.batch) { $groups.Add($Ids) } else { foreach ($id in $Ids) { $groups.Add(@($id)) } }
    foreach ($group in $groups) {
        $r = if ($spec -is [array]) {
            Invoke-DFManagerCommand -Operation $Operation -Manager $Manager -Argv (Expand-DFInstallArgv -Template $spec -Values @{ ids = $group }) -Elevation $Elevation
        } else {
            $arguments = @{}
            foreach ($p in $spec.args.PSObject.Properties) {
                # ($true -eq '{id}' is true in PowerShell, so check the type first.)
                $arguments[$p.Name] = if ($p.Value -is [string] -and $p.Value -eq '{id}') { [string[]]$group } else { $p.Value }
            }
            Invoke-DFManagerCommand -Operation $Operation -Manager $Manager -Function $spec.function -Arguments $arguments
        }
        foreach ($id in $group) { [pscustomobject]@{ Id = $id; ExitCode = $r.ExitCode; Output = $r.Output } }
    }
}

function Invoke-DFManagerOperation {
    <#
    .SYNOPSIS
        Updates or removes packages through the manager Find-DFToolSource found, asking for administrator rights when its block needs them.
    .PARAMETER Operation
        update or remove.
    .PARAMETER Found
        Find-DFToolSource's result for the first tool (Manager, Block).
    .PARAMETER Ids
        The installed package ids.
    .PARAMETER ToolDb
        Name -> tool record (for the elevator role).
    .OUTPUTS
        PSCustomObject per id: Id, ExitCode, Output.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateSet('update', 'remove')][string]$Operation,
        [Parameter(Mandatory)][pscustomobject]$Found,
        [Parameter(Mandatory)][string[]]$Ids,
        [Parameter(Mandatory)][hashtable]$ToolDb
    )
    $elevation = if ($Found.Block.elevate) {
        $method = Get-DFElevationMethod -ToolDb $ToolDb
        if ($method.Method -ne 'Direct') { $method }
    }
    Invoke-DFManagerBatch -Operation $Operation -Manager $Found.Manager -Block $Found.Block -Ids $Ids -Elevation $elevation
}

function ConvertTo-DFManagerResult {
    <#
    .SYNOPSIS
        Turns one Invoke-DFManagerBatch outcome into a result row: the success word, Skipped (the manager can't do it), or Failed with its last lines.
    .PARAMETER Tool
        Tool name.
    .PARAMETER Outcome
        One Invoke-DFManagerBatch result.
    .PARAMETER Manager
        The manager's name.
    .PARAMETER Success
        The Result for exit code 0 (Updated, Removed).
    .OUTPUTS
        PSCustomObject: Tool, Result, Detail.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string]$Tool, [pscustomobject]$Outcome, [string]$Manager, [string]$Success)
    switch ($Outcome.ExitCode) {
        0 { [pscustomobject]@{ Tool = $Tool; Result = $Success; Detail = "via $Manager" } }
        -1 { [pscustomobject]@{ Tool = $Tool; Result = 'Skipped'; Detail = $Outcome.Output } }
        default {
            $tail = @("$($Outcome.Output)".Trim() -split "`r?`n" | Select-Object -Last 3) -join ' / '
            [pscustomobject]@{ Tool = $Tool; Result = 'Failed'; Detail = "$Manager failed: $tail" }
        }
    }
}
