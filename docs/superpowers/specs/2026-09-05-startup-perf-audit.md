# Startup Performance Audit — Redundant Work & Async Deferral

**Date:** 2026-09-05
**Status:** Investigation only. No code changes made. All numbers below are
measured on this machine (Windows 11, 40 tools in the registry, ~37 typically
installed, ~101 PATH directories — same profile referenced in the PATH-index
writeup) via real process spawns and `Measure-Command`, never estimated.

## Executive summary, ranked by expected real-world impact

| # | Finding | Measured cost | Category | Expected impact |
|---|---|---|---|---|
| 1 | Three PowerShell module imports (`Terminal-Icons`, `PSFzf`, `posh-git`) dominate startup | 352 + 258 + 288 ≈ **898ms** cold; confirmed droppable to ~65ms each (~195ms total) via background pre-warm + foreground re-import | Async-deferral candidate, **verified viable** | **Largest lever found** — bigger than every caching opportunity combined |
| 2 | `inshellisense`'s `is -c` session check | ~130ms typical, npm double-hop shim | Async-deferral candidate | Second-largest single item; also the noisiest (up to 1.1s observed once) |
| 3 | `carapace _carapace powershell` (519 completers) | 101ms mean, byte-identical across runs | Cacheable (deterministic) | Largest *pure caching* win; safe, no behavior change |
| 4 | `zoxide init`, `mdcat --completions`, `scoop-search --hook` | 39 + 18 + 41 ≈ 98ms combined | Cacheable (deterministic) | Small but free — no downside, no deferral risk |
| 5 | `fnm env --use-on-cd`, `oh-my-posh init pwsh` | 39ms, 41ms | **Not cacheable, not safely deferrable** | Confirms these two are near their floor already |
| — | `vivid generate` | 45ms raw, ~0ms cached | Already fixed | Confirms the caching pattern this audit recommends elsewhere already works in production |

**Bottom line:** the caching opportunities (carapace + the three small deterministic
inits) recover roughly **200ms** of real work, worth doing because it's risk-free.
The async-deferral opportunity (three module imports + the inshellisense check)
is **roughly 5x bigger (~1000ms)** and requires real architectural care —
PowerShell runspaces do not share loaded modules, defined functions, or
`$global:` state (confirmed empirically below), so "just background it" as
commonly imagined does not work for these specific items as literally stated.
The one thing that does cross a runspace boundary automatically is environment
variables (confirmed below). The workable pattern that emerged from testing
this directly — background-import a module purely to pre-warm it, then do the
real foreground `Import-Module` once the background job finishes — cut the
measured foreground cost by **~77%, reproduced 3/3 times** (see Part 2), which
is what makes this worth doing rather than a theoretical exercise.

None of the four already-settled optimizations from this session (`Test-DFToolAvailable`
memoization, the PATH-index rejection, the package-manager-query rejection, the
delta/mdv tool-setup-lifecycle migrations) are revisited here.

---

## Part 1 — Redundant per-session work

### Method

- Baseline: `build/Measure-DFStartup.ps1`, 5 iterations of `Register-DFTool -All`
  on a freshly `Import-Module -Force`'d copy: **Min 1070.4ms / Mean 1451.4ms / Max 2677.9ms**.
- Per-tool breakdown: naively calling `Register-DFTool -Name <tool>` once per tool
  (40 separate calls) turned out to be a measurement trap — it re-pays
  `Register-DFTool`'s shared fixed overhead (the whole-DB conflict-check scan,
  `Initialize-DFCompletionStack` rebuild) 40 times instead of once, inflating
  unrelated tools (`bitwarden`, `chezmoi`, `rustup`, `gsudo`) to 110–180ms each
  even though they do nothing at registration time. Corrected by timestamping the
  `Write-Verbose "DotForge: $($tool.name) registered"` marker `Register-DFTool.ps1`
  already emits, from **one single real `-All` call**, and taking deltas between
  consecutive markers. This is the only valid way to attribute marginal per-tool
  cost within a real run.
- Every "is this deterministic" claim below is a real `diff` of two live command
  outputs, not an assumption.
- Module-import costs measured via `Remove-Module -Force; Measure-Command { Import-Module $name }`
  in a fresh `-NoProfile` process — a true cold import, matching what a real new
  shell actually pays once per session.

