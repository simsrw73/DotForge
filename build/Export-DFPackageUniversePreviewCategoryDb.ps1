#Requires -Version 7.0
<#
.SYNOPSIS
    Exports the live package-universe classifications as a preview category
    database, for browsing the real Phase D taxonomy through trifle
    (`Find-DFPackage -Category`/`-WorksWith`, `Get-DFCategoryList`) without
    touching the shipped data/tool-categories.json. Author-side tooling —
    never loaded by the DotForge module. See
    docs/package-universe-review-guide.md.
.DESCRIPTION
    Writes to Get-DFCategoryDb's existing "refreshed copy" slot
    ($XDG_DATA_HOME/dotforge/tool-categories.json) — the same mechanism
    Update-DFCategoryDb uses for a real published release, just pointed at
    local build output instead of a GitHub asset. Get-DFCategoryDb already
    prefers this file over the shipped one whenever its `updated` timestamp
    is newer (falling back to shipped on any schema failure), so no core
    module code changes are needed. To go back to the shipped ~78-tool db,
    delete the written file.

    This is explicitly a PREVIEW, not the Plan 2 shipped-db promotion (which
    the design spec gates behind an offline quality-eval harness that
    doesn't exist yet) -- it exists so the real classification quality and
    category shape can be browsed and used to prioritize the review backlog,
    not as a release artifact.
.PARAMETER DatabasePath
    Path to the package-universe working database.
.PARAMETER DomainsPath / TaxonomyPath
    Closed-vocabulary files (only Function/WorksWith are used -- the shipped
    category-db schema has no domain axis).
.PARAMETER OutPath
    Where to write the preview db. Defaults to
    $Env:XDG_DATA_HOME/dotforge/tool-categories.json (Get-DFCategoryDb's
    refreshed-copy path). Throws if XDG_DATA_HOME is unset and -OutPath is
    not given explicitly.
.OUTPUTS
    [pscustomobject] with ToolCount and OutPath.
.EXAMPLE
    ./build/Export-DFPackageUniversePreviewCategoryDb.ps1
    Get-DFCategoryDb -Force | Out-Null   # or open a fresh shell
    Get-DFCategoryList
    trifle -Category font-management
#>
[CmdletBinding()]
param(
    [string]$DatabasePath = (Join-Path $PSScriptRoot '.package-universe/universe.db'),
    [string]$DomainsPath = (Join-Path $PSScriptRoot 'categories/domains.jsonc'),
    # NOT build/categories/taxonomy.jsonc -- that's the flat source fragment
    # Build-DFCategoryDb.ps1 reads. Import-DFPackageUniverseVocab (shared with
    # the live Build-DFPackageUniverseCategories.ps1 classifier) always expects
    # the WRAPPED { taxonomy: { function; worksWith } } shape, matching this
    # file's real default -- getting this wrong silently loads an empty vocab
    # (see the domains.jsonc/tool-categories.json staleness incident earlier
    # in this branch's history for the exact same class of mistake).
    [string]$TaxonomyPath = (Join-Path $PSScriptRoot '../data/tool-categories.json'),
    [string]$OutPath
)

Set-StrictMode -Version Latest
if (-not (Get-Module -ListAvailable -Name 'PSSQLite')) { throw "Export-DFPackageUniversePreviewCategoryDb: PSSQLite not installed." }
Import-Module PSSQLite -ErrorAction Stop
Get-ChildItem -Path (Join-Path $PSScriptRoot 'Private') -Filter '*.ps1' | ForEach-Object { . $_.FullName }
# Test-DFCategoryDbSchema lives in the repo-root Private/ (the module's own
# private functions), NOT build/Private/ (package-universe build helpers) --
# distinct directories, easy to conflate.
. (Join-Path $PSScriptRoot '../Private/Test-DFCategoryDbSchema.ps1')

if (-not (Test-Path $DatabasePath)) { throw "Export-DFPackageUniversePreviewCategoryDb: database not found at '$DatabasePath'. Run Build-DFPackageUniverseCategories.ps1 first." }

if (-not $OutPath) {
    if (-not $Env:XDG_DATA_HOME) { throw "Export-DFPackageUniversePreviewCategoryDb: `$Env:XDG_DATA_HOME is not set and -OutPath was not given. Get-DFCategoryDb's refresh mechanism only checks `$Env:XDG_DATA_HOME/dotforge/tool-categories.json -- set XDG_DATA_HOME (see CLAUDE.md) or pass -OutPath explicitly." }
    $OutPath = Join-Path $Env:XDG_DATA_HOME 'dotforge/tool-categories.json'
}
$outDir = Split-Path $OutPath -Parent
if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

$vocab = Import-DFPackageUniverseVocab -DomainsPath $DomainsPath -TaxonomyPath $TaxonomyPath

$conn = New-SQLiteConnection -DataSource $DatabasePath
try {
    $doc = ConvertTo-DFPackageUniverseCategoryDbPreview -Connection $conn -Vocab $vocab
} finally { $conn.Close() }

$errs = $null
if (-not (Test-DFCategoryDbSchema -Database $doc -Errors ([ref]$errs))) {
    throw "Export-DFPackageUniversePreviewCategoryDb: generated document failed its own schema validation (this should not happen -- please report): $($errs -join '; ')"
}

($doc | ConvertTo-Json -Depth 8) | Set-Content -Path $OutPath -Encoding utf8

$toolCount = @($doc.tools.PSObject.Properties | ForEach-Object { $_.Name }).Count
Write-Host "Wrote $OutPath ($toolCount tools, $($vocab.Function.Count) function + $($vocab.WorksWith.Count) worksWith categories)"
Write-Host "Get-DFCategoryDb -Force  # or open a fresh shell -- picks up this file automatically since it's newer than the shipped db"

[pscustomobject]@{ ToolCount = $toolCount; OutPath = $OutPath }
