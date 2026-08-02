#Requires -Version 7.0
<#
.SYNOPSIS
    Phase D of the package-universe pipeline: categorization (Plan 1 engine).
.DESCRIPTION
    Classifies every merged tool into a closed taxonomy by reading its docs via
    an LLM, caching each result durably (survives re-runs and re-clustering).
    Resumable and budget-capped: re-run to continue where the last stop left off.
    See docs/superpowers/specs/2026-07-17-package-universe-categorization-design.md.
.PARAMETER DatabasePath
    Path to the shared SQLite working database (default: the standard
    build/.package-universe/universe.db next to this script).
.PARAMETER EnvPath
    Path to the .env file holding OPENAI_API_KEY and ANTHROPIC_API_KEY
    (default: repo-root .env). Not consulted when the corresponding -Classify
    / -Escalate seam is supplied.
.PARAMETER ClassificationsPath
    Path to the durable, version-controlled classification export (default:
    data/package-universe-classifications.jsonc). Imported at the start of the
    run and re-exported at the end.
.PARAMETER DomainsPath
    Path to the coarse domain vocabulary (default: build/categories/domains.jsonc).
.PARAMETER TaxonomyPath
    Path to the function/worksWith taxonomy (default: data/tool-categories.json).
.PARAMETER Model
    The OpenAI chat-completions model used by the real classify seam. Ignored
    when a -Classify seam is supplied.
.PARAMETER EscalateModel
    The Claude model used by the real escalate seam (default:
    claude-haiku-4-5-20251001) -- a stronger model reserved for the
    low-confidence/nothing_fits tail, per the Phase D design. Ignored when an
    -Escalate seam is supplied. Falls back to escalating on the same $Model
    (with a warning) when ANTHROPIC_API_KEY is absent from $EnvPath.
.PARAMETER BudgetCalls
    Max model calls this run (stop-and-resume budget). Default: unlimited.
.PARAMETER EscalateThreshold
    Confidence below which (or on nothing_fits) the Escalate seam is used.
.PARAMETER Http / Classify / Escalate
    Injectable seams (tests + custom models); defaults use the real network.
.OUTPUTS
    A reconciliation summary object.
.EXAMPLE
    ./build/Build-DFPackageUniverseCategories.ps1 -BudgetCalls 500
#>
[CmdletBinding()]
param(
    [string]$DatabasePath = (Join-Path $PSScriptRoot '.package-universe/universe.db'),
    [string]$EnvPath = (Join-Path $PSScriptRoot '../.env'),
    [string]$ClassificationsPath = (Join-Path $PSScriptRoot '../data/package-universe-classifications.jsonc'),
    [string]$DomainsPath = (Join-Path $PSScriptRoot 'categories/domains.jsonc'),
    [string]$TaxonomyPath = (Join-Path $PSScriptRoot '../data/tool-categories.json'),
    [string]$Model = 'gpt-4o-mini',
    [string]$EscalateModel = 'claude-haiku-4-5-20251001',
    [int]$BudgetCalls = [int]::MaxValue,
    [double]$EscalateThreshold = 0.5,
    [scriptblock]$Http,
    [scriptblock]$Classify,
    [scriptblock]$Escalate
)

Set-StrictMode -Version Latest
if (-not (Get-Module -ListAvailable -Name 'PSSQLite')) { throw "Build-DFPackageUniverseCategories: PSSQLite not installed." }
Import-Module PSSQLite -ErrorAction Stop
if (-not (Get-Command Invoke-DFPackageUniverseCategorizeRun -ErrorAction Ignore)) {
    Get-ChildItem -Path (Join-Path $PSScriptRoot 'Private') -Filter '*.ps1' | ForEach-Object { . $_.FullName }
}

if (-not (Test-Path $DatabasePath)) { throw "Build-DFPackageUniverseCategories: database not found at '$DatabasePath'. Run Phase A-C first." }
$hasPkgs = @(Invoke-SqliteQuery -DataSource $DatabasePath -Query "SELECT name FROM sqlite_master WHERE type='table' AND name='tool_packages';")
if ($hasPkgs.Count -eq 0) { throw "Build-DFPackageUniverseCategories: tool_packages not found. Run Build-DFPackageUniverseTools.ps1 (Phase C) first." }