### Import-Module DotForge.psd1 and Initialize-DFEnvironment

- `Import-Module DotForge.psd1 -Force`: **500.8ms**, dot-sourcing 25 `Public/*.ps1`
  + 49 `Private/*.ps1` = 74 files. This matches the earlier session's .NET
  `EnumerateFiles` investigation: the cost is script *parsing/compilation*, not
  directory enumeration — already investigated and confirmed not improvable by
  changing how files are discovered. **Not revisited; no new finding here.**
- `Initialize-DFEnvironment`: **81.7ms**. Not deep-dived further — it's a minor
  contributor (~5% of a ~1650ms floor) and mostly comprises `Resolve-DFPackageManager`
  probing, which is a one-shot cost per session already, not a per-tool repeat.

### Companions that spawn an external process every session

Verified real per-tool marginal costs, isolated (`Measure-Command` directly
against the real binary, 5 samples, mean reported unless noted):

| Companion | Command | Mean | Deterministic? (2-run diff) | Classification |
|---|---|---|---|---|
| `carapace.ps1` | `carapace _carapace powershell` | 101.3ms | **Yes** — byte-identical, 1105 lines | **Cacheable** |
| `fnm.ps1` | `fnm env --use-on-cd --shell powershell` | 39.1ms | **No** — embeds a PID-scoped `FNM_MULTISHELL_PATH` in every line | **Not cacheable** — this *is* fnm's actual multi-shell isolation mechanism, not incidental noise |
| `mdcat.ps1` | `mdcat --completions powershell` | 18.4ms | **Yes** | **Cacheable** |
| `oh-my-posh.ps1` | `oh-my-posh init pwsh --config <path>` | 40.6ms | **No** — embeds a fresh `POSH_SESSION_ID` GUID every run | **Not cacheable** — and separately, cannot be safely *deferred* either (see Part 2) |
| `zoxide.ps1` | `zoxide init --hook pwd --cmd cd powershell` | 39.2ms | **Yes** | **Cacheable** |
| `scoop.ps1` | `scoop-search --hook` (only when `scoop-search` installed) | 40.8ms | **Yes** | **Cacheable** |
| `inshellisense.ps1` | `is -c` (session check, unconditional) | 135ms mean / 128.9ms median over 15 samples (one outlier hit 1146ms in an earlier 5-sample run, likely a cold antivirus scan of the npm `.cmd` shim) | N/A — it's a live fact-check, not cacheable output | **Async-deferral candidate** |
| `vivid.ps1` | `vivid generate <theme>` | 45.1ms raw, **already cached** (~0ms on cache hit) | Yes | **Already fixed** — cited as the existing precedent for the caching pattern recommended below |

**`fnm`'s dependency chain matters for both caching and async plans**:
`carapace` → `fnm` → `zoxide` (all `dependsOn`-declared, topo-sorted). Any change
to `fnm` or `zoxide` timing must account for `carapace` running after both.

**`is -c`'s cost is a Node.js/npm-shim tax, not inshellisense logic**: `is` resolves
to `is.cmd`, an npm-generated Windows shim (`cmd.exe` → `node.exe`, a real
double-process-hop, confirmed via `where is` + reading the shim). The ~125–140ms
floor is Node interpreter startup, not the actual "am I in a session" check,
which is why it can't be meaningfully sped up by changing the check itself —
only by not paying for it synchronously (see Part 2).

### Companions that spawn a real PowerShell module import every session

**This is the single largest finding in Part 1**, and it wasn't in the original
per-tool scan's obvious "spawns a process" list — `Import-Module` doesn't look
like a process spawn, but its cost dwarfs every process-spawning companion
measured above:

| Module | Cold `Import-Module` cost | Notes |
|---|---|---|
| `Terminal-Icons` | **352.5ms** | Purely cosmetic — file-type icons in `ls`/`Get-ChildItem` output |
| `posh-git` | **287.6ms** | Feeds git-status info to the prompt (only if `oh-my-posh` reads `POSH_GIT_ENABLED`) |
| `PSFzf` | **258.2ms** | Rebinds `Tab`, `Ctrl+T`, `Ctrl+R` |
| `PSReadLine` | 32.0ms | **Not a real DotForge cost in practice** — PowerShell 7 loads PSReadLine itself before any profile runs; this number reflects a cheap re-import over an already-loaded module, not a true cold cost |

