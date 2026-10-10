#Requires -Version 7.0

# GitHub enrichment for trifle's -GitInfo: repo stats + latest release,
# fetched via gh (authenticated, 5000 req/hr) when available, anonymous REST
# (60 req/hr — fine for single lookups) otherwise. Cached through the catalog
# detail engine under catalogs/github/details/.

function Test-DFGitHubCli {
    <#
    .SYNOPSIS
        True when gh is on PATH and authenticated. Memoized per session in
        $script:DFGitHubCliOk.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if ($null -eq $script:DFGitHubCliOk) {
        $script:DFGitHubCliOk = $false
        if (Get-Command gh -ErrorAction Ignore) {
            $null = gh auth status 2>$null
            $script:DFGitHubCliOk = ($LASTEXITCODE -eq 0)
        }
    }
    $script:DFGitHubCliOk
}

function Invoke-DFGitHubApi {
    <#
    .SYNOPSIS
        Fetches one GitHub REST path ('repos/<o>/<r>', …) via gh or anonymous
        Invoke-RestMethod. Mockable seam; throws on failure.
    .PARAMETER Path
        API path relative to https://api.github.com/.
    .PARAMETER Accept
        Optional Accept header (e.g. 'application/vnd.github.raw' for readmes).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Path,

        [string]$Accept
    )

    if (Test-DFGitHubCli) {
        $ghArgs = @('api', $Path)
        if ($Accept) { $ghArgs += @('-H', "Accept: $Accept") }
        $raw = gh @ghArgs 2>$null
        if ($LASTEXITCODE -ne 0) { throw "gh api $Path failed" }
        $joined = $raw -join "`n"
        # Raw-media responses (readme) aren't JSON — return the text as-is.
        return ($Accept -like '*raw*') ? $joined : ($joined | ConvertFrom-Json)
    }

    $headers = @{ 'User-Agent' = 'DotForge PowerShell module (+https://github.com/simsrw73/DotForge)' }
    if ($Accept) { $headers['Accept'] = $Accept }
    Invoke-RestMethod -Uri "https://api.github.com/$Path" -Headers $headers -TimeoutSec 10
}

function Resolve-DFGitHubRepoUrl {
    <#
    .SYNOPSIS
        Resolves a merged ToolInfo to a GitHub owner/repo pair, checking each
        source detail's RepositoryUrl (canonical order) then the Homepage.
        Returns $null when nothing points at github.com.
    .PARAMETER Info
        A DotForge.ToolInfo (Details may be $null).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Info
    )

    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($Info.Details) {
        foreach ($detail in $Info.Details.Values) {
            if ($detail -and $detail.RepositoryUrl) { $candidates.Add([string]$detail.RepositoryUrl) }
        }
    }
    if ($Info.Homepage) { $candidates.Add([string]$Info.Homepage) }

    foreach ($url in $candidates) {
        if ($url -match 'github\.com[/:]([^/]+)/([^/#?\s]+)') {
            return [pscustomobject]@{
                Owner = $Matches[1]
                Repo  = ($Matches[2] -replace '\.git$', '')
            }
        }
    }
    $null
}

function Get-DFGitHubRepoInfo {
    <#
    .SYNOPSIS
        Fetches (cache-first) GitHub repo stats + latest release as a
        DotForge.RepoInfo, or $null when the repo is unreachable.
    .PARAMETER Owner
        Repository owner.
    .PARAMETER Repo
        Repository name.
    .PARAMETER Fresh
        Force a live fetch.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Owner,

        [Parameter(Mandatory)]
        [string]$Repo,

        [switch]$Fresh
    )

    Get-DFCatalogDetailCache -Provider 'github' -PackageId "$Owner/$Repo" -Fresh:$Fresh -Fetch {
        param($id)
        $repoDoc = Invoke-DFGitHubApi -Path "repos/$id"

        $release = $null
        try { $release = Invoke-DFGitHubApi -Path "repos/$id/releases/latest" } catch {
            Write-Verbose "DotForge: no latest release for $id"
        }

        $toDate = { param($v) if ($v) { try { [datetime]$v } catch { $null } } }

        [pscustomobject]@{
            PSTypeName      = 'DotForge.RepoInfo'
            Owner           = ($id -split '/')[0]
            Repo            = ($id -split '/')[1]
            Stars           = [long]$repoDoc.stargazers_count
            OpenIssues      = [long]$repoDoc.open_issues_count
            PushedAt        = & $toDate $repoDoc.pushed_at
            LatestRelease   = [string]$release.tag_name
            LatestReleaseAt = & $toDate $release.published_at
            Archived        = [bool]$repoDoc.archived
            DefaultBranch   = [string]$repoDoc.default_branch
            Description     = [string]$repoDoc.description
            License         = [string]$repoDoc.license.spdx_id
        }
    }
}
