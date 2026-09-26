# DotForge Architectural Audit (Claude)

Scope: `Public/`, `Private/`, `Tools/*.json`+`.ps1`, `build/`, `DotForge.psd1`/`.psm1`, cross-checked
against `CLAUDE.md`, `docs/*.md`, and `TODO.md`. This is a read-only review — no changes were made.

Two other audits already exist in the repo (`audit.codex.md`, `audit.gemini.md`). I did not treat
either as a starting point or a source of truth — every claim below comes from reading the actual
code path myself. Where that independent read happens to land on the same conclusion as one of the
other audits, I've said so and shown the evidence I used to get there (not theirs). Where I checked a
claim from one of them and found it needed correcting — either downgraded (the SQL-construction
item, §3.3) or substantiated more precisely with evidence they didn't show (the package-manager
picker duplication, §2.3) — I've said that explicitly too, including one place I actively disagree
with the scope of a proposed fix (§2.3's "don't collapse all three PMs into one function" point).

## Executive summary

This is an unusually disciplined PowerShell module for its category. The plugin architecture
(`Tools/<name>.json` + optional `.ps1`) is genuinely followed, not just declared — I read the tool
registration path end-to-end and never found a `switch ($tool.name)` in core code. The author-time
conformance harness (`build/Test-DFToolConformance.ps1` + `data/tool-conformance.json`) is a rare
and valuable feature: most projects that configure "other people's tools via undocumented behavior"
never build a ledger to catch when that behavior silently drifts. Test coverage is broad (Pester
files roughly track 1:1 with source files) and `docs/external-dependencies.md` is the kind of
document most projects only write after an incident, not before one.

The main cost of that discipline is size: `Register-DFTool` has grown into a 348-line function that
does seven unrelated jobs, and a few caching helpers repeat a bug pattern that one sibling function
(`Get-DFCategoryDb`) has already solved correctly. None of what follows is "this design is wrong" —
it's "this design has earned enough surface area that a few specific extractions and one shared
helper would pay for themselves."

## Part 1 — Architecture

### 1.1 What's genuinely well designed

**The plugin boundary holds up under inspection.** `Register-DFTool` reads `xdg`, `env`, `aliases`,
`picker`, `role`, `dependsOn`, and `themeMap` off each tool object via
`$tool.PSObject.Properties['x']?.Value` and no-ops when absent — exactly the invariant
`docs/plugin-architecture.md` describes. Adding a tool really does mean adding a JSON file (and
maybe a sidecar), not touching `Register-DFTool.ps1`. I verified this against `Tools/eza.json`,
`Tools/zoxide.json`, and `Tools/fzf.json` — three tools with very different needs (role-based alias
suppression, a picker, XDG env vars, a raw `env` block) and none of them required a code branch.

**There are two independent, parallel plugin systems, and both are done the same way.** Beyond the
tool registry, `Private/DFCatalog.*.ps1` implements a second registry for package-manager/registry
providers (scoop, winget, choco, npm, pypi, crates, psgallery). Each provider file populates
`$script:DFCatalogProviders['name'] = @{ Test; Search; GetInstalled; Refresh; Detail }` — a
hashtable of scriptblocks — and `Get-DFCatalogProvider`/`Get-DFCatalogDetail` dispatch through that
table, never through a name check. This is the same "declare a hook, core reads it generically"
shape as the tool registry, arrived at independently for a different subsystem. That's a good sign
for the architecture's coherence — but `docs/plugin-architecture.md` only documents the *tool*
registry. I'd fold the catalog-provider pattern into that doc (or a sibling doc) as a second worked
example, both to make the parallel explicit and so a future contributor adding an 8th provider
doesn't have to reverse-engineer the contract from `DFCatalog.Npm.ps1`.

**The conformance harness is the standout feature.** `build/DFConformance.ps1` defines a claim-id
grammar (`tool/honors-{xdg|env|config-read|config-content|flag}[:name]`), probe kinds
(`env-then-spawn`, `flag-then-spawn`, `manual`, `code`), and a verdict ledger. Sidecars that work
around a tool's failure to honor its own documented config cite the claim id in a comment (`#
adapter for glow/honors-env:GLOW_CONFIG_DIR`), and the harness flags adapters that no longer point
at a failing claim. This closes the loop that `docs/external-dependencies.md` opens: instead of
"we assume tool X behaves like Y, and it might not," there's an executable check for whether it
still does. I didn't find an equivalent pattern in comparable dotfile-manager projects I'm aware of.

**`ConvertTo-DFPath` as a single normalization primitive is the right call.** Every path boundary
(env vars, `Add-DFToPath`, `New-DFDirectory`, shims, catalog cache paths) routes through it, and it
correctly treats a relative path as a bug (warn + pass through) rather than silently resolving
against CWD — a common source of "works on my machine" profile bugs when a function is called from
an unexpected directory during shell startup.

### 1.2 The one real architectural wart: `Register-DFTool`

At 348 lines, `Public/Register-DFTool.ps1` is nearly 3x the size of the next-largest `Public`
function and does all of the following in one function body, one loop:

1. Resolve the tool set (name/all, skip-list, topo-sort)
2. Resolve `$DFConfig.Defaults` role-winner suppression
3. Per tool: availability probe (module vs. exe)
4. Per tool: XDG config application (4-way switch on `xdg.method`)
5. Per tool: non-XDG `env` block application
6. Per tool: alias/wrapper-function creation (with builtin-alias removal dance)
7. Per tool: picker codegen (building a scriptblock from JSON strings via `[scriptblock]::Create`)
8. Per tool: companion `.ps1` dot-sourcing
9. Per tool: one-time `.setup.ps1` dot-sourcing
10. Completion-stack initialization
11. Coreutils conflict warning

None of this is *wrong* — every piece is short and defensible in isolation, and per
`docs/plugin-architecture.md`'s own boundary ("core" = the generic registration path), all of it
correctly belongs in core. The problem is testability and readability, not correctness: today,
verifying "does picker codegen handle a multi-word `list` command" or "does alias suppression
correctly skip only the losing tool's overlapping keys" requires driving the entire function through
`Register-DFTool`, because none of steps 4–9 are independently callable. (`tests/Register-DFTool.Tests.ps1`
does exactly this — it's a big, capable test file, but every test pays the setup cost of the whole
pipeline to exercise one branch.)

**Recommendation:** extract steps 4, 6, 7, 8/9 into private functions that take `$tool` (and the
small amount of shared state each needs — `$activeRoleWinners`, `$resolvedToolsPath`) and return or
mutate nothing beyond what they already do:

- `Set-DFToolXdgConfig -Tool $tool` (the `switch ($xdgMethod)` block)
- `Register-DFToolAliases -Tool $tool -RoleWinner $roleWinner` (the alias/wrapper-function block)
- `New-DFToolPickerFunction -Tool $tool` (the picker codegen — this one especially benefits, since
  it's the densest, most string-manipulation-heavy piece and the one with an open TODO bug about
  `list_accepts_path` splitting on whitespace)
- `Invoke-DFToolCompanion -Tool $tool -ToolsPath $resolvedToolsPath` (companion + one-time setup)

`Register-DFTool` itself becomes an orchestrator: resolve tools → topo-sort → role resolution →
`foreach ($tool in $tools) { <five one-line calls> }` → completion stack → conflict check. This is a
pure internal refactor — it doesn't touch the JSON schema, doesn't add a new extension point, and
every extracted function is trivially unit-testable against a hand-built `$tool` PSCustomObject
without needing a real `Tools/` directory or a real `Get-Command` probe.

★ Insight ─────────────────────────────────────
This is a case where "the core invariant says this all belongs in core" and "this function should
be smaller" are both true at once. The plugin-architecture doc's core/plugin boundary is about
*where* logic lives (never branch on a tool's identity), not about *how many functions* implement
core's side of the contract. Splitting a god-function into several core-owned private functions
doesn't create a new plugin surface — it's orthogonal to the invariant the doc protects, which is
easy to conflate when a codebase has one dominant architectural rule.
─────────────────────────────────────────────────

### 1.3 The declarative picker system is clever but stringly-typed

`Tools/*.json`'s `picker` block lets a tool declare an fzf picker purely as data: `list` (a command
string), `preview`, `action` (with `{}` substituted for the selected value), `parse` (a scriptblock
body as a string). `Register-DFTool` turns these into real scriptblocks via
`[scriptblock]::Create(...)` and a `.Replace('{}', '$v')` on the action string.

This is the right call for genericity — it's how a JSON file can describe behavior without the core
knowing what the behavior is. But it means picker logic is authored as unchecked strings: no
PSScriptAnalyzer, no syntax highlighting in the JSON file, and a bug like the currently-tracked
"`list_accepts_path` splits on whitespace, breaking quoted arguments" (TODO.md, Priority 2) is
exactly the class of bug this shape invites — `$capturedList -split '\s+'` has no way to know
`'eza --icons -1'` should split into 3 tokens while `'"C:\Program Files\eza.exe" -1'` shouldn't.
I don't think this warrants abandoning the string-based DSL (a fully-typed alternative would be far
more code for marginal safety gain on ~15 tool declarations), but it's worth noting the tradeoff
explicitly: every picker declaration is effectively untested PowerShell source until a real fzf
session exercises it, which is why `tests/Tools.PickerDeclaration.Tests.ps1` checking *declaration
honesty* (does the JSON's `picker` field match what the sidecar actually builds) is doing real work,
while the codegen's *runtime* correctness (quoting, multi-word commands) has comparatively thin
coverage — matching the TODO item asking for tests that "invoke generated picker functions, not just
tests that verify they exist."

## Part 2 — Code reuse

### 2.1 The `?.Value` idiom wants a helper, not because it's wrong, but because it's everywhere

`$obj.PSObject.Properties['name']?.Value` appears well over 100 times across `Private/` and
`Public/` — it's the correct, StrictMode-safe, documented way to read an optional PSCustomObject
property (`CLAUDE.md` calls it out explicitly for conformance fragments). I'm not suggesting it's a
mistake. But at this frequency it's also a repeated opportunity to typo a property name silently
(PowerShell won't warn you `'exeutable'` isn't `'executable'` — it just returns `$null`), and every
call site re-derives "and what's the default when absent" by hand (`?? 'exe'`, `?? ''`, `?? @()`,
...).

A tiny private helper —

```powershell
function Get-DFPropertyValue {
    param([Parameter(Mandatory)]$Object, [Parameter(Mandatory)][string]$Name, $Default)
    $v = $Object.PSObject.Properties[$Name]?.Value
    if ($null -eq $v) { $Default } else { $v }
}
```

— wouldn't replace every call site (some want the raw `$null` distinct from "absent," e.g. the
schema validator), but would collapse the ~30 `?? <default>` occurrences in `Register-DFTool` alone
into `Get-DFPropertyValue $tool 'header' ''`-style one-liners, and would give StrictMode-safe
property access a single place to harden later (e.g., logging unknown-field typos during
development) instead of 100+ inline sites. Low risk, pure addition, doesn't touch the plugin
contract.

Related: `Private/Test-DFToolSchema.ps1` defines its own local `PSProp` closure that reimplements
this exact lookup instead of using the `?.Value` idiom the rest of the codebase already settled on.
Minor, but it's the one place I found where the established pattern wasn't reused even though it
directly applies.

### 2.2 Catalog query-cache providers share near-identical boilerplate

`Search-DFCatalogNpm`, `Search-DFCatalogPSGallery`, `Search-DFCatalogPypi`, and (per the same shape)
crates each do nothing but forward to `Search-DFCatalogQueryCache -Provider 'x' -Fetch {...}`, and
each provider's `Get-DFCatalogXDetail` does the same against `Get-DFCatalogDetailCache`. The
provider-registration block at the bottom of each file is also structurally identical modulo the
provider name and three scriptblock references. Comparing `DFCatalog.Npm.ps1` and
`DFCatalog.PSGallery.ps1` line-for-line, the only real content is `Invoke-DFCatalogXFetch`,
`Get-DFCatalogXInstalled`, and `Invoke-DFCatalogXDetailFetch` — the rest (roughly 20 of each file's
~125–200 lines) is ceremony.

This is lower-value than the `Register-DFTool` split (it's 4 files, not a load-bearing 348-line
function), but a small factory would remove the duplication without hiding the real logic:

```powershell
function Register-DFCatalogQueryCacheProvider {
    param([string]$Name, [scriptblock]$Fetch, [scriptblock]$GetInstalled, [scriptblock]$DetailFetch)
    $script:DFCatalogProviders[$Name] = @{
        Name = $Name; Kind = 'query-cache'; Test = { $true }
        Search       = { param($Query, $Fresh) Search-DFCatalogQueryCache -Provider $Name -Query $Query -Fresh:$Fresh -Fetch $Fetch }
        GetInstalled = $GetInstalled
        Refresh      = { param($Query) if ($Query) { $null = Search-DFCatalogQueryCache -Provider $Name -Query $Query -Fresh -Fetch $Fetch } }
        Detail       = { param($PackageId, $Fresh) Get-DFCatalogDetailCache -Provider $Name -PackageId $PackageId -Fresh:$Fresh -Fetch $DetailFetch }
    }.GetNewClosure()
}
```

I'd scope this to the four `query-cache`-kind providers only — `Scoop` and `Winget` are structurally
different (index-kind, SQLite-backed, much larger fetch logic) and forcing them into the same
factory would be the "one abstraction too far" this codebase otherwise avoids.

### 2.3 The three package-manager pickers (`Tools/scoop.ps1`, `winget.ps1`, `choco.ps1`) repeat one template three times over

This is the largest reuse opportunity I found, and I read all three sidecars in full rather than
estimating from a diff. Each of `Tools/scoop.ps1`, `Tools/winget.ps1`, and `Tools/choco.ps1`
independently implements the same four-part shape:

1. An `Assert-DF<PM>[Module]` guard (module/binary present, else `Write-Warning` with the exact
   install command and return).
2. A `Select-<PM>Package` search-and-install picker: build `$items`, call `Invoke-DFPicker` with
   `-Delimiter "`t" -WithNth '1' -Expect 'alt-r' -Bind 'alt-i:execute(<pm> install {2} ...)'`, then
   branch on `$sel.Key -eq 'alt-r'` → call the PM's install cmdlet/CLI, else return the install
   command string for the caller to inspect/run.
3. A `Remove-<PM>Package` uninstall picker: same shape, `-Expect 'alt-c' -Bind 'alt-x:execute(...)'`.
4. An `Invoke-<PM>Update` picker: same shape with `-Multi`, `-Expect 'alt-a'`, branching on
   "update all" vs. the multi-selected subset.

Plus two verbatim-repeated details in every one of the nine pickers (3 files × 3 pickers): the
`'ping -n 2 127.0.0.1 >nul & <pm> ...'` preview-debounce prefix, and — at the bottom of each
file — an identical-shape `Set-PSReadLineKeyHandler -Chord 'Ctrl+g,<letter>'` block that reads the
current line, calls that file's `Select-<PM>Package -Query $line`, and inserts the resulting command
string back onto the line.

What's *not* shared, and matters for how I'd refactor this: each file talks to its package manager
completely differently — scoop through the `Scoop` PowerShell module (`Get-ScoopApp`,
`Install-ScoopApp`, ...) with a `scoop-search` CLI fallback for the search step specifically; winget
through `Microsoft.WinGet.Client` (`Find-WinGetPackage -MatchOption Equals`, ...); choco through raw
CLI output parsing (`choco search -r` → pipe-delimited text, no object module exists) plus a
choco-specific elevation wrapper (`Invoke-DFChocoElevated`, routing through `gsudo` when configured).
And the `alt-i`/`alt-x` in-place binds in all three necessarily use each PM's raw CLI syntax rather
than a cmdlet, for a shared, load-bearing reason documented in every file: fzf's `--bind
execute(...)` runs in a `cmd` subshell that cannot invoke a PowerShell cmdlet, so the "run without
leaving fzf" path has to be a CLI invocation no matter which PM it targets.

**That last constraint is why I'd scope a shared helper narrower than "collapse all three files into
one,"** which is the failure mode a generic refactor here could fall into. I'd extract only the parts
that are byte-for-byte identical regardless of package manager — the picker wiring, not the package
manager calls:

```powershell
function Invoke-DFPackageManagerPicker {
    param(
        [string]$Verb,            # 'search' | 'uninstall' | 'update'
        [scriptblock]$ListItems,
        [string]$PreviewCommand,  # e.g. 'scoop info {2}' — the ping-debounce prefix is added here, once
        [string]$Header,
        [string]$ExpectKey,
        [string]$Bind
    )
    Invoke-DFPicker -List $ListItems -Delimiter "`t" -WithNth '1' `
        -Preview "ping -n 2 127.0.0.1 >nul & $PreviewCommand" -PreviewWindow 'right:60%' `
        -Header $Header -Parse { ($_ -split "`t")[1] } -Expect $ExpectKey -Bind $Bind
}
```

Each `Select-<PM>Package`/`Remove-<PM>Package`/`Invoke-<PM>Update` keeps its own item-building and
its own post-selection action (install/uninstall/update via that PM's own module or CLI) — that part
is genuinely PM-specific and shouldn't be forced into a shared abstraction. This removes the
repeated picker-wiring (delimiter, debounce prefix, preview window, parse) from nine call sites down
to one, without pretending scoop/winget/choco are more alike than they are. The PSReadLine
Ctrl+G-chord block is a second, smaller, equally mechanical duplication (3 near-identical blocks
differing only in chord letter and which `Select-*Package` to call) that a
`Register-DFPackageManagerQuickSearch -Chord 'g,s' -Selector { Select-ScoopPackage @args }`-style
helper could collapse the same way.

I'd weight this below the `Register-DFTool` split (§1.2) in priority, even though it's a larger raw
line count, because these three files are leaves — nothing else in the codebase depends on their
internal shape, so consolidating them is lower-risk but also lower-leverage than fixing the one
function everything else routes through.

### 2.4 `script:` scope prefix is applied inconsistently, with no behavioral difference

Seven `Private/` files declare `function script:Name { ... }` (`ConvertTo-DFPath`,
`Expand-DFXdgPath`, `Get-DFConfiguredTheme`, `Get-DFCoreutilsShadowSet`, `Get-DFToolSetupState`,
`Import-DFToolDb`, `Resolve-DFPackageManager`, `Resolve-DFThemeName`); the other ~35 just write
`function Name { ... }`. Because `DotForge.psm1` dot-sources every `Private/*.ps1` at the module's
own top-level scope, both forms land in the same place — `function Name` inside a dot-sourced file
already defines the function in the caller's scope (the module's script scope), so `script:` is a
no-op here, not a stricter or safer declaration. The inconsistency itself is harmless, but it reads
as if there's a meaningful distinction between "these 7 are script-scoped" and "these 35 aren't,"
which isn't true and could mislead a future contributor into thinking `script:` is required for some
category of private function (e.g., "ones with a module-level cache variable" — but
`Get-DFCategoryDb`, which has exactly that, doesn't use it). Worth picking one convention and
applying it uniformly, or documenting why the seven are special if there's a reason I didn't find.

## Part 3 — Refactoring targets

### 3.1 `New-DFShim`'s `cd /d` likely breaks relative-path arguments for every shimmed tool

The generated `.cmd` (`Public/New-DFShim.ps1:133-140`) does:

```
cd /d "<executable's own directory>"
"<resolved target>" %*
```

I traced this rather than assuming it's fine: the `cd` runs inside the shim's own `cmd.exe` process,
so it never affects the calling PowerShell session's `$PWD` — that part is safe. But it *does* change
what the **target executable** sees as its current directory. If a user runs a shimmed tool with a
relative-path argument — `ripgrep-shim.cmd pattern .\notes.txt` from `C:\Users\me\project` — the
shim first `cd`s into wherever the real `ripgrep.exe` lives, then runs `ripgrep.exe pattern
.\notes.txt`, so `.\notes.txt` resolves against the tool's install directory, not the directory the
user actually invoked it from. That's silent and surprising: the shim works perfectly for anything
that takes no path arguments or only absolute ones, and breaks unpredictably the moment someone
passes a relative one — exactly the kind of bug that survives a manual smoke test (`New-DFShim
-Name ripgrep; ripgrep --version`) and only surfaces later in real use.

Common shim generators (Scoop's own `.cmd`/`.exe` shims among them) deliberately do *not* change
directory — they exist purely to add indirection on `PATH`, and Windows already resolves an
executable's own DLL/resource dependencies relative to its own directory without any `cd` (that's
how the default DLL search order works), so `cd`-ing into the app directory isn't needed for that
purpose either. Unless there's a specific tool this was built to accommodate that genuinely needs
`cwd == its own install dir` (worth checking git history / the original design note if one exists),
I'd drop the `cd /d` line entirely and let the target inherit the caller's actual working directory:

```
"<resolved target>" %*
```

If some tool really does need it, that's a property of that one tool, not a default every shim
should carry — it'd fit the `.setup.ps1`/per-tool-declaration model better than a blanket behavior in
the shared shim template. `tests/New-DFShim.Tests.ps1` currently checks the shim's *content* (does it
contain the target path) but I didn't find a test that actually executes a generated shim with a
relative-path argument and asserts against the caller's cwd — that'd be the regression test this fix
needs.

### 3.2 The un-keyed-cache bug exists in two places, and the fix already exists in a third

Three private functions cache a computed result in a bare `$script:` variable, guarded by
`-Force`, but two of them ignore the very parameter that should invalidate the cache:

| Function | Cache var | Distinguishing param | Bypasses cache when param given? |
|---|---|---|---|
| `Import-DFToolDb` | `$script:DFToolDb` | `-ToolsPath` | **No** — first caller's `ToolsPath` wins for the session (tracked in TODO.md) |
| `Resolve-DFPackageManager` | `$script:DFPackageManagers` | `-Priority` | **No** — first caller's `Priority` wins (tracked in TODO.md) |
| `Get-DFCategoryDb` | `$script:DFCategoryDb` | `-Path` | **Yes** — `if (-not $Path -and -not $Force -and $script:DFCategoryDb)` |

`Get-DFCategoryDb` already contains the correct fix for this exact bug class: only consult the cache
when the caller *didn't* supply the parameter that would make a cached answer wrong. Applying the
identical guard shape to `Import-DFToolDb` (`if (-not $ToolsPath -and -not $Force -and
$script:DFToolDb)`) and `Resolve-DFPackageManager` (`if ($Priority equals the default -and -not
$Force -and ...)`) closes both open TODO items with a one-line change each, using a pattern the
codebase has already validated elsewhere — no new design needed, just consistency with itself. I'd
frame this as "apply the existing fix," not "invent a fix," when picking it up.

### 3.3 `Invoke-DFSqliteQuery`'s string-built SQL is a correctness risk more than a security one — but worth tightening

The function's own docstring is upfront about this: "No parameter binding — embed values
pre-escaped." I checked every call site rather than taking the design note at face value:

- `Get-DFCatalogLocalPackages.ps1` and two `DFCatalog.Winget.ps1` calls use fixed, literal SQL with
  no interpolated user data — no risk.
- The one call site that embeds free text (`DFCatalog.Winget.ps1:213-221`, the search path) does
  escape it first: `$safe = $normalized -replace "'", "''"` — standard SQL single-quote doubling —
  before building the `WHERE` clause.

So the current call sites aren't exploitable, and given this is a local, single-user, read-only
(`SQLITE_OPEN_READONLY`) query against the user's own machine (winget's own local index), the
realistic "attack" is a user crafting input that corrupts their own search query — a robustness bug,
not a privilege boundary crossing, since there's no other party whose trust could be violated. That
said, manual escaping is a discipline that has to be re-applied correctly at every future call site
forever, versus parameter binding (`sqlite3_bind_text`), which makes the class of bug structurally
impossible. Since the P/Invoke surface already exists in `Invoke-DFSqliteQuery`, adding
`sqlite3_bind_text`/`sqlite3_reset` and a `-Parameters` array parameter would remove the "did the
caller remember to escape" burden entirely for a modest addition to an already-compiled shim. I'd
prioritize this below the two items above — it's hardening a currently-correct call site, not fixing
an active bug.

### 3.4 `fzf`'s theme is hardcoded, bypassing the theme-resolution system every other themed tool uses

`Tools/fzf.json`'s `env.FZF_DEFAULT_OPTS` embeds a full catppuccin-mocha color string as a literal
JSON value. Compare `Tools/delta.ps1`, which resolves the *configured* theme through
`Get-DFConfiguredTheme -ToolKey 'DeltaTheme' -Default 'catppuccin-mocha'` and
`Resolve-DFThemeName -ThemeMap $DFCurrentTool.themeMap` before setting `DELTA_FEATURES` — so a user
who sets `$DFConfig.Theme = 'catppuccin-latte'` (or a `DeltaTheme` override) gets it reflected in
delta but not in fzf, which will keep rendering mocha's colors regardless of `$DFConfig.Theme`. This
is squarely inside the theming gap TODO.md already tracks ("Audit theming mechanisms... case by
case") — I'd add fzf explicitly to that list, since unlike `bat`/`mdcat`/`vivid` (which the existing
item calls out as needing a decision about env-var-vs-file-config precedence), fzf's case is simpler:
there's no competing config to clobber, it's just that the JSON hardcodes one theme instead of
routing through the resolver a sidecar could call. A `Tools/fzf.ps1` companion that resolves the
theme and sets `FZF_DEFAULT_OPTS` the way `delta.ps1` does would close this with the existing
mechanism, no new primitive needed.

## Part 4 — Simplification

- **`Get-DFTool`/`Find-DFTool`/`Install-DFTool`/`Register-DFTool` all repeat the same 4-line
  `$dbArgs = if ($ToolsPath) { @{ ToolsPath = $ToolsPath } } else { @{} }; $db = Import-DFToolDb
  @dbArgs` splat-forwarding idiom.** This one's genuinely minor (4 lines × ~6 call sites), but since
  it's *only* ever used to forward `-ToolsPath` into `Import-DFToolDb`, a private
  `Get-DFToolDbForCaller -ToolsPath $ToolsPath` wrapper would remove the splat boilerplate at each
  call site without adding an abstraction layer that hides anything — it's a rename more than a
  refactor.
- **`Register-DFTool`'s alias block silently special-cases zero-arg vs. multi-arg aliases**
  (`Set-Alias` for the former, a generated wrapper function for the latter) because PowerShell
  aliases can't carry arguments. This split is necessary, not a smell — but the comment explaining
  *why* (`aliasArgs.Count -eq 0`) is good and should stay if this block gets extracted per §1.2;
  it's exactly the kind of non-obvious PowerShell constraint a future editor could "simplify" away
  incorrectly.
- **`Test-DFToolSchema`'s validation is thin relative to the schema's actual surface** (only `name`,
  `executable`, `type` enum, `xdg.method` enum are checked — `aliases`, `picker`, `packages`,
  `xdg.vars`, `dependsOn` shapes are unchecked). This is already tracked in TODO.md ("Expand tool
  schema validation") — I'd only add that a malformed `picker` block is the highest-value one to
  validate first, since (per §1.3) it fails at codegen/runtime with a much less legible error than a
  missing `name` would.

## Part 5 — PowerShell idioms and best practices

Overall this codebase is more idiomatic than the median PowerShell project I've seen: consistent
`[CmdletBinding()]`, real `OutputType` attributes, `SupportsShouldProcess`/`ShouldProcess` used
correctly (`Install-DFTool`, `New-DFShim`), `?.`/`??` used throughout instead of verbose null-checks,
`[System.Collections.Generic.List[T]]` preferred over `+=` array growth in hot paths, and
comment-based help that actually satisfies the project's own "before committing" checklist (I
spot-checked `Add-DFToPath`, `Invoke-DFPicker`, `Install-DFTool`, `Register-DFTool` — all have
complete `.SYNOPSIS`/`.PARAMETER`/`.EXAMPLE`/`.OUTPUTS`).

A few smaller things:

- **`-creplace`/`-cmatch` discipline is followed correctly** in the places that matter (`ConvertTo-DFPath`'s
  `~` expansion, `Expand-DFXdgPath`'s token replacement) — this is a real Windows-path gotcha
  (case-insensitive `-replace` could mis-match a token that happens to collide with something in a
  path segment) and the project's own `CLAUDE.md` rule is actually honored in the code, not just
  written down.
- **`Write-Host` is used for genuinely interactive, colorized, non-data output** (`Initialize-DFEnvironment`'s
  "Environment ready" banner, `Install-DFTool`'s progress line) rather than for anything a caller
  might want to capture or pipe — the right call, since `Write-Host`'s output can't be redirected or
  tested via output-stream assertions, and none of these call sites need to be.
- **One inconsistency worth flagging**: `Test-DFToolSchema`'s nested `function PSProp (...)` is
  defined *inside* another function body and redefined on every call. It's cheap (no measurable
  cost at this call frequency), but it's the one place I found a function-in-a-function where the
  codebase's usual style is flat private functions dot-sourced once — likely just missed when this
  file was written before the `?.Value` idiom was standardized elsewhere.
- **`Invoke-DFTopoSort`'s Kahn's-algorithm implementation is textbook-correct and well-tested** —
  stable-order queue seeding, cycle detection with a clear fallback-and-warn rather than a throw.
  Nothing to improve here; flagging it because it's exactly the kind of infrastructure code where
  "textbook correct" is the compliment, not "clever."

## Part 6 — Execution speed

Startup speed is called out in `CLAUDE.md` as a first-class constraint, and the architecture mostly
earns that claim: JSON is read once and cached (`Import-DFToolDb`), cross-tool aggregation is
pre-computed at build time into `data/tool-categories.json`/`data/tool-identities.json` rather than
scanned at profile load, and `Register-DFTool -All` only touches tools that are actually on `PATH`
(`Get-Command $tool.executable -ErrorAction Ignore` gates every other branch).

Two concrete opportunities:

- **`Register-DFTool`'s per-tool availability probe calls `Get-Command` once per tool, every
  session.** For a profile invoking `Register-DFTool -All` across ~60 tool records, that's ~60
  `Get-Command` probes (each of which walks `PATH` looking for the executable) on every shell
  startup. `Get-Command` is not free — it's the single most expensive line in the per-tool loop for
  any tool that *isn't* installed (the common case for most users, who have a subset of the 60). A
  one-time-per-session cache of `PATH`'s executable listing (`Get-ChildItem` over each `PATH` entry,
  built once, checked as a hashtable) would turn N `Get-Command` spawns/`PATH` walks into one
  filesystem sweep plus N hashtable lookups.
- **The picker/completion/theme sidecars each independently call external processes at
  registration time** (`zoxide init`, `oh-my-posh init`, `carapace _carapace powershell`, `fnm env`)
  via `Invoke-Expression`. These are individually necessary (documented in
  `docs/external-dependencies.md` as the *only* way to get each tool's init script), so there's no
  architectural fix here — but if profile-startup latency ever becomes a measured problem, this is
  where the remaining cost lives (process-spawn latency × number of tools with a companion), not in
  DotForge's own PowerShell logic. Worth a `Measure-Command` baseline around `Register-DFTool -All`
  if startup speed work is ever prioritized, so future changes have a number to check against
  instead of relying on "feels fast."

## Recommended order of work

1. **`New-DFShim`'s `cd /d`** (§3.1) — the only item here I'd call a correctness bug rather than a
   design tradeoff; verify intent, then likely just delete the `cd` line and add the regression test.
2. **Apply `Get-DFCategoryDb`'s cache-bypass guard to `Import-DFToolDb` and `Resolve-DFPackageManager`**
   (§3.2) — closes two tracked TODO items with a pattern the codebase already trusts.
3. **Split `Register-DFTool` into the five extracted private functions** (§1.2) — highest-leverage
   readability/testability win, zero behavior change, unblocks better tests for the picker-codegen
   bug already on the TODO list.
4. **`fzf.json` → a `fzf.ps1` sidecar that resolves theme like `delta.ps1` does** (§3.4) — small,
   closes a real theming gap using an existing mechanism.
5. **`Get-DFPropertyValue` helper + `PATH`-listing cache for `Register-DFTool`** (§2.1, §6) — pure
   quality-of-life and startup-speed wins, no urgency.
6. **Extract `Invoke-DFPackageManagerPicker` from `Tools/{scoop,winget,choco}.ps1`** (§2.3) — the
   largest raw duplication in the codebase by line count, but lower urgency than #3 since these
   three files are leaves nothing else depends on; do it once the shared picker-wiring shape has
   stopped changing (right now it's still shipping new bind/expect combinations tool by tool).
7. Everything else in Parts 2–5 — genuine improvements, none blocking, safe to fold in opportunistically
   the next time each file is touched (which is exactly what `docs/plugin-architecture.md` already
   prescribes for its own kind of debt).
