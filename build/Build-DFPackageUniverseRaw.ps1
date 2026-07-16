#Requires -Version 7.0

<#
.SYNOPSIS
    Phase A of the package-universe pipeline: crawls scoop (local buckets),
    winget (via a winget-pkgs GitHub snapshot), and choco (one unfiltered
    OData next-link walk of the whole catalog), writing normalized rows into
    build/.package-universe/universe.db (raw_packages, pipeline_log).
    Author-side tooling — never loaded by the DotForge module.
.DESCRIPTION
    All three catalogs are full rebuilds every run; there is no incremental
    mode. Budget roughly 50 minutes: ~1 min scoop, ~30 min winget (dominated by
    the snapshot download+parse; pass -WingetPkgsSnapshot to reuse an existing
    tree), ~21 min choco (~281 politely-paced requests).
.PARAMETER DatabasePath
    SQLite working database path (default: .package-universe/universe.db
    next to this script).
.PARAMETER ScoopRoot
    The scoop root directory (default: Get-DFCatalogScoopRoot's resolution).
.PARAMETER WingetPkgsSnapshot
    Path to an already-downloaded/extracted winget-pkgs tree (directly
    containing manifests/). Omit to download a fresh zip snapshot of the
    default branch.
.PARAMETER ChocoDelayMinMs
    Lower bound of the randomized/jittered pacing between choco requests.
.PARAMETER ChocoDelayMaxMs
    Upper bound of the randomized/jittered pacing between choco requests.
.PARAMETER ChocoMaxRequests
    Runaway backstop: total choco requests this run will make before giving up
    with whatever partial data was collected, logging an error and skipping the
    prune. A complete walk needs ~281 requests (~40 packages per page), so the
    default (500) leaves room for catalog growth while still catching a
    runaway. Rate-limit safety comes from the jittered pacing and the immediate
    429-abort, not this ceiling.
.PARAMETER LogFile
    Path to the verbose run-transcript log file. Defaults to a timestamped
    file (acquire-<UTC>.log) alongside the database. This captures far more
    detail than the database's pipeline_log table — every request with
    timing/status, retries, page progression, budget usage, how the walk
    terminated, prune results, and per-catalog summaries — so a failed or
    partial run can be diagnosed after the fact. This transcript is what made
    the 2026-07-15 redesign diagnosable from a killed run's logs alone.
.PARAMETER SkipScoopUpdate
    Skip the 'scoop update' bucket refresh that otherwise runs before scoop
    acquisition. Use for offline runs, or when the buckets are already current.
.PARAMETER ScoopUpdate
    Override the scoop bucket-refresh step (default: 'scoop update'). Tests
    inject a no-op or a spy here so no real scoop process runs.
.PARAMETER ScoopFetchItems
    Override the scoop manifest fetcher (default: a thin wrapper around the
    real Build-DFCatalogScoopIndexData). Tests inject canned entries here.
.PARAMETER ChocoFetchPage
    Override the choco page fetcher (default: a live Packages() OData
    request). Tests inject canned pages here.
.PARAMETER ChocoSleep
    Override the choco pacing/backoff sleep (default: Start-Sleep). Tests
    inject a no-op here so retry/backoff tests run instantly.
.EXAMPLE
    ./build/Build-DFPackageUniverseRaw.ps1
    Full rebuild of all three catalogs, downloading a fresh winget-pkgs
    snapshot. Roughly 50 minutes.
.EXAMPLE
    ./build/Build-DFPackageUniverseRaw.ps1 -WingetPkgsSnapshot ./build/.package-universe/winget-pkgs
    Reuses an already-downloaded winget-pkgs tree, skipping the run's most
    expensive step. The iteration-friendly form when working on choco.
.OUTPUTS
    None. Writes universe.db and a run transcript; prints per-catalog row
    counts and the log path.
#>
[CmdletBinding()]
param(
    [string]$DatabasePath = (Join-Path $PSScriptRoot '.package-universe/universe.db'),
    [string]$ScoopRoot,
    [string]$WingetPkgsSnapshot,
    [int]$ChocoDelayMinMs = 2500,
    [int]$ChocoDelayMaxMs = 6500,
    [int]$ChocoMaxRequests = 500,
    [string]$LogFile,

    [switch]$SkipScoopUpdate,

    [scriptblock]$ScoopFetchItems,
    [scriptblock]$ScoopUpdate,
    [scriptblock]$ChocoFetchPage,
    [scriptblock]$ChocoSleep
)

# Strict by default, and the reused Private/DFCatalog.*.ps1 mappers are written
# to be strict-safe (they probe for absent feed properties via Get-DFXmlMember
# rather than reading them bare). This replaced an earlier `Set-StrictMode -Off`
# that existed because those mappers threw under strict — which was strict mode
# correctly reporting that the code read properties that do not exist, not a
# reason to disable it. Silencing it had already cost one real bug: `publisher`
# came back silently empty for every choco package because the mapper read
# $props.Authors, which feed customization always omits.
#
# Set-StrictMode is DYNAMICALLY scoped, so this also governs everything
# dot-sourced below — that is intended, not incidental.
Set-StrictMode -Version Latest

# Invoke-WebRequest's progress bar cripples large downloads on some PS builds;
# the winget-pkgs snapshot is hundreds of MB, so suppress it for this run.
$ProgressPreference = 'SilentlyContinue'

foreach ($requiredModule in 'PSSQLite', 'powershell-yaml') {
    if (-not (Get-Module -ListAvailable -Name $requiredModule)) {
        throw "Build-DFPackageUniverseRaw: required build-time module '$requiredModule' is not installed. Install it with: Install-Module $requiredModule -Scope CurrentUser"
    }
}
Import-Module PSSQLite -ErrorAction Stop
Import-Module powershell-yaml -ErrorAction Stop

# Private/*.ps1 functions aren't exported, so Import-Module alone would not
# make them visible here — dot-source directly, mirroring how DotForge.psm1
# loads them into the module's own session (see Build-DFToolIdentities.ps1).
if (-not (Get-Command Build-DFCatalogScoopIndexData -ErrorAction Ignore)) {
    Get-ChildItem -Path (Join-Path $PSScriptRoot '../Private') -Filter '*.ps1' |
        ForEach-Object { . $_.FullName }
}
if (-not (Get-Command Get-DFPackageUniverseScoopRows -ErrorAction Ignore)) {
    Get-ChildItem -Path (Join-Path $PSScriptRoot 'Private') -Filter '*.ps1' |
        ForEach-Object { . $_.FullName }
}

# Resolved here rather than as a param() default — default-value expressions
# evaluate before dot-sourcing above runs, so Get-DFCatalogScoopRoot wouldn't
# exist yet at that point in a fresh (non-DotForge-imported) session.
if (-not $ScoopRoot) { $ScoopRoot = Get-DFCatalogScoopRoot }

if (-not $ScoopFetchItems) {
    # -IncludeRaw: Stage 0 full-fidelity capture keeps the verbatim scoop
    # manifest (checkver/autoupdate reveal the repo when homepage is a vanity URL).
    $ScoopFetchItems = { param($ScoopRoot) Build-DFCatalogScoopIndexData -ScoopRoot $ScoopRoot -IncludeRaw }
}
if (-not $ScoopUpdate -and -not $SkipScoopUpdate) {
    # Refresh local scoop buckets (git-pull) before reading them, so the snapshot
    # reflects current upstream manifests -- scoop reads local bucket clones,
    # unlike winget's snapshot re-download and choco's live walk. Output is
    # suppressed; a failure degrades to a warning in Get-DFPackageUniverseScoopRows.
    $ScoopUpdate = { scoop update *>&1 | Out-Null }
}
if (-not $ChocoFetchPage) {
    # The real implementation lives in Private/DFPackageUniverse.Choco.ps1 so it
    # is unit-testable: inline here, the production fetch path had no coverage
    # whatsoever, since every test injects a fake seam in its place.
    $ChocoFetchPage = { param($Url) Invoke-DFPackageUniverseChocoLiveFetch -Url $Url }
}
if (-not $ChocoSleep) {
    $ChocoSleep = { param($Milliseconds) Start-Sleep -Milliseconds $Milliseconds }
}

function Get-DFPackageUniverseWingetSnapshot {
    <#
    .SYNOPSIS
        Downloads and extracts a zip snapshot of winget-pkgs's default
        branch, normalizing past the zipball's wrapping top-level folder so
        callers always see <root>/manifests/... Mirrors
        Update-DFCatalogWingetIndex's atomic tmp-then-Move-Item idiom.
    .PARAMETER WorkingDir
        Directory to stage the download/extraction under.
    .PARAMETER Trace
        Optional scriptblock: param($Message) -> verbose file-log line.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$WorkingDir,

        [scriptblock]$Trace = { }
    )

    New-DFDirectory $WorkingDir
    $zipPath = Join-Path $WorkingDir "winget-pkgs.$PID.zip"
    $extractTmp = Join-Path $WorkingDir "winget-pkgs.tmp.$PID"
    $finalDir = Join-Path $WorkingDir 'winget-pkgs'

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & $Trace 'downloading winget-pkgs master.zip from github.com ...'
    Invoke-WebRequest -Uri 'https://github.com/microsoft/winget-pkgs/archive/refs/heads/master.zip' -OutFile $zipPath
    $zipMb = [Math]::Round((Get-Item $zipPath).Length / 1MB, 1)
    & $Trace "download complete: ${zipMb}MB in $([Math]::Round($sw.Elapsed.TotalSeconds, 1))s; extracting ..."

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path $extractTmp) { Remove-Item $extractTmp -Recurse -Force -ErrorAction Ignore }
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $extractTmp)
    Remove-Item $zipPath -Force -ErrorAction Ignore

    # GitHub's zipball wraps everything in one winget-pkgs-<sha>/ folder.
    $wrapper = Get-ChildItem -Path $extractTmp -Directory | Select-Object -First 1
    if (-not $wrapper) { throw "Build-DFPackageUniverseRaw: winget-pkgs zip extracted to an unexpected shape at $extractTmp" }

    if (Test-Path $finalDir) { Remove-Item $finalDir -Recurse -Force }
    Move-Item -Path $wrapper.FullName -Destination $finalDir -Force
    Remove-Item $extractTmp -Recurse -Force -ErrorAction Ignore
    & $Trace "snapshot ready at $finalDir (total $([Math]::Round($sw.Elapsed.TotalSeconds, 1))s)"

    $finalDir
}

