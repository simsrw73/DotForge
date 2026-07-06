#Requires -Version 7.0

function ConvertTo-DFNormalizedHomepage {
    <#
    .SYNOPSIS
        Normalizes a homepage URL for cross-catalog comparison: strips
        scheme, a leading www., and trailing slashes; lowercases the result.
    .PARAMETER Url
        The raw homepage URL.
    .OUTPUTS
        [string] — normalized form, or an empty string for a null/empty input.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Url
    )

    if (-not $Url) { return '' }
    ($Url -creplace '^[a-zA-Z]+://', '' -creplace '^www\.', '' -creplace '/+$', '').ToLowerInvariant()
}

function Resolve-DFToolIdentityCandidateRepo {
    <#
    .SYNOPSIS
        Resolves one catalog candidate's real-world identity for the
        tool-identity-guide build pass: a GitHub owner/repo pair when
        discoverable, and a normalized homepage as a weaker fallback.
    .DESCRIPTION
        Resolution order: detail-level RepositoryUrl (via Get-DFCatalogDetail,
        checked through the existing Resolve-DFGitHubRepoUrl matching logic);
        then, only if that fails, a live search for the exact PackageId,
        checking the matching hit's Homepage the same way; if that still
        isn't a GitHub URL, its normalized form is returned as the weaker
        Homepage signal instead. Never throws — any failure at any stage
        yields both fields $null.
    .PARAMETER Source
        Catalog name (scoop, winget, choco, npm, pypi, crates, psgallery).
    .PARAMETER PackageId
        The catalog's package id, exactly as it appears in a Tools/*.json
        packages block or a build/identities/*.jsonc fragment.
    .PARAMETER Fresh
        Bypass the catalog's own detail/search caches for this lookup.
    .OUTPUTS
        [pscustomobject]@{ Repo; Homepage }
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [string]$Source,

        [Parameter(Mandatory)]
        [string]$PackageId,

        [switch]$Fresh
    )

    $repo = $null
    $homepage = $null

    try {
        $detail = Get-DFCatalogDetail -Source $Source -PackageId $PackageId -Fresh:$Fresh
        if ($detail -and $detail.RepositoryUrl) {
            $wrapper = [pscustomobject]@{ Details = [ordered]@{ $Source = $detail }; Homepage = '' }
            $resolved = Resolve-DFGitHubRepoUrl -Info $wrapper
            if ($resolved) { $repo = "$($resolved.Owner)/$($resolved.Repo)".ToLowerInvariant() }
        }
    } catch {
        Write-Verbose "DotForge: identity-guide detail lookup for '$Source`:$PackageId' failed: $_"
    }

    if (-not $repo) {
        try {
            $provider = $script:DFCatalogProviders[$Source]
            if ($provider) {
                $hit = @(& $provider.Search $PackageId $Fresh.IsPresent) |
                    Where-Object { $_.PackageId -ieq $PackageId } | Select-Object -First 1
                if ($hit -and $hit.Homepage) {
                    $wrapper = [pscustomobject]@{ Details = $null; Homepage = $hit.Homepage }
                    $resolved = Resolve-DFGitHubRepoUrl -Info $wrapper
                    if ($resolved) {
                        $repo = "$($resolved.Owner)/$($resolved.Repo)".ToLowerInvariant()
                    } else {
                        $homepage = ConvertTo-DFNormalizedHomepage -Url $hit.Homepage
                    }
                }
            }
        } catch {
            Write-Verbose "DotForge: identity-guide search lookup for '$Source`:$PackageId' failed: $_"
        }
    }

    [pscustomobject]@{ Repo = $repo; Homepage = $homepage }
}
