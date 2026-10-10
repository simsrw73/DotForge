# Testing

## Test Strategy

- **Tooling:** Pester 6 (`Invoke-Pester tests/` from `pwsh -NoProfile`); the development modules are pinned in `build/requirements.psd1` and installed by `build/Install-DFDevDependencies.ps1`. 144 test files, ~2,540 tests.
- **Unit tests** dot-source every module source file into the test's scope (`Get-DFTestModuleFile` in `tests/TestSupport.ps1`), so `Mock` reaches private functions. External processes and the machine are seams: availability (`Test-DFExecutableOnPath`, `Test-DFModuleOnPath`, `Test-DFToolAvailable`), installs (`Invoke-DFInstallCommand`), the host (`Test-DFInteractiveHost`, `Read-DFInstallChoice`, `Test-DFElevated`), fzf (`Invoke-DFFzf`), PATH (`Update-DFPathFromRegistry`). No test may run a real package manager.
- **Isolation:** `Set-DFTestXdg` / `Restore-DFTestXdg` put every `XDG_*_HOME` under `$TestDrive` and point `GIT_CONFIG_GLOBAL` at a throwaway file there (sidecars may run `git config --global`); `Set-DFTestConfig` sets session config; `Reset-DFTestSession` clears session state between tests; `Remove-DFTestGlobal` removes test-defined globals.
- **Contract tests** run a real `Import-Module` in a child `pwsh`: the module split (`ModuleSplit.Tests.ps1`), the core bundle (`CoreBundle.Tests.ps1`), the public surface (`PublicSurface.Tests.ps1`).
- **Shipped-data tests** check every `Tools/*.json`, `data/*.json` and generated file (tool registry, core bundle, reference docs, category and identity data) against its source.
- **Doc examples** run every unmarked `powershell` block in README, `examples/` and `docs/guide/` in a sandbox and compare its output (`Docs.Examples.Tests.ps1`).
- **"Green"** means: 0 failed tests **and 0 failed containers** (a file that fails discovery is neither passed nor failed), and a full run with every `XDG_*_HOME` pointed at empty sentinel folders leaves them empty. `build/Test-DFFull.ps1` checks all three and exits 1 otherwise; CI runs it on every push.

## Safety Net Map

Starting module (Phase 1, 2026-10-10): tool registration and session activation, and the tool-record loader. Coverage = commands executed by the 20 suites that exercise these files (684 tests).

| Module | Pinned behaviors | Test files | Gaps |
|---|---|---|---|
| `Public/Register-DFTool.ps1` (97%) | Adding named tools/+groups to the session; re-applying an active tool; unknown-name warning; one-time setup lifecycle; aliases, env, XDG, pickers per tool | `Register-DFTool`, `Roles.Registration`, `XdgSplit`, `delta`, `TabCompletionHooks` | Skipping an excluded tool on re-registration (l.75) |
| `Private/Invoke-DFSessionActivation.ps1` (95%) | Request → records → requirements → topo order → role winners → per-tool activation; Missing/Failed/Excluded states (an unreadable record → Failed, the rest still load); `requires` (tools and roles); missing-tools notice (3 shapes); lazy install hints | `Start-DFSession`, `Requires`, `Install-DFTool`, `Get-DFToolStatus`, `Runtimes` | Skipping an already-Active tool on a second activation (main loop); `requires` naming a tool with no record (`Resolve-DFToolRequirements`); role hint with one or no members (`Get-DFRoleRequirementHint`); install hint for a planned item (`Add-DFInstallHint`) |
| `Private/Register-DFToolSteps.ps1` (92%) | Role winners (Defaults, priority, fallback, opt-in); per-tool registration steps; conflict notice suppression | `Get-DFRoleWinners`, `Roles.Registration`, `DefaultToolRoles`, `TabCompletionRole` | The coreutils-conflict warning text itself (l.258–266; tests mock the notice); a role member with no record (l.57) |
| `Shared/Import-DFToolDb.ps1` (95%) | Normalized records (every field present); registry fast path and slow-path fallback; `-Name` loading; schema warnings with file names; the per-name and full-DB caches (hits, `-Force`, explicit `-ToolsPath` bypass); the "Failed to parse" warning | `Import-DFToolDb`, `ConvertTo-DFToolRecord`, `ToolRegistry`, `Test-DFToolSchema` | None in the mapped paths (caches and the parse warning pinned 2026-10-10) |
| `Shared/Test-DFToolSchema.ps1` (98%) | Required fields, allowed values, shapes of every block, `installs`/`install`/`setup`/`requires`/`after`, typo suggestions | `Test-DFToolSchema`, `Installs.Schema`, `ToolRegistry` | A few error branches: non-object `aliases` (l.114), non-object `installs` block (l.173), non-array `installs.command` (l.179), malformed `requires` (l.190), invalid `picker` type (l.201); exact-case typo match (l.290) |

## Characterization Backlog

- [x] `Import-DFToolDb` caches: a second `-Name` load hits the record cache; a full load is reused; `-ToolsPath` bypasses both (high) — `Import-DFToolDb.Tests.ps1`, 2026-10-10, mutation-checked
- [x] Activation of a requested tool with a missing/invalid record → Failed with the record warning, and the rest still activate (high) — `Start-DFSession.Tests.ps1`, 2026-10-10, mutation-checked
- [x] The "N tools failed to load" notice text (medium) — covered by the invalid-record test
- [ ] The coreutils-conflict warning text, unmocked (medium)
- [ ] `requires` naming a tool with no record → Missing with "has no tool record" (low)
- [ ] Role hint with one member and with none (low)
- [ ] Schema error branches listed above (low)
- [x] Git-config guard: `Set-DFTestXdg` points `GIT_CONFIG_GLOBAL` at a throwaway file, so no test that isolates XDG can touch the user's real git config (high) — `TestSupport.Tests.ps1`, 2026-10-10. (Not at `TestSupport.ps1` load: that would leak into an interactive shell that runs `Invoke-Pester`.)

## CI Gates

`.github/workflows/test.yml` runs `build/Test-DFFull.ps1` on `windows-latest` for every push and pull request. Locally, the same script is the gate before a merge.
