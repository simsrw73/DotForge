#Requires -Version 7.0

function Invoke-DFTopoSort {
    <#
    .SYNOPSIS
        Topological sort of tool objects using Kahn's algorithm.
        Tools whose dependsOn deps are not in the input set are processed normally.
        Cycles emit a warning and fall back to original order.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [object[]]$Tools = @()
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
        $deps = $t.PSObject.Properties['dependsOn']?.Value
        if (-not $deps) { continue }
        foreach ($dep in @($deps)) {
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

    if ($sorted.Count -ne $Tools.Count) {
        Write-Warning 'DotForge: circular dependency detected in tool dependsOn — falling back to original order'
        return $Tools
    }

    return $sorted.ToArray()
}