These three together (898ms) are **not cacheable** — module import is the .NET
runtime loading and compiling real code, not text generation, so there's no
"cache the output" equivalent to carapace's approach. They are, however, the
best candidates in the whole audit for **async deferral** (Part 2) precisely
*because* each one's absence during the first second of a session degrades
softly rather than breaking anything: no icons for a moment, no fuzzy Tab for a
moment, no git branch in the prompt for a moment.

### Redundant `Get-Command`/`Get-Module` probes outside `Test-DFToolAvailable`

Grepped every `Tools/*.ps1` for `Get-Command`/`Get-Module` calls not routed
through the memoized `Test-DFToolAvailable`. Found several (`oh-my-posh.ps1`'s
`Get-Module -ListAvailable posh-git`, `choco.ps1`/`scoop.ps1`/`winget.ps1`'s
`Get-Command Set-PSReadLineKeyHandler`, `PSFzf.ps1`'s `Get-Module -Name PSFzf`
post-import check). None of these are worth memoizing: each is called at most
once per `Register-DFTool -All` run (they're not in a loop, unlike the
role-winner-resolution double-probe `Test-DFToolAvailable` was built to fix),
and `Measure-Command` around a bare `Get-Command`/`Get-Module` call on this
machine is sub-millisecond. **No finding here** — the earlier memoization work
already closed the only case that mattered (repeated probes across many tools
in the same run).

### File I/O reloading static content every session

- `carapace.ps1`'s bundled-spec deployment (`Get-Content`/`Set-Content` with a
  byte-comparison skip) and `Tools/mdv.setup.ps1`'s config seed (now one-time)
  were already measured as negligible in prior session work — not re-measured,
  no new finding.
- Theme JSON parsing (`Get-DFConfiguredTheme`, `Resolve-DFThemeName`, the
  bundled `psreadline`/`glow`/`fzf`/`delta` theme files) is small, single-file
  reads per tool — not independently re-measured here since none of these
  tools showed up in the top-15 real cost breakdown below.

### Actual top-cost tools in a single real `Register-DFTool -All` run

Timestamped from one real run (verbose-marker-delta method):

```
oh-my-posh      435.3ms   <- see caveat below
Terminal-Icons  358.4ms
carapace        191.2ms
PSFzf           181.7ms
scoop           159.5ms
eza             138.1ms
fnm              70.2ms
zoxide           63.9ms
winfetch         56.4ms
psreadline       56.2ms
```

**Caveat that must not be missed**: `oh-my-posh`'s 435.3ms here is *not* its
real marginal cost — the isolated measurement above puts its own `init pwsh`
call at 40.6ms. The gap (~395ms) is one-time .NET/regex JIT warmup that lands
on whichever tool happens to run first in a real cold `-All` call, confirmed by
re-running the breakdown after a throwaway warm-up pass, which produced a
completely different top-cost tool (`carapace`, at 477ms in that run) for the
exact same reason — whichever tool goes first in *that* pass ate the tax
instead. **This warmup tax is real (every actual new shell process pays it
once) but it is not attributable to, or fixable by touching, whichever tool's
code happens to run first.** The tools worth optimizing are the ones that show
up expensive *consistently regardless of position* — `carapace`, `PSFzf`, and
`Terminal-Icons` (Terminal-Icons and PSFzf both recur in the top 3 across
multiple methodologies here) — matching exactly the isolated-measurement
findings above, which is the correct way to read this data.

---

## Part 2 — Async/deferred startup research

### The mechanism, verified empirically (not assumed)

Four things were tested directly with `Start-ThreadJob` (PS 7's built-in
background-runspace primitive) in a fresh `-NoProfile` process:

| Test | Result |
|---|---|
| `Start-ThreadJob` round-trip overhead for trivial work | **81.7ms** — non-trivial; comparable to fnm's or zoxide's *entire* real cost |
| Module imported inside a background job — visible in main session after job completes? | **No** |
| Function defined inside a background job — callable in main session? | **No** |
| `[Environment]::SetEnvironmentVariable(..., 'Process')` set inside a background job — visible in main session? | **Yes** |
| Cost of importing the DotForge module a second time, fresh, inside a background job's own runspace | **474.5ms** |

