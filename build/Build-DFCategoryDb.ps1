#Requires -Version 7.0

<#
.SYNOPSIS
    Merges build/categories/*.jsonc fragments into data/tool-categories.json.
    Author-side tooling — never loaded by the DotForge module.
.PARAMETER CategoriesDir
    Directory of *.jsonc fragments (default: build/categories next to this script).
.PARAMETER OutPath
    Output file (default: data/tool-categories.json at the repo root).
.EXAMPLE
    ./build/Build-DFCategoryDb.ps1
    Regenerates data/tool-categories.json from the checked-in fragments.
#>
[CmdletBinding()]
param(
    [string]$CategoriesDir = (Join-Path $PSScriptRoot 'categories'),
    [string]$OutPath = (Join-Path $PSScriptRoot '../data/tool-categories.json')
)

. (Join-Path $PSScriptRoot '../Private/Test-DFCategoryDbSchema.ps1')

function Read-DFCategoryFragment {
    param([string]$Path)
    $raw = Get-Content $Path -Raw
    # Strip //-prefixed line comments — these fragments are author-controlled,
    # not general JSONC, so a simple non-quoted-// strip is sufficient.
    $stripped = ($raw -split "`n" | ForEach-Object {
        if ($_ -match '^(?<code>(?:[^"]|"[^"]*")*?)//') { $Matches.code } else { $_ }
    }) -join "`n"
    $stripped | ConvertFrom-Json
}

$fragmentFiles = Get-ChildItem $CategoriesDir -Filter '*.jsonc' | Sort-Object Name
$taxonomyFile = $fragmentFiles | Where-Object Name -eq 'taxonomy.jsonc'
if (-not $taxonomyFile) { throw "Build-DFCategoryDb: no taxonomy.jsonc found in $CategoriesDir" }

# domains.jsonc is Phase D's coarse-domain vocabulary file (package-universe
# categorization), not a tool-fragment -- it lives in the same directory by
# convention but has no "tools" shape (top-level domain/schemaVersion keys),
# so it must be excluded from the tool-fragment walk below the same way
# taxonomy.jsonc is.
$nonToolFragments = 'taxonomy.jsonc', 'domains.jsonc'

$taxonomy = Read-DFCategoryFragment -Path $taxonomyFile.FullName
$tools = [ordered]@{}
$seenIn = @{}

foreach ($file in ($fragmentFiles | Where-Object { $nonToolFragments -notcontains $_.Name })) {
    $fragment = Read-DFCategoryFragment -Path $file.FullName
    foreach ($prop in $fragment.PSObject.Properties) {
        if ($tools.Contains($prop.Name)) {
            throw "Build-DFCategoryDb: duplicate tool key '$($prop.Name)' in $($file.Name) (already defined in $($seenIn[$prop.Name]))"
        }
        $tools[$prop.Name] = $prop.Value
        $seenIn[$prop.Name] = $file.Name
    }
}

$sortedTools = [ordered]@{}
foreach ($key in ($tools.Keys | Sort-Object)) { $sortedTools[$key] = $tools[$key] }

$doc = [pscustomobject]@{
    schemaVersion = 1
    updated       = [datetime]::UtcNow.ToString('yyyy-MM-dd')
    taxonomy      = $taxonomy
    # Cast the [ordered] dictionary to PSCustomObject so Test-DFCategoryDbSchema's
    # PSObject.Properties enumeration walks tool keys, not the dictionary's own
    # .NET members (Count, Keys, Values, ...).
    tools         = [pscustomobject]$sortedTools
}

$errs = $null
if (-not (Test-DFCategoryDbSchema -Database $doc -Errors ([ref]$errs))) {
    throw "Build-DFCategoryDb: generated document failed validation:`n$($errs -join "`n")"
}

$doc | ConvertTo-Json -Depth 8 | Set-Content -Path $OutPath -Encoding UTF8
Write-Host "Wrote $OutPath ($($sortedTools.Count) tools)"
