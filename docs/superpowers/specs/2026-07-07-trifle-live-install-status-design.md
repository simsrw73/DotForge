# trifle Live Install-Status Checking — Design

**Date:** 2026-07-07
**Status:** Approved
**Depends on:** trifle discovery v1 (`docs/superpowers/specs/2026-07-05-trifle-discovery-v1-design.md`) and the tool identity guide (`docs/superpowers/specs/2026-07-06-trifle-tool-identity-guide-design.md`) — both already shipped. This spec touches `Private/Get-DFCatalogInstalled.ps1`, `Private/Resolve-DFCatalogQueryMerge.ps1`, and `Public/Update-DFPackageCache.ps1`; it does not modify catalog search, merge/identity logic, or the tool-identity guide itself.

## Problem

The original complaint was that `trifle <tool>` sometimes reports "not installed" for a tool that was just installed. Investigation ruled out the initially-suspected cause (package name differing from the binaries it installs, e.g. Sysinternals-style collections): every catalog provider's installed-status check already keys off package name/ID, not binary name, so multi-binary collections are not actually at risk here.

The real cause is caching:

- `Get-DFCatalogInstalled` caches its aggregated installed-package snapshot (`catalogs/installed.json`) with a 15-minute TTL.
- `Resolve-DFCatalogQueryMerge` calls `Get-DFCatalogInstalled` with no `-Force`, and `trifle <tool> -Fresh` only threads `-Fresh` through to catalog **search** — it never reaches the installed-status cache at all.

So installing a tool and immediately running `trifle <tool>` (even with `-Fresh`) can genuinely return stale pre-install data for up to 15 minutes.

Measuring each of the 7 catalog providers' `GetInstalled` hook (steady-state, warm) on real data:

| Provider | Cost | Mechanism |
|---|---|---|
| scoop | ~65-80ms (scales with app count; 61 apps here) | reads `apps/<name>/current/manifest.json` |
| winget | ~2-3ms | SQLite query against `installed.db` |
| choco | ~3ms | parses `lib/*/*.nuspec` |
| npm | ~0-3ms | reads global `node_modules/*/package.json` |
| crates | ~1-10ms | reads `.crates2.json` |
| psgallery | ~25ms | `Get-InstalledPSResource` (or `Get-Module -ListAvailable` fallback) |
| pypi | **~500-750ms, every call** | spawns `pipx list --json` — no on-disk shortcut found |

Six of seven providers are cheap enough to run live, uncached, on every query. Only `pypi` (via pipx) is genuinely expensive, and it's expensive because it's the only provider still shelling out to an external process rather than reading the package manager's own on-disk state — no faster on-disk pipx venv metadata was confirmed available (this repo has no pipx packages installed to inspect; worth rechecking during implementation).

A naive fix — fan all 7 providers out via `ForEach-Object -Parallel` — was measured to make things **worse** (~1017ms vs. ~600-850ms sequential warm), because each parallel runspace must reimport the whole DotForge module to reach the private functions each provider hook depends on, and that reimport cost, multiplied across concurrent runspaces competing for CPU, exceeds the savings from overlapping the actual provider work. Passing the existing provider scriptblock table across the `-Parallel` runspace boundary via the pipeline was also found to break outright (even unrelated builtin cmdlets failed inside the received scriptblocks) — scriptblocks captured in one runspace and invoked after crossing into another via `$_` lose their command-resolution context; scriptblocks created fresh inside the parallel block work fine.

The winning approach needs neither a full module reimport nor a special-cased background job: each provider's `GetInstalled` hook actually depends on only 1-2 small private files (its own `DFCatalog.<Provider>.ps1`, plus `Invoke-DFSqliteQuery.ps1` for winget alone) — not the whole ~6,862-line, ~30-file module. Dot-sourcing *only* that minimal per-provider file set inside each parallel runspace was measured at **506ms warm** (677ms cold, the one-time cost of compiling winget's SQLite P/Invoke shim via `Add-Type` — that compile lands in the shared .NET process, not any single runspace, so every other runspace reuses it immediately; confirmed by a second run dropping winget from 438ms to 3ms). This beats every other option measured, including a variant that ran the 6 cheap providers live in the foreground and backgrounded only pipx via `Start-ThreadJob` (~623ms) — folding pipx into the *same* uniform parallel batch as the other 6, rather than treating it as a special case, both simplifies the design and overlaps its cost against everyone else's instead of racing only the foreground work.

