#Requires -Version 7.0

<#
.SYNOPSIS
    Builds data/tool-identities.json: verified cross-catalog identity links
    for Tools/*.json's curated tools, plus any hand-authored
    build/identities/*.jsonc fragments. Author-side tooling — never loaded
    by the DotForge module.
.PARAMETER ToolsPath
    Tools/*.json directory (default: Tools/ at the repo root).
.PARAMETER IdentitiesDir
    Directory of hand-authored *.jsonc fragments (default: build/identities
    next to this script). May be empty or absent — all v1 seed data comes
    from Tools/*.json; this is the extension point for future manual entries.
.PARAMETER OutPath
    Output file (default: data/tool-identities.json at the repo root).
.PARAMETER Fresh
    Bypass catalog/GitHub caches during resolution — use for the real
    published-artifact build; omit for a quick local dry run against
    whatever's already cached.
.PARAMETER ResolveLinkage
    Override the per-tool linkage resolver (default: a thin wrapper around
    the real Resolve-DFToolIdentityLinkage). Tests inject a canned
    scriptblock here to avoid live network access.
.EXAMPLE
    ./build/Build-DFToolIdentities.ps1 -Fresh
    Regenerates data/tool-identities.json with live, uncached resolution.
#>
[CmdletBinding()]
param(
    [string]$ToolsPath = (Join-Path $PSScriptRoot '../Tools'),
    [string]$IdentitiesDir = (Join-Path $PSScriptRoot 'identities'),
    [string]$OutPath = (Join-Path $PSScriptRoot '../data/tool-identities.json'),
    [switch]$Fresh,
    [scriptblock]$ResolveLinkage
)

if (-not (Get-Command Test-DFToolIdentityGuideSchema -ErrorAction Ignore)) {
    # Test-DFToolIdentityGuideSchema / Resolve-DFToolIdentityLinkage are
    # Private (not exported) per repo convention, so Import-Module alone
    # would not make them visible here — dot-source Private/*.ps1 directly,
    # mirroring how DotForge.psm1 loads them into the module's own session.
    Get-ChildItem -Path (Join-Path $PSScriptRoot '../Private') -Filter '*.ps1' |
        ForEach-Object { . $_.FullName }
}
if (-not $ResolveLinkage) {
    $ResolveLinkage = {
        param($ToolName, $Packages, $Fresh)
        Resolve-DFToolIdentityLinkage -ToolName $ToolName -Packages $Packages -Fresh:$Fresh
    }
}

function Read-DFIdentityFragment {
    param([string]$Path)
    $raw = Get-Content $Path -Raw
    $stripped = ($raw -split "`n" | ForEach-Object {
        if ($_ -match '^(?<code>(?:[^"]|"[^"]*")*?)//') { $Matches.code } else { $_ }
    }) -join "`n"
    $stripped | ConvertFrom-Json
}

$tools = [ordered]@{}
$seenPairs = @{}

function Add-DFIdentityEntry {
    param([string]$Key, $Entry, [string]$SourceLabel)
    if ($tools.Contains($Key)) {
        throw "Build-DFToolIdentities: duplicate tool key '$Key' from $SourceLabel (already defined)"
    }
    foreach ($prop in $Entry.packages.PSObject.Properties) {
        if (-not $prop.Value) { continue }
        $pairKey = "$($prop.Name.ToLowerInvariant()):$(([string]$prop.Value).ToLowerInvariant())"
        if ($seenPairs.ContainsKey($pairKey)) {
            throw "Build-DFToolIdentities: $pairKey claimed by both '$($seenPairs[$pairKey])' and '$Key' ($SourceLabel)"
        }
        $seenPairs[$pairKey] = $Key
    }
    $tools[$Key] = $Entry
}

# Seed from Tools/*.json — the authoritative, already-curated 32. The build
# pass VERIFIES this existing curation (attaching automated repo/homepage
# evidence where possible) rather than discovering new links from scratch.
foreach ($file in (Get-ChildItem $ToolsPath -Filter '*.json')) {
    $tool = Get-Content $file.FullName -Raw | ConvertFrom-Json
    if (-not $tool.packages -or @($tool.packages.PSObject.Properties).Count -eq 0) { continue }

    $linkage = & $ResolveLinkage $tool.name $tool.packages $Fresh.IsPresent
    $entry = [ordered]@{ packages = $tool.packages; linkedVia = $linkage.LinkedVia }
    if ($linkage.Repo) { $entry.repo = $linkage.Repo }
    Add-DFIdentityEntry -Key $tool.name -Entry ([pscustomobject]$entry) -SourceLabel "Tools/$($file.Name)"
}

# Hand-authored additions (empty for v1; mechanism for future growth).
if (Test-Path $IdentitiesDir) {
    foreach ($file in (Get-ChildItem $IdentitiesDir -Filter '*.jsonc' -ErrorAction Ignore)) {
        $fragment = Read-DFIdentityFragment -Path $file.FullName
        foreach ($prop in $fragment.PSObject.Properties) {
            Add-DFIdentityEntry -Key $prop.Name -Entry $prop.Value -SourceLabel $file.Name
        }
    }
}

$sortedTools = [ordered]@{}
foreach ($key in ($tools.Keys | Sort-Object)) { $sortedTools[$key] = $tools[$key] }

$doc = [pscustomobject]@{
    schemaVersion = 1
    updated       = [datetime]::UtcNow.ToString('yyyy-MM-dd')
    # Cast to PSCustomObject so Test-DFToolIdentityGuideSchema's
    # PSObject.Properties enumeration walks tool keys, not the ordered
    # dictionary's own .NET members.
    tools         = [pscustomobject]$sortedTools
}

$errs = $null
if (-not (Test-DFToolIdentityGuideSchema -Database $doc -Errors ([ref]$errs))) {
    throw "Build-DFToolIdentities: generated document failed validation:`n$($errs -join "`n")"
}

$doc | ConvertTo-Json -Depth 8 | Set-Content -Path $OutPath -Encoding UTF8
Write-Host "Wrote $OutPath ($($sortedTools.Count) tools)"