$vocab = Import-DFPackageUniverseVocab -DomainsPath $DomainsPath -TaxonomyPath $TaxonomyPath

if (-not $Classify) {
    $key = Get-DFPackageUniverseApiKey -EnvPath $EnvPath -Name 'OPENAI_API_KEY'
    if (-not $key) { throw "Build-DFPackageUniverseCategories: OPENAI_API_KEY not found in '$EnvPath' (and no -Classify seam supplied)." }
    $Classify = New-DFPackageUniverseClassifySeam -ApiKey $key -Model $Model
    if (-not $Escalate) {
        $claudeKey = Get-DFPackageUniverseApiKey -EnvPath $EnvPath -Name 'ANTHROPIC_API_KEY'
        if ($claudeKey) {
            $Escalate = New-DFPackageUniverseClaudeClassifySeam -ApiKey $claudeKey -Model $EscalateModel
        } else {
            Write-Warning "Build-DFPackageUniverseCategories: ANTHROPIC_API_KEY not found in '$EnvPath' -- escalating on the same model ($Model) instead of a stronger one."
            $Escalate = $Classify
        }
    }
}
if (-not $Http) {
    $Http = { param($Url) $c = Invoke-RestMethod -Uri $Url -TimeoutSec 20 -Headers @{ 'User-Agent' = 'DotForge package-universe (+https://github.com/simsrw73/DotForge)' }; [pscustomobject]@{ Content = [string]$c; ContentType = 'text'; Status = 'ok' } }
}

Initialize-DFPackageUniverseCategorizeSchema -DatabasePath $DatabasePath
Import-DFPackageUniverseClassifications -DatabasePath $DatabasePath -Path $ClassificationsPath

$conn = New-SQLiteConnection -DataSource $DatabasePath
# NOTE: the design doc's inline log seam used `param($Level,$Src,$Pid,$Msg)`.
# $Pid shadows PowerShell's read-only automatic variable $PID -- binding to it
# via `&` throws "Cannot overwrite variable Pid because it is read-only or
# constant." (same bug class as the $Input/$Home renames noted in
# tests/DFPackageUniverse.Categorize.Tests.ps1). Renamed to $PackageId.
$log = { param($Level, $Src, $PackageId, $Msg) Invoke-SqliteQuery -SQLiteConnection $conn -Query "INSERT INTO pipeline_log (stage,source,package_id,level,message,logged_at) VALUES ('categorize',@s,@p,@l,@m,@at)" -SqlParameters @{ s = $Src; p = $PackageId; l = $Level; m = $Msg; at = [datetime]::UtcNow.ToString('o') } }
try {
    $summary = Invoke-DFPackageUniverseCategorizeRun -Connection $conn -Vocab $vocab -Http $Http -Classify $Classify -Escalate $Escalate -BudgetCalls $BudgetCalls -EscalateThreshold $EscalateThreshold -Log $log
} finally { $conn.Close() }

Update-DFPackageUniverseToolCategories -DatabasePath $DatabasePath
Export-DFPackageUniverseClassifications -DatabasePath $DatabasePath -Path $ClassificationsPath

Write-Host 'Phase D (categorization) run complete:'
Write-Host "  processed    : $($summary.Processed)"
Write-Host "  classified   : $($summary.Classified)"
Write-Host "  escalated    : $($summary.Escalated)"
Write-Host "  deferred     : $($summary.Deferred)"
Write-Host "  nothing-fits : $($summary.NothingFits)"
Write-Host "  remaining    : $($summary.Remaining)  (re-run to continue)"
if ($summary.RateLimited) {
    $resetMsg = if ($summary.RateLimitResetAt) { "around $($summary.RateLimitResetAt)" } else { 'at an unknown time -- check the provider dashboard' }
    Write-Warning "Stopped EARLY: a rate-limit / quota-exhaustion signal was hit. Every further call this run would have failed too, so the batch stopped rather than deferring the rest of the budget. Resets $resetMsg -- re-run after that."
}

$summary
