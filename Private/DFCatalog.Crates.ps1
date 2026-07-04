#Requires -Version 7.0

# crates.io catalog provider (query-cache kind). crates.io REQUIRES a
# descriptive User-Agent — anonymous requests are rejected.

function Invoke-DFCatalogCratesFetch {
    <#
    .SYNOPSIS
        Live crates.io search, normalized to DotForge.ToolSourceInfo.
    .PARAMETER Query
        Normalized query text.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Query
    )

    $uri = "https://crates.io/api/v1/crates?q=$([uri]::EscapeDataString($Query))&per_page=15"
    $headers = @{ 'User-Agent' = 'DotForge PowerShell module (+https://github.com/simsrw73/DotForge)' }
    $response = Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 10

    foreach ($crate in @($response.crates)) {
        $published = $null
        if ($crate.updated_at) { try { $published = [datetime]$crate.updated_at } catch {} }

        New-DFToolSourceInfo -Source 'crates' `
            -PackageId $crate.name `
            -Name $crate.name `
            -Description ([string]$crate.description) `
            -LatestVersion ([string]($crate.max_stable_version ?? $crate.max_version)) `
            -Homepage ([string]($crate.homepage ?? $crate.repository)) `
            -PublishedAt $published `
            -MatchKind ($crate.name -eq $Query ? 'exact-name' : 'keyword')
    }
}

function Search-DFCatalogCrates {
    <#
    .SYNOPSIS
        Cache-first crates.io search.
    .PARAMETER Query
        Name or keywords.
    .PARAMETER Fresh
        Block on a live fetch.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Query,

        [switch]$Fresh
    )

    Search-DFCatalogQueryCache -Provider 'crates' -Query $Query -Fresh:$Fresh `
        -Fetch { param($q) Invoke-DFCatalogCratesFetch -Query $q }
}

function Get-DFCatalogCratesInstalled {
    <#
    .SYNOPSIS
        Lists cargo-installed binaries by parsing ~/.cargo/.crates2.json —
        no cargo.exe invocation.
    .PARAMETER CargoHome
        Cargo home directory (defaults to $Env:CARGO_HOME or ~/.cargo).
    #>
    [CmdletBinding()]
    param(
        [string]$CargoHome = ($Env:CARGO_HOME ? $Env:CARGO_HOME : (Join-Path $HOME '.cargo'))
    )

    $file = Join-Path $CargoHome '.crates2.json'
    if (-not (Test-Path $file)) { return }

    try { $data = Get-Content $file -Raw | ConvertFrom-Json -AsHashtable } catch { return }
    if (-not $data.installs) { return }

    foreach ($spec in $data.installs.Keys) {
        # Keys look like: "ripgrep 14.1.1 (registry+https://github.com/rust-lang/crates.io-index)"
        $parts = $spec -split ' '
        if ($parts.Count -ge 2) {
            [pscustomobject]@{
                Source           = 'crates'
                Name             = $parts[0]
                PackageId        = $parts[0]
                InstalledVersion = $parts[1]
            }
        }
    }
}

function Invoke-DFCatalogCratesDetailFetch {
    <#
    .SYNOPSIS
        Live crates.io crate-detail lookup, mapped to DotForge.ToolSourceDetail.
    .PARAMETER PackageId
        The crate name.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$PackageId
    )

    $headers = @{ 'User-Agent' = 'DotForge PowerShell module (+https://github.com/simsrw73/DotForge)' }
    $doc = Invoke-RestMethod -Uri "https://crates.io/api/v1/crates/$([uri]::EscapeDataString($PackageId))" -Headers $headers -TimeoutSec 10
    $crate = $doc.crate
    if (-not $crate.name) { return $null }

    $extra = [ordered]@{}
    if ($crate.recent_downloads) { $extra['recent_downloads'] = [long]$crate.recent_downloads }

    New-DFToolSourceDetail -Source 'crates' `
        -PackageId $crate.name `
        -Tags (@(@($crate.keywords) + @($crate.categories)) | ForEach-Object { [string]$_ }) `
        -Downloads ([nullable[long]]$crate.downloads) `
        -RepositoryUrl ([string]$crate.repository) `
        -DocsUrl ([string]$crate.documentation) `
        -InstallHint "cargo install $($crate.name)" `
        -Extra $extra
}

function Get-DFCatalogCratesDetail {
    <#
    .SYNOPSIS
        Cache-first crates.io detail lookup.
    .PARAMETER PackageId
        The crate name.
    .PARAMETER Fresh
        Force a live fetch.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$PackageId,

        [switch]$Fresh
    )

    Get-DFCatalogDetailCache -Provider 'crates' -PackageId $PackageId -Fresh:$Fresh `
        -Fetch { param($id) Invoke-DFCatalogCratesDetailFetch -PackageId $id }
}

if (-not $script:DFCatalogProviders) { $script:DFCatalogProviders = @{} }
$script:DFCatalogProviders['crates'] = @{
    Name         = 'crates'
    Kind         = 'query-cache'
    Test         = { $true }   # pure web registry — searchable without a local toolchain
    Search       = { param($Query, $Fresh) Search-DFCatalogCrates -Query $Query -Fresh:$Fresh }
    GetInstalled = { Get-DFCatalogCratesInstalled }
    Refresh      = { param($Query) if ($Query) { $null = Search-DFCatalogCrates -Query $Query -Fresh } }
    Detail       = { param($PackageId, $Fresh) Get-DFCatalogCratesDetail -PackageId $PackageId -Fresh:$Fresh }
}
