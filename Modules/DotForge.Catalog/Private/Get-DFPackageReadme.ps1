#Requires -Version 7.0

function Get-DFPackageReadme {
    <#
    .SYNOPSIS
        Resolves a readme for a merged ToolInfo: npm registry readme, then the
        GitHub readme (raw media type, cache-first), then a PyPI markdown/plain
        long description. Returns the readme as lines, or $null.
    .PARAMETER Info
        A DotForge.ToolInfo whose Details have been populated.
    .PARAMETER Fresh
        Force a live GitHub fetch.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Info,

        [switch]$Fresh
    )

    if ($Info.Details) {
        $npm = $Info.Details['npm']
        if ($npm -and $npm.Readme) { return [string[]]($npm.Readme -split "\r?\n") }
    }

    $repo = Resolve-DFGitHubRepoUrl -Info $Info
    if ($repo) {
        # Engine path is catalogs/<provider>/details/ — a distinct provider
        # name keeps readmes out of the RepoInfo namespace.
        $wrapper = Get-DFCatalogDetailCache -Provider 'github-readme' -PackageId "$($repo.Owner)/$($repo.Repo)" -Fresh:$Fresh -Fetch {
            param($id)
            $content = Invoke-DFGitHubApi -Path "repos/$id/readme" -Accept 'application/vnd.github.raw'
            $content ? [pscustomobject]@{ Content = [string]$content } : $null
        }
        if ($wrapper -and $wrapper.Content) { return [string[]]($wrapper.Content -split "\r?\n") }
    }

    if ($Info.Details) {
        $pypi = $Info.Details['pypi']
        if ($pypi -and $pypi.Extra -and $pypi.Extra.description -and
            $pypi.Extra.description_content_type -match 'markdown|plain|^$') {
            return [string[]]($pypi.Extra.description -split "\r?\n")
        }
    }

    $null
}
