# Roles v2: Formal Role Contract — Design

**Date:** 2026-10-05
**Status:** Draft for review.
**Supersedes:** the mechanism in `2026-07-25-default-tool-roles-design.md` (role v1). The
`$DFConfig.Defaults` shape is unchanged.
**Governed by:** `docs/plugin-architecture.md`, `docs/builtin-safety-policy.md`.

## Purpose

Several tools can do the same job: a pager, a prompt engine, a project-environment hook. The user
picks one, and DotForge must be the only thing that decides which tool is *active* in that role.

Role v1 does not deliver that. A tool declares one `role` string; `$DFConfig.Defaults` names a
winner; the only effect is that a loser skips the aliases the winner also declares. A loser's
environment block, sidecar and shell hooks still run, so two prompt engines or two project-env hooks
would both install themselves and fight. Separately, role-like selection is scattered across
unrelated mechanisms: `$Env:Pager` (`Invoke-DFWithPager`), `$Env:Picker` (`Invoke-DFFzf`),
`$Env:EDITOR` (`Edit-Profile`, `Tools/ripgrep.ps1`), delta's top-level `GIT_PAGER`, and
`Resolve-DFPackageManager`'s priority list. `ToolAcquisitionSpec.md` §9 allows defaulting
`PAGER`/`EDITOR` only when unset; that is not implemented.

Roles v2 makes the boundary a **contract**: a tool declares the roles it joins, and every piece of
role behavior sits behind a role entry point that **only DotForge invokes, and only for the winner**.
A plugin cannot make itself active in a role the user gave to another tool.

**Scope:** the framework, plus migrating tools DotForge already ships. New tools join roles in later
per-role batches (see Deferred).

## Concepts

- **Role** — a named job (`pager`, `prompt`, `grep`). Defined once by DotForge in `data/roles.json`.
- **Member** — a tool that declares the role in its own JSON.
- **Candidate** — a member that is in the current registration set and is installed.
- **Winner** — the one candidate whose role behavior runs (`single` roles only).
- **Role behavior** — anything that makes a tool "the" tool for a role: reserved env vars, reserved
  aliases, shell hooks. It lives only in the tool's role block and role hook.

A tool may join several roles. Winning or losing is decided per role: mise can lose `project-env`
and still win `version-manager`.

## 1. Role definitions — `data/roles.json`

One core file, keyed by role. It is never keyed by tool, so adding a tool never edits it; adding a
*role* is a core feature and edits it, which the plugin invariant allows.

```jsonc
{
  "pager": {
    "kind": "single",
    "exclusive": false,
    "hook": "Initialize-DFRolePager",
    "reserved": { "env": ["PAGER"], "aliases": [], "code": [] },
    "description": "Pages long output. The winner sets PAGER."
  },
  "prompt": {
    "kind": "single",
    "exclusive": true,
    "hook": "Initialize-DFRolePrompt",
    "reserved": { "env": [], "aliases": [], "code": ["Invoke-Expression", "iex", "function:prompt"] },
    "description": "Draws the shell prompt. Only one engine may own function:prompt."
  },
  "package-manager": {
    "kind": "single",
    "exclusive": false,
    "hook": "Initialize-DFRolePackageManager",
    "emptyMembership": true,
    "reserved": { "env": [], "aliases": [], "code": [] },
    "description": "Installs tools. Resolve-DFPackageManager tries the winner first."
  },
  "grep": { "kind": "category", "description": "Searches file contents." }
}
```

| Field | Meaning |
|---|---|
| `kind` | `single`: one winner per registration. `category`: grouping only; no winner, no hook, no reserved names. |
| `exclusive` | `single` only. `true` when two active members would break each other (prompt, project-env). Drives the unresolved-choice warning (§3). |
| `hook` | `single` only. The fixed function name a member's sidecar defines for code-needing behavior. Always `Initialize-DFRole<PascalRole>`. |
| `reserved.env` / `reserved.aliases` | Names only this role's winner may set. Enforced by tests (§6). Windows env var names are case-insensitive, so `PAGER` also covers DotForge's `$Env:Pager`. |
| `reserved.code` | Command names and strings a **member's** sidecar may use only inside its role hook (e.g. `Invoke-Expression` for prompt engines, whose init is an `Invoke-Expression`). Enforced by an AST test (§6). |
| `emptyMembership` | `single` only, default `false`. `true` when core reads the winner directly, so a member needs no aliases, env or hook (package-manager). |
| `requires` | Optional prose stating what a member must support (picker: "accepts fzf's command line and reads candidates on stdin"). Checked by review; by test where it can be. |
| `description` | One line, used by `Get-DFRole` and the generated reference. |

