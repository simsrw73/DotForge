#Requires -Version 7.2

function Invoke-DFTopoSort {
    <#
    .SYNOPSIS
        Topological sort of tool objects using Kahn's algorithm.
        Tools whose after deps are not in the input set are processed normally.
        Cycles emit a warning and fall back to original order.
    .PARAMETER Tools
        Tool records (parsed Tools/*.json objects) to order; each may carry a
        after array of tool names. Names compare case-insensitively.
    .PARAMETER ExtraEdges
        More ordering on top of after: tool name -> names it must come after
        (what requires adds). Names outside -Tools are ignored, as for after.
    .OUTPUTS
        System.Object[]. The same records, dependencies first.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [object[]]$Tools = @(),
        [hashtable]$ExtraEdges = @{}
    )

    if ($null -eq $Tools -or $Tools.Count -eq 0) { return @() }

    $toolNames = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($t in $Tools) { [void]$toolNames.Add($t.name) }

    $inDegree   = @{}
    $successors = @{}
    foreach ($t in $Tools) {
        $inDegree[$t.name]   = 0
        $successors[$t.name] = [System.Collections.Generic.List[string]]::new()
    }

    foreach ($t in $Tools) {
        foreach ($dep in @(@($t.after) + @($ExtraEdges[$t.name]) | Where-Object { $_ } | Select-Object -Unique)) {
            # A dependency outside this call's set (not installed, skipped, or
            # not requested) imposes no order, so it adds no edge.
            if ($toolNames.Contains($dep)) {
                $successors[$dep].Add($t.name)
                $inDegree[$t.name]++
            }
        }
    }

    # Seed the queue in original array order to preserve stable ordering
    $queue = [System.Collections.Generic.Queue[string]]::new()
    foreach ($t in $Tools) {
        if ($inDegree[$t.name] -eq 0) { $queue.Enqueue($t.name) }
    }

    $nameToTool = @{}
    foreach ($t in $Tools) { $nameToTool[$t.name] = $t }

    $sorted = [System.Collections.Generic.List[object]]::new()
    while ($queue.Count -gt 0) {
        $name = $queue.Dequeue()
        $sorted.Add($nameToTool[$name])
        foreach ($successor in $successors[$name]) {
            $inDegree[$successor]--
            if ($inDegree[$successor] -eq 0) { $queue.Enqueue($successor) }
        }
    }

    # Tools on a cycle never reach in-degree 0, so they never leave the queue
    # stage; any shortfall means a cycle. Registering in the caller's order is
    # safer than dropping those tools.
    if ($sorted.Count -ne $Tools.Count) {
        Write-Warning 'DotForge: circular dependency detected in tool after/requires — falling back to original order'
        return $Tools
    }

    return $sorted.ToArray()
}
