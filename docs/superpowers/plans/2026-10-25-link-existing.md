# Link Existing Data Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A requested tool whose config, data or state already exists outside the XDG folders keeps it there: DotForge links the empty XDG location to it, doesn't set the variable that would hide it, and activates the tool. Only "both places hold content" stays a Conflict, resolved by `-Adopt` (set the XDG copy aside, then link). `-Move`/`-Done` go.

**Architecture:** Records lose `xdg.native.move`/`block` and gain a `${SCOOP}` root. A small link layer (`Shared/DFToolLink.ps1`) makes, checks and removes junctions/symlinks without ever touching targets. `Find-DFToolConflict` becomes a per-location classifier (link / conflict / nothing); `Test-DFToolOwnership` makes the links and records them in `ownership.json` (`how = 'linked'`, `links`); registration skips the linked variables and seeds. `Resolve-DFToolConflict` keeps only `-Adopt`.

**Tech Stack:** PowerShell 7.2+, Pester 6, .NET `System.IO` for links.

**Spec:** `docs/superpowers/specs/2026-10-25-link-existing-design.md`

## Global Constraints

- Never move or delete user data; never overwrite anything at an XDG location; removing a link never touches its target (delete the link entry itself: `[IO.Directory]::Delete($path)` on a junction, `[IO.File]::Delete` on a file symlink, never `Remove-Item -Recurse`).
- Caches (`${XDG_CACHE_HOME}` templates) are never linked; `Get-DFToolRelocation` already leaves them out.
- The existing location for a key is: its variable's current value when set outside DotForge (`Get-DFEnvState`'s rule: set, and not equal to `Written[<name>]`) and different from the XDG path; else the first `xdg.native` path with content.
- Folders → directory junction. Files → file symlink only when Developer Mode is on (`HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock` `AllowDevelopmentWithoutDevLicense = 1`, read through one mockable helper), else a status note.
- Links are recorded in `ownership.json` (one state file): entry `{ since, how = 'linked', links = [ { key, path, target } ] }`. Ruling (spec left it to the builder): `ownership.json`, not a new `links.json` — one home for "what DotForge did about a tool's old locations".
- Plugin rule: no tool names in core. All directory creation through `New-DFDirectory`; all paths through `ConvertTo-DFPath`.
- Worktree `../DotForge-link-existing`, branch `link-existing`; move the uncommitted spec and this plan in first. Signed commits, batched in Task 5.

## Review Focus

1. A junction whose target is gone: `Test-Path` on it is false but the link entry exists; `New-DFDirectory` or a seed must not write through or around it. Test in Task 2 (detect a dangling junction) and Task 3 (removed and noted at registration).
2. A tool already owned as `clean` in `ownership.json` from earlier loads must not be re-checked or linked (no file-system calls for owned tools). Test in Task 3.
3. A linked folder is the user's real folder: a `setup.seed` destination inside it must not be written. Test in Task 3.
4. Two relocated keys of one tool where one links and the other is fresh (bitwarden has one, rustup two): the fresh one's variable is still set. Test in Task 3.
5. `Remove-DFTool` on a linked tool removes only the link; the target's files remain. Test in Task 4.

---

### Task 1: Records and schema

**Files:** `Shared/Import-DFToolDb.ps1` (native normalization ~line 270-280), `Shared/Test-DFToolSchema.ps1` (~line 428-431), `Shared/DFToolOwnership.ps1` (`Get-DFNativeRoot`), `Tools/*.json` with `move`/`block` (bun, npm, oh-my-posh, pip, pipx, pnpm, python, rustup, uv), `Tools/bitwarden.json`; regenerate `data/tool-registry.json`.
**Tests:** `tests/ToolNative.Schema.Tests.ps1`, `tests/DFToolOwnership.Tests.ps1`, `tests/ToolLocations.Tests.ps1`, `tests/ToolNative.Coverage.Tests.ps1`.
**Produces:** normalized native entry `{ paths, guide, setting }` (no `move`, no `block`); `${SCOOP}` expands from `$Env:SCOOP`, skipped when unset.

- [ ] **Step 1: Failing tests.** Schema: a native entry with `move` → error `*xdg.native.<key>.move was retired*`; same for `block`. `Expand-DFNativePath '${SCOOP}/persist/x'` with `$Env:SCOOP = 'C:\s'` → `C:\s\persist\x`; with SCOOP unset → `$null`. bitwarden: `xdg.method = 'env'`, `xdg.vars.BITWARDENCLI_APPDATA_DIR = '${XDG_DATA_HOME}/bitwarden'`, native paths `@('${SCOOP}/persist/bitwarden-cli/bw-data', '${APPDATA}/Bitwarden CLI')`.
- [ ] **Step 2: Run** `./build/Test-DFFull.ps1 -Path tests/ToolNative.Schema.Tests.ps1, tests/DFToolOwnership.Tests.ps1, tests/ToolLocations.Tests.ps1`. Expected: new tests FAIL.
- [ ] **Step 3: Implement.** Drop `move`/`block` from normalization and the records; schema rejects them with the retired message. Each retired entry's `guide` is rewritten to read right in a Conflict (both places hold content) or removed. `Get-DFNativeRoot` accepts `SCOOP`. bitwarden record as above. `./build/Build-DFToolRegistry.ps1`.
- [ ] **Step 4: Run** Step 2's command plus `tests/ToolNative.Coverage.Tests.ps1, tests/ToolRegistry.Tests.ps1`. Expected: PASS.