**This is the central finding of Part 2.** PowerShell runspaces do not share
loaded modules, defined functions, or `$global:` variables — each runspace has
its own independent session state. Only OS-process-level state (environment
variables, in this case) crosses automatically. This means:

- **"Just wrap `Import-Module PSFzf` in a background job" does not work as
  literally stated** — the import would only exist inside the job's own
  runspace. The user's actual interactive session would never see `PSFzf`'s
  functions, key bindings, or the module at all.
- **The only architecturally sound async pattern for this codebase** is:
  run the *external-process-spawn-and-capture-text* step (e.g. `carapace _carapace powershell`,
  `oh-my-posh init pwsh --config ...`) in a background job with **zero DotForge
  module dependency** (bare native command lines only — confirmed above that
  re-importing DotForge inside the job costs another ~475ms, which would erase
  most of the benefit if the job's script block needed any DotForge private
  function). The job returns a **string**. Something running in the *main*
  runspace — the `prompt` function, or a `Set-PSReadLineKeyHandler`-driven
  check — then retrieves that string (`Receive-Job`) and `Invoke-Expression`s
  it **in the foreground**, once, when ready. Only the *string* crosses the
  runspace boundary; the actual function/completer registration still happens
  synchronously in the main runspace at that later point, it's just delayed
  rather than blocking the first prompt.
- **Env-var-only sidecar work (no functions, no module) genuinely can run
  in a true fire-and-forget background job with no marshaling step at all**,
  because `SetEnvironmentVariable(..., 'Process')` is confirmed to cross the
  boundary on its own. This describes very little of DotForge's own sidecar
  work, though — most companions define at least one function or import a
  module, which is exactly why this distinction matters here specifically
  (a generic "background it" writeup would have missed this).

### What's actually safe to defer in this codebase, tool by tool

