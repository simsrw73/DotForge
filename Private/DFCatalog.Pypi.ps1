#Requires -Version 7.0

# PyPI catalog provider (query-cache kind). PyPI has NO supported search API —
# only exact-name lookups via the JSON API work, so multi-word keyword queries
# yield no PyPI results (documented limitation). Installed state comes from pipx.

function Invoke-DFCatalogPypiFetch {
    <#
    .SYNOPSIS
        Live PyPI JSON-API lookup for an exact package name, trying the -/_
        normalized twin as well.
    .PARAMETER Query
        Normalized query text.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Query
    )

    if ($Query -match ' ') { return @() }

    $names = @($Query)
    $twin = $Query.Contains('-') ? ($Query -replace '-', '_') : ($Query -replace '_', '-')
    if ($twin -ne $Query) { $names += $twin }

    foreach ($name in $names) {
        try {
            $doc = Invoke-RestMethod -Uri "https://pypi.org/pypi/$([uri]::EscapeDataString($name))/json" -TimeoutSec 10
        } catch {
            Write-Verbose "DotForge: PyPI lookup for '$name' failed (probably not a package): $_"
            continue
        }
        $info = $doc.info
        $homepage = [string]($info.home_page ? $info.home_page : $info.project_urls.Homepage)

        return New-DFToolSourceInfo -Source 'pypi' `
            -PackageId $info.name -Name $info.name `
            -Description ([string]$info.summary) `
            -LatestVersion ([string]$info.version) `
            -Homepage $homepage `
            -License ([string]$info.license) `
            -MatchKind 'exact-name'
    }

    @()
}

function Search-DFCatalogPypi {
    <#
    .SYNOPSIS
        Cache-first PyPI lookup (exact names only — PyPI has no search API).
    .PARAMETER Query
        Package name.
    .PARAMETER Fresh
        Block on a live fetch.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Query,

        [switch]$Fresh
    )

    Search-DFCatalogQueryCache -Provider 'pypi' -Query $Query -Fresh:$Fresh `
        -Fetch { param($q) Invoke-DFCatalogPypiFetch -Query $q }
}

function Invoke-DFCatalogPipxList {
    <#
    .SYNOPSIS
        Runs `pipx list --json` when pipx is available. Mockable seam.
    #>
    [CmdletBinding()]
    param()

    if (Get-Command pipx -ErrorAction Ignore) {
        pipx list --json 2>$null
    }
}

function Get-DFCatalogPypiInstalled {
    <#
    .SYNOPSIS
        Lists pipx-installed packages and versions.
    #>
    [CmdletBinding()]
    param()

    $json = Invoke-DFCatalogPipxList
    if (-not $json) { return }

    try { $data = ($json -join '') | ConvertFrom-Json } catch { return }
    if (-not $data.venvs) { return }

    foreach ($name in $data.venvs.PSObject.Properties.Name) {
        $main = $data.venvs.$name.metadata.main_package
        [pscustomobject]@{
            Source           = 'pypi'
            Name             = $name
            PackageId        = $name
            InstalledVersion = [string]$main.package_version
        }
    }
}

function Invoke-DFCatalogPypiDetailFetch {
    <#
    .SYNOPSIS
        Live PyPI JSON-API detail lookup, mapped to DotForge.ToolSourceDetail.
    .PARAMETER PackageId
        The PyPI package name.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$PackageId
    )

    $doc = Invoke-RestMethod -Uri "https://pypi.org/pypi/$([uri]::EscapeDataString($PackageId))/json" -TimeoutSec 10
    $info = $doc.info
    if (-not $info.name) { return $null }

    $urls = $info.project_urls
    $repo = [string]($urls.Repository ? $urls.Repository : ($urls.Source ? $urls.Source : ((([string]$urls.Homepage) -match 'github\.com') ? $urls.Homepage : '')))
    $docsUrl = [string]($urls.Documentation ? $urls.Documentation : $urls.Docs)

    $extra = [ordered]@{}
    if ($info.requires_python) { $extra['requires_python'] = [string]$info.requires_python }
    if ($info.description) {
        $extra['description'] = [string]$info.description
        $extra['description_content_type'] = [string]$info.description_content_type
    }

    New-DFToolSourceDetail -Source 'pypi' `
        -PackageId $info.name `
        -Publisher ([string]($info.author ? $info.author : $info.maintainer)) `
        -Tags @(([string]$info.keywords) -split '[,\s]+' -ne '') `
        -RepositoryUrl $repo `
        -DocsUrl $docsUrl `
        -InstallHint "pipx install $($info.name)" `
        -Extra $extra
}

function Get-DFCatalogPypiDetail {
    <#
    .SYNOPSIS
        Cache-first PyPI detail lookup.
    .PARAMETER PackageId
        The PyPI package name.
    .PARAMETER Fresh
        Force a live fetch.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$PackageId,

        [switch]$Fresh
    )

    Get-DFCatalogDetailCache -Provider 'pypi' -PackageId $PackageId -Fresh:$Fresh `
        -Fetch { param($id) Invoke-DFCatalogPypiDetailFetch -PackageId $id }
}

if (-not $script:DFCatalogProviders) { $script:DFCatalogProviders = @{} }
$script:DFCatalogProviders['pypi'] = @{
    Name         = 'pypi'
    Kind         = 'query-cache'
    Test         = { $true }
    Search       = { param($Query, $Fresh) Search-DFCatalogPypi -Query $Query -Fresh:$Fresh }
    GetInstalled = { Get-DFCatalogPypiInstalled }
    Refresh      = { param($Query) if ($Query) { $null = Search-DFCatalogPypi -Query $Query -Fresh } }
    Detail       = { param($PackageId, $Fresh) Get-DFCatalogPypiDetail -PackageId $PackageId -Fresh:$Fresh }
}
