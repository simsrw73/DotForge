# Updating and removing tools: design

**Status:** approved 2026-10-10 · **Decided in:** a grilling session (every decision below is the user's) · **Backlog item:** `TODO.md` T-44 · **Builds on:** [the install design](2026-10-09-install-design.md)

## Context

`Install-DFTool` installs missing tools through package managers that are plugins: each manager's record declares an
`installs` block, `New-DFInstallPlan` stages the work, and `Invoke-DFInstallCommand` is the only place a manager runs.
There is no way to update or remove a tool. This adds `Update-DFTool` and `Remove-DFTool` on the same model.

## Decisions

| # | Decision |
| --- | --- |
| 1 | **Where a tool came from: ask the managers, each time.** Only the managers in the tool's `packages`, in install-precedence order (`InstallVia` > the tool's `install.prefer` > `InstallOrder` > DotForge's order), skipping managers that aren't installed; stop at the first manager that has it. Truthful for tools installed outside DotForge or changed by hand; usually one or two calls. A tool installed through two managers is reported under the first one found (stated in the help). |
| 2 | **Each manager declares five operations in its `installs` block:** `install` (renamed from `command`), `update`, `remove`, `list`, `outdated`. They share the block's `batch` and `elevate`. `install`/`update`/`remove` are an argv with `{id}`, or `function`/`args`. A manager without an operation gets a clear "can't <operation> through <manager>". |
| 3 | **`list` and `outdated` are always `function` entries** in the manager's companion (`Tools/<manager>.ps1`), returning objects `{ Id, Installed, Available }` (`Available` empty for `list`). Core validates the shape; anything malformed means "unknown", never a crash. Each parser is tested against recorded output samples (no test runs a real manager). Parsing code may be copied from the catalog providers, never called (trifle is frozen). |
| 4 | **Elevation, in order:** already elevated → the `elevator` role's winner (gsudo) → Windows' built-in `sudo` when it is enabled in inline mode (`HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Sudo` `Enabled` = 3) → `Start-Process -Verb RunAs -Wait` (its own window; exit code only, which the plan says). One admin prompt per batched call. With no one to answer a prompt (non-interactive host), steps that need admin are reported, not run. Applies to install too: a manager that needs admin is no longer skipped for lack of gsudo. |
| 5 | **`Update-DFTool`:** bare shows a table for the session's active tools (Tool, Manager, Installed, Available; "up to date" / "unknown") and stops. `-All` updates every active tool that has an update, plus the unknowns (the manager no-ops when current); `-Name` updates those tools by the same rule. `-WhatIf` shows the plan. Output is objects (`DotForge.ToolUpdate`), shown as the table. |
| 6 | **Runtimes managed by a version manager** (node via fnm or mise, Python via uv or pymanager) are out of the first version: `Update-DFTool node` says which manager owns it and the command to use. |
| 7 | **`Remove-DFTool`:** removes the package only, through the manager it came from, then reports what is left: seeded config files, setup changes recorded in `setup-state.json` with the command to undo each, and the tool's entry in your `Tools` list (DotForge never edits your profile). The setup record is kept, so a reinstall doesn't run setup twice. Status becomes Missing ("removed by Remove-DFTool"); its aliases stay until a new shell, which it says. **Follow-up:** `-Purge` (delete seeded files unchanged since seeding; undo setup changes a tool's setup declares how to undo; with T-38). |
| 8 | **Dependents:** removing a tool another active tool `requires` (directly, or as the only active member of a required role) is refused, naming the dependents; `-Force` proceeds. `-IncludeDependents` follows `requires` chains transitively, shows the removal order (dependents first) and asks once (`ConfirmImpact = High`; `-WhatIf`, `-Confirm:$false`). Removing a **manager** that still has tools installed always needs `-Force`, lists those tools, and never cascades. |
| 9 | **The rename is hard:** `installs.command` becomes a schema error pointing to `installs.install` (like `dependsOn` → `after`). DotForge's own manager records are renamed in the same change. |

## Implementation notes (the coordinator's calls; change them in review if needed)

- `Invoke-DFInstallCommand` becomes `Invoke-DFManagerCommand -Operation install|update|remove|list|outdated`, still the single seam tests mock.
- One planner for the three operations (grouping by manager, batching, elevation per decision 4); `Install-DFTool`, `Update-DFTool` and `Remove-DFTool` build plans with it and print them the same way.
- After an update, a manager block with `reactivate` re-activates its tools in this shell, as after an install. Cached command output is keyed to the executable's file identity, so it refreshes by itself.
- New public commands go in `DotForge.psd1` with full comment-based help, a `docs/guide/` section and `docs/reference.md` regenerated.

## Out of scope

`-Purge` (follow-up, with T-38); updating runtimes through version managers; an `outdated` check for managers that have none (cargo shows "unknown"); any change to the frozen catalog code.

## Contract (tests)

- Source detection asks only the tool's `packages` managers, in precedence order, and stops at the first hit (mocked `list` functions; call counts asserted).
- Each manager's `list`/`outdated` parser, against recorded output samples, including an empty result and garbage.
- The elevation chain picks the right method for each host state (elevated, gsudo, Windows sudo inline/off, none, non-interactive).
- Bare `Update-DFTool` runs no update; `-WhatIf` runs nothing; `-All` updates only tools with an update or unknown.
- Remove refuses a required tool; `-Force` proceeds; `-IncludeDependents` removes in dependents-first order after one confirmation; a manager with installed tools never cascades.
- The leftovers report lists seeded files, recorded setup changes and the `Tools` entry.
- `installs.command` is a schema error naming `installs.install`.
- No test runs a real package manager (everything goes through `Invoke-DFManagerCommand`).