### Task 2: Link layer

**Files:** Create `Shared/DFToolLink.ps1`. **Tests:** Create `tests/DFToolLink.Tests.ps1` (all under `$TestDrive`).
**Produces:**
- `Test-DFDeveloperMode` → `[bool]` (the registry value above; the only reader).
- `New-DFToolLink -Path <string> -Target <string>` → `[pscustomobject]` `{ Path; Target; Made (bool); Note (string or $null) }`. Folder target → junction; file target → symlink if `Test-DFDeveloperMode`, else `Made = $false` and `Note = "turn on Developer Mode to let DotForge link <path> to <target>"`. An existing link to the same target → `Made = $true`, unchanged. Anything else at `Path` → throws (callers check first).
- `Get-DFToolLinkTarget -Path <string>` → `[string]` target of a junction/symlink at Path, or `$null` (not a link). Works for a dangling link.
- `Remove-DFToolLink -Path <string>` → removes the link entry only; no-op when Path isn't a link.

- [ ] **Step 1: Failing tests:** a folder target makes a junction whose `Get-DFToolLinkTarget` is the target and whose contents list the target's files; calling again is a no-op; a file target with `Test-DFDeveloperMode` mocked `$true` makes a symlink, mocked `$false` returns the note and creates nothing; `Remove-DFToolLink` leaves every target file in place; a junction whose target was deleted is still found by `Get-DFToolLinkTarget` and removed by `Remove-DFToolLink`; `Remove-DFToolLink` on a real folder does nothing.
- [ ] **Step 2: Run** `./build/Test-DFFull.ps1 -Path tests/DFToolLink.Tests.ps1`. Expected: FAIL (functions missing). (If the test machine can't make symlinks, the symlink test mocks `New-Item`'s call through a seam; note it as a ruling.)
- [ ] **Step 3: Implement** with `New-Item -ItemType Junction|SymbolicLink`, `(Get-Item -Force).LinkTarget`, and the .NET deletes from Global Constraints. Full comment-based help is not required (private), but each function gets SYNOPSIS/PARAMETER/OUTPUTS like its neighbours.
- [ ] **Step 4: Run** the same. Expected: PASS.

### Task 3: Registration links

