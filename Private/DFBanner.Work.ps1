#Requires -Version 7.2

# The startup banner's background jobs: one runspace pool, started before tools
# load and collected when Start-DFSession ends. A runspace pool needs no module
# import (ThreadJob would add to startup). See
# docs/superpowers/specs/2026-10-11-startup-banner-design.md.

function Start-DFBannerWork {
    <#
    .SYNOPSIS
        Starts the banner parts' background jobs in one runspace pool, so they run while tools load.
    .PARAMETER Work
        Items with Name, ScriptBlock and ArgumentList, and optionally Partial
        ($true: what the job has output so far is used when it isn't done in
        time). A script block runs in a fresh runspace: it sees its arguments,
        not the caller's variables.
    .OUTPUTS
        A handle for Receive-DFBannerWork.
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Work)
    $count = @($Work).Count
    if (-not $count) { return [pscustomobject]@{ Pool = $null; Jobs = @() } }
    $pool = [runspacefactory]::CreateRunspacePool(1, $count)
    $pool.Open()
    $jobs = foreach ($item in $Work) {
        $shell = [powershell]::Create()
        $shell.RunspacePool = $pool
        $null = $shell.AddScript($item.ScriptBlock.ToString())
        foreach ($argument in @($item.ArgumentList)) { $null = $shell.AddArgument($argument) }
        $output = [System.Management.Automation.PSDataCollection[psobject]]::new()
        $partial = [bool]($item -is [System.Collections.IDictionary] -and $item['Partial'])
        [pscustomobject]@{
            Name = $item.Name; PowerShell = $shell; Output = $output; Partial = $partial
            Async = $shell.BeginInvoke([System.Management.Automation.PSDataCollection[psobject]]$null, $output)
        }
    }
    [pscustomobject]@{ Pool = $pool; Jobs = @($jobs) }
}

function Receive-DFBannerWork {
    <#
    .SYNOPSIS
        Collects the background jobs that finish within WaitMs; stops the rest without waiting for them.
    .PARAMETER Handle
        Start-DFBannerWork result.
    .PARAMETER WaitMs
        Longest total wait.
    .OUTPUTS
        System.Collections.Hashtable: job name -> its output. A job that threw
        is left out; so is one not done in time, unless it is marked Partial
        and has output something.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Handle, [int]$WaitMs)
    $results = @{}
    $deadline = [DateTime]::UtcNow.AddMilliseconds($WaitMs)
    foreach ($job in $Handle.Jobs) {
        $left = [int][Math]::Max(0, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        if ($job.Async.AsyncWaitHandle.WaitOne($left)) {
            try {
                $job.PowerShell.EndInvoke($job.Async) | Out-Null
                if ($job.PowerShell.HadErrors) { Write-Verbose "DotForge: banner job $($job.Name) failed: $($job.PowerShell.Streams.Error | Select-Object -First 1)" }
                else { $results[$job.Name] = @($job.Output) }
            } catch {
                Write-Verbose "DotForge: banner job $($job.Name) failed: $($_.Exception.Message)"
            }
            $job.PowerShell.Dispose()
        } else {
            # Not done: keep what a Partial job has output so far, and leave the
            # job running (it stops itself; see the part). Never wait for it here.
            if ($job.Partial -and $job.Output.Count) { $results[$job.Name] = @($job.Output.ReadAll()) }
        }
    }
    # Closing the pool lets unfinished jobs end on their own; it never blocks here.
    if ($Handle.Pool) { $null = $Handle.Pool.BeginClose($null, $null) }
    $results
}
