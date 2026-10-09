# Tab completion as a role: design

**Status:** approved 2026-10-08 · **Date:** 2026-10-08 · **Audit item:** `arch-imp-audit-(claude).md` #5

## Problem

`Private/Initialize-DFCompletionStack.ps1` is the last place where core code branches on tool names:

```powershell
if ((Get-DFCompletionMode) -eq 'Inshellisense') { ... Start-DFInshellisense ... }   # a global only inshellisense.ps1 defines
if ($tools.Contains('psfzf')) {
    if ($tools.Contains('carapace')) { Enable-DFFzfAnsiOption }
    Set-PSReadLineKeyHandler -Key Tab -ScriptBlock { Invoke-FzfTabCompletion }
}
elseif ($tools.Contains('carapace')) { Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete }
```

That breaks the plugin invariant (`docs/plugin-architecture.md`). A fourth completion tool would need a core edit, and core calls a global function that one sidecar happens to define.

## Key observation

Roles v2 already provides exactly what this hand-written switch does: one winner among the installed candidates, a priority order, a user override (`$DFConfig.Defaults`), and a hook that runs **only** for the winner (`Initialize-DFRole<Name>`). Today `completion` is only a `category` role, which is a grouping label with no winner. Who owns the Tab key is a single-winner question; what adds completers is not. So the fix is to separate the two.

## Design

### 1. New single role `tab-completion` in `data/roles.json`

```json
"tab-completion": {
  "kind": "single",
  "exclusive": false,
  "hook": "Initialize-DFRoleTabCompletion",
  "reserved": { "env": [], "aliases": [], "code": ["Set-PSReadLineKeyHandler -Key Tab"] },
  "description": "Owns the Tab key. The winner binds Tab; the others still register their completers."
}
```

`completion` stays a category: carapace's completers, PSFzf's other bindings and inshellisense's specs keep working whatever wins Tab.

`exclusive: false` means no "you have two candidates and haven't chosen" notice. Priority decides silently, as it does today.

### 2. Each tool declares its claim in its own JSON and hook

| Tool | `roles` block | Hook body (in its own sidecar) |
|---|---|---|
| PSFzf | `"tab-completion": { "priority": 20 }` | `Set-PSReadLineKeyHandler -Key Tab -ScriptBlock { Invoke-FzfTabCompletion }` |
| carapace | `"tab-completion": { "priority": 10 }` | `Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete` |
| inshellisense | `"tab-completion": { "priority": 0, "optIn": true }` | `Start-DFInshellisense` (it doesn't bind Tab; it takes over completion) |

This reproduces today's order: PSFzf beats carapace, and inshellisense only wins when you ask for it.

### 3. `optIn` — the one new core feature (declarative, generic)

Today, registering inshellisense alone does **not** start it; only `CompletionMode = 'Inshellisense'` does. Plain priority can't express that: as the sole installed candidate, inshellisense would win. A role block may therefore declare `"optIn": true`. `Get-DFRoleWinners` then skips that candidate unless `$DFConfig.Defaults[<role>]` names it. Core reads a field. It never reads a tool name, and any future role can use the field.

### 4. The PSFzf + carapace `--ansi` coupling moves into a sidecar

`Enable-DFFzfAnsiOption` exists because carapace's list items carry ANSI colors that fzf must be told to render. That's knowledge about how those two tools interact, and sidecars may hold tool-specific knowledge. PSFzf's tab hook appends `--ansi` to `FZF_DEFAULT_OPTS` when carapace's completers are registered. That condition is checked with `Get-Command carapace`, the same way `Tools/carapace.ps1` already checks for PSFzf. The function moves from `Private/` into `Tools/PSFzf.ps1`.

### 5. Ordering

Today Tab is bound after **all** tools register, for two reasons: the final registration set must be known, and changing PSReadLine's `EditMode` resets Tab. With roles:

- **The registration set:** winners are already computed up front from the full set (`Get-DFRoleWinners`).
- **EditMode:** a role hook runs during its tool's registration. The PSFzf hook is safe because `PSFzf.json` declares `dependsOn: ["psreadline"]`. carapace and inshellisense need the same `dependsOn` for the same reason. Each is one line in its own JSON, and topo-sort already handles it.

So `Initialize-DFCompletionStack` and its call in `Register-DFTool` are deleted, not just thinned.

### 6. `$DFConfig.CompletionMode`

Removed (see Decisions). `Enable-DFCarapaceInshellisenseBridge` moves into `Tools/carapace.ps1` and bridges only when inshellisense is installed and is **not** the `tab-completion` winner, which it learns from `Get-DFRole`.

## What gets deleted

- `Initialize-DFCompletionStack` and its call in `Register-DFTool`.
- `Get-DFCompletionMode` and the `CompletionMode` setting.
- Core's knowledge of the names `psfzf`, `carapace`, `Start-DFInshellisense` and `Invoke-FzfTabCompletion`.

## Tests

- **Role resolution, with fake tool records, no real tools:**
  - the highest priority wins Tab
  - `optIn` is skipped unless named in Defaults
  - Defaults overrides priority
  - a sole opt-in candidate does not win
- **Each sidecar's hook:** binds the expected Tab handler, using `Set-PSReadLineKeyHandler` mocked.
- **Behavior parity with today's matrix:**
  - PSFzf + carapace → fzf Tab with `--ansi`
  - carapace only → MenuComplete
  - neither → Tab untouched
  - inshellisense opted in → started, Tab untouched
  - inshellisense opted in but not installed → priority winner, with the roles system's standard warning
- **Invariant:** a test asserting no `Private/`/`Public/` file contains a literal tool name from `Tools/*.json` as a string comparison (`-eq 'x'`, `.Contains('x')`). This guards the invariant from now on.

## Decisions (2026-10-08)

1. **CompletionMode is removed now**, with no shim: DotForge is pre-1.0. The CHANGELOG (Removed) and `docs/guide/completion.md` say to set `$DFConfig.Defaults['tab-completion'] = 'inshellisense'`.
2. **carapace asks `Get-DFRole`** for the `tab-completion` winner. This replaces section 6's proposal to extend `$DFCurrentTool`.
3. **The role name is `tab-completion`.**
