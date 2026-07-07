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

A targeted alternative was prototyped and measured: fire pipx's check in the background via `Start-ThreadJob` the moment the installed-status fetch begins (a self-contained scriptblock needing no DotForge module — just `Get-Command`, a direct process invocation, and `ConvertFrom-Json`, all available in a bare thread-job runspace), let the other 6 providers run live in the foreground, and collect the pipx job's result right before use. Measured wall time: ~623ms — i.e., roughly pipx's own cost alone, with the other providers' ~150ms absorbed for free — versus ~650-900ms if simply run in sequence.

## Goals

- Eliminate installed-status cache staleness as a bug class entirely: no TTL, no `-Force`/`-Fresh` wiring to maintain or get wrong.
- Every `trifle <query>` reflects true, current installed state at the moment it runs.
- Keep added latency bounded and honest: ~100-150ms typical (pipx not installed, or its cost overlaps for free with the other work), capped at roughly pipx's own cost (~500-750ms) in the worst case — never a serial sum of all 7 providers.
- Preserve existing per-provider failure isolation — one provider erroring must never blank out the others.
- Extend the existing `Write-Progress` feedback (already shipped for the search phase) to cover this fetch, so the added latency doesn't feel like a silent stall.

## Non-Goals

- No manifest/binary-level install verification. Ruled out during design: today's package-ID-level matching already handles multi-binary collections correctly, since no provider keys installed-status by binary name.
- No broad `ForEach-Object -Parallel` fan-out across all 7 providers — measured to be a net loss due to per-runspace module-reimport contention.
- No change to `Update-DFPackageCache`'s catalog *search*-cache or catalog-index re-warming — only its installed-status re-warm step becomes moot and is removed.
- No attempt in this pass to make pipx itself cheaper (e.g., reading its on-disk venv metadata directly instead of spawning `pipx list --json`) — noted as a promising future optimization (see Out of Scope), not required to meet the goals above.
- No change to catalog search caching, merge/identity logic, or the tool-identity guide.

## Architecture

`Get-DFCatalogInstalled` loses its cache entirely — no TTL, no `catalogs/installed.json` snapshot file, no `-Force` parameter (there is nothing left to force-bypass). It becomes a thin, always-live aggregator with this flow:

1. **Dispatch the pipx probe first, in the background.** A new private helper — self-contained, with zero dependency on other DotForge private functions (only `Get-Command`, a direct process invocation of `pipx list --json`, and `ConvertFrom-Json`) — is fired via `Start-ThreadJob` the moment `Get-DFCatalogInstalled` begins. It is wrapped behind an injectable parameter so tests can substitute a synchronous canned result instead of a real background job (mirroring the `-ResolveLinkage` injection pattern from `build/Build-DFToolIdentities.ps1`).
2. **Run the other 6 providers live, sequentially, in the foreground** — same per-provider `try/catch` loop structure as today, just always executed (no cache-check gate).
3. **Collect the pipx job immediately before merging results** — a bounded wait (`Wait-Job -Timeout 5` seconds) so a hung or misbehaving `pipx` process cannot stall `trifle` indefinitely. On timeout or any failure, it degrades to contributing zero pipx items — identical in effect to pipx not being installed — warned via `Write-Verbose`, never thrown.
4. **`Resolve-DFCatalogQueryMerge`** calls `Get-DFCatalogInstalled` with no `-Force` parameter to pass (it no longer exists) — the entire "does `-Fresh` reach the installed-status cache" question disappears because there is no cache to reach.
5. **`Write-Progress`** gains a status line for this phase (e.g., "Checking installed status…"), shown while the 6 foreground providers run and the backgrounded pipx job is in flight — reusing the exact `Write-Progress` mechanism already shipped for the search phase, not a new UI mechanism.
6. **`Update-DFPackageCache`** drops its `Get-DFCatalogInstalled -Force` re-warm step and its "Refreshing installed-package snapshot…" message — there is nothing left to warm.

## Error Handling

- Each of the 6 foreground providers keeps its existing isolated `try/catch` (already present in today's `Get-DFCatalogInstalled` loop) — one provider's failure never blanks the others.
- The backgrounded pipx probe gets the same treatment plus a bounded wait: a `Wait-Job -Timeout 5` timeout or a faulted job both degrade to zero pipx items for that call, warned via `Write-Verbose`, never thrown — matching this codebase's established warn-not-throw convention.
- No behavior changes to any of the other 6 providers' existing error handling.

## Testing (Pester 5)

Real background jobs are slow and non-deterministic in unit tests, so the pipx-probe dispatch is injectable: `Get-DFCatalogInstalled` gains a parameter (e.g. `-GetPipxInstalled <scriptblock>`) defaulting to the real `Start-ThreadJob`-based implementation; tests inject a synchronous canned scriptblock instead.

- `tests/Get-DFCatalogInstalled.Tests.ps1`: drop all cache/TTL/shipped-vs-refreshed-snapshot assertions (nothing left to test). Add: per-provider failure isolation continues to hold (already covered conceptually, verify it still passes with the new structure); the injected pipx-result seam is correctly merged into `Items`; a pipx timeout/failure case degrades to zero pipx items without throwing; the 6 foreground providers still run and aggregate correctly with no cache involved.
- `tests/Update-DFPackageCache.Tests.ps1`: drop the assertion that it calls `Get-DFCatalogInstalled -Force` (parameter no longer exists); update to reflect the simplified re-warm flow.
- `tests/Resolve-DFCatalogQueryMerge.Tests.ps1`: no `-Force`/cache-related assertions should exist there already (this file was added in the tool-identity-guide work and doesn't touch installed-status caching); confirm no incidental coupling.
- New or updated test coverage for the `Write-Progress` status line addition, matching the existing pattern used for the search-phase progress messages.

## Out of Scope / Future

- Investigate whether pipx maintains on-disk venv metadata (a `pipx_metadata.json`-style file per venv, or similar) that could let `Get-DFCatalogPypiInstalled` read state directly instead of spawning `pipx list --json`, the same way all 6 other providers already avoid shelling out. This repo currently has no pipx-installed packages to inspect the real on-disk layout against; worth revisiting when real venvs are available to verify against.
- Manifest/binary-level install verification (the originally-suspected problem) remains unimplemented, since it was ruled out as unnecessary during this design — today's package-ID-level matching already correctly handles multi-binary collections. If a genuine binary-level verification need surfaces later (e.g., detecting a partially-broken install where the package manager's bookkeeping says "installed" but a key binary is actually missing), it would be a separate, future spec.
