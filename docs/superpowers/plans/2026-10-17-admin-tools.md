# Admin tools Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** procs, btop, bottom, glances, ntop, pstop, dust, dua, gdu and duf get the whole tool contract, grouped in two new categories (`process-viewer`, `disk-usage`). btop-lhm runs through an active elevator when it's the installed btop build.

**Architecture:**
- **Records:** each tool gets a record (procs already has one) with packages, `xdg`, `theme` where the tool has one, and completions. Facts come from Task 1's probes.
- **Categories:** declared in `data/roles.json`, with no hooks or aliases.
- **btop:** its companion detects the build on PATH. Only for btop-lhm, with an active elevator, does it define a `btop` function that runs it through `Get-DFElevationMethod`.

**Tech Stack:** PowerShell 7.2+, Pester 6, the tools' Windows builds.

**Spec:** `docs/superpowers/specs/2026-10-17-admin-tools-design.md`

## Global Constraints

- **Categories, not single roles.** No role aliases, no `top`/`du`/`df` names; every tool keeps its own command.
- **No tool names in core** (`Private/`, `Public/`, `Shared/`).
- **No Windows `sudo` record.** The elevator stays gsudo; the guide documents Windows sudo.
- **ncdu and htop stay out.** `htop` is pstop's link, which pstop's record and the docs note.
- **`+admin-tools` gains dust.**
- **btop:**
  - The plain build is the default install (scoop `btop`), and `btop-lhm` is opt-in.
  - When the lhm build is on PATH and an `elevator` member is active this session, `btop` runs it through that elevator (`Get-DFElevationMethod` with the session's active records), in the same console.
  - Otherwise nothing is wrapped.
- **Sensible defaults** are seeded only where the tool's own defaults are poor. A theme follows `Theme` only where the tool has a catppuccin theme, or a color config the palette maps onto.
- **Probes:**
  - Never leave a TUI running: `--help`/`--version` only, `timeout 10`, stdin `</dev/null`.
  - Never run btop-lhm.
  - Note the known folders before and after each probe; remove only what the probe created.
- **Rebuild** after changes: bundle, registry and reference docs; categories/identities when the suite asks. A new config key goes in `$script:DFConfigKeys`. Gate: `build/Test-DFFull.ps1`.

## Review Focus

1. A tool whose config folder the user already has (for example `%APPDATA%\bottom\bottom.toml`) isn't hidden: its `xdg.native` makes it a Conflict, or the tool reads it as is (Tasks 3 and 5).
2. btop-lhm is on PATH, but gsudo isn't in `Tools`. `btop` isn't wrapped, and nothing prompts at load (Task 4).
3. The btop build can't be determined (exe not found, or an unknown folder layout). No wrapper, no error (Task 4).
4. A theme name a tool doesn't have falls back with a warning, and the tool still starts (Tasks 3–5).
5. A wrapper built for a relocation flag (bottom `-C`, glances `-C`) passes the user's own arguments through unchanged, including short flags PowerShell would take as common parameters (Tasks 3 and 5).

---

### Task 1: Probes

**Files:**
- Modify: the spec (add a "Probe results" section)

- [ ] **Step 1: Probe each tool**: procs, btop (plain, installed; read its folder, never run btop-lhm), btm, glances, ntop, pstop, dust, dua, gdu, duf.
  - **Config:** location on Windows, and the env var or flag that relocates it. Check `--help`, plus a run with a scratch `XDG_CONFIG_HOME`/`APPDATA` that lists any files it creates.
  - **Theme and color options**, and any catppuccin theme upstream with its license.
  - **Completions:** a generator flag, carapace's own completer (`carapace --list`), or none.
  - **Install ids:** scoop bucket and id (`scoop info`), winget id (`winget show --id …`).
  - **btop build detection:** `scoop prefix btop`, and whether btop-lhm's folder holds `LibreHardwareMonitorLib.dll`. The user has the lhm build installed; read its folder only.
- [ ] **Step 2: Record a table per tool in the spec.** Each row gives the XDG approach (`env`, a flag through a `wrapper`, `default`, or `none`), its theme, its completions, and its ids. Then commit: `docs: admin tools probe results`.

### Task 2: Categories and the group

**Files:**
- Modify: `data/roles.json`; `data/groups.json`.
- Test: `tests/AdminTools.Tests.ps1` (new)

**Interfaces:**
- Produces: the categories `process-viewer` ("Shows running processes and system load.") and `disk-usage` ("Shows what uses disk space, and free space per drive.").

- [ ] **Step 1: Failing tests:**
  - Both roles exist with `kind: category`, and neither has a hook or reserved aliases.
  - `+admin-tools` contains dust.
- [ ] **Step 2: Run** `./build/Test-DFFull.ps1 -Path tests/AdminTools.Tests.ps1` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS, plus `tests/Roles.Contract.Tests.ps1` and `tests/Get-DFRoleDb.Tests.ps1`.
- [ ] **Step 5: Commit.** `feat: process-viewer and disk-usage categories; +admin-tools gains dust`

### Task 3: Process viewers (procs, bottom, glances, ntop, pstop)

**Files:**
- Create: `Tools/bottom.json`, `Tools/glances.json`, `Tools/ntop.json`, `Tools/pstop.json`, plus a companion or carapace spec where Task 1 needs one.
- Modify: `Tools/procs.json`, `Tools/procs.ps1`.
- Create (where the tool has a catppuccin theme): theme files under `Tools/<tool>/`, generated by `build/New-DFCatppuccinThemes.ps1` when they're palette-mapped.
- Test: `tests/AdminTools.Tests.ps1`, `tests/ToolNative.Coverage.Tests.ps1`, `tests/CatppuccinThemes.Tests.ps1`

**Interfaces:**
- Each record joins `"process-viewer": {}`, follows Task 1's table, and sets `executable` (`btm.exe` for bottom).
- New theme keys (for example `BottomTheme`) go in `$script:DFConfigKeys`, only for tools that got a theme.

- [ ] **Step 1: Failing tests**, per tool, in a test session (`Mock Test-DFToolAvailable { $true }`, XDG isolated):
  - Its XDG variable or wrapper points at its XDG folder.
  - Its native locations are declared (coverage test).
  - Its theme resolves for `Theme = 'catppuccin-latte'`, where it has one.
  - It is a `process-viewer` member.
  - A wrapper (if any) passes `-d -p x` through unchanged (Review Focus 5).
  - pstop's record notes `htop`.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement.** Run the theme generator if it changed; rebuild the registry and the bundle.
- [ ] **Step 4: Run** `./build/Test-DFFull.ps1 -Path tests/AdminTools.Tests.ps1, tests/ToolNative.Coverage.Tests.ps1, tests/CatppuccinThemes.Tests.ps1, tests/Roles.Contract.Tests.ps1, tests/Docs.Help.Tests.ps1` → PASS.
- [ ] **Step 5: Real check:** each tool's `--version` under its XDG settings (timeout, stdin from `/dev/null`) writes nothing outside the XDG folders.
- [ ] **Step 6: Commit.** `feat: process viewers follow the tool contract`

### Task 4: btop: builds, elevation, themes

**Files:**
- Create: `Tools/btop.json`, `Tools/btop.ps1`, and btop's catppuccin themes (`Tools/btop/*.theme`, upstream MIT copies or generated).
- Test: `tests/btop.Tests.ps1` (new)

**Interfaces:**
- `Get-DFBtopBuild -Executable <path>` (sidecar) returns `'lhm'` when `LibreHardwareMonitorLib.dll` sits beside the resolved exe (or the scoop app folder is `btop-lhm`), `'plain'` when the exe exists without it, and `$null` otherwise.
- With `'lhm'`, the companion calls `Get-DFElevationMethod -ToolDb <active session records>`.
  - On `Method -eq 'Elevator'`, it defines `global:btop` (full help), which runs `& <elevator> <btop.exe> @args`.
  - Any other method: no function.
  - Active records means the members of `elevator` that are Active, through `Get-DFRoleMember`; no tool name.
- **Install:** `packages.scoop = "btop"`, `winget` per Task 1. The lhm build is chosen with `InstallVia`-style package overrides, if Task 1 shows they reach a different scoop id; otherwise documented as `scoop install btop-lhm`.

- [ ] **Step 1: Failing tests** (fake exe folders in `$TestDrive`; `Get-DFElevationMethod` mocked):
  - `Get-DFBtopBuild` returns `lhm`, `plain` and `$null` for the three layouts.
  - With lhm and `Method = 'Elevator'` (`Executable = 'gsudo.exe'`), `btop -p 1` calls the stubbed gsudo with the btop path then `-p 1`.
  - With lhm and `Method = 'RunAs'`, or `WindowsSudo`, or no active elevator: no `btop` function (Review Focus 2).
  - With plain: no function.
  - With an exe that can't be found: no function, no error (Review Focus 3).
  - The theme resolves to latte with `Theme = 'catppuccin-latte'`.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement.** Rebuild the registry and the bundle.
- [ ] **Step 4: Run** `./build/Test-DFFull.ps1 -Path tests/btop.Tests.ps1, tests/Docs.Help.Tests.ps1, tests/Roles.Contract.Tests.ps1` → PASS.
- [ ] **Step 5: Commit.** `feat: btop follows the tool contract; btop-lhm runs through your elevator`

### Task 5: Disk usage (dust, dua, gdu, duf)

**Files:**
- Create: `Tools/dust.json`, `Tools/dua.json`, `Tools/gdu.json`, `Tools/duf.json`, plus companions, carapace specs or theme files per Task 1.
- Test: `tests/AdminTools.Tests.ps1`

**Interfaces:** each record joins `"disk-usage": {}`. duf's `--theme` maps from `Theme`: catppuccin-latte to `light`, the other flavors to `dark`, if Task 1 confirms the flag and its names.

- [ ] **Step 1: Failing tests:** the same shape as Task 3, for these four.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement.** Rebuild.
- [ ] **Step 4: Run** the Task 3 command → PASS.
- [ ] **Step 5: Real check:** as in Task 3.
- [ ] **Step 6: Commit.** `feat: disk-usage tools follow the tool contract`

### Task 6: Docs, catalog data, backlog, gate

- [ ] **Step 1: Docs:**
  - `docs/guide/tools.md`: included tools table, commands table, notes on btop's two builds and Windows sudo;
  - `docs/guide/configuration.md`: new theme keys;
  - `docs/guide/safety.md`: relocated tools;
  - `docs/external-dependencies.md`: btop-lhm detection, and any relocation flag;
  - `CHANGELOG.md`.
- [ ] **Step 2: Catalog:** add the new tools to `build/categories/dotforge-curated.jsonc`, and regenerate `data/tool-categories.json` and `data/tool-identities.json` if the suite asks. Restore any identity hunk the regeneration loses.
- [ ] **Step 3: Backlog:**
  - `TODO.md`: a new T-item for the process-viewer instant replay (spec text), and bump the next free ID.
  - `TODO-Tools.md`: process-viewer and disk-usage move to Done; ncdu goes under "not on Windows"; htop under pstop; the Windows sudo note.
- [ ] **Step 4: Regenerate** the bundle, registry and reference docs.
- [ ] **Step 5: Full gate.** `./build/Test-DFFull.ps1` → `Failed 0 … StrayFolders 0`.
- [ ] **Step 6: Commit.** `docs: admin tools`
