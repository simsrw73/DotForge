# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Project Is

DotForge is a PowerShell 7+ module that configures CLI tools (XDG paths, fzf pickers, aliases) from a JSON tool database.

PowerShell 7+ module that configures CLI tools (XDG paths, fzf pickers,
aliases) from a JSON tool database. Extracted and generalized from a real-world
PowerShell profile.

## Core Invariant: Plugin Architecture

**Adding or updating a tool never modifies core logic.** Each tool is a plugin
(`Tools/<tool>.json` + optional `Tools/<tool>.ps1`); a new core feature is an
optional declarative extension point the core reads when present and no-ops when
absent. Cross-tool queries resolve from the loaded tool DB or a build-time
generated index — never runtime reflection, and never a `switch ($tool.name)` in
core code. Startup speed is a first-class constraint; per-tool declarations are
free (JSON already loaded) and aggregation is paid once at build time. Full
statement, rules, and the realistic boundary (the psd1 manifest): **`docs/plugin-architecture.md`** —
read it before designing any new core feature or a central tool-keyed data file.

## Core Invariant: Builtin Safety

**Never overwrite a builtin PowerShell command or alias without explicit,
documented reasoning.** Check every new alias (general-helper or per-tool) against
`Get-Alias`/`Get-Command` before shipping it. Full statement and the `copy`→`yank`
incident that prompted it: **`docs/builtin-safety-policy.md`** — read it before
adding any new alias.

## Structure

```
DotForge/
├── Public/          # The startup core's exported commands (+ DFAliases.ps1: every alias)
├── Private/         # The core's internal functions
├── Shared/          # Stateless helpers the core and the on-demand modules both load
├── Bundle/          # Generated: the startup core as one file (build/Build-DFCoreBundle.ps1)
├── Modules/         # On-demand modules, auto-loaded on first use of one of their commands
│   ├── DotForge.Catalog/   # trifle: package catalogs, identity, categories (Private/, Public/)
│   └── DotForge.Helpers/   # general helpers: help, navigation, files, env, clipboard
├── Tools/           # Per-tool JSON + optional .ps1
├── docs/            # Specs and implementation plans
├── examples/        # Profile usage examples
└── tests/           # Pester 6 tests
```

## Conventions

- **All public functions** use the `DF` prefix: `Add-DFToPath`, `Invoke-DFPicker`, etc.
- **Private helpers** also use `DF` prefix but live in `Private/` and are not exported.
- **Tool JSON files** are named `<toolname>.json` (lowercase, no spaces).
- **Optional `.ps1` companions** share the same basename as the JSON file.
- **No `$ErrorActionPreference = 'Stop'`** in any module file — inherited from caller.
- **All directory creation** goes through `New-DFDirectory`, never raw `New-Item`.
- **All PATH additions** go through `Add-DFToPath`, never raw `$Env:Path +=`.
- **Paths are canonical.** Every path DotForge stores, compares, emits, or accepts as input goes
  through `ConvertTo-DFPath` (`Private/ConvertTo-DFPath.ps1`): absolute, native separator, no `.`/`..`,
  no trailing separator. Write `$HOME` in module code — never `~`; a user-supplied `~` path is
  expanded by `ConvertTo-DFPath`. A relative path is returned unchanged with a warning, never bound to
  CWD. New path boundaries must route through it.