$workingDir = Split-Path $DatabasePath -Parent
New-DFDirectory $workingDir
if (-not $LogFile) {
    $LogFile = Join-Path $workingDir "acquire-$([datetime]::UtcNow.ToString('yyyyMMdd-HHmmss'))Z.log"
}

# Trace scriptblocks and $logger resolve $LogFile / $conn / the Write-DF*
# functions from this script scope at invocation time. They are plain (NOT
# .GetNewClosure()'d) scriptblocks on purpose — a new closure would snapshot
# an isolated scope and lose sight of $conn and the dot-sourced log helpers.
$logger = {
    param($Level, $Source, $PackageId, $Message)
    $pkgPart = if ($PackageId) { " [$PackageId]" } else { '' }
    Write-DFPackageUniverseTrace -LogFile $LogFile -Message "$($Level.ToUpper()) ${Source}${pkgPart}: $Message"
    if ($Level -in @('error', 'warning', 'review')) {
        Write-DFPackageUniverseLogEntry -Connection $conn -Level $Level -Source $Source -PackageId $PackageId -Message $Message
    }
}
$chocoTrace = { param($m) Write-DFPackageUniverseTrace -LogFile $LogFile -Message "choco: $m" }
$wingetTrace = { param($m) Write-DFPackageUniverseTrace -LogFile $LogFile -Message "winget: $m" }

