#Requires -Version 7.0

function New-DFInstallPlan {
    <#
    .SYNOPSIS
        Builds the install layer of the session graph: a source and manager per tool, stages in dependency order, and gaps.
    .DESCRIPTION
        For each named tool, picks a source (Resolve-DFInstallSource). A
        manager that is itself one of the named tools counts as planned, so the
        tool waits for it. A tool with no packages that requires a tool in the
        plan is "provided by" it (npm comes with node). Nothing unnamed is
        added, except a manager the user chose for a gap (-Choice), which
        joins the plan. A tool's stage is one more than the highest stage it
        depends on; within a stage, tools are batched per manager.
    .PARAMETER Name
        The tools to install.
    .PARAMETER ToolDb
        Name -> tool record; must include every named tool and the manager records.
    .PARAMETER IsAvailable
        { param($record) } -> whether that tool is installed now.
    .PARAMETER Choice
        Source -> manager name, from the user (interactive) or -UseDefaults.
    .PARAMETER Via
        Tool -> source for this call (Install-DFTool -Via).
    .OUTPUTS
        PSCustomObject: Items, Stages, Gaps.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string[]]$Name,
        [Parameter(Mandatory)][hashtable]$ToolDb,
        [Parameter(Mandatory)][scriptblock]$IsAvailable,
        [hashtable]$Choice = @{},
        [hashtable]$Via = @{}
    )
    $want = [System.Collections.Generic.List[string]]::new()
    foreach ($n in $Name) { if (-not $want.Contains($n)) { $want.Add($n) } }
    # A manager the user chose for a gap joins the plan when it isn't installed.
    foreach ($m in $Choice.Values) {
        if ($m -and -not $want.Contains($m) -and $ToolDb[$m] -and -not (& $IsAvailable $ToolDb[$m])) { $want.Add($m) }
    }

    # A manager that needs admin rights runs only in an elevated shell or
    # through an elevator (the elevator role, e.g. gsudo) that is installed or
    # installed earlier in this run.
    $elevated = Test-DFElevated
    $elevators = @($ToolDb.Values | Where-Object { $_.roles.PSObject.Properties['elevator'] } | Sort-Object name)
    $elevatorNow = $elevators | Where-Object { & $IsAvailable $_ } | Select-Object -First 1
    $elevatorPlanned = if (-not $elevatorNow) { $elevators | Where-Object { $want.Contains($_.name) } | Select-Object -First 1 }
    $elevator = if ($elevatorNow) { $elevatorNow } else { $elevatorPlanned }
    $canElevate = $elevated -or [bool]$elevator

    $items = [ordered]@{}
    $gaps = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $want.Count; $i++) {
        $t = $ToolDb[$want[$i]]
        if (-not $t) { continue }
        $required = @($t.requires | Where-Object { $_ -and $_ -notlike 'role:*' -and $want.Contains($_) })
        # (@($null?.X) is a one-element array, so test the object first.)
        $hasPackages = $t.packages -and @($t.packages.PSObject.Properties).Count -gt 0
        if (-not $hasPackages -and $required) {
            $items[$t.name] = [pscustomobject]@{ Tool = $t.name; Source = $null; Manager = $null; Ref = $null; ProvidedBy = $required[0]; DependsOn = [string[]]$required; Stage = 0 }
            continue
        }
        $planned = [string[]]@($want | Where-Object { $_ -ne $t.name })
        $r = Resolve-DFInstallSource -Tool $t -ToolDb $ToolDb -IsAvailable $IsAvailable -Planned $planned -Choice $Choice -Via $Via -CanElevate $canElevate
        if ($r.Gap) {
            $gaps.Add([pscustomobject]@{
                Tool = $t.name; Reason = $r.Gap; Options = $r.Options
                Source = (Get-DFInstallSourceOrder -Tool $t -ToolDb $ToolDb -Via $Via 3>$null | Select-Object -First 1)
                Dependents = [string[]]@()
            })
            continue
        }
        $needsElevator = $r.Manager.installs.elevate -and -not $elevated -and $elevatorPlanned
        $deps = @(@($required) + $(if ($want.Contains($r.Manager.name)) { $r.Manager.name }) + $(if ($needsElevator) { $elevatorPlanned.name }) |
            Where-Object { $_ -and $_ -ne $t.name } | Select-Object -Unique)
        $items[$t.name] = [pscustomobject]@{ Tool = $t.name; Source = $r.Source; Manager = $r.Manager; Ref = $r.Ref; ProvidedBy = $null; DependsOn = [string[]]$deps; Stage = 0 }
    }

    # Tools that depend (transitively) on a gap can't be installed either.
    $blocked = @($gaps.Tool)
    $blockedBy = @{}
    do {
        $more = @($items.Values | Where-Object { $_.Tool -notin $blocked -and @($_.DependsOn | Where-Object { $_ -in $blocked }).Count })
        foreach ($b in $more) {
            $blocked += $b.Tool
            # Credit the dependent to the gap it ultimately waits on (directly, or through another blocked tool).
            $root = $b.DependsOn | Where-Object { $_ -in $blocked } | Select-Object -First 1
            while ($root -and -not ($gaps | Where-Object Tool -eq $root)) { $root = $blockedBy[$root] }
            $blockedBy[$b.Tool] = $root
            $g = $gaps | Where-Object Tool -eq $root | Select-Object -First 1
            if ($g) { $g.Dependents += $b.Tool }
            $items.Remove($b.Tool)
        }
    } while ($more)

    # Stage = 1 + the highest stage depended on (a cycle falls back to stage 1).
    $stageOf = @{}
    $visit = $null
    $visit = {
        param($n, $seen)
        if ($stageOf.ContainsKey($n)) { return $stageOf[$n] }
        if ($n -in $seen) { return 0 }
        $deps = @($items[$n].DependsOn | Where-Object { $items.Contains($_) })
        $s = 1 + (@($deps | ForEach-Object { & $visit $_ (@($seen) + $n) }) + 0 | Measure-Object -Maximum).Maximum
        $stageOf[$n] = $s
        $s
    }
    foreach ($n in @($items.Keys)) { $items[$n].Stage = & $visit $n @() }

    $stages = @(foreach ($g in ($items.Values | Group-Object Stage | Sort-Object { [int]$_.Name })) {
        $batches = @(foreach ($b in ($g.Group | Where-Object Manager | Group-Object { $_.Manager.name })) {
            $m = $b.Group[0].Manager
            $elev = [bool]$m.installs.elevate -and -not $elevated
            [pscustomobject]@{
                Manager = $m; Source = $b.Group[0].Source; Items = @($b.Group)
                Elevate = $elev; ElevateWith = $(if ($elev -and $elevator) { $elevator.executable })
            }
        })
        [pscustomobject]@{ Number = [int]$g.Name; Batches = $batches; Provided = @($g.Group | Where-Object ProvidedBy) }
    })
    [pscustomobject]@{ Items = @($items.Values); Stages = $stages; Gaps = @($gaps) }
}
