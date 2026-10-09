# Installing tools: managers as plugins, sources, staged install (slice 3)

**Status:** implemented 2026-10-09 (branch `feat/install-slice3`; deviations are the rulings in the plan ledger) · **Date:** 2026-10-09 · **Decided in:** a grilling session (decisions 1–14 below are the user's)
**Parent:** [the tool-selection spec](2026-10-09-tool-selection-design.md), slice 3. This spec replaces its section 9 (`Install-DFTool`) and the "managers are not runtimes" open item in section 10.

## Context

Slices 1 and 2 made loading opt-in: `Start-DFSession` configures the requested tools that are installed and lists the missing ones, pointing at `Install-DFTool -Missing`. That command doesn't exist yet. What exists today (`Public/Install-DFTool.ps1`):

- **One tool at a time**, trying managers in order. The install command lines live in a `switch ($pm)` in core code, which is exactly the tool-name switch the plugin invariant forbids.
- **npm isn't in the switch**, so inshellisense (npm only) can't be installed.
- **Manager order** is the `package-manager` role (scoop > winget > choco; `Defaults` or `PackageManagerOrder` override). cargo is appended as a last resort, and psresource is reached only when nothing earlier has the package.
- **`packages` keys are manager names** (`scoop` 38 tools, `winget` 28, `choco` 22, `psresource` 3, `cargo` 2, `npm` 1). The catalog search names sources differently (`crates`, `psgallery`), which needed an alias field on the catalog providers (`33cac38`).
- **Third-party scoop buckets** are a scoop-only special case: the `scoopBucket` field and `Add-DFScoopBucket`.
- **The same install commands are written three more times:** the picker sidecars' `InstallCommand` (`Tools/{scoop,winget,choco}.ps1`) and six catalog `InstallHint` strings (`Private/DFCatalog.*.ps1`).
- **fnm and mise are in `js-runtime`**, but they manage runtimes rather than being one. fnm installed doesn't mean node is.

## Goals

- `Install-DFTool -Missing` installs everything the session reported missing, in one run, in the right order, with the user's choices made up front.
- Every manager is a plugin. Core never names one.
- Curated per-tool knowledge (which package is official, which is stale) is expressible in the tool spec, and the user can override it.
- Nothing the user didn't ask for is installed, unless they chose to accept defaults.
- No startup cost on a machine where every requested tool is installed.

## Non-goals (follow-ups)

- **Updating installed tools** (`Update-DFTool`) and **removing tools**. These are TODO items.
- **Version pinning** beyond what a source id already says (fnm's `lts`).
- **Non-module libraries** (a Python or npm library with no command). See decision 6.

## Decisions

| # | Decision |
|---|---|
| 1 | **Managers are plugins.** A manager's own tool JSON declares how it installs (`installs`). Core reads the block of whichever manager it picked. No central manager table. |
| 2 | **Preference is layered; the tool spec owns its own preference.** From highest: the user's per-tool `InstallVia`, the tool spec's `install.prefer`, the user's `InstallOrder`, DotForge's built-in order. Tools are hand-curated: the spec knows which packages are official and maintained. |
| 3 | **`packages` is keyed by source**: a system manager (scoop, winget, choco) or an ecosystem **registry** (npm, pypi, crates, psgallery). A registry is served by its ecosystem role's winner: `js-package-manager` (npm, pnpm, bun), `python-package-manager` (pip, pipx, uv), `powershell-package-manager` (psresource). The keys match the catalog's source names, so the alias field goes. |
| 4 | **Feeds** (scoop buckets, Claude Code marketplaces, winget sources, extra indexes) are part of the package entry: `{ "id": …, "feed": { "name": …, "url": … } }`. The manager declares how to list and add feeds and how a feed-qualified id is formed. `scoopBucket` is folded in. A third-party feed is always shown in the plan before the user confirms. |
| 5 | **Nothing unrequested is installed by default.** `-UseDefaults` lets an experienced user accept DotForge's and the tool specs' defaults for every gap. |
| 6 | **One kind of record.** Tools and libraries are both tool records; `type` (`exe`, `module`) says how to check that one is installed. A non-module library type waits for a real case; its installed check (asking the manager) is too slow for startup and needs its own design. |
| 7 | **Runtimes are tools; version managers are sources.** `node` and `bun` are the `js-runtime` members; fnm and mise leave that role. node's preference lists the version managers first (`fnm install lts`). npm requires node and comes with it. `after` accepts `role:` entries, so node is checked after any version manager has run. |
| 8 | **One graph.** `Start-DFSession` builds the request/requirement graph (as now). The install layer is added to the same graph only when something is missing, or on demand. The missing notice, `Get-DFToolStatus` and the installer all read it. |
| 9 | **Two modes, interactive by default.** Interactive: each open choice shows its default ("OK, or change?"), then the staged plan is confirmed once and runs unattended. `-UseDefaults`: no questions. A non-interactive host without `-UseDefaults` installs only what needs no decision and reports each gap. `-WhatIf`: the plan only. |
| 10 | **Staged execution with PATH refresh.** Install in dependency order. After each stage, merge registry PATH entries, re-activate managers that ask for it, re-check. A failed stage skips its dependents with the reason. |
| 11 | **Elevation is declared by the manager.** Run through gsudo when it is active (one UAC prompt per batch); otherwise skip that manager, offering the next source in interactive mode. Never relaunch the shell. |
| 12 | **`Invoke-DFToolSetup -Name [-Force]`** re-runs a tool's one-time setup. `Install-DFTool` doesn't take `-Setup`. |
| 13 | **`InstallOrder` is an order only.** Leaving a source out doesn't forbid it; `ExcludeSources` does. `InstallVia` beats an exclusion. |
| 14 | **Same slice:** the picker sidecars and the catalog providers read the managers' `installs` blocks, and the catalog alias field is deleted. |

## Design

### 1. The manager's `installs` block

A manager is a tool record with an `installs` block. Example shapes (final field names settled in the plan):

```json
// scoop.json
"installs": {
  "from": "scoop",
  "command": ["scoop", "install", "{id}"],
  "batch": true,
  "feeds": {
    "list": ["scoop", "bucket", "list"],
    "add":  ["scoop", "bucket", "add", "{name}", "{url}"],
    "id":   "{feed}/{id}"
  }
}

// choco.json
"installs": { "from": "choco", "command": ["choco", "install", "{id}", "-y"], "batch": true, "elevate": true }

// pnpm.json (a js-package-manager; installs from the npm registry)
"installs": { "from": "npm", "command": ["pnpm", "add", "-g", "{id}"], "batch": true }

// fnm.json (a version manager is a source too)
"installs": { "from": "fnm", "command": ["fnm", "install", "{id}"], "reactivate": true }

// psresource.json (a module command, not an executable)
"installs": { "from": "psgallery", "function": "Install-PSResource", "args": { "Name": "{ids}", "Scope": "CurrentUser" } }
```

- **`from`** names the source the manager installs. For a system manager it's the manager's own name. For a registry, several managers share it, and the ecosystem role's winner serves it.
- **`batch`** means the manager can install several ids in one call.
- **`elevate`** means the manager needs an elevated shell (decision 11).
- **`reactivate`** means DotForge re-runs the manager's companion after it installs something, so new runtimes reach PATH in this session.
- **`feeds`** is optional (decision 4).
- **New manager records:** cargo, psresource, pnpm, bun, pip, pipx, uv (whichever the shipped tools need first), plus `node`. npm's record gains `installs` and the `js-package-manager` role.

### 2. The tool side: `packages` and `install.prefer`

```json
"packages": {
  "winget": "charmbracelet.glow",
  "scoop":  "glow",
  "choco":  "glow"
},
"install": { "prefer": ["winget", "scoop"] }
```

- A `packages` value is an id, or `{ "id": …, "feed": { "name": …, "url": … } }`.
- **`install.prefer`** is the tool spec's ordered preference, layer 2 of decision 2. Sources it doesn't list follow in the user's or built-in order. It may name any source the tool has, including a registry (`"prefer": ["psgallery"]` for a PowerShell module) or a version manager (node: `["fnm", "mise", "scoop", "winget"]`).
- **The ecosystem rule** (libraries install through their ecosystem's manager) is expressed through `install.prefer`, not by a type.
- **Key renames:** `cargo` becomes `crates`, and `psresource` becomes `psgallery`. `scoopBucket` becomes a `feed`.

### 3. Choosing a source per tool

For each tool to install, the candidate sources are its `packages` keys, minus `ExcludeSources` (unless named by `InstallVia`), ordered by:

1. **`InstallVia[tool]`** from the session config, if set.
2. **The tool's `install.prefer`.**
3. **`InstallOrder`** from the session config. It is ordering only (decision 13).
4. **DotForge's built-in order.** System managers by `package-manager` role priority, then registries.

The first candidate whose manager is **available or planned in an earlier stage** wins. For a registry, the manager is the ecosystem role's winner among requested tools (`Defaults` first).

When no candidate is usable, the tool is a **gap**:
- In interactive mode, the user is asked: for example, pick a `js-package-manager`, or allow an excluded source once.
- With `-UseDefaults`, DotForge takes the role's top-priority member.
- Otherwise, it is reported and skipped (decision 9).

Gap reports name the cause precisely: "glow: no source left (only choco has it, and choco is in ExcludeSources)".

### 4. The graph

`Start-DFSession` already builds the request graph:
- requested tools;
- requirements (`requires`);
- ordering (`after`);
- what's installed.

When the session has **Missing** tools, it adds the install layer for them:
- the chosen source and manager per tool (section 3);
- dependencies on managers and runtimes (inshellisense → npm registry → npm → node → fnm);
- the resulting **stages**;
- the **gaps**.

With nothing missing, none of this runs. `Install-DFTool -Name x` builds it on demand.

The missing notice and `Get-DFToolStatus` read the install layer for their detail, e.g. "node: not on PATH — fnm is active; `Install-DFTool -Missing` will run `fnm install lts`".

### 5. `Install-DFTool`

```powershell
Install-DFTool -Missing [-UseDefaults] [-WhatIf]
Install-DFTool -Name <string[]> [-Via <source>] [-UseDefaults] [-WhatIf]
```

1. **Targets.**
   - `-Missing` takes the session's Missing tools, including requirements.
   - `-Name` takes the given tools; `+groups` expand. `-Via` is a one-off `InstallVia` for every named tool.
2. **Resolve** sources, managers, stages and gaps (sections 3 and 4).
3. **Choose.**
   - Interactive: open choices one by one, each showing its default.
   - `-UseDefaults`: take every default.
   - Non-interactive host: gaps are skipped.

   When the user changes a choice, interactive mode can print the config line that would make it permanent. DotForge never edits the profile.
4. **Plan.** Stages, each listing manager batches. Example:
   ```
   stage 1  scoop: fnm · winget: Starship.Starship
   stage 2  fnm: node (lts)
   stage 3  npm: @microsoft/inshellisense
            scoop: + bucket 'dotenv' (https://github.com/…) · ps-dotenv
            choco (1 UAC prompt via gsudo): glow
   ```
   Third-party feeds and elevation are always visible. Interactive mode confirms the whole plan once (`ShouldProcess`). `-UseDefaults` doesn't prompt, and `-WhatIf` stops here.
5. **Run each stage.** For each manager batch:
   - add any feeds;
   - run the batch (one call when the manager supports `batch`), elevated per decision 11;
   - capture the output.

   After the stage:
   - merge new User/Machine registry PATH entries into `$Env:Path` through `Add-DFToPath`, appending only and never reordering;
   - re-activate managers with `reactivate`;
   - re-check the stage's tools with no cached answer.

   A failed tool skips its dependents ("skipped: fnm failed").
6. **Activate.**
   - Newly installed requested tools are activated in this session (`Register-DFTool -Name`, which runs their one-time setup), and `Get-DFToolStatus` updates.
   - A tool installed by name but not in `Tools` is activated too, with the hint "add it to Tools to load it in future sessions".
   - A tool that is installed but still not found is reported as "installed; open a new shell".
7. **Summary:** installed, failed (with the manager's output), skipped (with the reason), and gaps.

**The process seam:** every manager command runs through one private runner, so tests substitute a recording fake. This is the same injectable-seam pattern as the conformance harness.

### 6. `Invoke-DFToolSetup`

`Invoke-DFToolSetup -Name <tool> [-Force]` clears the tool's setup record and runs its setup step now: seeds, then the setup script.
- A seeded file that already exists is kept.
- `-Force` overwrites seeded files after a `ShouldProcess` confirm.
- The tool must be active in the session.

### 7. Config keys

| Key | Meaning |
|---|---|
| `InstallVia` | `@{ tool = 'source' }`: per-tool choice; beats everything, including `ExcludeSources`. |
| `InstallOrder` | Ordered sources; ordering only. |
| `ExcludeSources` | Sources never used (except via `InstallVia`). |
| `Defaults['<ecosystem>-package-manager']` | Which manager serves a registry (existing `Defaults` mechanism). |

**Removed:** `PackageManagerOrder`, and `Install-DFTool -PackageManager` (replaced by `-Via`).

### 8. Runtimes and version managers

| Record | Roles | Installed via |
|---|---|---|
| `node` (new) | `js-runtime` | `prefer: [fnm, mise, scoop, winget]`; `after: ["role:version-manager"]` |
| `bun` (new) | `js-runtime`, `js-package-manager` | scoop / winget / npm |
| `npm` | `js-package-manager` | no packages: `requires: ["node"]`, comes with node |
| `fnm`, `mise` | `version-manager` (leave `js-runtime`) | system managers; `installs` with `reactivate` |
| inshellisense | | npm registry; `requires: ["role:js-runtime"]` |

**The planning rule:** a tool with no packages that requires X is planned as "provided by X". Installing X is how it gets installed, and it is re-checked after X's stage.

### 9. Pickers and catalog hints

- **The picker sidecars** (`Tools/{scoop,winget,choco}.ps1`) format their own record's `installs.command` instead of a hard-coded `InstallCommand`.
- **Each catalog provider** asks "the manager for my source" for its `InstallHint`. This reads manager records during a search only.
- **The `PackageManager` alias field** on catalog providers is deleted, because `packages` keys now equal catalog source names.

## What's removed

- The `switch ($pm)` in `Install-DFTool`.
- `scoopBucket` (as a field), `PackageManagerOrder`, `-PackageManager`.
- The `cargo`/`psresource` package keys, renamed `crates`/`psgallery`.
- fnm and mise's `js-runtime` membership.
- The catalog providers' `PackageManager` alias.
- The hard-coded picker `InstallCommand`s and catalog `InstallHint` strings.

## Tests

- **Source choice:**
  - the four layers, in order;
  - `ExcludeSources`, with `InstallVia` beating it;
  - a registry served by the role winner;
  - gap detection, with the precise reason.
- **Graph:**
  - the install layer is built only when something is missing (assert no manager record is read on a healthy load);
  - stages for scoop → fnm → node → npm → inshellisense;
  - "provided by" for npm.
- **Modes:**
  - interactive choice prompts (mocked host input);
  - `-UseDefaults` asks nothing;
  - a non-interactive host skips gaps and reports their dependents;
  - `-WhatIf` runs nothing.
- **Execution with the recording fake:**
  - one batch per manager per stage;
  - feeds added before installs, and shown in the plan;
  - elevation through gsudo, and skipped without it;
  - a failed stage skips dependents;
  - PATH merge appends only;
  - `reactivate` re-runs the companion;
  - activation and the "add to Tools" hint afterwards.
- **`Invoke-DFToolSetup`:** reruns setup; keeps existing seeds; `-Force` overwrites with confirmation.
- **Shipped data:**
  - every `packages` key is a known source;
  - every source has a manager record whose `installs.from` names it;
  - every `install.prefer` entry is one of the tool's own sources;
  - the picker and catalog hints match the manager's `installs`.
- **The decoy-folder full run**, as for the earlier slices.

## Open items for review

- **Exact field names** in `installs` (`function`/`args` for psresource, the feed id template) are settled in the implementation plan.
- **Which Python managers** get records now: only those a shipped tool needs. Today that's none, so pip/pipx/uv may wait.
- **The built-in order between registries** (npm vs pypi vs crates vs psgallery) only matters for a tool that has two registries and no `prefer`. None does today.
