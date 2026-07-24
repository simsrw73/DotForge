# Tool Conformance Infrastructure — Design

**Date:** 2026-07-24
**Status:** Approved design; ready for implementation planning.
**Parent standard:** `ToolAcquisitionSpec.md` §4 (Conformance Protocol); audit
`ToolAcquisitionSpec-Audit.md` platform gap #1.

## Purpose

`ToolAcquisitionSpec.md` makes conformance the load-bearing principle: *no
configuration is "done" until a probe shows the tool reads it and honors its
content* (Principle 2, §4.5). None of that machinery exists today — there is no
harness, no versioned ledger, no schema, no tests, and no way to link a sidecar
adapter to the failure it works around.

This spec designs that machinery as the **first** of the "machinery first,
retrofit later" workstreams. It builds the conformance subsystem end to end and
proves it on **two pilot tools** (`bat`, `glow`), leaving the other 36 tools to
a later per-tool retrofit. It does **not** touch theme centralization,
default-tool roles, or the xdg-model split — those are separate specs.

## Invariants (inherited, non-negotiable)

- **Author-time only.** Conformance probing, ledger generation, and issue-report
  generation NEVER run in the live shell and are NEVER loaded or invoked by the
  DotForge module. (`ToolAcquisitionSpec.md` §13.)
- **Strict mode.** All harness/build code uses `Set-StrictMode -Version Latest`
  and `#Requires -Version 7.0`.
- **Determinism.** No `Date.now()`-equivalent inside the harness: the harness
  never calls the system clock. Timestamps (`probedAt`, manual `evidence`
  dates) are passed in or carried by the descriptor fragment.
- **Isolation.** Probes run against a minimal, scratch-dir-isolated environment —
  only the variable/config under test — never the author's ambient environment.
- **Injectable seam.** External-tool spawning goes through a single injectable
  scriptblock so tests run with canned output and never spawn a real process,
  mirroring `Build-DFToolIdentities.ps1 -ResolveLinkage`.
- **Degrade, never fail** applies to *runtime* only; author-side harness code MAY
  surface hard errors on malformed input (a bad descriptor is an author bug).

## Section 1 — Artifacts & data flow

Five artifacts, mirroring the existing `tool-identities` pipeline:

| Artifact | Role | Precedent |
|---|---|---|
| `build/conformance/<tool>.jsonc` | Hand-authored probe descriptors, one fragment per tool. Author-time only. | `build/identities/*.jsonc` |
| `build/conformance/probes/<ref>.ps1` | Bespoke `code`-kind probe scriptblocks. | (new) |
| `build/Test-DFToolConformance.ps1` | The harness: reads fragments, runs probes, writes the ledger, emits the issue report. | `build/Build-DFToolIdentities.ps1` |
| `data/tool-conformance.json` | The generated, committed ledger, keyed by tool + version. | `data/tool-identities.json` |
| `reports/tool-conformance-issues.md` | Generated issue report from `fail` verdicts. | (new) |
| `tests/Test-DFToolConformance.Tests.ps1` | Schema + shipped-data + behavior tests. | `tests/Build-DFToolIdentities.Tests.ps1` |

**Key placement decision:** probe descriptors live under `build/conformance/`,
**not** inside `Tools/*.json`. The hardest invariant is "author-time, never
loaded by the module"; putting probe data in the runtime-loaded tool records
would ship author-only data the module never reads. `build/` already holds
author-only inputs (`build/identities/`), so descriptors belong there.

**Data flow:**

1. Author runs `./build/Test-DFToolConformance.ps1`.
2. It reads each `build/conformance/<tool>.jsonc`, validates it against the
   descriptor schema, and runs each claim's probe (spawning real tools through
   the seam).
3. It captures the tool version, computes verdicts, and **merges** results into
   `data/tool-conformance.json` (preserving hand-authored `manual` verdicts —
   see §3).
4. It regenerates `reports/tool-conformance-issues.md`.
5. Author reviews and commits the ledger + report.
6. CI's Pester run validates the ledger against its schema and against the
   shipped `Tools/*.json` set — **never spawning anything** (uses the injected
   seam).

## Section 2 — Probe descriptor schema

Each `build/conformance/<tool>.jsonc` fragment names the tool and a `claims`
array. Every claim has an `id` in the spec's grammar
(`<tool>/<claim-type>[:<arg>]`, e.g. `bat/honors-env:BAT_CONFIG_PATH`) and a
`probe` block whose `kind` selects a generic data-driven probe or the `code`
escape hatch.

```jsonc
{
  "tool": "bat",
  "claims": [
    {
      "id": "bat/honors-env:BAT_CONFIG_PATH",
      "probe": {
        "kind": "env-then-spawn",
        "setEnv": { "BAT_CONFIG_PATH": "${SCRATCH}/bat.conf" },
        "writeFile": { "${SCRATCH}/bat.conf": "--theme=\"ansi\"" },
        "spawn": ["bat", "--config-file"],
        "expect": { "match": "bat\\.conf$" }
      }
    },
    {
      "id": "bat/honors-config-content:theme",
      "probe": {
        "kind": "code",
        "ref": "bat.theme",
        "manualFallback": {
          "retest": "set theme=ansi in bat.conf; run `bat sample.md`; confirm ANSI palette"
        }
      }
    }
  ]
}
```