| Approach | Wall time (warm) |
|---|---|
| Sequential (today's pattern, cache removed) | ~600-850ms |
| Naive `ForEach-Object -Parallel` + full `Import-Module -Force` per runspace | 1017ms (worse) |
| 6 foreground + pipx backgrounded via `Start-ThreadJob` | ~623ms |
| **All 7 in one `-Parallel` batch, each dot-sourcing only its needed files** | **506ms** |

## Goals

- Eliminate installed-status cache staleness as a bug class entirely: no TTL, no `-Force`/`-Fresh` wiring to maintain or get wrong.
- Every `trifle <query>` reflects true, current installed state at the moment it runs.
- Keep added latency bounded and honest: measured ~506ms warm across all 7 providers running as one parallel batch (dropping to well under that when pipx isn't installed), never a serial sum of all 7 providers (~600-850ms) and never worse than sequential (the naive full-module-reimport parallel approach measured 1017ms — a real trap, not a hypothetical one).
- Preserve existing per-provider failure isolation — one provider erroring must never blank out the others.
- Extend the existing `Write-Progress` feedback (already shipped for the search phase) to cover this fetch, so the added latency doesn't feel like a silent stall.

## Non-Goals

- No manifest/binary-level install verification. Ruled out during design: today's package-ID-level matching already handles multi-binary collections correctly, since no provider keys installed-status by binary name.
- No `ForEach-Object -Parallel` fan-out that reimports the whole DotForge module per runspace — measured to be a net loss (1017ms) due to per-runspace module-reimport contention. (Parallel fan-out itself is in scope; the *whole-module-reimport* variant of it is not — see Architecture.)
- No change to `Update-DFPackageCache`'s catalog *search*-cache or catalog-index re-warming — only its installed-status re-warm step becomes moot and is removed.
- No attempt in this pass to make pipx itself cheaper (e.g., reading its on-disk venv metadata directly instead of spawning `pipx list --json`) — noted as a promising future optimization (see Out of Scope), not required to meet the goals above.
- No change to catalog search caching, merge/identity logic, or the tool-identity guide.

## Architecture

`Get-DFCatalogInstalled` loses its cache entirely — no TTL, no `catalogs/installed.json` snapshot file, no `-Force` parameter (there is nothing left to force-bypass). It becomes a thin, always-live aggregator that runs all 7 providers as **one uniform `ForEach-Object -Parallel` batch**, where each parallel branch dot-sources only the 1-2 private files its own provider needs (never the whole module) before calling that provider's existing `GetInstalled` function by name.

A small, explicit table maps each provider to its minimal dependency file list — this table is the one thing that must be kept in sync if a provider's `GetInstalled` hook ever grows a new dependency (see Testing):

```
$script:DFCatalogInstalledDeps = @{
    scoop     = @('DFCatalog.Scoop.ps1')
    winget    = @('DFCatalog.Winget.ps1', 'Invoke-DFSqliteQuery.ps1')
    choco     = @('DFCatalog.Choco.ps1')
    npm       = @('DFCatalog.Npm.ps1')
    crates    = @('DFCatalog.Crates.ps1')
    psgallery = @('DFCatalog.PSGallery.ps1')
    pypi      = @('DFCatalog.Pypi.ps1')
}
# provider name -> its GetInstalled function name (already exists per-provider today)
$script:DFCatalogInstalledFn = @{
    scoop = 'Get-DFCatalogScoopInstalled';   winget    = 'Get-DFCatalogWingetInstalled'
    choco = 'Get-DFCatalogChocoInstalled';   npm       = 'Get-DFCatalogNpmInstalled'
    crates = 'Get-DFCatalogCratesInstalled'; psgallery = 'Get-DFCatalogPSGalleryInstalled'
    pypi  = 'Get-DFCatalogPypiInstalled'
}
```

Pseudocode for `Get-DFCatalogInstalled`'s core loop:

```
function Get-DFCatalogInstalled {
    # $PSScriptRoot here resolves to .../Private at dot-source time (this file
    # already lives in Private/) -- NOT the caller's working directory, so this
    # works identically whether run from a git checkout or an installed module.
    $privateRoot = $PSScriptRoot
    $deps        = $script:DFCatalogInstalledDeps      # copy to a plain local for $using:
    $fnNames     = $script:DFCatalogInstalledFn         # ditto

    Write-Progress -Activity 'trifle' -Status 'Checking installed status…'

    $items = @(
        $script:DFCatalogOrder | ForEach-Object -Parallel {
            $name = $_
            $deps = $using:deps
            $fnNames = $using:fnNames
            $privateRoot = $using:privateRoot

            try {
                foreach ($file in $deps[$name]) {
                    . (Join-Path $privateRoot $file)
                }
                @(& (Get-Command $fnNames[$name]))
            } catch {
                # one provider's failure never blanks the others -- this
                # try/catch is PER PARALLEL BRANCH, same isolation guarantee
                # as today's foreach loop, just running concurrently instead
                # of sequentially.
                Write-Verbose "DotForge: installed enumeration for '$name' failed: $_"
                @()
            }
        } -ThrottleLimit 8 -TimeoutSeconds 10
    ) | Where-Object { $_ }

    Write-Progress -Activity 'trifle' -Completed

    # identity-map construction (from Tools/*.json packages blocks) is
    # unchanged -- it was already cheap and rebuilt on every call today.
    @{ Items = $items; IdentityMap = $identity }
}
```

Notes on the pseudocode:
- `$using:` can only reach plain local variables, not `$script:`-qualified names directly inside a `-Parallel` block — hence copying `$script:DFCatalogInstalledDeps` etc. into local variables just before the pipeline.
- `ThrottleLimit 8` covers all 7 providers running concurrently in one wave (no batching needed at this scale).
- Winget's one-time `Add-Type` P/Invoke compile (inside the dot-sourced `Invoke-DFSqliteQuery.ps1`) happens in whichever runspace's branch reaches it first; the resulting type is process-wide and immediately available to every other runspace, so it is never recompiled per-call.
- `Resolve-DFCatalogQueryMerge` calls `Get-DFCatalogInstalled` with no `-Force` parameter to pass (it no longer exists) — the entire "does `-Fresh` reach the installed-status cache" question disappears because there is no cache to reach.
- `Update-DFPackageCache` drops its `Get-DFCatalogInstalled -Force` re-warm step and its "Refreshing installed-package snapshot…" message — there is nothing left to warm.

## Error Handling

- Each provider's parallel branch keeps the same isolated `try/catch` semantics as today's sequential loop — one provider's failure (including a provider whose dependency file fails to dot-source, or whose function throws) degrades to zero items for that provider only, warned via `Write-Verbose`, never thrown. The difference from today is concurrency, not isolation: the guarantee that one provider's failure can't blank out the others is unchanged.
- `ForEach-Object -Parallel` surfaces a branch's uncaught exception by default; since every branch's own `try/catch` already catches and swallows (returning `@()`), no exception should ever escape to the caller of `Get-DFCatalogInstalled` from a single provider's failure.
- **A hung provider (e.g., a `pipx` process that never returns) must not stall `trifle` indefinitely.** The whole `ForEach-Object -Parallel` call carries `-TimeoutSeconds 10` (PS 7.2+): if the batch as a whole exceeds this, still-running branches are stopped and whatever branches already completed are kept — this bounds the worst case without needing a per-provider `Wait-Job`/timeout mechanism, since one shared timeout on the batch covers every provider uniformly, including any future provider added to `$script:DFCatalogOrder`.

## Testing (Pester 5)

Real parallel runspaces are slow and non-deterministic to assert against directly in most unit tests, so the bulk of `Get-DFCatalogInstalled`'s test coverage exercises the aggregation/error-isolation logic against a fast, synchronous stand-in (e.g. an injectable per-provider fetch delegate), the same way this codebase has consistently used injection seams for anything expensive or non-deterministic (`-ResolveLinkage` in `build/Build-DFToolIdentities.ps1`, mockable download seams for `Update-DFCategoryDb`/`Update-DFToolIdentityGuide`).

- `tests/Get-DFCatalogInstalled.Tests.ps1`: drop all cache/TTL/shipped-vs-refreshed-snapshot assertions (nothing left to test). Add: per-provider failure isolation continues to hold under the new parallel structure (one provider's injected failure doesn't blank the others); results from all providers aggregate correctly into `Items`; the identity-map construction (unchanged) still works alongside the new fetch mechanism.
- **Drift-detection test (real, not mocked):** a dedicated test that actually dot-sources each provider's declared minimal file set from `$script:DFCatalogInstalledDeps` and calls its real `GetInstalled` function (no catalog providers or fixtures needed — just confirming the function *resolves and runs* without `CommandNotFoundException`). This is the test that would catch a future change adding a new dependency to, say, `Get-DFCatalogScoopInstalled` without updating its entry in `$script:DFCatalogInstalledDeps` — exactly the failure mode this design's minimal-dependency-list approach is exposed to.
- `tests/Update-DFPackageCache.Tests.ps1`: drop the assertion that it calls `Get-DFCatalogInstalled -Force` (parameter no longer exists); update to reflect the simplified re-warm flow.
- `tests/Resolve-DFCatalogQueryMerge.Tests.ps1`: no `-Force`/cache-related assertions should exist there already (this file was added in the tool-identity-guide work and doesn't touch installed-status caching); confirm no incidental coupling.
- New or updated test coverage for the `Write-Progress` status line addition, matching the existing pattern used for the search-phase progress messages.

## Out of Scope / Future

- Investigate whether pipx maintains on-disk venv metadata (a `pipx_metadata.json`-style file per venv, or similar) that could let `Get-DFCatalogPypiInstalled` read state directly instead of spawning `pipx list --json`, the same way all 6 other providers already avoid shelling out. This repo currently has no pipx-installed packages to inspect the real on-disk layout against; worth revisiting when real venvs are available to verify against.
- Manifest/binary-level install verification (the originally-suspected problem) remains unimplemented, since it was ruled out as unnecessary during this design — today's package-ID-level matching already correctly handles multi-binary collections. If a genuine binary-level verification need surfaces later (e.g., detecting a partially-broken install where the package manager's bookkeeping says "installed" but a key binary is actually missing), it would be a separate, future spec.
