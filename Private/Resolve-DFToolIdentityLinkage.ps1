#Requires -Version 7.0

function Resolve-DFToolIdentityLinkage {
    <#
    .SYNOPSIS
        Determines one tool's identity-guide linkedVia tier by resolving
        every declared catalog package and checking for cross-catalog
        corroboration: repo agreement (strongest), homepage agreement
        (weaker fallback), or curated (no automated corroboration).
    .PARAMETER ToolName
        The tool's canonical key (used only for Verbose diagnostics).
    .PARAMETER Packages
        A flat object of catalog name -> package id (a Tools/*.json
        packages block, or a build/identities/*.jsonc fragment entry's
        packages). Null/empty package values are skipped.
    .PARAMETER Fresh
        Bypass catalog/GitHub caches for every candidate resolution.
    .OUTPUTS
        [pscustomobject]@{ LinkedVia; Repo } — LinkedVia is 'repo', 'homepage',
        or 'curated'; Repo is a full https://github.com/... URL when
        LinkedVia is 'repo', otherwise $null.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [string]$ToolName,

        [Parameter(Mandatory)]
        [PSCustomObject]$Packages,

        [switch]$Fresh
    )

    $repos = [ordered]@{}
    $homepages = [ordered]@{}
    foreach ($prop in $Packages.PSObject.Properties) {
        if (-not $prop.Value) { continue }
        $resolved = Resolve-DFToolIdentityCandidateRepo -Source $prop.Name -PackageId ([string]$prop.Value) -Fresh:$Fresh
        if ($resolved.Repo) { $repos[$prop.Name] = $resolved.Repo }
        elseif ($resolved.Homepage) { $homepages[$prop.Name] = $resolved.Homepage }
    }

    $distinctRepos = @($repos.Values | Select-Object -Unique)
    if ($distinctRepos.Count -eq 1 -and $repos.Count -ge 2) {
        return [pscustomobject]@{ LinkedVia = 'repo'; Repo = "https://github.com/$($distinctRepos[0])" }
    }

    $distinctHomepages = @($homepages.Values | Select-Object -Unique)
    if ($distinctHomepages.Count -eq 1 -and $homepages.Count -ge 2) {
        return [pscustomobject]@{ LinkedVia = 'homepage'; Repo = $null }
    }

    Write-Verbose "DotForge: '$ToolName' has no automated cross-catalog corroboration — recorded as curated"
    [pscustomobject]@{ LinkedVia = 'curated'; Repo = $null }
}