### Probe `kind`s (first slice)

| `kind` | Covers claims | Behavior |
|---|---|---|
| `env-then-spawn` | `honors-env:*`, `honors-config-read` | Set `setEnv` var(s), optionally `writeFile` a sentinel config, spawn `spawn`, apply `expect` to stdout. |
| `flag-then-spawn` | `honors-flag:*` | Pass the flag via `spawn`, apply `expect` to stdout / exit. |
| `manual` | any visually-verified claim | No spawn. Carries `evidence` + `retest`; verdict is always `manual`. |
| `code` | subtle `honors-config-content:*` | Names a scriptblock `build/conformance/probes/<ref>.ps1` receiving `${SCRATCH}` + a spawn function, returning `@{ verdict; evidence; retest }`. Optional `manualFallback.retest` used when the code returns `manual`. |

The `expect` object supports `match` (stdout regex must match ⇒ `pass`) and
`notMatch` (stdout regex must NOT match ⇒ `pass`); exactly one is required for
spawn kinds.

### Token expansion

Two token families are expanded inside descriptor string values:

- `${SCRATCH}` — the per-probe isolated temp directory the harness creates.
- `${XDG_CONFIG_HOME}` / `${XDG_DATA_HOME}` / `${XDG_STATE_HOME}` /
  `${XDG_CACHE_HOME}` — via the existing `Private/Expand-DFXdgPath.ps1`
  (case-sensitive, exact `${…}` form). `XDG_BIN_HOME` is not a token.

The harness validates every fragment against the descriptor schema **before
running any probe**; a malformed fragment (unknown `kind`, missing `spawn`,
missing `expect` on a spawn kind, `manual` without `retest`) is rejected at
author time.

## Section 3 — Harness execution model

`build/Test-DFToolConformance.ps1`, structured like `Build-DFToolIdentities.ps1`:

```powershell
#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$ConformanceDir = (Join-Path $PSScriptRoot 'conformance'),
    [string]$OutPath        = (Join-Path $PSScriptRoot '../data/tool-conformance.json'),
    [string]$ReportPath     = (Join-Path $PSScriptRoot '../reports/tool-conformance-issues.md'),
    [string[]]$Tool,             # limit to named tools; default = all fragments
    [string]$ProbedAt,           # author-supplied date stamp; harness never reads the clock
    [scriptblock]$SpawnTool      # THE injectable seam
)
Set-StrictMode -Version Latest
```

The harness dot-sources `Private/*.ps1` (for `Expand-DFXdgPath` etc.), matching
how `Build-DFToolIdentities.ps1` loads Private helpers.

**The spawn seam.** Default is a real child-process invocation; tests inject a
canned resolver:

```powershell
if (-not $SpawnTool) {
    $SpawnTool = {
        param($Exe, $Argv, $Env, $Cwd)
        # real: launch $Exe with $Argv, isolated env $Env, in $Cwd;
        # return @{ ExitCode; StdOut; StdErr }
    }
}
```

Per-tool / per-probe execution, in order:

1. **Version capture.** Spawn `<exe> --version` (overridable per-fragment via
   `versionArgs`), parse and record the version string — the ledger key.
2. **Tool-absent handling.** If the executable can't be resolved (seam reports
   absence), **skip** every claim for that tool with verdict `unknown` — a
   missing binary on the author's machine is not a conformance `fail`. The
   report lists what was skipped (no silent caps).
3. **Isolation.** For each probe: create a fresh `${SCRATCH}` dir; build a
   minimal env map (only the vars under test + launch essentials); write any
   `writeFile` sentinels.
4. **Run** per `kind`; capture stdout + exit; apply `expect` ⇒ `pass`/`fail`,
   storing captured output as `evidence`.
5. **Manual claims** never spawn; their hand-authored verdict passes through.

**Manual-verdict preservation (merge on write).** Automated claims are
regenerated every run. A `manual` verdict encodes a human's visual confirmation
that cannot be re-derived, so the harness merges rather than overwrites:

- An automated probe result overwrites the prior claim.
- A `manual` claim is **preserved** from the existing ledger when its
  `versionTested` matches the freshly-probed version.
- When the tool version has moved, the preserved `manual` claim is kept but
  **flagged in the report as "needs re-confirmation."**

This prevents visually-verified verdicts from silently evaporating on every
regeneration.

## Section 4 — Ledger schema & tests

### Ledger shape (`data/tool-conformance.json`)

```jsonc
{
  "bat": {
    "versionTested": "0.24.0",
    "probedAt": "2026-07-24",
    "claims": [
      { "id": "bat/honors-env:BAT_CONFIG_PATH", "verdict": "pass",
        "kind": "env-then-spawn",
        "evidence": "stdout resolved to ...\\bat\\bat.conf" },
      { "id": "bat/honors-config-content:theme", "verdict": "manual",
        "kind": "code",
        "evidence": "ANSI palette confirmed visually 2026-07-24",
        "retest": "set theme=ansi in bat.conf; run `bat sample.md`" }
    ]
  }
}
```