Loaded by a new private `Get-DFRoleDb`, cached in `$script:DFRoleDb` following the process-scoped
cache convention (an explicit `-Path` is uncached).

## 2. The tool side — declaring a role

A tool joins roles with a top-level `roles` map:

```jsonc
"roles": {
  "listing": {
    "priority": 20,
    "aliases": {
      "ls": { "command": "eza", "args": ["--group-directories-first"] },
      "ll": { "command": "eza", "args": ["--long", "--git"] }
    },
    "env": {}
  },
  "grep": {}
}
```

- `priority` (integer, default `0`) ranks members when the user has not chosen (§3).
- `aliases` and `env` use the same shapes as the top-level fields and are applied **only if this
  tool wins the role**.
- For behavior that needs code, the tool's sidecar defines a **plain, non-global** function with
  the role's fixed hook name:

  ```powershell
  # Tools/starship.ps1
  function Initialize-DFRolePrompt {
      param([PSCustomObject]$Tool, [string]$Role)
      Invoke-Expression (& starship init powershell --print-full-init | Out-String)
  }
  ```

  `Invoke-DFToolCompanion` dot-sources the sidecar in its own function scope, so the definition
  stays local to that one call: two sidecars can both define `Initialize-DFRolePrompt` without
  colliding. DotForge reads the function right after dot-sourcing and calls it only if the tool
  won. Hooks may use `$DFCurrentTool` as sidecars do today.
- A membership in a `single` role must supply at least one of `aliases`, `env` or the hook,
  unless the role sets `emptyMembership`; otherwise joining does nothing. A membership in a
  `category` role must supply none of them.
- `ConvertTo-DFToolRecord` normalizes `roles` to a map on every record (empty when absent). The
  legacy `"role": "x"` string is accepted and converted to `roles.x = { priority: 0 }`; the
  normalized record no longer exposes `role`.

## 3. Choosing winners

`Get-DFRoleWinners` (in `Private/Register-DFToolSteps.ps1`) is rewritten. For each `single` role
with at least one candidate:

1. If `Get-DFConfig Defaults` has an entry for the role and it names a candidate, that tool wins
   (reason `Defaults`).
2. If the entry names a tool that is unknown or not a member, warn and continue to step 3. If it
   names a member that is not installed or not being registered, continue to step 3 without a
   warning (the user may register a subset on purpose).
3. Otherwise the candidate with the highest `priority` wins; ties break on tool name (reason
   `priority`, or `sole` when there is one candidate).
4. If the role is `exclusive`, there are two or more candidates, and no valid `Defaults` entry
   picked the winner, warn once naming the winner and the line to change it:
   `DotForge: both oh-my-posh and starship can draw the prompt; using oh-my-posh. Choose with $DFConfig.Defaults = @{ prompt = 'starship' }`.
   "Once" means once per distinct candidate set, recorded in
   `<Get-DFXdgPath State>/dotforge/role-state.json` (read/written like
   `Private/Get-DFToolSetupState.ps1`, atomically through `Write-DFFileAtomic`). Installing a
   third candidate warns again.

The result maps role → `@{ Winner; Reason; Candidates }`. Roles with no candidate are absent.
Resolution reads only the loaded tool DB, `roles.json`, `$DFConfig` and the cached
`Test-DFToolAvailable`; no extra process starts.

## 4. Registration

`Invoke-DFToolRegistration` runs, for every tool, winner or not:

1. XDG, top-level `env`, top-level `aliases`, picker (as today).
2. For each role in `$Tool.roles` the tool **won**, in role-name order: the role block's `env`
   through `Set-DFRoleEnv` (below), then its `aliases` through `Register-DFToolAliases`. Doing this
   before the sidecar lets the sidecar body and the hooks see the role's variables.
3. The sidecar body (as today).
4. For each won role, in role-name order: the role's hook, if the sidecar defined it, called with
   `-Tool $Tool -Role $roleName`.

Roles the tool lost are skipped completely. `Invoke-DFToolCompanion` gains a `-WonRoles`
parameter and calls the hooks itself, right after dot-sourcing, so the hook functions never leave
its scope. A hook counts only if its definition comes from that tool's own sidecar file, so a stray
global function of the same name is never mistaken for it. Hooks are dot-sourced into the same scope
the sidecar body ran in, so init scripts behave exactly as they did in the body. Hooks run inside
each tool's own registration slot, so `dependsOn` ordering (prompt engine before zoxide,
psreadline before PSFzf) still holds.

**`Set-DFRoleEnv`** (private) sets a role's reserved variable. Precedence, highest first:

1. **An explicit `Defaults` choice.** When the winner's reason is `Defaults`, the variable is set
   even if it already held a value from outside DotForge. The user named this tool for this role in
   DotForge's own config, which is the most specific choice available.
2. **A value set outside DotForge.** When the winner was auto-picked (reason `priority` or
   `sole`), a variable that already held a value DotForge did not set is left alone, per
   `ToolAcquisitionSpec.md` §9. A user's `PAGER` beats DotForge's guess.
3. **The auto-picked winner.** Sets the variable when it is unset or holds a value DotForge set
   earlier.

"Set by DotForge" is tracked in `$script:DFRoleEnvSet` (variable → value DotForge wrote); a
variable whose current value differs from what DotForge wrote counts as set outside DotForge.

**Conflict diagnostic.** Case 1 means two explicit settings disagree, for example
`$Env:PAGER = 'less'` in the profile and `$DFConfig.Defaults = @{ pager = 'moar' }`. DotForge
applies the `Defaults` choice and warns, naming both settings and how to resolve it:

```text
WARNING: DotForge: PAGER was 'less' but $DFConfig.Defaults.pager is 'moar'; using moar.
  Remove one of the two settings to silence this.
```

The warning repeats in every new session until the user removes one of the two settings, since
the config contradicts itself. (Within one session, a second `Register-DFTool` call finds the value
DotForge wrote and stays quiet.) It is not shown when the old value equals what the winner sets.

**Reserved variables come only from the role block's declarative `env`.** Hooks never assign them,
which the contract test enforces (§6). `Set-DFRoleEnv` is therefore called only by core, with the
reason core computed, so no plugin can raise its own precedence.

The v1 suppression branch in `Register-DFToolAliases` (`-RoleWinner`) is removed: a role's aliases
now exist only inside role blocks, so a loser never had them to suppress.

**Package manager.** `Resolve-DFPackageManager`'s default order comes from the `package-manager`
role: winner first, then the other candidates by priority. An explicit `-Priority` argument is
unchanged and still bypasses the cache.

### Error handling

Startup never throws because of roles.

| Condition | Behavior |
|---|---|
| A hook throws | `Write-Warning` naming tool and role; registration continues. |
| A `single` membership has no role block content and no hook | Warning at registration; author-time test fails. |
| A tool declares a role missing from `roles.json` | Warning, membership ignored; author-time test fails. |
| `Defaults` names an unknown tool or a non-member | Warning; fall back to priority. |
| `role-state.json` unreadable | Treated as empty (the warning may repeat); never fatal. |
| A reserved env var set outside DotForge disagrees with an explicit `Defaults` winner | `Defaults` applies; conflict warning every registration until resolved (§4). |
| A reserved env var set outside DotForge disagrees with an auto-picked winner | The user's value stays; no warning; `Get-DFRole` shows it (§7). |

## 5. Initial roles

Only tools DotForge already ships. A role with a single member behaves exactly as today.

| Role | Kind | Members | Winner's role behavior |
|---|---|---|---|
| `prompt` | single, exclusive | oh-my-posh, starship | prompt init (moved into hooks) |
| `project-env` | single, exclusive | direnv | `LocationChangedAction` hook (moved into hook) |
| `navigation` | single, exclusive | zoxide | init (moved into hook) |
| `listing` | single | eza, lsd | `ls`, `ll`, `la`, `tree` (moved into `roles.listing.aliases`) |
| `pager` | single | less, bat | `PAGER` |
| `diff` | single | delta | `GIT_PAGER` (moved from top-level `env`) |
| `picker` | single | fzf | `Picker`; requires fzf command-line compatibility |
| `editor` | single | micro | `EDITOR`, `VISUAL` |
| `package-manager` | single | scoop, winget, choco | resolution order |
| `markdown-viewer` | category | glow, mdv, mdcat | — |
| `completion` | category | psreadline, carapace, inshellisense, PSFzf | — |
| `grep` | category | ripgrep | — |
| `file-search` | category | fd | — |
| `system-info` | category | fastfetch | — |
| `url-fetch` | category | curl, wget | — |
| `version-manager` | category | fnm, uv, rustup | — |

Completion is a category because these tools layer on PSReadLine rather than replace each other.
Markdown viewer becomes `single` once something in DotForge consumes a winner.

`pager`, `editor` and `picker` winners now set variables that are unset today. For a user who set
none of them, the only visible change is that DotForge's pager and `Edit-Profile` start working. A
user's own value is kept unless they also name a different tool in `Defaults`, which applies the
`Defaults` choice and warns about the conflict (§4).

## 6. Enforcing the contract (author-time tests)

