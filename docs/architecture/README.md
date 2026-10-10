# DotForge architecture and startup

These diagrams describe the repository at commit `439e3d7c130c1584f308dc82349390c1078be70f`.

- [Component map and boundaries](dotforge-architecture.html)
- [What module import does](dotforge-import-startup.html)
- [What Start-DFSession does](dotforge-session-startup.html)

## The important split

`Import-Module DotForge` and `Start-DFSession` are deliberately different operations.

| Operation | Does | Does not do |
| --- | --- | --- |
| Import module | Adds `Modules/` to this process's `PSModulePath`; loads the current core bundle or the individual `Shared/`, `Private/`, and `Public/` source files; makes exported commands and module aliases available. | Store a profile configuration, create XDG folders, read selected tool records, check an executable, invoke a sidecar, or configure a tool. |
| Start session | Stores a validated copy of the supplied configuration; exports XDG folders; resolves requested tools; calculates order and role winners; configures installed tools; records status and gives end-of-session notices. | Install missing tools or remove effects from a tool that was already activated in this PowerShell process. |

The distinction matters for scripts that only need an exported helper: importing DotForge has no chosen-tool activation side effects. Profile users normally do both, in that order.

## Architectural boundaries

The module package boundary includes the manifest, the `DotForge.psm1` loader, the startup core, and two on-demand modules: `DotForge.Catalog` and `DotForge.Helpers`. The loader makes these two modules discoverable through `PSModulePath`; their commands load only when command resolution needs them. The startup core is always loaded in `Shared → Private → Public` order, either from `Bundle/DotForge.Core.ps1` when its header hash matches the current sources, or by dot-sourcing those source files when it does not (or `DF_NO_BUNDLE` is set).

The session runtime boundary starts only with `Start-DFSession`. It owns the configuration snapshot, requested-tool status, session tool database, and role-winner table. It reads declarative tool records from `Tools/*.json`, plus curated group and role definitions from `data/`. Imperative `Tools/<name>.ps1` companions are intentionally outside that declarative registry boundary: they are invoked only after a tool is selected and proved available.

The process boundary is the current PowerShell process. Tool registration can add process environment variables, functions, aliases, pickers, PATH entries, and key bindings. Persistent writes are a separate boundary: XDG directories and seeded files, the completed-setup state, and—in a documented tool-specific case—an include in global Git configuration.

## Import startup, in order

1. PowerShell reads `DotForge.psd1`, whose `RootModule` is `DotForge.psm1` and whose exports define the public surface.
2. `DotForge.psm1` prepends its `Modules/` directory to the current process's `PSModulePath` if absent. This enables later command discovery for the Catalog and Helpers modules without importing them now.
3. It loads `Bundle/CoreSourceHash.ps1`, reads the bundled core's header, and compares the embedded source hash with a newly calculated hash of the core source files.
4. If the hashes match and `DF_NO_BUNDLE` is not set, it dot-sources `Bundle/DotForge.Core.ps1`; otherwise it dot-sources every core file in `Shared/`, then `Private/`, then `Public/`.
5. Those files define the session machinery and initialize module script scope. Public alias definitions such as `trifle`, `env`, and `touch` are established during this core load so they can take precedence over executable-name conflicts.
6. The loader removes its temporary local variables. Import is complete: DotForge commands are available, but no profile tool selection has taken place.

## Start-DFSession startup, in order

1. `Set-DFSessionConfig` validates configuration keys, warns for unknown or removed keys, and deep-copies the dictionary into module session state. Later caller mutation does not alter the session snapshot.
2. `Set-DFXdgEnvironment` resolves the five XDG homes (`Config`, `Data`, `State`, `Cache`, and `Bin`), exports them to the current process, and ensures the directories exist.
3. `Resolve-DFRequestedTools` expands direct names and `+group` entries from `Tools`, applies `ExcludeTools`, preserves first-seen order, records why a tool was requested, and warns for unknown names. It uses filenames to validate tool names before reading any JSON record.
4. `Invoke-DFSessionActivation` records excluded statuses, reads only non-excluded requested records, then resolves `requires` and `after` dependencies. It topologically sorts the resulting set and computes single-role winners from installed candidates, role priorities, and `Defaults`. Opt-in role members participate only when selected in `Defaults`.
5. It stores the requested records and role winners before a companion runs, so a companion can query its winner. It may start a background prewarm job for configured module-type tools.
6. For each ordered tool, it first handles dependency blocks and availability. A missing executable/module becomes `Missing`; invalid records become `Failed`; neither terminates the other tools' activation.
7. For an available tool, `Invoke-DFToolRegistration` applies declarative XDG configuration, process environment values, aliases, picker functions, and the environment/aliases reserved by roles that this tool won. Losing role members do not receive the winner-only behavior.
8. `Invoke-DFToolCompanion` performs one-time setup first when applicable and not skipped: it seeds declared files, executes `<name>.setup.ps1` when present, and records completion. It then dot-sources `<name>.ps1` for every activation and calls only the role hooks belonging to roles that tool won. Setup and hook failures warn; a registration failure is recorded and the loop continues.
9. The activation coordinator removes any prewarm job, enriches role fallback status, and retains active records as session state. A second call adds new work but does not deactivate a no-longer-requested tool; it warns that such effects persist until a new shell.
10. Finally, `Start-DFSession` optionally checks active tools for coreutils shadowing and emits a consolidated session notice. `Get-DFToolStatus` is the authoritative inspection command for the result.

## Operational consequences

- A tool not requested by this call is not inspected during normal session startup.
- `Start-DFSession` never installs tools; `Install-DFTool -Missing` is the explicit installation path.
- The role decision is made before tool companions run. Sidecars can observe the decision, but should not independently choose winners.
- One failed or missing tool is isolated from the remaining requested tools.
- A second session start is additive because aliases, environment values, prompt hooks, and other current-process effects are not generally reversible.
