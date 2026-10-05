# DotForge Thermo-Nuclear Code Quality Review (Claude)

Scope: the whole module — `Public/` (25 files, 3.1k lines), `Private/` (51 files, 5.9k), `Tools/*.ps1`
(28 files, 2.3k), `build/` (16 files, 4.2k), plus `DotForge.psm1`/`.psd1`. Tests were read only where
they explain a design choice.

Standard applied: the "thermo-nuclear code quality review" prompt
(`cursor-team-kit/skills/thermo-nuclear-code-quality-review`), adapted from a branch diff to the whole
codebase. Its question for every area is not "is this tidy?" but "is there a code-judo move that
deletes a category of complexity?" The findings below are ranked by how much complexity each move
would delete, not by how easy it is. Every claim was checked against the code; the evidence column
names the file and line.

The earlier audits (`audit.claude.md`, `audit.codex.md`, `audit.gemini.md`) were not used as inputs.
Where this review disagrees with one of them, it says so.

## Verdict

**Not approved against this bar** — not because the code is sloppy (it isn't; see "What holds up"),
but because the same handful of concepts are implemented two or three times over, and several
"cross-cutting" decisions (is XDG set? should I use color? which catalogs exist?) are re-made locally
at every use site instead of once. No file is over 1,000 lines, so nothing here is a size emergency;
the problems are duplication of *ideas*, which grows faster than line counts show.

The six changes that would delete the most complexity, in order:

1. One "release data file" abstraction instead of two hand-copied stacks (categories, identities).
2. The catalog provider record as the single source of truth for which catalogs exist.
3. Normalize a tool record once at load time, so 59 defensive property reads become plain access.
4. Resolve XDG paths through one accessor that applies defaults, so "not set" stops being a branch.
5. Package-manager pickers as data (a spec per manager) plus one generator.
6. Hoist the installed-package snapshot out of per-query (and per-facet-key) code.

## 1. Missed code-judo: the "release data file" concept is written twice (presumptive blocker)

**What.** "A JSON data file that ships with the module, can be superseded by a newer copy downloaded
from the latest release into `$XDG_DATA_HOME\dotforge\`, is schema-validated, falls back to the shipped
copy if the downloaded one is corrupt, and warns once if neither loads" is a single concept. It is
implemented twice, end to end, as four parallel file pairs:

| Role | Categories | Identities |
| --- | --- | --- |
| Loader (resolve shipped vs refreshed, two-tier fallback, warn once) | `Private/Get-DFCategoryDb.ps1` | `Private/Get-DFToolIdentityGuide.ps1` |
| Updater (download, validate, atomic write) | `Public/Update-DFCategoryDb.ps1` | `Public/Update-DFToolIdentityGuide.ps1` |
| Download seam | `Private/Invoke-DFCategoryDbDownload.ps1` | `Private/Invoke-DFToolIdentityGuideDownload.ps1` |
| Schema validator, incl. a private `PSProp` | `Private/Test-DFCategoryDbSchema.ps1` | `Private/Test-DFToolIdentityGuideSchema.ps1` |

**Evidence.** After normalizing names, the two `Update-*` files differ in 16 lines, almost all help text.
The download seams differ only in names. The loaders' resolution and fallback blocks (the
`$refreshedUpdated -gt $shippedUpdated` comparison, `$tryLoad…` scriptblock, `$usedRefreshed` retry,
`$script:…Warned` flag) are identical modulo names. Only the *index building* at the end differs.

**The move.** One private pair, parameterized by data:

```powershell
# Private/DFReleaseData.ps1
function Read-DFReleaseData  { param($FileName, [scriptblock]$Validate, $Label) }   # resolve + fallback + warn-once; returns raw doc or $null
function Update-DFReleaseData { param($FileName, [scriptblock]$Validate, $Label) }  # download + validate + atomic write
```

`Get-DFCategoryDb` and `Get-DFToolIdentityGuide` shrink to "read raw, build my indexes"; the public
`Update-DFCategoryDb`/`Update-DFToolIdentityGuide` stay (public API) as two-line calls. Both
download seams and both copies of the fallback logic disappear. A third data file (there will be
one — `data/tool-conformance.json` is the obvious candidate) then costs one call, not four files.

**Payoff.** About 250 lines and four files deleted; the fallback rules can no longer drift apart.

## 2. The list of catalogs is hard-coded in eight places (presumptive blocker)

**What.** The provider registry (`$script:DFCatalogProviders`, filled by each `DFCatalog.<Name>.ps1`)
already *is* the list of catalogs. Yet the seven names are also typed out in:

- `Private/DFCatalog.ps1:18` — `$script:DFCatalogOrder`
- `Public/Find-DFPackage.ps1:106` — `[ValidateSet(...)]`
- `Public/Find-DFPackage.ps1:155` — `$canonicalOrder = @(...)`
- `Public/Find-DFPackage.ps1:187` — the qualified-id regex `scoop|winget|choco|...`
- `Public/Select-DFPackage.ps1:73` and `Public/Update-DFPackageCache.ps1:51` — two more `ValidateSet`s
- `Private/Get-DFCatalogInstalled.ps1:5-24` — two *more* tables keyed by the same names
  (`$DFCatalogInstalledDeps`, `$DFCatalogInstalledFn`), a second registry that duplicates the
  provider record's own `GetInstalled` field.

Adding an eighth catalog means a new provider file plus eight coordinated edits — exactly the kind of
central, name-keyed list `docs/plugin-architecture.md` forbids.

**The move.** Make the provider record carry everything, and derive the rest:

- Give each record `Order` and `Files` (the dot-source list the parallel installed fetch needs; winget's
  includes `Invoke-DFSqliteQuery.ps1`). Delete both tables in `Get-DFCatalogInstalled.ps1`; pass the
  provider records to `Invoke-DFCatalogInstalledFetch`.
- Replace the `ValidateSet`s with one `[ValidateScript({ $_ -in (Get-DFCatalogName) })]` plus an
  `[ArgumentCompleter]`, and the regex alternation with `(Get-DFCatalogName) -join '|'`.
- The seven registration blocks themselves are pure boilerplate: every `Search`, `GetInstalled`,
  `Refresh` and `Detail` member is a one-line scriptblock forwarding to `<Verb>-DFCatalog<Name>…`.
  A `Register-DFCatalogProvider -Name choco -Kind query-cache` that binds by naming convention, with
  explicit overrides only where they differ (scoop/winget `Test`, `Refresh`), deletes ~60 lines of
  wrappers that add indirection without adding meaning.

## 3. The tool record is an untyped bag, so every reader re-validates it

**What.** `Import-DFToolDb` validates two fields and returns the parsed JSON unchanged. Every consumer
then reads it defensively: there are **59** `PSObject.Properties['x']?.Value` reads across `Public/`,
`Private/` and `Tools/`, and defaults are re-derived at each use (`type ?? 'exe'` four times,
`prewarm ?? $true`, `preview_window ?? 'right:60%'`, …). `Test-DFToolSchema.ps1` and both data-file
validators each define their own identical `PSProp` helper (`Private/Test-DFToolSchema.ps1:29`,
`Test-DFCategoryDbSchema.ps1:30`, `Test-DFToolIdentityGuideSchema.ps1:30`).

**The move.** Normalize once, at the boundary. `Import-DFToolDb` returns records with every optional
field present and defaulted (`type='exe'`, `aliases=@{}`, `env=@{}`, `packages=@{}`, `dependsOn=@()`,
`prewarm=$true`, `picker=$null`, …), args arrays coerced to arrays. Downstream code reads
`$tool.type`, `$tool.aliases` directly. Two bugs fixed this session were exactly this invariant leaking:
`@($null).Count -eq 1` turning a missing `args` into one argument
(`Private/Register-DFToolAliases.ps1`), and the `if`-expression unwrap of a one-element array. A
normalized record makes that class of bug structurally impossible rather than individually patched.
Hoist the one `PSProp` into a shared private file for the validators that still need it.

## 4. XDG "not set" is a branch in seven places instead of a default in one

**What.** `Initialize-DFEnvironment` fills in XDG defaults, but nothing guarantees it ran, so
consumers each decide what to do when a variable is missing — and decide differently:

- Warn and do nothing: `Complete-DFToolSetup.ps1:52`, `Update-DFCategoryDb.ps1:50`,
  `Update-DFToolIdentityGuide.ps1:52`, `Get-DFHelpTopicList.ps1:17`, `Tools/vivid.ps1:61`.
- Warn and disable caching: `DFCatalog.ps1:116`.
- Warn, different text: `Tools/oh-my-posh.ps1:29`.
- Silently fall back to a default: `Tools/carapace.ps1:42`.
- Crash: `Tools/psreadline.ps1:72` (`Join-Path $Env:XDG_STATE_HOME …` with no guard) — the error users
  hit when `Register-DFTool` runs before `Initialize-DFEnvironment`, which the new docs now have to
  explain in three places.

**The move.** One accessor, `Get-DFXdgPath -Kind Config|Data|State|Cache|Bin`, that returns the
environment value or the spec default (`$HOME\.config`, …). Every site above calls it; all seven
warning branches and the crash disappear, and "call `Initialize-DFEnvironment` first" stops being a
requirement anyone has to remember. `Initialize-DFEnvironment` keeps its job (export the variables so
*other* programs see them, create the folders, report package managers).

## 5. Package-manager pickers: the control flow is shared, only the commands differ

**What.** `Tools/winget.ps1`, `scoop.ps1` and `choco.ps1` (254, 284, 278 lines) each define a
dependency guard plus three pickers (search→install, installed→uninstall, outdated→update) and a
`Ctrl+G` chord. That's nine pickers and three chords with one control flow: check dependency → build
`name\tid` lines → `Invoke-DFPackageManagerPicker` → branch on the pressed key → run the action or
return the command string. The three chord blocks are byte-identical except for one function name.

**Disagreement with `audit.claude.md` §2.3.** That audit stopped at extracting the fzf wiring
(`Private/Invoke-DFPackageManagerPicker.ps1`, since implemented) because "each file talks to its
package manager completely differently." True — but that difference is *data*: which command lists
packages, how to parse a line, which string is the install command, which call installs. None of it is
control flow. A spec per manager makes the differences explicit and the sameness free:

```powershell
$spec = @{
    Name = 'winget'; Chord = 'Ctrl+g,w'
    Require      = { [bool](Get-Command Find-WinGetPackage -EA Ignore) }; RequireHint = 'Install-Module Microsoft.WinGet.Client -Scope CurrentUser'
    Preview      = 'winget show --id {2}'
    Search       = { param($q) Find-WinGetPackage $q | % { ,@($_.Name, $_.Id, $_.Version) } }
    Installed    = { Get-WinGetPackage | % { ,@($_.Name, $_.Id, $_.InstalledVersion) } }
    Outdated     = { Get-WinGetPackage | ? IsUpdateAvailable | % { ... } }
    InstallCmd   = 'winget install --id {0} --exact';  Install   = { param($id) Install-WinGetPackage -Id $id -MatchOption Equals }
    UninstallCmd = 'winget uninstall --id {0}';        Uninstall = { param($id) Uninstall-WinGetPackage -Id $id -MatchOption Equals }
    UpdateAll    = { winget upgrade --all };           Update    = { param($id) Update-WinGetPackage -Id $id -MatchOption Equals }
}
New-DFPackageManagerPickers -Spec $spec -Search Select-WingetPackage -Remove Remove-WingetPackage -Update Invoke-WingetUpdate
```

Each sidecar drops to ~40 lines of spec; the nine near-identical function bodies and three chord
blocks become one generator (with full comment-based help emitted once). Public names, aliases and
key behavior stay the same. Estimated net deletion: ~500 lines.

## 6. Orchestration: the installed snapshot is rebuilt per query, and per facet key

**What.** `Private/Resolve-DFCatalogQueryMerge.ps1:67` calls `Get-DFCatalogInstalled` (a seven-way
parallel runspace batch that dot-sources provider files) and `:103` reloads the identity guide on
*every* call. In category mode, `Public/Find-DFPackage.ps1:174` calls it once per matched tool, so a
facet search matching N tools builds N installed snapshots. The comment at `:47` claims a "cached unified
snapshot (15-min TTL)", but `Get-DFCatalogInstalled` documents itself as "always live … never
cached" — the comment is wrong, and the cost it was written to avoid is real.

Meanwhile the per-catalog searches (`:56-62`) run **sequentially**, including live web fetches on cache
misses — the independent work is serial while the dependent-free snapshot is the part that runs in
parallel.

**The move.** Split the merge into "search" and "annotate": take the installed snapshot and identity
index as parameters (computed once by the caller), so facet mode computes them once per command. Then
the searches are the obvious candidate for the same `ForEach-Object -Parallel` treatment the installed
fetch already uses — not as a micro-optimization, but because it makes the flow "fan out, then merge"
instead of a hand-written progress loop.

## 7. Duplicate cache-first engines in `Private/DFCatalog.ps1`

**What.** `Get-DFCatalogDetailCache` (`:483`) and `Search-DFCatalogQueryCache` (`:697`) are the same
algorithm: derive key → TTL lookup (the identical ternary on both) → path → read → if fresh serve, if
stale schedule refresh and serve → else fetch → on failure fall back → write. They differ only in
subfolder, single-vs-many result, rehydration, and the pseudo-provider rule.

**The move.** One `Invoke-DFCacheFirst -Path -Ttl -Fetch -OnStale -Rehydrate` that owns the state
machine; the two callers supply the differences. While here, `DFCatalog.ps1` (795 lines) is a grab-bag —
XML helpers, cache I/O, record constructors, two engines, provider lookup, the seen-query LRU. Split
it by concept (`DFCatalog.Cache.ps1`, `DFCatalog.Records.ps1`, `DFXml.ps1`) before it is the first
file over 1k.

The atomic "write to `<file>.tmp.<pid>`, then `Move-Item`" idiom is written out six times
(`Complete-DFToolSetup`, both `Update-*`, `DFCatalog.ps1` twice, `DFCatalog.Winget.ps1`). One
`Write-DFFileAtomic -Path -Content` removes it.

## 8. `Register-DFTool` is five concerns in one function

**What.** `Public/Register-DFTool.ps1` (272 lines) does: module prewarm (`:145`), role-winner
resolution (`:161`), the per-tool loop (`:193`), completion-stack finalization (`:234`), and the
coreutils warning (`:235`), all inside a `try` (`:146`) whose body isn't indented and whose `finally`
is at `:256`. About a third of the file is comments explaining history ("measured ~77% reduction…",
"extracted verbatim…").

**The move.** The per-tool loop already delegates to five well-named helpers; finish the job. Extract
`Get-DFRoleWinners` (pure: tools + `$DFConfig.Defaults` → winner map) and
`Write-DFConflictNotice`. The body then reads as the algorithm it is:

```powershell
$tools   = Get-DFRegistrationSet …      # resolve names / -All / SkipTools, topo-sort
$winners = Get-DFRoleWinners $tools
$job     = Start-DFModulePrewarm (… module tools …)
try {
    $registered = foreach ($t in $tools) { if (Register-DFOneTool $t $winners) { $t.name } }
    Initialize-DFCompletionStack -RegisteredTools $registered
    Write-DFConflictNotice
} finally { $job | Remove-Job -Force -ErrorAction Ignore }
```

Move the historical rationale into the design docs it already cites; keep one-line "why" comments.

## 9. Private helpers are duplicated because of a scoping belief that turns out to be false

**What.** `Tools/vivid.ps1:14` states that Private functions are unreachable from a `function:global:`
closure and that this is "a hard scoping constraint, not a missed refactor." On the strength of that,
theme-file resolution (absolute path → `$XDG_CONFIG_HOME\<tool>\themes\<name>.json` → bundled) is
written three times (`Tools/fzf.ps1:54`, `Tools/psreadline.ps1:119`, `Tools/glow.ps1:65`), and vivid
bypasses the mockable `Invoke-DFCommandCapture` seam.

**Evidence.** Calling a private function *by name* from such a closure does fail. But capturing it
first works: `$resolve = ${function:Resolve-DFThemeFile}` in the companion, then `& $resolve …`
inside `{ … }.GetNewClosure()`. Verified during this review with a throwaway module: by-name call
fails, captured-scriptblock call succeeds.

**The move.** One private `Resolve-DFThemeFile -Tool -Name`, captured by the three companions;
vivid uses the capture seam. Correct the comment in `vivid.ps1` so the next reader doesn't
re-duplicate on the same belief.

## 10. Smaller structural items

- **`New-DFToolPickerFunction`** builds two near-identical scriptblocks that differ only in how the
  list is produced, and copies every `$pX` into a `$capturedX` that `.GetNewClosure()` would capture
  anyway. Build the list scriptblock in the `if`, then one `Invoke-DFPicker` closure.
- **`Find-DFPackage`** (281 lines) contains a complete second mode: category search (`:121-180`) is
  its own function in all but name (`Find-DFCatalogFacet`). Card assembly also leaks into the command:
  the "GitHub — no repository resolved" line is appended outside `Format-DFToolDetailCard`.
- **Identity lookup** with scoop's bucket stripping is written twice inside `resolveDFTool`
  (`Resolve-DFCatalogQueryMerge.ps1`) and a third time in `Get-DFCategoryDbEntry`, whose comment says
  it "mirrors" the first. One `Resolve-DFIdentityKey -Source -PackageId` returning the candidate keys.
- **Color decisions**: `(-not $Env:NO_COLOR) -and $Host.UI.SupportsVirtualTerminal` is computed in five
  places, and `$Color ? "`e[..m" : ''` palettes are rebuilt in each formatter. One
  `Get-DFAnsiPalette -Invocation $MyInvocation` returning `@{ Bold; Faint; Reset; … }` (empty strings
  when color is off, honoring the piped check too).
- **`$DFConfig` access**: 25 raw reads with three spellings (`['X']` after a null check,
  `.X` after `Test-Path Variable:`, `Get-DFConfiguredTheme`). One `Get-DFConfig -Key -Default` makes
  the null-safety rule live in one place; the copy-pasted "Test the value, not the variable's
  existence" comment then has nowhere to be pasted.
- **Process-scoped caches** follow one pattern three times (`Import-DFToolDb`,
  `Resolve-DFPackageManager`, `Test-DFToolAvailable`: "cache in `$script:` unless the caller passed an
  explicit argument"). Fine as a pattern; worth a one-line note in `docs/plugin-architecture.md` so
  it stays one pattern.

## 11. `build/`: an author-time pipeline with no consumer

**What.** The package-universe pipeline — `build/Build-DFPackageUniverseRaw.ps1`, `…Links.ps1`,
`…Tools.ps1`, six `build/Private/DFPackageUniverse.*.ps1` files (~2,400 lines) and six test files —
builds `build/.package-universe/universe.db`. Nothing reads it: the shipped data files come from
`Build-DFCategoryDb.ps1` and `Build-DFToolIdentities.ps1`, which take other inputs, and no module code
references it. It is also what puts a full `microsoft/winget-pkgs` clone in the repo tree, which is
the documented cause of the `Publish-PSResource` hang and makes any unscoped `grep -r` crawl gigabytes.

**The move.** Decide: if it will feed the category and identity builds, wire one consumer now so it
stops being speculative. If not yet, move it to its own branch or repo until it does. Either way, move
the clone outside the module tree (for example `$XDG_CACHE_HOME\dotforge-build\winget-pkgs`) so the
publish workaround and the crawl hazard both disappear.

## What holds up well

- The plugin invariant is real: no `switch ($tool.name)` in core code; tools are JSON plus optional
  companions, and the core is a set of small, well-named steps.
- Seams for testing are deliberate and consistent (`Invoke-DFFzf`, `Invoke-DFPagerExe`,
  `Invoke-DFCommandCapture`, `-FetchItems`, download seams).
- Failure policy is coherent: undocumented external behavior degrades silently and is catalogued in
  `docs/external-dependencies.md`.
- Atomic writes and "never cache an empty result" are applied wherever caches exist.
- No file over 1,000 lines; most files have one clear subject.

## Suggested order

1. **Normalize the tool record (3) and add `Get-DFXdgPath` (4).** They're small, they remove whole
   bug classes, and they simplify everything that follows.
2. **One release-data abstraction (1)** and **provider record as source of truth (2).** These are the
   biggest deletions in the module proper.
3. **Hoist the installed snapshot (6)**, then fold the two cache engines (7).
4. **Package-manager pickers as specs (5)** and the theme-file resolver (9). These are the biggest
   deletions in `Tools/`.
5. **Decompose `Register-DFTool` (8) and `Find-DFPackage` (10)** once the helpers they would call exist.
6. **Resolve the package-universe pipeline's status (11).**

Every step is behavior-preserving and covered by the existing 1,699-test suite plus the docs tests,
which run each documented example as written.

## Resolution (2026-10-05)

Worked through the same day. Item 11 (the package-universe pipeline) was left alone at the author's
request: it is experimental work in progress. Everything else is done, behavior-preserving except
where noted, with the full suite (1,713 tests, including the docs tests) passing after each step.

| # | Finding | What was done |
| --- | --- | --- |
| 1 | Release data written twice | `Private/DFReleaseData.ps1`: `Read-DFReleaseData`, `Update-DFReleaseData`, `Invoke-DFReleaseAssetDownload`. Both loaders now only build their indexes; both `Update-*` cmdlets are one call. Two download-seam files deleted. Also restored the `.EXAMPLE` keyword an earlier doc pass had dropped from both `Update-*` help blocks. |
| 2 | Catalog list hard-coded in 8 places | `Private/DFCatalog.Base.ps1`: `Register-DFCatalogProvider` (hooks bound by naming convention, overrides only for scoop/winget) and `Get-DFCatalogName`. The three `ValidateSet`s, the `source:id` regex, `$script:DFCatalogOrder` and both installed-fetch tables are gone; the parallel fetch takes provider records. |
| 3 | Untyped tool records | `ConvertTo-DFToolRecord` normalizes every record at load; the 59 defensive reads of tool fields became plain access, and a StrictMode test reads every field of every shipped record. |
| 4 | XDG "not set" handled 7 ways | `Get-DFXdgPath` everywhere, including `Expand-DFXdgPath` and `Initialize-DFEnvironment`. **Behavior change:** DotForge's own commands now work without `Initialize-DFEnvironment` (they use the XDG defaults) instead of warning or crashing. |
| 5 | Package-manager pickers | One engine, `Invoke-DFPackageManagerAction`, plus a spec per manager and `Register-DFPrefillChord`. The three sidecars went from 816 to 617 lines. |
| 6 | Snapshot per query and per facet key | `Resolve-DFCatalogQueryMerge` takes `-InstalledInfo`/`-IdentityGuide`; a category search now takes one snapshot (a test proves 2 → 1 for two tools). The wrong "15-min TTL" comment was corrected. |
| 7 | Duplicate cache engines, grab-bag file, atomic writes | `Invoke-DFCacheFirst` and `Get-DFCatalogTtl`; `DFCatalog.ps1` split into `DFXml.ps1`, `DFCatalog.Records.ps1` and the cache core (795 → 513 lines); `Write-DFFileAtomic` replaces four hand-written temp-and-rename sequences. |
| 8 | `Register-DFTool` doing five jobs | `Private/Register-DFToolSteps.ps1`: `Get-DFRegistrationSet`, `Get-DFRoleWinners`, `Invoke-DFToolRegistration`, `Write-DFConflictNotice`. 272 → 126 lines. |
| 9 | Duplicated theme lookup | `Resolve-DFThemeFile`, captured by the fzf, psreadline and glow companions via `${function:...}`; the incorrect "hard scoping constraint" comment in `vivid.ps1` was corrected. |
| 10 | Smaller items | `New-DFToolPickerFunction` builds one closure; `Find-DFCatalogFacet` extracted from `Find-DFPackage` (281 → 232 lines) and the GitHub line moved into the card formatter; `Get-DFIdentityKeys`; `Test-DFColorOutput` and `Get-DFAnsiPalette`; `Get-DFConfig`; the cache pattern documented in `docs/plugin-architecture.md`. |

**Bugs found while doing it**

- `Get-DFIdentityKeys` replaced a lookup that stripped everything before `/` for every catalog, so a
  scoped npm package (`@scope/zed`) could merge into an unrelated tool's row. Now only scoop ids are
  stripped. Covered by a new test.
- Two module files used the same `$script:DFPackageManagers` name (the new spec table collided with
  `Resolve-DFPackageManager`'s cache). Renamed, and `tests/ModuleState.Tests.ps1` now fails when two
  files initialize the same `$script:` variable.
- The docs-example runner let children inherit the test run's stdin, which intermittently hung glow.
  Children now get a closed stdin.

**Where the review was revised**

- **Parallel catalog searches (6): not done.** Each runspace would need to import the module, which
  costs more than the warm-cache searches it would parallelize (milliseconds each). Only cold misses
  would gain.
- **Picker generator (5): replaced by an engine.** Generating the nine functions would hide them from
  the help test and the reference generator (both parse the sidecars) and turn `Get-Help` into
  generated text. The functions stay explicit with their help; each body is one engine call.
- **Shared `PSProp` (3): kept local.** The two data-file validators are also dot-sourced on their own
  by build scripts; a four-line local helper keeps them self-contained.
- **vivid capture seam (9): not changed.** vivid's tests stub the command directly; switching to
  `Invoke-DFCommandCapture` would change test mechanics for no behavior gain.

**Test isolation lesson.** Making unset XDG variables mean "the real default" exposed tests that
relied on unset meaning "disabled": during the work they wrote into the developer's real XDG folders
(cleaned up). Those tests were removed, the carapace tests now isolate `XDG_CONFIG_HOME`, and
`CLAUDE.md` now requires tests to point every `XDG_*_HOME` they can write to at `$TestDrive`.