`tests/Roles.Contract.Tests.ps1`:

- Every key in every tool's `roles` exists in `roles.json`.
- Every `single` membership has role-block content or its sidecar defines the role's hook; every
  `category` membership has neither.
- No tool's **top-level** `env` or `aliases` contains any role's reserved name. This also stops a
  non-member from setting `PAGER`.
- AST scan of each `Tools/*.ps1`, outside `Initialize-DFRole*` functions:
  - no command call or string matching a `reserved.code` entry of any role the tool is a member of;
  - no assignment to a reserved env var of **any** role (`$Env:PAGER = …`,
    `SetEnvironmentVariable('PAGER', …)`). This rule applies inside hooks too: reserved variables
    come only from role blocks.

  (PSReadLine key-handler ownership is out of scope for v2.)
- A sidecar may not define an `Initialize-DFRole*` function for a role its JSON does not declare.

`roles.json` itself is validated: known `kind`, `hook` present and matching the naming rule for
`single`, absent for `category`.

## 7. Discovery and docs

- New public `Get-DFRole [[-Name] <string[]>]` returns one object per role: `Name`, `Kind`,
  `Exclusive`, `Members`, `Candidates`, `Winner`, `Reason`, and `Overridden`: the reserved
  variables whose current value is not the one the winner sets, each with its value and source
  (`outside DotForge`). This makes the auto-pick case visible, for example `Winner: bat`,
  `Overridden: PAGER=less (outside DotForge)`. Full comment-based help; exported in
  `DotForge.psd1`.
- `Find-DFTool -Role <name>` filters by membership.
- `build/Build-DFReferenceDocs.ps1` adds a Roles section generated from `roles.json` and tool
  memberships.
- Update: `docs/plugin-architecture.md` (worked example), `ToolAcquisitionSpec.md` §9 and §10,
  CLAUDE.md "Tool JSON Schema" (`roles` replaces `role`), `docs/guide/configuration.md`,
  `docs/guide/writing-a-tool.md`, CHANGELOG `[Unreleased]`, TODO.md.

## 8. Testing

Synthetic fixtures follow `tests/Register-DFTool.Tests.ps1`, with every XDG folder pointed at
`$TestDrive` and globals removed with `Remove-DFTestGlobal`:

- The winner's hook runs once; a loser's hook never runs; a loser's non-role behavior still runs.
- A tool in two roles loses one and wins the other: only the won hook runs.
- `Defaults` overrides priority; an invalid `Defaults` entry warns and falls back.
- An exclusive role with two candidates warns once per candidate set and again when the set changes.
- `Set-DFRoleEnv` precedence: an explicit `Defaults` winner replaces a pre-set variable and warns
  with both values; an auto-picked winner leaves a pre-set variable alone without a warning; either
  replaces a value DotForge set earlier; no warning when the old and new values are equal.
- `Get-DFRole` reports `Overridden` for an auto-picked winner whose variable was pre-set.
- A throwing hook warns and does not stop later tools.
- The legacy `role` string normalizes to `roles`.

Real records: `Defaults = @{ listing = 'lsd' }` versus `'eza'` flips who owns `ls`; with
oh-my-posh and starship both stubbed available, exactly one prompt hook runs.

Startup: `build/Measure-DFStartup.ps1` before and after shows no measurable regression.

## Deferred

New members per role, each its own small spec or plan:

- pager: moar, ov
- editor: nano, vim
- picker: skim; television does not take fzf's command line, so it needs its own adapter or a different role
- file-manager (new role): yazi, superfile, broot
- project-env: ps-dotenv (needs a declarative scoop-bucket field), mise
- system-info: winfetch
- url-fetch: httpie, xh, curlie, aria2

Suggested new roles: shell-history (atuin), git-tui (lazygit, gitui), process-viewer (procs, btop,
bottom), disk-usage (dust, dua, gdu), json (jq, jaq, fx, jless), cat (bat), elevation (gsudo),
dotfiles (chezmoi, yadm), quick-help (tealdeer), secrets (bitwarden), replace (sd), watch
(watchexec), code-stats (tokei, scc).

Also deferred: role-level alias behavior specs (existing TODO: describe `ll` once per role and let
each tool map it to its own flags; the role block's `aliases` is where that lands).

## Acceptance criteria

- Only DotForge invokes role behavior, and only for the winner, for every role in §5.
- Every shipped single-member role behaves as before.
- `Defaults` selects; priority decides otherwise; exclusive conflicts warn once per candidate set.
- The contract tests in §6 pass and fail on a deliberately broken fixture.
- Full suite green under Pester 6; reference regenerated; docs updated.