Write-DFPackageUniverseTrace -LogFile $LogFile -Message "=== Build-DFPackageUniverseRaw run start (PID $PID) ==="
Write-DFPackageUniverseTrace -LogFile $LogFile -Message "database=$DatabasePath chocoMaxRequests=$ChocoMaxRequests chocoDelayMs=[$ChocoDelayMinMs..$ChocoDelayMaxMs]"

$catalogRowCounts = [ordered]@{}
$conn = $null
$runSw = [System.Diagnostics.Stopwatch]::StartNew()

try {
    Initialize-DFPackageUniverseDb -DatabasePath $DatabasePath
    $conn = New-SQLiteConnection -DataSource $DatabasePath

    foreach ($catalog in 'scoop', 'winget') {
        $catSw = [System.Diagnostics.Stopwatch]::StartNew()
        Write-DFPackageUniverseTrace -LogFile $LogFile -Message "--- ${catalog}: acquisition start ---"
        $txnOpen = $false
        try {
            $rows = switch ($catalog) {
                'scoop' {
                    Get-DFPackageUniverseScoopRows -ScoopRoot $ScoopRoot -FetchItems $ScoopFetchItems -ScoopUpdate $ScoopUpdate `
                        -Log { param($l, $p, $m) & $logger $l 'scoop' $p $m }
                }
                'winget' {
                    Get-DFPackageUniverseWingetRows -WingetPkgsSnapshot $WingetPkgsSnapshot `
                        -FetchSnapshot { Get-DFPackageUniverseWingetSnapshot -WorkingDir $workingDir -Trace $wingetTrace } `
                        -Log { param($l, $p, $m) & $logger $l 'winget' $p $m } -Trace $wingetTrace
                }
            }

            $count = 0
            Invoke-SqliteQuery -SQLiteConnection $conn -Query 'BEGIN TRANSACTION;'
            $txnOpen = $true
            foreach ($row in @($rows)) {
                Write-DFPackageUniverseRawPackage -Connection $conn -Row $row
                $count++
            }
            Invoke-SqliteQuery -SQLiteConnection $conn -Query 'COMMIT;'
            $txnOpen = $false
            $catalogRowCounts[$catalog] = $count
            Write-DFPackageUniverseTrace -LogFile $LogFile -Message "--- ${catalog}: wrote $count rows in $([Math]::Round($catSw.Elapsed.TotalSeconds, 1))s ---"
        } catch {
            & $logger 'error' $catalog $null "catalog acquisition failed: $_"
            $catalogRowCounts[$catalog] = 0
            # Roll back only a genuinely-open transaction (acquisition can throw
            # before BEGIN); rolling back when none is active is itself an error.
            if ($txnOpen) { try { Invoke-SqliteQuery -SQLiteConnection $conn -Query 'ROLLBACK;' -ErrorAction Stop } catch { } }
        }
    }

    # --- choco: one unfiltered next-link walk of the whole catalog ---
    $catSw = [System.Diagnostics.Stopwatch]::StartNew()
    Write-DFPackageUniverseTrace -LogFile $LogFile -Message '--- choco: acquisition start ---'
    try {
        # Flush each page as it arrives rather than batching the whole walk into
        # one transaction. A ~281-request walk takes ~21 minutes; the 2026-07-15
        # run proved that end-of-walk-only writes lose everything when a run is
        # interrupted. Upsert semantics make a re-run idempotent, so per-page
        # commits cost nothing in correctness.
        # Deliberately NOT .GetNewClosure(): that would rehome this scriptblock
        # into a fresh module scope which cannot see the Private/*.ps1 functions
        # dot-sourced into script scope, so Write-DFPackageUniverseRawPackage
        # would not resolve at call time. A plain scriptblock keeps its defining
        # session state, where both $conn and those functions live. The counter
        # is a hashtable (by reference) so the callee's writes are visible here.
        $chocoWriteState = @{ Count = 0 }
        $writeRows = {
            param($PageRows)
            foreach ($row in @($PageRows)) {
                Write-DFPackageUniverseRawPackage -Connection $conn -Row $row
                $chocoWriteState.Count++
            }
        }

        $chocoResult = Get-DFPackageUniverseChocoRows `
            -FetchPage $ChocoFetchPage -Sleep $ChocoSleep -Log { param($l, $p, $m) & $logger $l 'choco' $p $m } `
            -WriteRows $writeRows `
            -DelayMinMs $ChocoDelayMinMs -DelayMaxMs $ChocoDelayMaxMs -MaxRequests $ChocoMaxRequests -Trace $chocoTrace

        $chocoCount = $chocoWriteState.Count
        $catalogRowCounts['choco'] = $chocoCount

        # Pruning is destructive and is gated on a walk that both finished
        # naturally (ended on a missing next link — the server's definitive
        # end-of-catalog signal) and had zero errors. Otherwise a package we
        # merely failed to reach would be wrongly deleted: "the run stopped
        # early" must never masquerade as "removed upstream".
        if ($chocoResult.Complete -and $chocoResult.ErrorCount -eq 0) {
            # @() must wrap the WHOLE pipeline: with it around only the Get-*
            # call, a single-match Where-Object yields a bare string, and
            # $staleIds.Count then throws under strict mode (a scalar string has
            # no .Count). Non-strict would have silently tolerated it.
            $staleIds = @(Get-DFPackageUniverseExistingPackageIds -Connection $conn -Source 'choco' |
                    Where-Object { -not $chocoResult.SeenIds.Contains($_) })
            foreach ($staleId in $staleIds) {
                Remove-DFPackageUniverseRawPackage -Connection $conn -Source 'choco' -PackageId $staleId
            }
            if ($staleIds.Count -gt 0) {
                & $logger 'review' 'choco' $null "pruned $($staleIds.Count) choco package(s) no longer present in a complete catalog walk"
            }
            Write-DFPackageUniverseTrace -LogFile $LogFile -Message "choco: prune removed $($staleIds.Count) stale row(s)"
        } else {
            & $logger 'review' 'choco' $null "skipped pruning: walk was incomplete or had errors (complete=$($chocoResult.Complete), errors=$($chocoResult.ErrorCount), reason=$($chocoResult.AbortReason)); leaving existing choco rows in place to avoid false deletions"
            Write-DFPackageUniverseTrace -LogFile $LogFile -Message "choco: prune SKIPPED (complete=$($chocoResult.Complete), errors=$($chocoResult.ErrorCount))"
        }

        Write-DFPackageUniverseTrace -LogFile $LogFile -Message "--- choco: wrote $chocoCount rows in $([Math]::Round($catSw.Elapsed.TotalSeconds, 1))s over $($chocoResult.PageCount) page(s), $($chocoResult.RequestsUsed) request(s) (complete=$($chocoResult.Complete), errors=$($chocoResult.ErrorCount)) ---"
    } catch {
        & $logger 'error' 'choco' $null "catalog acquisition failed: $_"
        # Rows already flushed per-page are intentionally KEPT — they are valid,
        # merely incomplete, and the prune is gated on Complete so they cannot
        # cause false deletions. Report what actually landed rather than 0.
        $catalogRowCounts['choco'] = $chocoWriteState.Count
    }
} catch {
    Write-DFPackageUniverseTrace -LogFile $LogFile -Message "FATAL: unexpected top-level error: $_"
    Write-Warning "Build-DFPackageUniverseRaw failed: $_"
    throw
} finally {
    if ($conn) { try { $conn.Close() } catch { } }
    Write-DFPackageUniverseTrace -LogFile $LogFile -Message "=== run end ($([Math]::Round($runSw.Elapsed.TotalSeconds, 1))s total) ==="
}

Write-Host "Wrote $DatabasePath"
foreach ($catalog in $catalogRowCounts.Keys) {
    Write-Host "  $catalog`: $($catalogRowCounts[$catalog]) rows"
}
Write-Host "Detailed run log: $LogFile"