- **PowerShell regex on help output**: use `-creplace` (not `-replace`) for case-sensitive matching; use `\r?$` instead of `$` since `Get-Help | Out-String` produces CRLF on Windows.
- **XDG folders come from `Get-DFXdgPath`** (`Private/ConvertTo-DFPath.ps1`): the `XDG_*_HOME` variable if set, else the XDG default under `$HOME`. Never read `$Env:XDG_*` directly or treat an unset one as "disabled". A `function:global:` closure (sidecar wrappers) reaches it, or any private helper, through a captured scriptblock: `$_xdgPath = ${function:Get-DFXdgPath}`, then `& $_xdgPath Cache`.
- **Settings come from `Start-DFSession -Config` and are read only through `Get-DFConfig -Key -Default`** (`Private/DFSessionConfig.ps1`). Nothing reads a global `$DFConfig`; a test enforces it. Read list settings with `@(Get-DFConfig Tools)`. **A new config key must be added to `$script:DFConfigKeys`** in the same file (a test fails otherwise), so unknown keys can warn.
- **Tool records are normalized at load** (`ConvertTo-DFToolRecord` in `Private/Import-DFToolDb.ps1`): every known field exists, so read `$tool.type`, `$tool.aliases`, … directly. Only the free-form `settings` object needs defensive reads.
- **New public functions** go in the `FunctionsToExport` of the module whose `Public/` holds them (`DotForge.psd1`, or `Modules/DotForge.{Catalog,Helpers}/*.psd1`). **Every alias** is defined in `Public/DFAliases.ps1` (or next to a core function) and listed in `DotForge.psd1`'s `AliasesToExport` — never in an on-demand module, because an alias of a not-yet-loaded module loses to a program of the same name on PATH. `tests/ModuleSplit.Tests.ps1` checks both.
- **Readability rules** (adopted 2026-10-10):
  - A variable that lives across more than ~10 lines gets a full name (`$tool`, `$winner`), not `$t`/`$w`.
  - A function returns a result object; it doesn't fill hashtables or `[ref]` parameters its caller passes in.
  - A function past ~60 lines is split into named steps, so the top function reads as a list of them.
  - One home per rule: never re-implement logic another function already owns (e.g. `+group` expansion); call it.
- **Startup core vs on-demand code** (`docs/superpowers/specs/2026-10-10-module-split-design.md`): code a shell needs while it starts stays in the core; code only an explicit command needs goes in an on-demand module. A helper both need goes in `Shared/` and must hold no session state (on-demand modules get their own copy); they read session settings through the public `Get-DFConfig`. Paths from an on-demand module's file to repo-root files go up three levels (`Modules/<module>/<folder>`).

## Working Agreement

- **Standing permissions.** After a green full run (`build/Test-DFFull.ps1`), fast-forward the work
  into `main` and push it without asking. **Ask first** for: tags, releases and Gallery publishes, deleting
  branches or worktrees you didn't create, force-pushes, rewriting history, and anything touching the
  user's real profile, git config or installed tools.
- **The user's shell runs an installed DotForge, never this checkout.** Never link the checkout into a
  module folder (junction, symlink) or add it to `PSModulePath`. To try work in a real shell, publish a dev
  build to the local gallery: `./build/Publish-DFLocal.ps1` (version `<next patch>-dev<timestamp>`, built from
  the working tree: uncommitted edits and new files, never gitignored ones). `Start-DFSession` prints a
  one-line notice when it runs a dev build, so a private test build is never mistaken for a release. Publishing there needs no permission; installing it changes
  the user's shell, so the user runs `./build/Publish-DFLocal.ps1 -Install` (or asks you to). Gallery releases
  still follow Releasing below. `LocalGallery` is `C:\Users\simsr\repos\Local_PSGallery`, registered for
  PSResourceGet; an old PowerShellGet 3.0 beta on this machine shadows PSResourceGet's command names, so
  scripts call them module-qualified (`Microsoft.PowerShell.PSResourceGet\Publish-PSResource`).
- **Use a worktree** (`../DotForge-<topic>`) for risky or parallel work.
- **Search tracked files only** (`rg`, `git ls-files`, `git grep`): they skip ignored folders. A recursive
  `Get-ChildItem`/`grep -r` from the repo root can wander into large ignored data. The package-universe
  pipeline keeps its data (a winget-pkgs clone) in `$XDG_CACHE_HOME/dotforge/package-universe/`, outside
  the checkout; never put it back in the repo.
- **`trifle` and the package-universe pipeline are frozen until after 1.0** (`TODO.md`, last section): no
  feature work there, only fixes for bugs that break something else.
- **The gate is `build/Test-DFFull.ps1`** (sentinel XDG folders, failed containers, exit 1 on any
  failure). During a change, run it with `-Path` on the test files that cover the code you touched; run
  it on the whole suite before merging.
