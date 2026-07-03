#Requires -Version 7.0

function Start-DFCatalogRefreshJob {
    <#
    .SYNOPSIS
        Fire-and-forget background re-warm of one provider's query cache via
        Start-ThreadJob. Exists as its own function so tests can mock it.
    .DESCRIPTION
        The worker runs in its own runspace, imports DotForge fresh, and re-runs
        the provider search with Fresh so the result lands in the cache file for
        the NEXT query. Workers share nothing with the interactive session —
        results travel only through atomic cache-file writes, so no $script:
        state ever crosses threads. ThreadJobs die with the process, so an
        orphan can never outlive the shell.
    .PARAMETER Provider
        The catalog provider name.
    .PARAMETER Query
        The normalized query to re-warm.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Provider,

        [Parameter(Mandatory)]
        [string]$Query
    )

    $key = (ConvertTo-DFCatalogQueryKey -Query $Query).Key
    $jobName = "DotForge.Catalog.$Provider.$key"

    # Sweep finished jobs (name-prefix-filtered so user jobs are never touched),
    # and dedupe an already-in-flight refresh of the same entry.
    Get-Job -Name 'DotForge.Catalog.*' -ErrorAction Ignore |
        Where-Object { $_.State -in 'Completed', 'Failed', 'Stopped' } |
        Remove-Job -Force
    if (Get-Job -Name $jobName -ErrorAction Ignore) { return }

    $manifest = Join-Path $PSScriptRoot '..' 'DotForge.psd1'
    $null = Start-ThreadJob -Name $jobName -ThrottleLimit 4 -ArgumentList $manifest, $Provider, $Query -ScriptBlock {
        param($Manifest, $Provider, $Query)
        try {
            Import-Module $Manifest -Force
            & (Get-Module DotForge) {
                param($p, $q)
                $prov = $script:DFCatalogProviders[$p]
                if ($prov) { $null = & $prov.Search $q $true }
            } $Provider $Query
        } catch {
            # Background refresh is best-effort; the stale cache stays serveable.
        }
    }
}
