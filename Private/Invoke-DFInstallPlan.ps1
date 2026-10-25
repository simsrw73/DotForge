#Requires -Version 7.2

function Invoke-DFInstallPlan {
    <#
    .SYNOPSIS
        Runs an install plan stage by stage and reports each tool's result.
    .DESCRIPTION
        For each stage, each manager batch:
          - its feeds are added if missing (listed first, added once);
          - the batch runs as one command when the manager supports batch,
            else one command per tool;
          - a batch with an Elevation runs the way it says (an elevator such
            as gsudo, Windows' sudo, or a separate admin window), or is
            reported as failed when no one can answer the admin prompt;
          - when a batch fails, each of its tools is re-checked: one bad id
            doesn't fail the tools that did install;
          - every command sees the location variables of its tools, its
            manager and the tools the manager requires
            (Get-DFInstallEnvironment); a feed command only the manager's.
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
            $blk = $batch.Block
            $ready = @(foreach ($it in $batch.Items) {
                $d = & $badDep $it
                if ($d) { & $set $it.Tool 'Skipped' (& $skipFor $d) } else { $it }
            })
            if (-not $ready) { continue }
            # Feeds first, each once, and only those the manager doesn't list yet.
            if ($blk.feeds) {
                $feedEnvironment = Get-DFInstallEnvironment -Manager $m -ToolDb $ToolDb
                $feeds = @($ready | Where-Object { $_.Ref.Feed } | ForEach-Object { $_.Ref.Feed } | Sort-Object name -Unique)
                if ($feeds) {
                    $listed = (Invoke-DFManagerCommand -Operation install -Manager $m -Argv (Expand-DFInstallArgv -Template $blk.feeds.list -Values @{}) -Environment $feedEnvironment).Output
                    $names = @($listed -split "`r?`n" | ForEach-Object { ($_.Trim() -split '\s+')[0] } | Where-Object { $_ })
                    foreach ($f in $feeds | Where-Object { $_.name -notin $names }) {
                        $r = Invoke-DFManagerCommand -Operation install -Manager $m -Argv (Expand-DFInstallArgv -Template $blk.feeds.add -Values @{ name = $f.name; url = $f.url }) -Environment $feedEnvironment
                        if ($r.ExitCode -ne 0) { Write-Warning "DotForge: could not add $($m.name) feed '$($f.name)' ($($f.url))." }
                    }
                }
            }
            $idOf = {
                param($it)
                if ($it.Ref.Feed -and $blk.feeds) { $blk.feeds.id.Replace('{feed}', $it.Ref.Feed.name).Replace('{id}', $it.Ref.Id) }
                else { $it.Ref.Id }
            }
            # One call for the whole batch when the manager supports it, else one per tool.
            $ids = [string[]]@($ready | ForEach-Object { & $idOf $_ })
            $environment = Get-DFInstallEnvironment -Tool @($ready | ForEach-Object { $ToolDb[$_.Tool] }) -Manager $m -ToolDb $ToolDb
            $results = @(Invoke-DFManagerBatch -Operation install -Manager $m -Block $blk -Ids $ids -Elevation $batch.Elevation -Environment $environment)
            $batched = $blk.batch -and $ready.Count -gt 1
            for ($n = 0; $n -lt $ready.Count; $n++) {
                $it = $ready[$n]; $r = $results[$n]
                $t = $ToolDb[$it.Tool]
                # A failed batch may still have installed some of its tools.
                $ok = $r.ExitCode -eq 0 -or ($batched -and (Test-DFToolAvailable -Executable $t.executable -Type $t.type -Force))
                if ($ok) { & $set $it.Tool 'Installed' "via $($m.name)$(if ($it.AvoidReason) { " ($($it.AvoidReason))" })" }
                else { & $set $it.Tool 'Failed' (Format-DFManagerFailure -Tool $it.Tool -Manager $m.name -Output $r.Output) }
            }
            if (@($results | Where-Object ExitCode -eq 0).Count -and $blk.reactivate -and -not $reactivate.Contains($m.name)) { $reactivate.Add($m.name) }
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