- **The backlog is `TODO.md`**, open items only, each with an ID (`T-12`). Name the ID in the commit that
  resolves it (`Closes T-12`) and delete the item in that commit; new items take the next free ID noted
  at the top of the file. Don't leave `TODO`/`FIXME` comments in code: fix a small hack on the spot,
  or add a `TODO.md` item with its location.

## Architecture (3 layers)

Layer 1 — Core Primitives (Phase 1)
Add-DFToPath, New-DFDirectory, Invoke-DFPicker, Invoke-DFWithPager

Layer 2 — Tool Registry (Phase 2)
Import-DFToolDb, Get-DFTool, Find-DFTool, Register-DFTool

Layer 3 — Tool Operations (Phase 3)
Start-DFSession, Get-DFToolStatus, Get-DFToolGroup, Install-DFTool, Invoke-DFToolSetup

General Helpers (Phase 5+)
DFHelpers.\*.ps1 — pager, help/discovery, navigation, filesystem, process, environment, clipboard

## Testing

Load module for development:

```powershell
Import-Module ./DotForge.psd1 -Force
```

Pester 6 (verified with 6.2.0). Pester 5 is no longer supported or tested. Install the development modules (Pester, plus PSSQLite and powershell-yaml for the package-universe pipeline) at the versions pinned in `build/requirements.psd1` with `./build/Install-DFDevDependencies.ps1`; a new test or build dependency goes in that file, never in the manifest's `RequiredModules` (`tests/Requirements.Tests.ps1` checks it). Run all tests:

```powershell
Invoke-Pester tests/ -Output Detailed  # run from pwsh -NoProfile to avoid profile interference
```

**Load the module with the shared loader, never a hand-kept list.** A test's `BeforeAll` starts with
`. "$PSScriptRoot/TestSupport.ps1"` then `foreach ($f in Get-DFTestModuleFile) { . $f }`, which
dot-sources every source file (`Shared/`, the core's `Private/` and `Public/`, then each on-demand module's) in load order (so `Mock` works on private
functions without `-ModuleName`). Load a `Tools/*.ps1` companion explicitly after it.

**Isolate every XDG folder a test can write to.** Use `Set-DFTestXdg` in `BeforeEach` and
`Restore-DFTestXdg` in `AfterEach` (`tests/TestSupport.ps1`): all four `XDG_*_HOME` go under `$TestDrive`. An unset `XDG_*` variable means the real default
folder under `$HOME` (`Get-DFXdgPath`), not "disabled", so a test that registers a tool or calls a
cache/state writer must point the relevant `XDG_*_HOME` at `$TestDrive` and restore it afterwards.
Never unset one to test "no folder" behavior; that path writes to the developer's real folders.

**Set config with `Set-DFTestConfig`, and isolate session state with `Reset-DFTestSession`** (`tests/TestSupport.ps1`). `Set-DFTestConfig @{...}` sets the session config the module reads (`$null` clears it); never set a global `$DFConfig`. Session state (`Get-DFToolStatus`, the role winners, record caches) persists across tests in one file, and `Register-DFTool` folds it into each call, so every `Describe` that registers tools calls `Reset-DFTestSession` from its `BeforeEach`.

**Pester 6 syntax only.** Use `Should -Invoke`, never `Assert-MockCalled`: Pester 6 removed it, and
calling it makes PowerShell auto-import Windows PowerShell's bundled Pester 3.4.0, which then breaks
every `Mock`. Pester can only mock a command that exists, so stub a function a sidecar or an
uninstalled module defines (e.g. `function Set-PsFzfOption {}`) before mocking it. A mock
with only a `-ParameterFilter` does **not** fall through to the real command in Pester 6: unmatched calls
fail. Add a default mock, or prefer an assertion that needs no mock.

**Remove test-defined globals with `Remove-DFTestGlobal`** (`tests/TestSupport.ps1`). `Remove-Item
function:global:<name>` (or `alias:global:`) silently does nothing, so a stub such as `function global:git {}`
leaks into every later test file in the run; an unqualified `Remove-Item function:<name>` removes the nearest
definition, which may be the test file's own dot-sourced copy. `tests/TestSupport.Tests.ps1` rejects the
qualified form. `Test-Path alias:global:<name>` is always false, even for an existing global alias: check
aliases with `Get-Alias -Name <name> -Scope Global`.

