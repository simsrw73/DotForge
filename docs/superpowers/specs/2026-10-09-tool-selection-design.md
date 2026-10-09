# Opt-in tool selection, groups and explicit install: design

**Status:** approved 2026-10-09 · **Date:** 2026-10-09 · **Decided in:** a grilling session (decisions 1–14 below are the user's)
**Related:** `arch-imp-audit-(claude).md` (2026-10-09). This spec reorders that review: it comes first, and candidates 1 and 3 become follow-ups.

## Context

The original model was a mistake: DotForge configures **whatever happens to be installed**.

- **`Register-DFTool -All`** registers every tool DotForge knows that is present on the machine, and `SkipTools` subtracts from that.
- **Installing was presented as part of startup.** `examples/02-standard.ps1:47-58` checks a list of tools and calls `Install-DFTool` from the profile on every start. The module never installs during registration, but this is the pattern the docs teach.

The consequences:

- **Tools nobody asked for load.** posh-git and Terminal-Icons cost 1.3–2.6 s at startup (measured 2026-10-09), only because they are installed.
- **Every new tool DotForge adds** starts loading on every machine where it happens to exist.
- **A requested tool that's missing is silent.** It shows only under `-Verbose`.
- **Startup does install-only work.** `Initialize-DFEnvironment` detects package managers and loads the whole tool DB, but only installs need that.

The intended model is that the user says which tools they want. At load, DotForge configures those that are installed and lists those that aren't. Installing is a separate command, run when the user chooses, and it installs everything missing at once.

## Goals

- Load and configure only requested tools. Never look at tools that weren't requested.
- Never install during a normal load.
- Tell the user, every load, which requested tools are missing, and give one command that installs them all.
- Let users request predefined **groups** as well as individual tools.
- Make "what did DotForge do in this session" inspectable.

## Non-goals (follow-ups)

- **Idle-time activation** (review candidate 1): measure startup after this lands, then decide.
- **A compiled tool registry** (review candidate 3): an internal optimization behind the loader's interface, so it can be added later.
- **Deactivating a tool mid-session.**

## Decisions

| # | Decision |
|---|---|
| 1 | **Opt-in only.** `Register-DFTool -All` and `SkipTools` are removed. |
| 2 | The request list is **`Tools`** in the config hashtable. |
| 3 | **Groups** are DotForge-owned, predefined lists in **one file**, `data/groups.json`. This is a deliberate exception to the plugin rule against central tool-keyed lists (recorded in `docs/plugin-architecture.md`): it is curated data, not core logic. A test fails if a group names an unknown tool. |
| 4 | A group is written **`+name`** (e.g. `+dev-tools`). This works unquoted as a command argument. |
| 5 | **`ExcludeTools`** is a separate list. It accepts tools and `+groups`, exclusions always win, and excluding something that wasn't requested warns. |
| 6 | **Roles fall back among requested tools.** If the preferred tool is missing, another *requested* installed candidate fills the role, and the notice says so. `Defaults` stays. |
| 7 | **The missing notice shows on every load.** It lists names when there are 5 or fewer; otherwise it gives the count and the commands. It is silent when nothing is missing. |
| 8 | **`Get-DFToolStatus`** reports what the last load decided, one object per requested tool. |
| 9 | **`Install-DFTool -Missing`** plans, confirms (`-WhatIf`; `-Force` skips the prompt), batches per package manager, reports per tool, and activates in the current session. |
| 10 | **One-time setup runs on first activation.** Config-file seeding is part of setup. `Install-DFTool -Name x -Setup` re-runs it. |
| 11 | **`after` (ordering only) and `requires` (hard dependency)** replace `dependsOn`. Requirements are requested automatically; a tool whose requirement is missing isn't activated. |
| 12 | **`Start-DFSession -Config <hashtable>`** is the single profile entry point. `-Config` is required, the module keeps its own copy, and the global `$DFConfig` is no longer read anywhere. `Initialize-DFEnvironment` is removed. |
| 13 | Idle activation and the compiled registry are out of scope (follow-ups). |
| 14 | **`requires` can name a role** as well as a tool: inshellisense needs a JavaScript runtime (node or bun, or a node version manager such as fnm), not fnm itself. |

Defaults chosen while writing this spec. Each is reversible in review.

- **a.** Groups don't nest.
- **b.** Calling `Start-DFSession` again only adds tools. A tool removed from `Tools` stays active until the next shell, and DotForge says so.
- **c.** `Install-DFTool` uses any installed package manager, whether or not it's requested, ordered by the `package-manager` role (`Defaults`, then priority).
- **d.** The initial group list below is a draft for the user to edit.

## The profile

```powershell
Import-Module DotForge
Start-DFSession -Config @{
    Tools        = @('+core', '+dev-tools', 'starship', 'zoxide')
    ExcludeTools = @('lazygit')
    Defaults     = @{ prompt = 'starship' }
    Theme        = 'catppuccin-mocha'
}
```

`Import-Module DotForge` alone changes nothing in the session (apart from the general helpers, which are module commands). `Start-DFSession` does everything else.

## Design

### 1. Config

- **`Start-DFSession -Config <hashtable>`** validates the hashtable:
  - Unknown top-level keys warn with "did you mean", using the same suggestion helper as the tool schema (`Get-DFFieldSuggestion`).
  - The module stores a snapshot in `$script:DFSessionConfig`.
- **`Get-DFConfig -Key -Default`** reads only that snapshot. Today it falls back to a global `$DFConfig`; that fallback is removed. Every current reader of `$DFConfig` goes through `Get-DFConfig`, which CLAUDE.md already requires.
- **Before `Start-DFSession` runs** (for example, a script importing DotForge only for its helpers), `Get-DFConfig` returns defaults.
- **Known keys:**
  - `Tools`, `ExcludeTools` and `Defaults`.
  - The existing theme keys (`Theme` and per-tool keys such as `BatTheme`).
  - `SkipSetup`, `SkipConflictCheck` and `IgnoreConflicts`.
  - The per-tool keys a companion reads, e.g. `DotenvApprovedDirs`. Declaring those in tool JSON so they validate is review candidate 4; until then the list of valid keys is hand-kept in one place, next to `Start-DFSession`.

### 2. Groups: `data/groups.json`

```json
{
  "core":      { "description": "Everyday shell improvements", "tools": ["psreadline", "PSFzf", "fzf", "eza", "bat", "fd", "ripgrep", "zoxide", "carapace", "less"] },
  "prompt":    { "description": "A themed prompt", "tools": ["starship"] }
}
```

- The keys are group names: lowercase, letters, digits and hyphens.
- **Tests:**
  - every member is a tool in `Tools/`
  - no group name equals a tool name
  - no group references another group (default **a**)
  - descriptions are present
- `Get-DFToolGroup [-Name]` lists groups and their members. It is a small public command, so users can discover what `+dev-tools` means.

**Draft initial groups (to edit in review):**

| Group | Members (draft) |
|---|---|
| `+core` | psreadline, PSFzf, fzf, eza, bat, fd, ripgrep, zoxide, carapace, less |
| `+prompt` | starship |
| `+git` | delta, gh, lazygit |
| `+dev-tools` | jq, uv, fnm, rustup, micro, mise, chezmoi |
| `+admin-tools` | gsudo, procs, fastfetch, curl, wget |
| `+markdown` | glow |
| `+package-managers` | scoop, winget |

Not in any draft group: bitwarden, broot, choco, direnv, docker, inshellisense, lsd, mdcat, mdv, moor, npm, oh-my-posh, ov, posh-git, ps-dotenv, Terminal-Icons, vcpkg and vivid. They can still be requested by name.

### 3. Resolving the request set

`Resolve-DFRequestedTools` is pure: config and tool DB in, request set out. It runs these steps in order:

1. **Expand `Tools`.**
   - A `+group` becomes its members. An unknown group is an error.
   - A tool name stays itself. An unknown tool warns, with "did you mean".
   - Each item remembers what asked for it: `Tools`, or `+group`.
2. **Expand `ExcludeTools` the same way and remove those entries.**
   - An exclusion of something not requested warns.
   - Excluded tools are kept, marked `Excluded`, so `Get-DFToolStatus` can show them.
3. **Add requirements.** For each remaining tool, add its `requires` tools transitively, each marked `RequestedBy: requires (<tool>)`.
   - An excluded tool that another tool requires stays excluded. The requiring tool then reports `Missing` with the detail "requires X, which is excluded".
   - A cycle in `requires` warns and falls back to the original order, as `dependsOn` cycles always have; both tools are still activated. (Changed from "an error" when `requires` was implemented.)
4. **Return** the request set, ordered by `after` and `requires` (topological sort, as today's `Invoke-DFTopoSort`).

Only the records of requested tools are read. With today's per-file JSON that means the requested files plus `groups.json` (and `roles.json`). The loader exposes this as one call, "records for these names", so a compiled registry can replace it later.

### 4. Availability and roles

- **Availability:** `Test-DFToolAvailable` runs only on the request set.
- **States per requested tool:**
  - `Missing` when the tool isn't installed.
  - `Missing` with the detail "requires X" when a required tool is unavailable.
  - Otherwise the tool is a candidate for activation.
- **Role winners** (`Get-DFRoleWinners`) are computed over **requested, available** tools.
  - If the `Defaults` choice for a role is requested but missing, the next candidate wins, and the role result records it as `fallback`. The notice says "starship (prompt) is missing — using oh-my-posh until it's installed".
  - If the `Defaults` choice isn't requested at all, that's a warning. A role can't be filled by something the user didn't ask for.
  - `optIn` keeps its meaning: an opt-in member competes only when `Defaults` names it.

### 5. Lifecycle per tool

```
requested ──► available? ──no──► Missing (notice; Install-DFTool -Missing)
                 │yes
                 ▼
          setup recorded? ──no──► run setup (once) ──fail──► Failed (retried next load)
                 │yes                    │ok
                 ▼                       ▼
              activate (every load: env, aliases, picker, role env/aliases, companion, role hook)
                 │
                 ├─ok──► Active
                 └─throw► Failed (warned, rest continue — existing per-tool isolation)
```

**Setup (decision 10)** combines today's `Tools/<name>.setup.ps1` and declarative config seeding (`xdg.method: "config"`) into one **setup step**.

- **When it runs:** the first time the tool is activated, whether right after `Install-DFTool` or on the next load after a manual install. It is recorded in `$XDG_STATE_HOME/dotforge/setup-state.json`.
- **Seeding:**
  - It no longer checks for the config file on every load.
  - A config file deleted on purpose isn't recreated.
  - `-Setup` re-runs it.
- **`SkipSetup`** keeps its meaning.
- **Exact field shape:** `xdg.method: "config"` becomes a `setup.seed` block, and the TODO "`xdg.method` can't express env + config seeding" is resolved by letting a tool have both `xdg.vars` and `setup.seed`.

### 6. `Start-DFSession -Config`

1. Validate and store the config (section 1).
2. Export the XDG variables. This is today's `Initialize-DFEnvironment` minus package-manager detection and minus its status line; directories are created only when a tool writes to them.
3. Resolve the request set (section 3), check availability, pick role winners (section 4).
4. Set up, then activate each available tool in order. A failure warns and the rest continue.
5. Run the coreutils conflict check over the active tools, as today; it stays switchable with `SkipConflictCheck`.
6. Record the session result in `$script:DFSessionStatus` for `Get-DFToolStatus`.
7. Print the missing notice (section 7).

**Calling it again (default b):**
- It applies the new config and activates newly requested tools.
- Tools that are already active are not re-activated.
- A tool no longer requested warns: "removed from Tools; it stays active until you open a new shell".

**`Register-DFTool -Name x`** stays. It runs steps 3–4 for one tool against the session config, and `Install-DFTool` uses it to activate freshly installed tools.

### 7. The missing notice

It is one `Write-Warning` at the end of `Start-DFSession`, and it is skipped when nothing is missing.

- **5 or fewer missing:**
  `DotForge: 3 requested tools aren't installed: glow, lazygit, starship (prompt — using oh-my-posh). Run Install-DFTool -Missing to install them.`
- **More than 5:**
  `DotForge: 12 requested tools aren't installed. See Get-DFToolStatus -Missing; install them with Install-DFTool -Missing.`
- **Failed tools** get their own line: `DotForge: 1 tool failed to load: carapace. See Get-DFToolStatus -Failed.`

### 8. `Get-DFToolStatus`

```powershell
Get-DFToolStatus [-Name <string[]>] [-Missing] [-Failed]
```

It returns one `DotForge.ToolStatus` object per requested or excluded tool:

| Property | Meaning |
|---|---|
| `Name` | tool name |
| `State` | `Active`, `Missing`, `Failed`, `Excluded` |
| `RequestedBy` | `Tools`, `+group`, or `requires (<tool>)` |
| `Roles` | roles it won this session |
| `Detail` | failure message, "requires X", "using Y instead", "excluded by ExcludeTools" |

It reads `$script:DFSessionStatus` and costs nothing. Before `Start-DFSession` has run, it says so.

Its objects pipe into `Install-DFTool`, which takes `Name` by property name.

### 9. `Install-DFTool`

```powershell
Install-DFTool -Missing [-Force] [-WhatIf]
Install-DFTool -Name <string[]> [-Setup] [-Force] [-WhatIf]
```

1. **Targets:**
   - `-Missing` takes the session's `Missing` tools, including requirements.
   - `-Name` takes the given tools, and `+groups` expand.
   - With `-Setup` on an installed tool, it skips to step 6.
2. **Choose a manager per tool:** the first available package manager, in `package-manager` role order, for which the tool has a package (default **c**). A tool with no usable package is reported and skipped.
3. **Plan:** for example `scoop: glow lazygit · winget: Starship.Starship`. Confirm through `ShouldProcess` (ConfirmImpact High). `-Force` skips the prompt, and `-WhatIf` shows the plan only.
4. **Install in one batch per manager** (`scoop install glow lazygit`), through the **package-manager module** (review candidate 5).
   - That module owns the install argv per manager, bucket handling and `npm`. Today `npm` is missing, so npm-only tools can't install.
   - It sits behind a port with a recording fake for tests.
5. **Report per tool:** installed, failed (with the manager's output), or no package.
6. **Activate in the current session:** refresh availability, run setup (or re-run it with `-Setup`), then activate through `Register-DFTool -Name`. `Get-DFToolStatus` updates.
7. **A tool installed by name but not in `Tools`** warns: "installed and active now; add it to Tools to load it in future sessions".

Package managers are never detected at startup. Only `Install-DFTool` and the package-manager pickers do it, on first use.

### 10. `after` and `requires` (tool JSON)

```json
"after":    ["oh-my-posh", "starship"],
"requires": ["fzf"]
```

- **`after`** affects ordering only, and only among requested tools. It is today's `dependsOn` renamed.
- **`requires`** auto-requests the named tools and implies `after`. If a required tool is unavailable, the tool isn't activated.
- **A role requirement** is written `role:<name>`, e.g. `"requires": ["role:js-runtime"]`. A plain name is always a tool, so the two namespaces never collide.
  - It is satisfied when **any requested, available member** of the role is active.
  - **No member is ever requested on the user's behalf.** Which version manager or standalone runtime to use is the user's choice, made by listing it in `Tools`. (Changed during implementation: an auto-picked member was the first design, and was rejected.)
  - With no member requested, the requiring tool is **not** blocked: the runtime can come from outside DotForge (a standalone node on PATH). It still needs its own executable; if that is missing, its detail names the tools that could fill the role ("needs a js-runtime: add fnm or mise to Tools"). Finding them reads every tool record, so it happens only for a missing tool.
  - **Open for slice 3: managers are not runtimes.** fnm or mise being installed doesn't mean node is: a version manager may have no runtime installed yet. Likely model: `node`/`bun` records are the `js-runtime` members, ordered after the `version-manager` role; fnm/mise leave `js-runtime`. A tool that needs a particular runtime (`node`, `npm`) requires it by name, whoever manages it. The missing notice then tells "node not on PATH; fnm is active, run `fnm install --lts`" from "no runtime", and `Install-DFTool -Missing` installs a runtime through the active manager rather than a package manager.
  - A role requirement implies `after` for every member of the role.
  - `Resolve-DFToolRequirements` (in `Private/Invoke-DFSessionActivation.ps1`) handles both kinds after `Resolve-DFRequestedTools`; the schema checks the `requires` shape, and a test checks that shipped `role:` names exist in `roles.json`.
- **The schema validates both** (arrays of tool names; an unknown name is an error), and `dependsOn` is removed. That's no compatibility concern, since there are no users yet.

**Today's `dependsOn` re-sorted:**

| Tool | Today | After |
|---|---|---|
| PSFzf | psreadline, fzf | `requires: [fzf]`, `after: [psreadline]` |
| zoxide | oh-my-posh, starship | `after: [oh-my-posh, starship]` |
| carapace | fnm, psreadline | `after: [fnm, psreadline]`. The inshellisense bridge degrades without fnm. |
| inshellisense | psreadline | `requires: [role:js-runtime]`, `after: [psreadline]` |
| others | (see each `Tools/*.json`) | classified one by one during implementation |

## What's removed

- **`Register-DFTool -All` and `SkipTools`.**
- **`Initialize-DFEnvironment`.** It's folded into `Start-DFSession`, and package-manager detection moves into `Install-DFTool`.
- **The global `$DFConfig`.**
- **`dependsOn`**, replaced by `after` and `requires`.
- **`xdg.method: "config"`**, replaced by setup seeding.
- **The install-at-startup block** in `examples/02-standard.ps1`, and any guide text recommending it.

## Docs and migration

- **Guides:**
  - `docs/guide/getting-started.md` and `configuration.md` get the new profile.
  - `writing-a-tool.md` gets `after`/`requires`/setup.
  - `tools.md` gets the groups.
  - `troubleshooting.md` gets the new notices.
- **The examples are rewritten:** `examples/0x-*.ps1`.
- **The user's profile** (`~/.config/powershell/profile.ps1`, managed by chezmoi) needs migrating:
  - It has two load blocks (lines 86–92 and 122–130); both switch to `Start-DFSession -Config`.
  - Its `SkipTools = @('lsd', 'oh-my-posh')` is no longer needed: neither tool will be requested.
- **The CHANGELOG** gets a `Removed` section listing every removal above, each with its replacement.

## Tests

- **Request resolution (pure):**
  - group expansion, exclusions (tools and groups, exclusion wins)
  - warnings for unknown tools and groups, and for exclusions of unrequested tools
  - requirement auto-request, excluded requirement, `requires` cycle
  - ordering by `after`/`requires`
- **Roles:** fallback among requested tools; a `Defaults` choice that isn't requested warns; `optIn`.
- **Setup:**
  - runs once on first activation, not again
  - a failure retries next load
  - seeding doesn't recreate a deleted file
  - `-Setup` re-runs it
- **`Start-DFSession`:**
  - only requested tools are read and checked; an unrequested installed tool is never touched (assert `Test-DFToolAvailable` is never called for it)
  - the notice in its three shapes, and silent when nothing is missing
  - calling it again only adds
  - an unknown config key warns
- **`Get-DFToolStatus`:** states, filters, before-session behavior.
- **`Install-DFTool`** with the recording package-manager fake:
  - the plan
  - one batch per manager
  - `-WhatIf` installs nothing
  - activation afterwards
  - a tool with no package
  - npm
- **`groups.json` invariants** (section 2).
- **No global `$DFConfig` read** anywhere in `Private/`, `Public/` or `Tools/` (AST test).
- **The decoy-folder full run:** every `XDG_*_HOME` points at empty sentinel folders, and the run asserts no files were written there.

## Implementation slices

1. **`Start-DFSession`, config snapshot, request resolution, groups, missing notice, `Get-DFToolStatus`.**
   - `-All`, `SkipTools`, `Initialize-DFEnvironment` and the `$DFConfig` global are removed.
   - Startup is measured before and after.
2. **`after`/`requires`** replace `dependsOn`, and the **one-time setup step** absorbs config seeding.
3. **Package-manager module** (review candidate 5) and **`Install-DFTool -Missing`/`-Setup`.** This also fixes the npm bug.
4. **Migration:**
   - the user's profile, examples and guides
   - confirm the group list with the user
   - final startup measurement
   - then decide on the idle-activation follow-up

## Open items for review

- **The draft group list (section 2):** names and members are the user's call.
- **The new `js-runtime` role** (decision 14) needs members. fnm joins it, since it provides `node`, and stays in `version-manager`. `nodejs` and `bun` tool records don't exist yet; adding them is a TODO.
- **The notice threshold** of 5 is a guess. Adjust after living with it.