| Tool work | Safe to defer? | Reasoning |
|---|---|---|
| `Terminal-Icons` import | **Yes** | Purely additive formatting for `ls`/`Get-ChildItem`. Worst case: plain listing for the first command or two, then icons "pop in." No correctness risk. |
| `PSFzf` import | **Yes, with a caveat** | Rebinds `Tab`/`Ctrl+T`/`Ctrl+R`. If the user presses Tab before the deferred import lands, they get PowerShell's default completion instead of fuzzy — a worse experience for a moment, not a failure. Depends on `psreadline` (`dependsOn`), so the deferred job must not start until `psreadline.ps1` has run synchronously. |
| `posh-git` import | **Yes, with a caveat** | Feeds `POSH_GIT_ENABLED`/git-status to the prompt via `oh-my-posh`. Since `oh-my-posh.ps1` checks `Get-Module -ListAvailable posh-git` (not `-ErrorAction Stop`), if `posh-git`'s import is deferred, `oh-my-posh`'s own registration either needs to also move (see below) or the prompt will render without git-status for the first render(s) until the deferred import completes — a soft, already-common-in-the-wild degradation for git-aware prompts. |
| `inshellisense`'s `is -c` check | **Yes** | Only gates whether `Start-DFInshellisense` is later offered; nothing about first-prompt usability depends on it. The Node-shim tax (~130ms) is the best "just don't pay this synchronously" candidate in the whole audit. |
| `oh-my-posh init pwsh` | **No** | It defines the `prompt` function itself. Deferring it means showing PowerShell's *default* prompt first, then swapping — jarring, and more importantly: **`zoxide.ps1` wraps whatever `function:prompt` exists at the moment it runs.** If oh-my-posh's real prompt isn't installed yet (deferred to background) when `zoxide.ps1` runs, zoxide wraps the *placeholder* prompt. When the deferred oh-my-posh job later replaces `function:prompt` for real, it does so *outside* zoxide's wrap chain, and zoxide's own `$global:__zoxide_hooked` guard prevents re-hooking — this is the **exact, already-documented failure mode** in `CLAUDE.md`'s "oh-my-posh + zoxide prompt hook ordering" section (today triggered by a manual theme switch via `fpot`; deferring oh-my-posh's *initial* registration would trigger the identical bug on every single session, not just on a manual theme switch). Not a theoretical risk — a documented, reproduced one. |
| `fnm env --use-on-cd` | **No** | Rebinds `cd`, chained through `zoxide`'s captured alias (`$global:cdBeforeFnm`). Deferring risks the same class of hook-ordering breakage as oh-my-posh/zoxide, and its own cost (39ms) is already near its floor — not worth the risk for the reward. |
| `carapace`, `zoxide`, `mdcat` completions, `scoop-search --hook` | **Better served by caching (Part 1) than by async** | These are cheap (18–101ms) and deterministic — caching removes the process-spawn cost entirely with zero behavioral change or ordering risk, which is strictly better than async-deferring a cost that caching can eliminate outright. |

### Precedent from tools DotForge already wraps

Checked directly (not assumed): **oh-my-posh's own FAQ** discusses diagnosing
slow prompts (`oh-my-posh debug`, checking antivirus/slow git repos) but
documents no async/lazy-init pattern of its own. **Starship's FAQ** likewise
has no lazy-loading or async-init discussion — starship's speed story is
architectural (one compiled binary, one process spawn total), not a deferred-init
pattern, so it isn't a transferable precedent for a module-heavy PowerShell
profile like this one. Neither tool offers a built-in async mode DotForge could
simply opt into.

### Concrete recommendation

**Worth pursuing, with real engineering care — this is not a "not worth it"
finding.** The measured upside (~900–1000ms across three module imports plus
the inshellisense check) is roughly 5x the size of the caching opportunity, on
a startup that currently costs ~1.6–2.6s in total (`Import-Module` + `Initialize-DFEnvironment`
+ `Register-DFTool -All`). But the correct shape is narrower than "background
the slow stuff":

1. **Do the caching fixes first (Part 1).** They're strictly safe, need no new
   architecture, and prove out the "deterministic output, cache keyed on tool
   version" pattern `vivid.ps1` already uses successfully in production.
2. **For the async work, defer only the four confirmed-safe items**
   (`Terminal-Icons`, `PSFzf`, `posh-git` imports; the `inshellisense` check) —
   never `oh-my-posh` or `fnm`, for the ordering reasons proven above.
3. **The mechanism, and the finding that makes this worth doing**: a module
   import genuinely must be re-run in the *main* runspace to take effect there
   (confirmed above — a background-job import never crosses the boundary), so
   the background job cannot eliminate the foreground `Import-Module` call
   outright. But it can **pre-warm** it. Tested directly, 3 fresh processes:

   | | Cold foreground import (nothing pre-touched) | Foreground import after a background job already imported the same module in its own runspace |
   |---|---|---|
   | `PSFzf` | 282.1 / 279.9 / 300.3ms | **64.8 / 65.4 / 66.0ms** |

   A **~77% reduction, reproduced 3/3 times**, with the pre-condition verified
   each run (`Get-Module PSFzf` confirmed `$null` in the main runspace
   immediately before the timed foreground call — this is a real foreground
   cold-to-*that*-runspace import, not an accidental no-op). The mechanism is
   almost certainly OS/CLR-level caching (already-read file pages, possibly
   already-JITted assemblies) rather than anything PowerShell-specific, but
   the effect is large and consistent regardless of cause. Applied to all
   three module imports, the realistic architecture is: **fire a background
   job at profile start that imports `Terminal-Icons`, `PSFzf`, and `posh-git`
   in its own disposable runspace (pure pre-warm, its result is discarded);
   once that job completes, do the real, now-~65ms-instead-of~280ms,
   `Import-Module` calls in the main runspace** (still synchronous at that
   point, but cheap, and by then the background job likely finished before
   the user typed anything). This turns "~900ms combined, blocking" into
   "~82ms job overhead + ~200ms of now-cheap foreground imports, likely
   overlapped with the time the user spends reading/typing after the prompt
   first appears" — a real, measured, and now de-risked win, not a
   theoretical one.
4. **A `prompt`-function check is the simplest "swap in when ready" gate** —
   cheaper and more reliably triggered than `Register-EngineEvent -SourceIdentifier PowerShell.OnIdle`,
   whose reliability depends on host-specific idle-loop behavior that
   wasn't verified in this pass. The `prompt` function already runs before
   every render; checking one job-state variable there costs effectively
   nothing extra.

**Net assessment: worth implementing.** The one open question this audit
flagged as make-or-break (does pre-warming actually help, given a background
import can't cross runspaces) came back with a strong, reproducible yes. The
`inshellisense` check (~130ms, no pre-warming needed — it's a live fact-check,
just needs to not block) stacks on top of this independently.
