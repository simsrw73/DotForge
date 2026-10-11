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
