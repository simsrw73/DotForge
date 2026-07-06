# 05 — Package catalog info (trifle)
#
# Find-DFPackage (alias: trifle) answers "what is this tool, is it installed,
# where from, and what do the catalogs carry?" across scoop, winget, choco,
# npm, PyPI, crates.io, and PSGallery — cache-first, so warm queries answer in
# ~200 ms. Requires $Env:XDG_CACHE_HOME (set by Initialize-DFEnvironment).

Import-Module DotForge
Initialize-DFEnvironment

# ── Interactive lookups ────────────────────────────────────────────────────
trifle ripgrep                    # info card: installed via scoop? versions everywhere?
trifle rg                         # winget monikers resolve too (rg → ripgrep)
trifle static site generator      # keyword search → compact match table
trifle bat -Source scoop,winget   # restrict to specific catalogs
trifle rg -Fresh                  # block on live catalog data instead of cache

# ── Detail view ────────────────────────────────────────────────────────────
# A single confident match (exact id or exact name/moniker) renders
# a detail card — the info card plus one catalog's extra detail (manifest
# notes, dist-tags, GitHub description, …). "+N more matches" appears on the
# card when other candidates also matched.
# trifle zed                        # detail card
# trifle zed -All                   # force the full match table; Id column
#                                    # shows values usable as `trifle <source>:<id>`
# trifle winget:Zed.Zed -GitInfo    # qualified id + GitHub stars/release/activity
# ftrifle zed -Readme               # fzf live-search with instant preview cards;
#                                    # Enter -> detail card, then paged readme

# ── Discovery (categories) ─────────────────────────────────────────────────
# A curated, offline taxonomy ships with the module (~70 well-known CLI
# tools). Every match still resolves through a live catalog search — the
# database is an index, never a cached snapshot.
tcats                              # list every valid -Category/-WorksWith term, with live counts
# trifle -Category search           # facet search: every seed-db tool tagged 'search'
# trifle -Category search -WorksWith filesystem   # AND across facets
# trifle ripgrep                    # detail card now also shows Category/Related/Alt-to
# ftrifle -Categories               # browse the vocabulary in fzf, drill into a facet

# `trifle zed` never merges the winget Zed editor with choco's unrelated
# `zed` package just because they share a name — cross-catalog merges
# require a verified identity link (Tools/*.json or the shipped
# tool-identity guide), never a name-string guess.

# ── Scripting ──────────────────────────────────────────────────────────────
# Piped output is always raw DotForge.ToolInfo objects (no ANSI). For capture
# via assignment, use -AsObject (assignment looks interactive to pipeline
# detection):
$info = trifle ripgrep -AsObject
$info | Where-Object Installed | Select-Object Name, InstalledVia, InstalledVersion

# Which catalogs carry it, at which version?
($info | Select-Object -First 1).Latest    # ordered: scoop → winget → choco → …

# ── Fuzzy browser ──────────────────────────────────────────────────────────
ftrifle                           # fzf over every locally cached package; Enter → card

# ── Scheduled cache refresh ────────────────────────────────────────────────
# Keep caches warm so interactive queries never wait on the network. Run once
# (elevated not required for a per-user task):
#
#   $action  = New-ScheduledTaskAction -Execute 'pwsh' -Argument (
#       '-NoProfile -Command "winget source update; Import-Module DotForge; Update-DFPackageCache -Quiet"'
#   )
#   $trigger  = New-ScheduledTaskTrigger -Daily -At 6am
#   $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -RunOnlyIfNetworkAvailable
#   Register-ScheduledTask -TaskName 'DotForge catalog refresh' `
#       -Action $action -Trigger $trigger -Settings $settings
#
# IMPORTANT — why `winget source update` is in the action: the winget catalog
# is read from the source.msix that winget itself downloads, and winget only
# refreshes that file when winget runs. Update-DFPackageCache re-extracts
# whatever msix is present — it cannot make winget download a newer one, so on
# a machine that rarely runs winget the index silently ages (trifle's Cache
# line shows it, e.g. "winget 61d"). `winget source update` (~5s) first keeps
# winget data as fresh as the rest.
#
# Inspect / remove the task later:
#   Get-ScheduledTask -TaskName 'DotForge catalog refresh' | Get-ScheduledTaskInfo
#   Unregister-ScheduledTask -TaskName 'DotForge catalog refresh' -Confirm:$false
#
# Or refresh manually whenever you like:
#   winget source update; Update-DFPackageCache
