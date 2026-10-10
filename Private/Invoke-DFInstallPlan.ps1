#Requires -Version 7.0

function Invoke-DFInstallPlan {
    <#
    .SYNOPSIS
        Runs an install plan stage by stage and reports each tool's result.
    .DESCRIPTION
        For each stage, each manager batch:
          - its feeds are added if missing (listed first, added once);
          - the batch runs as one command when the manager supports batch,
            else one command per tool;
          - a batch the plan marked Elevate runs through its ElevateWith
            executable (the elevator role, e.g. gsudo);
          - when a batch fails, each of its tools is re-checked: one bad id
            doesn't fail the tools that did install.
        After the stage:
          - PATH is merged from the registry;
          - managers with installs.reactivate that installed something are
            re-activated (Register-DFTool -Name), so new runtimes reach PATH;
          - each tool is re-checked with no cached answer.
        A tool whose dependency failed or was skipped is skipped, naming it.
    .PARAMETER Plan
        From New-DFInstallPlan.
    .PARAMETER ToolDb
        Name -> tool record.
    .PARAMETER IsAvailable
        { param($record) } -> whether that tool is installed now.
    .PARAMETER ToolsPath
        Tools folder for re-activation. Default: the module's Tools/.
    .OUTPUTS
        PSCustomObject[]: Tool, Result (Installed, Failed, Skipped, NotFound), Detail.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Plan,
        [Parameter(Mandatory)][hashtable]$ToolDb,
        [Parameter(Mandatory)][scriptblock]$IsAvailable,
        [string]$ToolsPath
    )
    $pathArgs = if ($ToolsPath) { @{ ToolsPath = $ToolsPath } } else { @{} }
    $result = [ordered]@{}
    $set = { param($tool, $r, $d) $result[$tool] = [pscustomobject]@{ Tool = $tool; Result = $r; Detail = $d } }
    $badDep = {
        param($item)
        foreach ($d in $item.DependsOn) {
            if ($result.Contains($d) -and $result[$d].Result -in 'Failed', 'Skipped', 'NotFound') { return $d }
        }
    }
    $skipFor = {
        param($d)
        $why = @{ Failed = 'failed'; Skipped = 'was skipped'; NotFound = "isn't found yet" }[$result[$d].Result]
        "skipped: $d $why"
    }

    foreach ($stage in $Plan.Stages) {
        $reactivate = [System.Collections.Generic.List[string]]::new()
        foreach ($batch in $stage.Batches) {
            $m = $batch.Manager
            $ready = @(foreach ($it in $batch.Items) {
                $d = & $badDep $it
                if ($d) { & $set $it.Tool 'Skipped' (& $skipFor $d) } else { $it }
            })
            if (-not $ready) { continue }
            $elevate = [bool]$batch.Elevate
            if ($elevate -and -not $batch.ElevateWith) {
                foreach ($it in $ready) { & $set $it.Tool 'Skipped' "$($m.name) needs an elevated shell: rerun as administrator, or install an elevator such as gsudo" }
                continue
            }
            # Feeds first, each once, and only those the manager doesn't list yet.
            if ($m.installs.feeds) {
                $feeds = @($ready | Where-Object { $_.Ref.Feed } | ForEach-Object { $_.Ref.Feed } | Sort-Object name -Unique)
                if ($feeds) {
                    $listed = (Invoke-DFInstallCommand -Manager $m -Argv (Expand-DFInstallArgv -Template $m.installs.feeds.list -Values @{})).Output
                    $names = @($listed -split "`r?`n" | ForEach-Object { ($_.Trim() -split '\s+')[0] } | Where-Object { $_ })
                    foreach ($f in $feeds | Where-Object { $_.name -notin $names }) {
                        $r = Invoke-DFInstallCommand -Manager $m -Argv (Expand-DFInstallArgv -Template $m.installs.feeds.add -Values @{ name = $f.name; url = $f.url })
                        if ($r.ExitCode -ne 0) { Write-Warning "DotForge: could not add $($m.name) feed '$($f.name)' ($($f.url))." }
                    }
                }
            }
            $idOf = {
                param($it)
                if ($it.Ref.Feed -and $m.installs.feeds) { $m.installs.feeds.id.Replace('{feed}', $it.Ref.Feed.name).Replace('{id}', $it.Ref.Id) }
                else { $it.Ref.Id }
            }
            # One call for the whole batch when the manager supports it, else one per tool.
            # (A List, not `if { ,$ready }`: statement output would unroll the wrapper.)
            $groups = [System.Collections.Generic.List[object]]::new()
            if ($m.installs.batch) { $groups.Add($ready) } else { foreach ($it in $ready) { $groups.Add(@($it)) } }
            foreach ($group in $groups) {
                $ids = [string[]]@($group | ForEach-Object { & $idOf $_ })
                $r = if ($m.installs.function) {
                    $fnArgs = @{}
                    foreach ($p in $m.installs.args.PSObject.Properties) { $fnArgs[$p.Name] = if ($p.Value -eq '{id}') { $ids } else { $p.Value } }
                    Invoke-DFInstallCommand -Manager $m -Function $m.installs.function -Arguments $fnArgs
                } else {
                    Invoke-DFInstallCommand -Manager $m -Argv (Expand-DFInstallArgv -Template $m.installs.command -Values @{ ids = $ids }) -Elevate:$elevate -ElevateWith $batch.ElevateWith
                }
                foreach ($it in $group) {
                    $t = $ToolDb[$it.Tool]
                    # A failed batch may still have installed some of its tools.
                    $ok = $r.ExitCode -eq 0 -or ($group.Count -gt 1 -and (Test-DFToolAvailable -Executable $t.executable -Type $t.type -Force))
                    if ($ok) { & $set $it.Tool 'Installed' "via $($m.name)" }
                    else {
                        $tail = @("$($r.Output)".Trim() -split "`r?`n" | Select-Object -Last 3) -join ' / '
                        & $set $it.Tool 'Failed' "$($m.name) failed: $tail"
                    }
                }
                if ($r.ExitCode -eq 0 -and $m.installs.reactivate -and -not $reactivate.Contains($m.name)) { $reactivate.Add($m.name) }
            }
        }
        foreach ($p in $stage.Provided) {
            $d = & $badDep $p
            if ($d) { & $set $p.Tool 'Skipped' (& $skipFor $d) } else { & $set $p.Tool 'Installed' "comes with $($p.ProvidedBy)" }
        }

        Update-DFPathFromRegistry
        if ($reactivate.Count) { Register-DFTool -Name $reactivate.ToArray() @pathArgs 3>$null }
        foreach ($it in @($stage.Batches | ForEach-Object { $_.Items }) + @($stage.Provided)) {
            if (-not $it -or $result[$it.Tool].Result -ne 'Installed') { continue }
            $t = $ToolDb[$it.Tool]
            if (-not (Test-DFToolAvailable -Executable $t.executable -Type $t.type -Force)) {
                & $set $it.Tool 'NotFound' "installed, but '$($t.executable)' isn't found yet: open a new shell"
            }
        }
    }
    @($result.Values)
}