- `verdict` ∈ `pass | fail | manual | unknown`.
- `retest` is **required** when `verdict = manual`.
- `probedAt` is a string supplied by the author (`-ProbedAt`) or carried by the
  fragment; the harness never calls the clock.

### Tests (`tests/Test-DFToolConformance.Tests.ps1`)

All probe-free; the behavior tests use the injected `-SpawnTool` seam. Follows
the `Build-DFToolIdentities.Tests.ps1` "generate → shipped data → test-the-data"
pattern.

1. **Schema validation** — every record/claim has required fields; `verdict` in
   the enum; `manual` ⟹ `retest` present; claim `id` matches the
   `<tool>/<claim-type>[:<arg>]` grammar.
2. **Shipped-data consistency** — every tool with a `build/conformance/<tool>.jsonc`
   fragment appears in the ledger, and every ledger claim `id` traces back to a
   descriptor. Catches "fragment added, ledger not regenerated" drift.
3. **Harness behavior on canned output** — inject a `-SpawnTool` returning
   scripted stdout/exit; assert `env-then-spawn` ⇒ `pass` on match / `fail` on
   mismatch; `unknown` when the seam reports absence; `manual` survives a regen
   at matching version and is flagged at a moved version.
4. **Descriptor schema rejection** — a malformed fragment (bad `kind`, missing
   `spawn`/`expect`) is rejected before any probe runs.

## Section 5 — Issue report & adapter dead-code detection

### Issue report (`reports/tool-conformance-issues.md`)

Generated from all `fail` verdicts, one section each, formatted to paste
upstream: tool + version, claim, how it was probed (descriptor setup + spawn),
and observed-vs-expected from captured evidence. With zero fails, the harness
writes a short "no open conformance failures" stub rather than deleting the file
(stable git presence). Automates `ToolAcquisitionSpec.md` §4.4.

### Adapter ↔ claim linking

Convention: a sidecar working around a failing claim carries a comment
`# adapter for <claim-id>`. The harness closes the loop in both directions,
scanning `Tools/*.ps1`:

1. **Orphan check** — every `# adapter for <id>` comment must reference a claim
   that exists in the ledger; a stale/typo'd id surfaces as a report warning.
2. **Dead-adapter check** — for every claim whose verdict is `pass`, any adapter
   still referencing it is flagged **"dead code — upstream fixed, remove."**

Both checks are pure text/JSON, run inside the Pester suite (no spawning), so
adapter/verdict drift fails CI.

## Section 6 — Pilot scope

### `bat` — happy paths

- `bat/honors-env:BAT_CONFIG_PATH` — `env-then-spawn` ⇒ `pass`.
- `bat/honors-config-read` — `env-then-spawn` ⇒ `pass`.
- `bat/honors-config-content:theme` — `code` ⇒ `manual` (visual).

Exercises `pass`, `manual`, and the `code` escape hatch.

### `glow` — failure machinery

- `glow/honors-env:GLOW_CONFIG_DIR` — documented **`fail`** (established in the
  glow wrapper work). `Tools/glow.ps1` gains
  `# adapter for glow/honors-env:GLOW_CONFIG_DIR`.
- `glow/honors-flag:--config` and `glow/honors-flag:-s` — `flag-then-spawn` ⇒
  `pass`.

Exercises `fail` → issue-report → adapter-linkage → dead-code check, plus
`flag-then-spawn`. `unknown` is exercised by a behavior test with the seam
reporting absence.

Between the two pilots and the behavior tests, all four `kind`s and all four
verdicts are covered — every mechanism ships proven.

### Explicitly out of scope

- The other **36 tools** — no fragments authored; retrofit is per-tool, later.
- **Theme centralization, default-tool roles, xdg-model split** — separate specs.
- Full `docs/external-dependencies.md` cross-referencing of every ledger claim
  ID — only the glow entry's back-reference is added in this slice; the full
  sweep is retrofit work.
- Any **runtime** wiring — the module never loads or invokes conformance data.

## Acceptance criteria (this slice)

- `build/Test-DFToolConformance.ps1` exists, strict-mode, dot-sources Private,
  injectable `-SpawnTool` seam, never invoked by the module.
- `build/conformance/bat.jsonc` and `build/conformance/glow.jsonc` exist and
  validate against the descriptor schema.
- Running the harness produces `data/tool-conformance.json` with `bat` and
  `glow` records covering `pass`/`fail`/`manual` and
  `reports/tool-conformance-issues.md` with the glow failure.
- `Tools/glow.ps1` carries the adapter comment; the dead-adapter and orphan
  checks pass.
- `tests/Test-DFToolConformance.Tests.ps1` passes probe-free under the existing
  suite (Pester 5 and 6), covering schema, shipped-data consistency, harness
  behavior (all four verdicts), and descriptor rejection.
- No regression in the existing suite.
