#Requires -Version 7.2

function Get-DFInstallEnvironment {
    <#
    .SYNOPSIS
        Returns the location variables a package-manager command should see: its tools', its manager's, and those of the tools the manager requires.
    .DESCRIPTION
        An installer that reads a tool's location variables (rustup reads
        RUSTUP_HOME and CARGO_HOME) writes to its default folder unless they
        are set while it runs. The variables come, in this order, from:
          - each -Tool's xdg.vars (the tools being installed, updated or removed);
          - the -Manager's xdg.vars;
          - the xdg.vars of every tool the manager requires, following the
            chain (cargo -> rustup). Only tool references are followed: a
            role: requirement orders, it never names one tool. A name with no
            record is skipped.
        Only tools this session requested count, Active or Missing (not yet
        installed): those are the ones whose variables a session sets. A tool
        in Conflict keeps its data where the user has it, and one the session
        didn't request isn't relocated, so a cargo whose rustup lives in
        ~\.rustup isn't pointed at an empty folder. Without a session nothing
        is set. Only records whose xdg.method is env count, as at registration
        (Set-DFToolXdgConfig), and only xdg.vars: the env map holds flags and
        themes, which an installer doesn't need. When two sources name the
        same variable with different values, the later one wins (the manager
        and its runtimes run the command), with a verbose message.
        Invoke-DFManagerCommand -Environment applies the result.
    .PARAMETER Tool
        The tool records the command acts on; empty for a feed command.
    .PARAMETER Manager
        The manager's tool record.
    .PARAMETER ToolDb
        Name -> tool record, for the manager's requires chain.
    .OUTPUTS
        System.Collections.Specialized.OrderedDictionary: variable -> expanded value.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [AllowEmptyCollection()][pscustomobject[]]$Tool = @(),
        [Parameter(Mandatory)][pscustomobject]$Manager,
        [Parameter(Mandatory)][hashtable]$ToolDb
    )
    $sources = [System.Collections.Generic.List[pscustomobject]]::new()
    foreach ($record in $Tool) { if ($record) { $sources.Add($record) } }
    $sources.Add($Manager)
    # The manager's requires chain, breadth first; the visited set ends a cycle.
    $visited = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $null = $visited.Add($Manager.name)
    $queue = [System.Collections.Generic.Queue[pscustomobject]]::new()
    $queue.Enqueue($Manager)
    while ($queue.Count) {
        foreach ($entry in @($queue.Dequeue().requires)) {
            $reference = ConvertFrom-DFToolReference -Reference $entry
            if (-not $reference -or $reference.Kind -ne 'Tool' -or -not $visited.Add($reference.Name)) { continue }
            $required = $ToolDb[$reference.Name]
            if (-not $required) { continue }
            $sources.Add($required)
            $queue.Enqueue($required)
        }
    }

    $environment = [ordered]@{}
    $from = @{}
    $status = $script:DFSessionStatus
    foreach ($source in $sources) {
        if ($source.xdg.method -ne 'env') { continue }
        if (-not ($status -and $status.Contains($source.name) -and $status[$source.name].State -in 'Active', 'Missing')) { continue }
        foreach ($var in @($source.xdg.vars?.PSObject.Properties)) {
            if (-not $var) { continue }
            $value = Expand-DFXdgPath $var.Value
            if ($environment.Contains($var.Name) -and $environment[$var.Name] -ne $value) {
                Write-Verbose "DotForge: $($var.Name) from $($source.name) ($value) replaces the one from $($from[$var.Name]) ($($environment[$var.Name])) for this command."
            }
            $environment[$var.Name] = $value
            $from[$var.Name] = $source.name
        }
    }
    $environment
}
