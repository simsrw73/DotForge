#Requires -Version 7.2

function Write-DFInstallPlan {
    <#
    .SYNOPSIS
        Prints an install plan: stages, manager batches, feeds to add, elevation, and gaps.
    .PARAMETER Plan
        From New-DFInstallPlan.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Plan)
    foreach ($s in $Plan.Stages) {
        $parts = @(foreach ($b in $s.Batches) {
            $feeds = @($b.Items | Where-Object { $_.Ref.Feed } | ForEach-Object { "+ feed '$($_.Ref.Feed.name)' ($($_.Ref.Feed.url))" } | Select-Object -Unique)
            $elev = if ($b.Elevate) { " (needs admin: 1 UAC prompt via $([IO.Path]::GetFileNameWithoutExtension($b.ElevateWith)))" } else { '' }
            "$($b.Manager.name)$elev`: $((@($feeds) + @($b.Items | ForEach-Object { "$($_.Tool) ($($_.Ref.Id))" })) -join ' · ')"
        })
        $parts += @($s.Provided | ForEach-Object { "$($_.Tool) (comes with $($_.ProvidedBy))" })
        Write-Host ("  stage {0}  {1}" -f $s.Number, ($parts -join "`n           "))
    }
    foreach ($g in $Plan.Gaps) {
        Write-Host "  not installed: $($g.Tool) — $($g.Reason)$(if ($g.Dependents) { "; also waiting: $($g.Dependents -join ', ')" })" -ForegroundColor Yellow
    }
}

function Get-DFInstallGapResult {
    <#
    .SYNOPSIS
        Turns a plan's gaps into result rows (Result 'Gap', and 'Skipped' for the tools waiting on one).
    .PARAMETER Plan
        From New-DFInstallPlan.
    .OUTPUTS
        PSCustomObject[].
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Plan)
    foreach ($g in $Plan.Gaps) {
        [pscustomobject]@{ Tool = $g.Tool; Result = 'Gap'; Detail = "$($g.Reason)$(if ($g.Dependents) { "; also waiting: $($g.Dependents -join ', ')" })" }
        foreach ($d in $g.Dependents) { [pscustomobject]@{ Tool = $d; Result = 'Skipped'; Detail = "waits on $($g.Tool)" } }
    }
}

function Write-DFInstallSummary {
    <#
    .SYNOPSIS
        Prints one line per result group: installed, failed (with output), skipped, not found, gaps.
    .PARAMETER Result
        Rows from Invoke-DFInstallPlan and Get-DFInstallGapResult.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Result = @())
    foreach ($g in $Result | Group-Object Result) {
        Write-Host "  $($g.Name): $(@($g.Group | ForEach-Object { if ($_.Result -eq 'Installed') { $_.Tool } else { "$($_.Tool) ($($_.Detail))" } }) -join ', ')"
    }
}
