# Tool One-Time Setup Lifecycle — Design

**Status:** Approved design, not yet implemented.

## Purpose

Give any tool a way to make a persistent, user-visible change *exactly once,
ever* — never re-applied, never silently re-added after the user removes it.

This generalizes a pattern that first appeared as a bespoke, ad hoc marker
file while designing delta's catppuccin theming
(`docs/superpowers/specs/2026-09-04-delta-catppuccin-design.md`): delta needs
to add an `[include]` line to the user's real global git config once, and
never re-add it if the user deletes that line on purpose. Building that as a
one-off would mean re-inventing the same run-once-and-remember machinery by
hand for every future tool that needs it.

## Problem

`Register-DFTool` already has two levers for a tool to affect the world:

- **`env`/`xdg.vars`** — declarative, reapplied every session. Fine for
  values, wrong for actions with side effects on files the user might edit.
- **The companion `Tools/<name>.ps1`** — imperative, also reapplied every
  session. Anything it writes to a persistent file must itself be idempotent
  and non-destructive on every single run.

Some setup only *should* happen once: adding an include line to a shared
config file the user also edits by hand, seeding a config file with an
opinionated default. Doing this from a per-session script forces a choice
between two bad options: skip if the target already exists (can't tell "never
ran" from "ran once, user deleted it on purpose" — see the mdv finding
below), or always reassert it (actively overwrites the user's own edit).
Neither can be made correct without extra state that says *DotForge has
already done this*, independent of whether the artifact still exists.

### Audit: who else has this problem today

Scanning every `Tools/*.ps1` for writes to a persistent, user-visible
location outside DotForge's own cache:

- **`Tools/mdv.ps1`** — seeds `$XDG_CONFIG_HOME/mdv/config.yaml` with a theme,
  gated on `if (-not (Test-Path $_cfgFile))`. This has exactly the bug this
  design fixes: if a user deletes that file because they don't want
  DotForge's theme opinion, the next `Register-DFTool` call silently reseeds
  it, indistinguishable from a first run. A real, already-shipped instance of
  the class of bug this feature exists to close. **Candidate for migration —
  tracked in `TODO.md`, not migrated by this spec.**
- **`Tools/carapace.ps1`** — re-deploys DotForge's bundled completion specs
  every session, skipping the write only when content is byte-identical.
  **Not a candidate.** This is "stay in sync with what DotForge ships,"
  intentionally re-checked every session — a different lifecycle from
  "configure once and back off."
- **`Tools/vivid.ps1`'s `LS_COLORS` cache** — writes under `$XDG_CACHE_HOME`.
  **Not a candidate.** Genuinely a cache: safe to delete, regenerates on
  theme change by design.
- Every other `-Force` hit in `Tools/*.ps1` is `Set-Alias -Force` for
  session-scoped aliases — re-applied every session by design, unrelated.

## Design

### File convention

A new optional companion, `Tools/<name>.setup.ps1`, parallel to the existing
`Tools/<name>.ps1`. Imperative PowerShell, not declarative JSON — matching
the existing sidecar precedent (`env`/`xdg.vars` stay declarative *because*
they're pure value substitution; anything with real conditional logic already
lives in a `.ps1`). A declarative `"setup": [...]` block in the tool's JSON
was considered and rejected: it would require core to own a growing
vocabulary of action *types* as tools' real-world needs diversify, generalized
from a sample size of one (delta) — the premature-abstraction trap
`docs/plugin-architecture.md` already warns against.

### `Register-DFTool` integration

`$Global:DFConfig['SkipSetup']` is a new array, mirroring the existing
`SkipTools` convention: a generic, visible opt-out for any tool's one-time
setup. This replaces the tool-specific `DeltaSkipGitConfig` flag the delta
spec currently proposes with a general mechanism. It's read once before the
per-tool loop, next to the existing `$skipTools` computation
(`Public/Register-DFTool.ps1:60-62`), using the same
`if ($null -ne $Global:DFConfig)` guard that code already uses for
`$DFConfig` access — not the `?[` null-conditional index operator, which
that function deliberately avoids in favor of an explicit null check (it does
use `?.` member access elsewhere, e.g. `.PSObject.Properties['x']?.Value`;
the avoidance is specific to indexing `$DFConfig` itself):

```powershell
# alongside the existing $skipTools computation, before the per-tool loop
$skipSetup = @(if ($null -ne $Global:DFConfig) { $Global:DFConfig['SkipSetup'] })
```

Then, inside the per-tool loop, one new block inserted immediately after the
existing "Companion `.ps1`" block (currently lines 291–297) — after the
existing "tool is available" guard, so unavailable tools never reach it:

```powershell
# ── One-time setup ──────────────────────────────────────────────────
$setupCompanion = Join-Path $resolvedToolsPath "$($tool.name).setup.ps1"
if ((Test-Path $setupCompanion -PathType Leaf) -and
    $tool.name -notin $skipSetup -and
    -not (Get-DFToolSetupState).PSObject.Properties[$tool.name]) {
    $DFCurrentTool = $tool
    try { . ($setupCompanion) }
    catch { Write-Warning "DotForge: $($tool.name) one-time setup failed: $($_.Exception.Message)" }
    Remove-Variable -Name DFCurrentTool -ErrorAction Ignore
}
```

Placement note: this check runs on *every* `Register-DFTool` call, for
whichever tools are named. A tool added to the user's registration list for
the first time in session #500 is checked exactly the same way a tool present
since session #1 is — "added later" requires no special handling, it falls
out of the mechanism for free.

### Success/failure ownership

`Register-DFTool` does not decide whether a setup script "succeeded" — the
script decides, by calling `Complete-DFToolSetup` itself, only once its work
is actually done:

```powershell
# Tools/delta.setup.ps1
# ... resolve $resolvedIncludePath, call git config --global --add include.path ...
Complete-DFToolSetup -Name 'delta' -Actions @(
    @{ type = 'gitConfigInclude'; path = $resolvedIncludePath }
)
```

If the script throws before reaching that call, `Register-DFTool`'s
`try/catch` logs a warning and continues registering other tools — no state
entry is written, so the next session retries from the top. This means every
`Tools/<name>.setup.ps1` must be safe to re-run from scratch on retry (e.g.
"add the include line only if not already present," never "blindly append") —
a partial failure re-runs the whole script next time, not just the failed
step.

This keeps the success/failure boundary consistent with the rest of the
plugin architecture: core only ever reacts to a signal (was
`Complete-DFToolSetup` called?), never to tool-specific logic.

### Data model

`$XDG_STATE_HOME/dotforge/setup-state.json` — a flat JSON object keyed by
tool name:

```json
{
  "delta": {
    "ranAt": "2026-09-04T10:22:00Z",
    "actions": [
      { "type": "gitConfigInclude", "path": "C:\\Users\\simsr\\.config\\delta\\catppuccin.gitconfig" }
    ]
  },
  "mdv": { "ranAt": "2026-08-01T09:00:00Z", "actions": [] }
}
```

`$XDG_STATE_HOME` rather than `$XDG_CACHE_HOME`: state whose loss causes
silent, unwanted re-setup is not a cache by XDG's own definition (cache =
safe to delete, at most costs a recompute). `$XDG_STATE_HOME` is already set
by `Initialize-DFEnvironment.ps1` but, before this design, has no consumer
anywhere in the codebase — this is its first real use.