**Files:** `Shared/DFToolOwnership.ps1` (`Find-DFToolConflict` → classify; `Get-DFConflictAdvice` → Adopt only; delete `Invoke-DFPendingRemoval`), `Private/Invoke-DFSessionActivation.ps1` (`Test-DFToolOwnership`, `Complete-DFToolOwnership`), `Private/Set-DFToolXdgConfig.ps1` (`-Skip <string[]>` var names), `Private/Register-DFToolSteps.ps1:255` (pass the tool's linked var names), `Private/Invoke-DFToolSeed.ps1` (skip destinations inside a linked path).
**Tests:** `tests/Activation.Ownership.Tests.ps1`, `tests/DFToolOwnership.Tests.ps1`, `tests/Set-DFToolXdgConfig.Tests.ps1`, `tests/Invoke-DFToolSeed.Tests.ps1` (or wherever seeds are tested).
**Consumes:** Task 2's link functions.
**Produces:**
- `Find-DFToolConflict` result items gain `Existing` (the existing location) and `Action` (`Link`, `Conflict`); a key whose variable was set outside DotForge is classified like a native path (Existing = its value) instead of being skipped.
- `Get-DFToolLinkedVar -Name <tool>` → `[string[]]` the variable names linked for that tool (from the session's ownership state), read by registration.

- [ ] **Step 1: Failing tests** (sentinel XDG; a fake tool record `{ name: 'lt', executable: ..., xdg: { method: env, vars: { LT_HOME: '${XDG_DATA_HOME}/lt', LT_CFG: '${XDG_CONFIG_HOME}/lt' }, native: { LT_HOME: ['${HOME}/.lt'] } } }` with `$HOME` pointed under `$TestDrive` the way existing ownership tests do):
  - existing `~/.lt` with a file, empty XDG → after `Register-DFTool -Name lt`: state Active, `$XDG_DATA_HOME\lt` is a junction to `~/.lt`, `LT_HOME` not set, `LT_CFG` set (Review Focus 4), ownership entry `how = 'linked'` with one link, status detail contains `linked`.
  - a second registration changes nothing (same link, no new ownership write).
  - `LT_HOME` set outside DotForge to another folder with content, empty XDG → linked to that folder; the variable keeps its value.
  - both `~/.lt` and the XDG folder hold files → Conflict, advice names `Resolve-DFToolConflict lt -Adopt`.
  - a tool already owned `clean` → no link, no file-system check (mock `Test-DFPathHasContent`, `Should -Invoke -Times 0`) (Review Focus 2).
  - a seed destination inside the linked folder is not written (Review Focus 3).
  - the link's target deleted → next registration removes the link (target untouched), notes it, drops the ownership link, and sets `LT_HOME` (Review Focus 1).
  - a single-file key with Developer Mode mocked off → tool Active, variable not set, status note from `New-DFToolLink`.
- [ ] **Step 2: Run** `./build/Test-DFFull.ps1 -Path tests/Activation.Ownership.Tests.ps1, tests/DFToolOwnership.Tests.ps1, tests/Set-DFToolXdgConfig.Tests.ps1`. Expected: new tests FAIL; adjust or delete existing tests that pin Move/block behavior, each as a ledger ruling.
- [ ] **Step 3: Implement.** Classification per relocation: Existing found and target empty → `Link`; both content → `Conflict`. `Test-DFToolOwnership`: Conflict → as today; Links → `New-DFToolLink` each, record in `State.Table` (`how = 'linked'`), status notes into `State.Notes`, return `$true`. For an owned `linked` tool, each recorded link is checked with `Get-DFToolLinkTarget`/`Test-Path`: gone target → `Remove-DFToolLink`, note, drop the link (and the entry when none remain). Registration passes `Get-DFToolLinkedVar` to `Set-DFToolXdgConfig -Skip`; `Invoke-DFToolSeed` skips a destination at or under a linked path. Delete `Invoke-DFPendingRemoval` and its call.
- [ ] **Step 4: Run** the same. Expected: PASS.

### Task 4: Resolve-DFToolConflict and Remove-DFTool

**Files:** `Modules/DotForge.Helpers/Public/Resolve-DFToolConflict.ps1`, `Modules/DotForge.Helpers/Private/Resolve-DFToolConflict.Steps.ps1` (delete the Move/copy/verify/pending/reference steps), `Public/Remove-DFTool.ps1` (or `Write-DFRemoveLeftover`).
**Tests:** `tests/Resolve-DFToolConflict.Tests.ps1`; delete `tests/Resolve-DFToolConflict.Move.Tests.ps1`; `tests/Remove-DFTool.Tests.ps1`.
**Consumes:** Tasks 2-3.

- [ ] **Step 1: Failing tests:** `-Adopt` on a Conflict renames the XDG copy to `<name>.dotforge-moved`, links, records `linked`, and the tool registers Active; a rename that fails (mock it to throw) changes nothing and reports why; `-Move` and `-Done` are gone (`(Get-Command Resolve-DFToolConflict).Parameters.Keys` lacks them); the interactive walk offers Adopt or Skip; `Remove-DFTool` on a linked tool removes the link and leaves every target file (Review Focus 5) and drops the ownership entry.
- [ ] **Step 2: Run** `./build/Test-DFFull.ps1 -Path tests/Resolve-DFToolConflict.Tests.ps1, tests/Remove-DFTool.Tests.ps1`. Expected: FAIL.
- [ ] **Step 3: Implement**, with the help rewritten (SYNOPSIS, DESCRIPTION, `-Adopt`, EXAMPLE, OUTPUTS) to the new meaning.
- [ ] **Step 4: Run** the same. Expected: PASS.

### Task 5: Docs, backlog, gate, review, merge

**Files:** `docs/guide/safety.md` (Relocated tool data), the config-ownership user text (`docs/guide/configuration.md` or `troubleshooting.md`, wherever `Resolve-DFToolConflict` is explained), `CHANGELOG.md` (rewrite the unreleased Conflict entry: existing data is linked; `-Adopt` links; no Move), `CLAUDE.md` (`xdg.native` line: no `move`/`block`; links), `docs/external-dependencies.md` if Windows junction/Developer Mode behavior counts (add an entry), `TODO.md` (delete T-83 `Closes T-83`; new item for the first-run bad-source warning; next free ID +1), the restore notes (piece 6 done). Regenerate bundle, registry, reference.

- [ ] **Step 1:** Docs as listed.
- [ ] **Step 2:** Startup benchmark before (on `main`) and after; record both numbers in the ledger.
- [ ] **Step 3:** `./build/Test-DFFull.ps1`. Expected: 0 failed.
- [ ] **Step 4:** Commit (signed) with spec and plan: `feat: existing tool data stays put; DotForge links to it (Closes T-83)`.
- [ ] **Step 5:** Final review, fixes, fast-forward `main`, push, remove the worktree (leave it first).