Run a single file:

```powershell
Invoke-Pester tests/Add-DFToPath.Tests.ps1 -Output Detailed
```

## Before Commiting

- Update the user docs with any changes: the relevant page in `docs/guide/` (README.md is a short landing page; keep it that way), and `.\examples`.
- **Regenerate the core bundle** after changing any file in `Shared/`, `Private/` or `Public/`: `./build/Build-DFCoreBundle.ps1` rewrites `Bundle/DotForge.Core.ps1` (the startup core as one file, ~0.3 s faster to load). The module uses it only when its source hash matches, so a forgotten rebuild costs speed, never correctness; `tests/CoreBundle.Tests.ps1` fails when it is stale. Set `$Env:DF_NO_BUNDLE = '1'` to load the separate files (errors then report real file and line numbers).
- **Regenerate the tool registry** after changing any `Tools/*.json`: `./build/Build-DFToolRegistry.ps1` rewrites `data/tool-registry.json` (each record validated and normalized, keyed by a hash of its JSON, so startup skips those checks; a record whose hash doesn't match is read the slow way). `tests/ToolRegistry.Tests.ps1` fails when it is stale.
- **Regenerate the reference**: `./build/Build-DFReferenceDocs.ps1` rewrites `docs/reference.md` from comment-based help and `Tools/*.json`. Never edit `docs/reference.md` by hand; `tests/Docs.Reference.Tests.ps1` fails when it is stale.
- **Every public function, and every global function a `Tools/*.ps1` companion defines, must have complete comment-based help**: `.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER` for each param, at least one `.EXAMPLE` (code, then a blank line, then prose), and `.OUTPUTS`. `tests/Docs.Help.Tests.ps1` enforces this. Run `Get-Help <FunctionName> -Full` to confirm `Get-Help` renders all sections correctly.
- **Doc code blocks run.** `tests/Docs.Examples.Tests.ps1` runs every ```` ```powershell ```` block in README.md, `examples/README.md` and `docs/guide/*.md` in a sandbox and compares a following ```` ```text ```` block with the real output. Mark blocks that need a person (`<!-- interactive -->`), the network (`<!-- network -->`, read-only lookups), or change the machine outside the sandbox — installs, elevation, scheduled tasks, global git config, clipboard (`<!-- system -->`). A block that runs real tools gets `<!-- requires: eza, lsd -->`: it runs only where they are installed (CI has none). **Never leave a state-changing block unmarked**: unmarked blocks are executed. Rules for markers and output wildcards are at the top of `build/DFDocExamples.ps1`.

## Releasing

Publishing to the PowerShell Gallery follows this exact sequence. **The release must be tagged before it is published** — a `PreToolUse` hook in `.claude/settings.json` blocks `Publish-PSResource`/`Publish-Module` (real publishes, not `-WhatIf`) whenever `git HEAD` is not sitting on an exact tag.

1. **Bump the version** in `DotForge.psd1` (`ModuleVersion`; keep/adjust `PrivateData.PSData.Prerelease`) and refresh `ReleaseNotes`. We follow SemVer; preview releases carry `Prerelease = 'preview'` (published as e.g. `0.3.0-preview`).
2. **Finalize `CHANGELOG.md`**: rename the `[Unreleased]` heading to `[<version>] - <YYYY-MM-DD>` and open a fresh empty `[Unreleased]` above it.
3. **Commit** the version bump + changelog (scope the commit to release files; leave unrelated working-tree changes out).
4. **Validate**: `Test-ModuleManifest ./DotForge.psd1` and a publish dry-run: `Publish-PSResource -Path . -Repository PSGallery -ApiKey DRYRUN -WhatIf`.
5. **Tag** the release commit: `git tag -a v<version> -m "DotForge <version>"` (tag format is `v` + the full prerelease string, e.g. `v0.3.0-preview`).
6. **Push** `main` and the tag: `git push origin main && git push origin v<version>`.
7. **GitHub Release**: `gh release create v<version> --title v<version> --prerelease --notes "<CHANGELOG section>"` (drop `--prerelease` for stable releases).
8. **Publish to PSGallery**: read the API key from the gitignored `.env` (`PSGALLERY_API_KEY=...`) — never hardcode or commit it. Publish from a clean export of the tag, never the working tree: the publish command packs everything under `-Path`, ignoring `.gitignore`, so local leftovers would ship (and a large ignored folder once made it hang for hours with no output). The exported folder's name must equal the module name, since the publish command looks for `<folder>.psd1`:
   ```bash
   rm -rf /tmp/DotForge && mkdir -p /tmp/DotForge
   git archive v<version> | tar -x -C /tmp/DotForge
   ```
   Then: `Publish-PSResource -Path /tmp/DotForge -Repository PSGallery -ApiKey $key`.
9. **Verify** via the Gallery API (the local `Find-PSResource` view normalizes away the prerelease suffix, so confirm against the source of truth): `Invoke-RestMethod "https://www.powershellgallery.com/api/v2/FindPackagesById()?id='DotForge'"` and check the new `Version` / `IsPrerelease`.

## Tool JSON Schema

Each `Tools/*.json` must have at minimum:

- `name` (string, required)
- `executable` (string, required)
- `packages` (optional): install ids keyed by **source** — a system manager (`scoop`, `winget`,
  `choco`), a registry (`npm`, `crates`, `psgallery`) or a version manager (`fnm`, `mise`). A value is
  an id or `{ id, feed: { name, url } }` (a third-party scoop bucket). Read values only through
  `Get-DFPackageRef`. `install.prefer` (optional) is the tool's own source preference.
- `installs` (optional): makes the tool a package manager — `from` (its source), `command` (argv,
  `{id}`) or `function`/`args`, `batch`, `elevate`, `reactivate`, `feeds`. A list of blocks when it
  installs from several sources (uv); records always normalize to a list, read one with
  `Get-DFInstallBlock -Manager -Source`. Core never names a manager.
- `xdg.method`: one of `default | env | wrapper | manual` (seed a default config file with `setup.seed`, not an xdg method)
- `xdg.vars`: env vars to set when applying XDG config — values are `${XDG_*}` path templates only (expanded via `Expand-DFXdgPath`). Non-path values (flag strings, etc.) belong in `env` below, never in `xdg.vars`.
- `env` (optional): a top-level map of environment variable → value for **non-XDG** session
  settings (fzf options, `LESS`, theme names, …). Applied unconditionally by
  `Register-DFTool` via `[Environment]::SetEnvironmentVariable(..., 'Process')` through
  `Expand-DFXdgPath` (flag strings pass through; `${XDG_*}` still expands). Keep `xdg.vars`
  for `${XDG_*}` path templates only.
- `themeMap` (optional): a map of canonical theme family → this tool's native dialect (e.g.
  `{ "catppuccin-mocha": "catppuccin" }`). Only needed when the tool's native name differs from
  the canonical (per the plugin invariant — no central theme registry). Sidecars resolve the
  configured theme with `Get-DFConfiguredTheme` (chain) then `Resolve-DFThemeName` (translate via
  this map), then validate against their own built-in list. Shared `Theme` is
  canonical-only; a per-tool `<Tool>Theme` accepts the canonical name or the tool's own natives.
- `roles` (optional): the roles this tool joins, an object keyed by role name; each value is
  `{ priority, env, aliases }` (`"grep": {}` for a category). Roles are defined in `data/roles.json`
  (keyed by role, never by tool). Only the role's winner (`Defaults`, else highest priority; a role is filled only by a requested tool)
  gets the block's `env`/`aliases` and its hook: a plain `function Initialize-DFRole<Role>` in the
  sidecar, called by `Invoke-DFToolCompanion`. A role's reserved env vars and aliases may appear only
  in role blocks, and its reserved code only in the hook; `tests/Roles.Contract.Tests.ps1` enforces
  it. The legacy `role` string still loads. Read `docs/superpowers/specs/2026-10-05-roles-v2-design.md`
  before adding a role.
- `requires` (optional): tools (`"fzf"`) or roles (`"role:js-runtime"`) the tool can't work without.
  Resolved by `Resolve-DFToolRequirements` (`Private/Invoke-DFSessionActivation.ps1`): required tools
  are auto-requested and ordered first, and a missing/excluded one blocks the tool. A role requirement
  orders after the role's requested members, never requests a member itself (the user chooses in
  `Tools`), and never blocks.

## External Dependencies

DotForge relies on undocumented internals of several tools it configures (coreutils' `$__COREUTILS__`
variable and section-marker GUID, PSReadLine's `Colors` suppression, zoxide's prompt hooking, …).
**All of them are catalogued in `docs/external-dependencies.md` — read it before changing
`Private/Get-DFCoreutilsShadowSet.ps1` or any `Tools/*.ps1` sidecar, and add an entry there when you
take a new dependency on another tool's internals.** Each entry records what breaks and how it
degrades; the rule is that undocumented dependencies must degrade silently, never fail.

## Tool Conformance (author-time)

Whether a tool actually honors its configuration is verified, not assumed. The harness
`build/Test-DFToolConformance.ps1` reads probe descriptors (`build/conformance/*.jsonc`),
spawns the real tool through an injectable seam (defaulting to a real isolated
`ProcessStartInfo`; tests inject a canned scriptblock — same pattern as
`build/Build-DFToolIdentities.ps1`'s `-ResolveLinkage`), and writes per-claim verdicts to
the versioned ledger `data/tool-conformance.json` plus `reports/tool-conformance-issues.md`.
Sidecar adapters cite the failing claim (`# adapter for <claim-id>`); the harness flags
orphaned and upstream-fixed adapters. **Author-time only** — the module never loads or runs
any of it, and there is no runtime cost. The shared logic lives in `build/DFConformance.ps1`
(dot-sourced by the harness and by `tests/DFConformance.Tests.ps1`). Optional `[pscustomobject]`
fields parsed from fragments must be read StrictMode-safe (`$obj.PSObject.Properties['name']?.Value`).

## Key Design Decisions

- `Invoke-DFPicker` uses a private `Invoke-DFFzf` wrapper so tests can mock fzf
  without spawning a real process.
- The `Parse` scriptblock in `Invoke-DFPicker` receives `$_` via `ForEach-Object`,
  not as a positional argument.
- Scriptblocks passed to `Invoke-DFPicker -List` that capture local variables must use
  `.GetNewClosure()` (e.g., `{ $topics }.GetNewClosure()`). Without it, `& $List` inside
  `Invoke-DFPicker` silently sees nothing — the variable lookup happens in the wrong scope.
- **Prompt engine + zoxide prompt hook ordering**: zoxide's `--hook pwd` wraps
  `function:prompt` (not `LocationChangedAction` — both hook modes use prompt wrapping;
  `pwd` mode just skips `zoxide add` when the directory hasn't changed). The prompt engine
  (oh-my-posh or starship) must initialize _before_ zoxide so zoxide wraps its prompt.
  `zoxide.json` declares `"after": ["oh-my-posh", "starship"]`, so the session
  topo-sorts either engine ahead of zoxide whenever both are in the registration set. (The
  tool DB is a plain hashtable, so without `after` the order is hash order, not
  alphabetical.) After an oh-my-posh theme switch via
  `fpot`/`Select-PoshTheme`, OMP re-inits and replaces `function:prompt`; zoxide's
  `$global:__zoxide_hooked = 1` guard prevents re-hooking, so directory tracking stops
  until the next shell session. This is a known limitation with no clean workaround.
- **`direnv` does not need prompt-hook ordering**: unlike zoxide/oh-my-posh, direnv's `hook
  pwsh` output attaches to `$ExecutionContext.SessionState.InvokeCommand.LocationChangedAction`
  (fires on `Set-Location`), not `function:prompt` — confirmed against direnv's own
  `internal/cmd/shell_pwsh.go` source. So registering `direnv` before or after oh-my-posh/zoxide
  makes no difference; it was deliberately given no `after`. Requires PowerShell 7.2+
  (direnv's generated hook throws below that); `Tools/direnv.ps1` guards this with a warning.
- **Opt-in tool selection**: `Start-DFSession -Config` configures only the tools in `Tools` (names and `+groups` from `data/groups.json`, minus `ExcludeTools`) that are installed. Only those records are read (`Import-DFToolDb -Name`), role winners are picked among them, and nothing is ever installed during a load: missing tools are listed at the end and installed with `Install-DFTool -Missing`. `Invoke-DFSessionActivation` is the shared core of `Start-DFSession` and `Register-DFTool -Name`; it records a `DotForge.ToolStatus` per tool for `Get-DFToolStatus`. Full design: `docs/superpowers/specs/2026-10-09-tool-selection-design.md`.
- **Installing** (`Install-DFTool`, `docs/superpowers/specs/2026-10-09-install-design.md`): managers are plugins (`installs`); a source is chosen per tool by `InstallVia`, the tool's `install.prefer`, `InstallOrder`, then DotForge's order (`Private/DFInstallSource.ps1`); `New-DFInstallPlan` stages the install (a manager or runtime before what needs it; nothing unrequested unless the user picks it or passes `-UseDefaults`); `Invoke-DFInstallPlan` runs it, and **`Invoke-DFInstallCommand` is the only place a manager runs** — tests mock it, and no test may run a real package manager. `Start-DFSession` builds the install layer only when something is missing.
- **`after` ordering**: Any tool JSON may declare `"after": ["othertool"]` (ordering only; `requires` also requests the tool). The old `dependsOn` is a schema error. `Invoke-DFSessionActivation` (shared by `Start-DFSession` and `Register-DFTool -Name`) calls `Invoke-DFTopoSort` (private, `Private/Invoke-DFTopoSort.ps1`) to sort the requested tools using Kahn's algorithm before iterating. Dependencies outside the current registration set are skipped silently. Cycles emit `Write-Warning` and fall back to original order.
- **`$DFCurrentTool` sidecar contract**: `Invoke-DFToolCompanion` (called from `Invoke-DFSessionActivation`'s per-tool loop) sets `$DFCurrentTool = $tool` immediately before dot-sourcing a companion `.ps1` and clears it after. Sidecars may read `$DFCurrentTool.settings` and other fields. Existing sidecars that do not reference `$DFCurrentTool` are unaffected. Sidecars needing their own subdirectory use `$PSScriptRoot`, which resolves to `Tools/` at dot-source time.
- **Tool setup lifecycle**: the one-time setup step runs before the companion: `setup.seed` files (`Invoke-DFToolSeed`, copied only when absent), then an optional `Tools/<name>.setup.ps1`, parallel to the regular `.ps1`. It runs at most once ever per tool (tracked in `$XDG_STATE_HOME/dotforge/setup-state.json`, checked/updated via `Private/Get-DFToolSetupState.ps1`/`Public/Complete-DFToolSetup.ps1`) — for setup that makes a persistent, user-visible change (e.g. an `[include]` line in the user's real git config) that must never be silently reasserted after the user edits or removes it. The script owns its own success: it must call `Complete-DFToolSetup -Name <tool> [-Actions <object[]>]` itself, as its own last line, only once its work has actually succeeded — a thrown error records nothing, so the next load retries from the top. `SkipSetup` (array of tool names, in the session config) opts a tool's setup script out entirely. Full design: `docs/superpowers/specs/2026-09-04-tool-setup-lifecycle-design.md`.
- **PSReadLine + PSFzf ordering**: PSFzf declares `"after": ["psreadline"]` and `"requires": ["fzf"]`. `psreadline.ps1` runs first and applies `Set-PSReadLineOption` settings + theme via `$DFCurrentTool.settings`. PSFzf then overlays its key bindings via `Set-PsFzfOption`. Each tool owns only what it touches. The global `$DFPSReadLineColors` hashtable is set by `Invoke-DFApplyPSReadLineTheme` as a test-observable side channel (PSReadLine suppresses `Colors` in non-VT terminals).