`actions` is opaque to core: free-form hashtables/objects in whatever shape
the setup script chooses, recorded verbatim, never interpreted by
`Register-DFTool` or `Complete-DFToolSetup`. It exists so a *future* teardown
command has something precise to read instead of re-deriving or guessing what
a tool's setup changed — no teardown command is built by this spec (see
Scope).

### New functions

- **`Private/Get-DFToolSetupState.ps1`** — `Get-DFToolSetupState` (no
  parameters). Reads and parses the state file; returns `[PSCustomObject]@{}`
  if the file doesn't exist or fails to parse. Never throws. Used by
  `Register-DFTool`'s "already ran?" check and internally by
  `Complete-DFToolSetup`.
- **`Public/Complete-DFToolSetup.ps1`** — `Complete-DFToolSetup -Name
  <string> [-Actions <object[]>]`. Reads current state via
  `Get-DFToolSetupState`, sets/overwrites the entry for `-Name` with `ranAt`
  (UTC, ISO-8601 via `(Get-Date).ToUniversalTime().ToString('o')`) and
  `-Actions` (defaults to `@()`), creates `$XDG_STATE_HOME/dotforge/` via
  `New-DFDirectory` if needed, writes the whole object back with
  `ConvertTo-Json -Depth 10` + `Set-Content -Encoding UTF8`. Public, not
  Private — matching the existing convention that every function a
  dot-sourced sidecar calls is Public. This is a deliberate call-out: it
  sidesteps the `.GetNewClosure()`/Private-function scoping limitation found
  during the vivid work (a stored closure invoked *later*, outside
  `Register-DFTool`'s own call stack, cannot resolve Private functions).
  `Complete-DFToolSetup` doesn't hit that limitation regardless, because
  `Tools/<name>.setup.ps1` is dot-sourced and calls it synchronously, in the
  same call as `Register-DFTool` itself — but staying Public keeps the
  sidecar-facing API uniform and avoids ever having to reason about the
  distinction per-function.

Both need `FunctionsToExport` entries per the manifest convention
(`Complete-DFToolSetup` only — `Get-DFToolSetupState` is Private and does
not go in the manifest).

### Testing

Pester tests point `$Env:XDG_STATE_HOME` at `TestDrive:` for isolation
(matching the pattern existing cache-backed tests already use). Coverage:

- First `Register-DFTool` call for a tool with a `.setup.ps1`: state file is
  created, containing the tool's entry with the `actions` the script passed.
- Second call for the same tool: the setup script's side effect does not
  happen again (assert via an observable side channel, e.g. a global counter
  the test's `.setup.ps1` fixture increments, or a mocked
  `Complete-DFToolSetup` call count).
- A setup script that throws: no state entry is written; a `Write-Warning`
  is emitted; the tool otherwise finishes registering normally (aliases,
  picker, etc. from its own `.json`/`.ps1` are unaffected).
- `$DFConfig.SkipSetup = @('<tool>')`: the `.setup.ps1` is never dot-sourced
  and no state entry appears.
- `Get-DFToolSetupState` against a missing/corrupt state file returns an
  empty object rather than throwing.
- `Complete-DFToolSetup` called twice for the same tool name overwrites
  (not appends) that tool's entry, leaving other tools' entries untouched.

## Scope

**In scope:**

- `Tools/<name>.setup.ps1` convention.
- `Register-DFTool` integration (trigger, `SkipSetup`, try/catch).
- `Get-DFToolSetupState` / `Complete-DFToolSetup`.
- Delta migrates to this as its first real consumer (its own spec's Section 3
  is rewritten separately, in the delta implementation work, to use this
  instead of its bespoke `.done` marker file and `DeltaSkipGitConfig` flag).

**Out of scope (tracked in `TODO.md`):**

- Any teardown/uninstall command (e.g. `Uninstall-DFToolSetup`). The
  `actions` record exists so a future command has something to work from,
  but no such command is designed or built here — it deserves its own spec
  once there's more than one tool's worth of real `actions` shapes to
  generalize a safe, scoped undo from.
- Migrating `Tools/mdv.ps1`'s config-seeding to this primitive.

## Acceptance Criteria

- A tool with a `Tools/<name>.setup.ps1` runs it exactly once across
  repeated `Register-DFTool` calls/sessions, verified via the state file.
- Deleting the state file causes setup to run again (documented, expected
  behavior — the state file *is* the record of "ran," not a redundant cache
  of it).
- A failing setup script never registers as "done" and never breaks
  registration of that tool's other declared behavior or of subsequent
  tools in the same `Register-DFTool -All` call.
- `$DFConfig.SkipSetup` suppresses a tool's setup script without touching
  any other part of that tool's registration.
- No existing tool's behavior changes — this is purely additive per the
  plugin-architecture invariant (no `.setup.ps1` present ⇒ zero-cost no-op).
