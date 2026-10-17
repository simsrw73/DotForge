# Directory jump (Alt+C) and broot Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `directory-jump` role that owns Alt+C:
- fzf or skim show zoxide's ranked folders, then a breadth-first scan of the current folder;
- broot joins with its whole tool contract and a safe `br`.

**Architecture:**
- **Shared handler:** the Ctrl+R/Ctrl+T handler (`Private/Register-DFFuzzyKeyHandler.ps1`) gains a `Directory` key.
- **Sources:** its folder list comes from what the session's role winners declare (`navigation`: `directories`, `enter`; `file-search`: `directoryScan`). No core file names a tool.
- **broot:** its sidecar owns `br` and its Alt+C, through one helper that reads only the cd target from broot's `--outcmd` file.

**Tech Stack:** PowerShell 7.2+, Pester 6, PSReadLine, fzf / sk / fd / zoxide / broot 1.61.

**Spec:** `docs/superpowers/specs/2026-10-17-directory-jump-design.md`

## Global Constraints

- **Plugin invariant:** no file in `Private/`, `Public/` or `Shared/` names zoxide, fd or broot (`docs/plugin-architecture.md`).
- **Binding Alt+C:** only through `Set-DFRoleKeyHandler` (chord `'Alt+c'`), so a user's own binding is kept unless `Defaults` names a tool.
- **Members and priorities:** fzf 10, skim 5, broot 3. PSFzf is not a member, and imports with `''` for Alt+C.
- **Scan:** from the current folder, breadth-first, depth 1..`DirectoryJumpDepth` (default 6).
- **Order and display:** zoxide's folders first; no folder twice (full path, case-insensitive); `--tiebreak=index`.
  - zoxide entries show as full paths, with `$HOME` as `~`.
  - Scanned folders show relative to the current folder.
- **Moving there:** a picked folder is passed to the navigation winner's `enter` command as one argument value (else `Set-Location -LiteralPath`). It is never built into a command string or run from broot's file.
- **New config keys** go in `$script:DFConfigKeys` (`Private/DFSessionConfig.ps1`): `DirectoryJumpDepth`, `BrootTheme`.
- **Help:** every new global function in a sidecar has complete comment-based help (`tests/Docs.Help.Tests.ps1`).
- **Undocumented dependencies:** each new dependency on broot's internals gets an entry in `docs/external-dependencies.md`, and degrades silently.
- **Rebuild** after changes: the bundle (`Shared/Private/Public` changes), the registry (`Tools/*.json` changes), the reference docs. Gate: `build/Test-DFFull.ps1`.
- **broot probes** write real AppData. List the folders before and after each probe, and remove only what it created.

## Review Focus

1. A folder name with `[`, `]`, `'`, `$` or spaces arrives at `enter` unchanged, and is never treated as a wildcard or code (Task 3).
2. If the current location isn't a file-system folder (`HKLM:\`, `Env:`), the scan is skipped, zoxide's list still shows, and nothing throws (Task 3).
3. A pick made before the scan ends stops the scan: no fd process is left running (Task 4).
4. A folder that's gone by the time you pick it gives one plain error line, not a key-handler exception, and the prompt is redrawn (Task 3).
5. A broot outcmd file holding anything besides a single cd, or several lines, or a hostile line, moves nowhere and runs nothing (Task 6).

---

### Task 1: Probes

**Files:**
- Modify: `docs/superpowers/specs/2026-10-17-directory-jump-design.md` (add a "Probe results" section)

- [ ] **Step 1: broot's default folders.**
  - List `%APPDATA%\dystroy`, `%LOCALAPPDATA%\dystroy` and `~\.config\broot` (record whether each exists).
  - In a scratch folder with no `BROOT_CONFIG_DIR`, run `broot --set-install-state undefined` and then `installed`. Note which file each one writes and where.
  - Then restore the original state, and delete only the folders this probe created.
- [ ] **Step 2: outcmd format.**
  - With `BROOT_CONFIG_DIR` set to a scratch folder holding `--write-default-conf` output, run `broot --outcmd <tmp> --cmd ':cd' <folder>` on three folders: plain, with a space, and with a `'`.
  - It needs a real console. If it won't run unattended, ask the user to run the command and paste the file.
  - Record the exact bytes, for example `cd "C:\a b"`.
- [ ] **Step 3: skin override.** Give a scratch `conf.hjson` an import of `skins/dark-blue.hjson`, plus a second file with `skin: { default: rgb(255,0,0) none }`.
  - Run `broot --conf "<conf>;<second>" --cmd ':print_tree' --color yes` and check which skin wins in the output.
  - Record the answer: **live** (the second file wins) or **seeded** (it doesn't).
- [ ] **Step 4: streaming.**
  - Pipe a PowerShell generator to `fzf --filter x`. The generator writes one line, waits 3 s, then writes the rest.
  - Time when fzf's output first appears, with `Measure-Command` and a timestamped `ForEach-Object`.
  - Record **pipeline streams**, or **needs a writer** (then Task 4 uses `Process` with `StandardInput` writes and a flush per line).
- [ ] **Step 5: Commit.** Record the results in the spec's new "Probe results" section.
  `git commit -m "docs: directory-jump probe results"`

### Task 2: Role-block declarations and the role

**Files:**
- Create: `Private/Get-DFRoleDeclaration.ps1`
- Modify:
  - `Shared/Test-DFToolSchema.ps1`: add `directories`, `enter` and `directoryScan` to the known `role` fields, and type checks for them in `Get-DFRolesSchemaError`;
  - `data/roles.json`;
  - `Private/DFSessionConfig.ps1`;
  - `Tools/zoxide.json`, `Tools/fd.json`, `Tools/fzf.json`, `Tools/skim.json`, `Tools/broot.json`.
- Test: `tests/DirectoryJump.Tests.ps1` (new), plus the existing schema tests and `tests/Roles.Contract.Tests.ps1`.

**Interfaces:**
- Produces: `Get-DFRoleDeclaration -Role <string> -Field <string>` returns the value of `roles.<Role>.<Field>`, or `$null`.
  - For a single role, it reads that role's session winner.
  - For a category role, it reads the first Active member that declares the field (members sorted by name, via `Get-DFRoleMember`).
  - It reads only session state (`$script:DFSessionRoleWinners`, `$script:DFSessionToolDb`, the session's tool status). It never throws.
- Produces: role `directory-jump` with:
  - kind `single`, exclusive `false`, hook `Initialize-DFRoleDirectoryJump`;
  - reserved code `["Set-DFRoleKeyHandler","Register-DFFuzzyKeyHandler"]`;
  - description "Changes to a folder you pick from Alt+C. Only the winner binds the key; a binding you made yourself is kept."
- Produces the declarations:
  - zoxide: `roles.navigation`: `"directories": ["zoxide","query","--list"]`, `"enter": "cd"`.
  - fd: `roles.file-search`: `"directoryScan": ["fd","--type","d","--exact-depth","{depth}"]`.
  - fzf: `"directory-jump": { "priority": 10 }`.
  - skim: `"directory-jump": { "priority": 5 }`.
  - broot: `"directory-jump": { "priority": 3 }`.
- Produces: config key `DirectoryJumpDepth` = `'how deep Alt+C scans below the current folder (default 6)'`.

- [ ] **Step 1: Failing tests.**
  - Schema: `directories` and `directoryScan` must be non-empty string arrays, and `enter` a non-empty string. Each wrong type gives one error naming `roles.<role>.<field>`.
  - With zoxide and fd records active in a test session:
    - `Get-DFRoleDeclaration -Role navigation -Field enter` returns `'cd'`.
    - `Get-DFRoleDeclaration -Role file-search -Field directoryScan` returns fd's argv.
    - With zoxide not requested, it returns `$null`.
  - `Get-DFRole directory-jump` lists fzf, skim and broot.
  - fzf wins when all three are requested.
- [ ] **Step 2: Run them.**
  `./build/Test-DFFull.ps1 -Path tests/DirectoryJump.Tests.ps1, tests/Test-DFToolSchema.Tests.ps1`
  Expected: FAIL.
- [ ] **Step 3: Implement** the schema checks, `Get-DFRoleDeclaration`, the role, the config key and the record changes.
  - Rebuild the registry and the bundle.
  - Give `Tools/broot.json` a stub `Initialize-DFRoleDirectoryJump` only if the contract test requires it. Otherwise Task 6 adds it.
- [ ] **Step 4: Run them again,** plus `tests/Roles.Contract.Tests.ps1` and `tests/ToolRegistry.Tests.ps1`. Expected: PASS.
- [ ] **Step 5: Commit.** `feat: directory-jump role and role-block folder declarations`

### Task 3: The folder list and moving there

**Files:**
- Create: `Private/DFDirectoryJump.ps1`
- Test: `tests/DirectoryJump.Tests.ps1`

**Interfaces:**
- Consumes: `Get-DFRoleDeclaration` (Task 2).
- Produces:
  - `Get-DFDirectoryJumpCandidate [-Depth <int>]` streams `[pscustomobject]@{ Shown = <string>; Path = <full path> }` to the pipeline as it goes:
    - first the navigation `directories` (run through `Invoke-DFNative`-style `& $argv[0] $argv[1..]`; failures give nothing);
    - then depth 1..Depth of the scan (`directoryScan` with `{depth}` replaced, run with the current folder as the working folder; else `Get-ChildItem -LiteralPath . -Directory -Depth` filtered to exact depth, skipping hidden folders).
    - It drops duplicates by full path, case-insensitively, and shows `$HOME` as `~` in zoxide entries.
    - If `(Get-Location).Provider.Name -ne 'FileSystem'`, it skips the scan.
  - `Enter-DFDirectory -Path <string>` calls `& <enter> $Path` when `navigation` declares `enter`, else `Set-Location -LiteralPath $Path`.
    - A missing folder writes one error line, `DotForge: <path> no longer exists`, and returns `$false`.
    - Returns `$true` on success.

- [ ] **Step 1: Failing tests.** Fixture: a `$TestDrive` tree (`a\b\c\d\e\f\g`, `x y`, `q'uote`, `w[1]`, `.hidden`), with mocked declarations and a stub `function global:zoxide` that prints two folders, one also in the tree.
  - The order is zoxide's two, then the depth-1 folders, then depth-2, and so on.
  - Nothing is deeper than `-Depth 3` when `-Depth 3`.
  - The folder zoxide listed isn't repeated, even with different case.
  - Without fd's declaration the `Get-ChildItem` fallback gives the same set, and `.hidden` is absent.
  - Without the navigation declaration only the scan runs.
  - Started in `Env:`, it lists zoxide's two only and doesn't throw.
  - `Enter-DFDirectory`:
    - with `enter = 'Test-Enter'` (a stub recording `$args`), `w[1]` and `q'uote` arrive unchanged as one argument;
    - without `enter`, it ends in `w[1]`;
    - a deleted folder gives `$false` and the one error line.
- [ ] **Step 2: Run them.** `./build/Test-DFFull.ps1 -Path tests/DirectoryJump.Tests.ps1`. Expected: FAIL.
- [ ] **Step 3: Implement** both functions. Rebuild the bundle.
- [ ] **Step 4: Run them again.** Expected: PASS.
- [ ] **Step 5: Commit.** `feat: Alt+C's folder list (zoxide first, breadth-first scan) and the move`

### Task 4: Alt+C through the shared handler; PSFzf steps back

**Files:**
- Modify:
  - `Private/Register-DFFuzzyKeyHandler.ps1`: add `Directory` to `-Key` (role `directory-jump`, chord `Alt+c`);
  - `Tools/fzf.ps1`, `Tools/skim.ps1`: `Initialize-DFRoleDirectoryJump` calls `Register-DFFuzzyKeyHandler -Engine <fzf|sk> -Key Directory -Tool $Tool.name`;
  - `Tools/PSFzf.ps1`: `-ArgumentList '', '', '', 'Alt+a'`; remove the `-AltCCommand` block; update the header comment.
- Test: `tests/FuzzyKeys.Tests.ps1`, `tests/FuzzyKeys.Members.Tests.ps1`

**Interfaces:**
- Consumes: `Get-DFDirectoryJumpCandidate`, `Enter-DFDirectory` (Task 3).
- `Invoke-DFFuzzyKey -Key Directory`:
  - streams the candidates' `Shown` text to the engine with `--tiebreak=index`, keeping a Shown → Path map as lines go out;
  - maps the pick back, calls `Enter-DFDirectory`, then `Update-DFReadLineBuffer`, which redraws and keeps the line.
  - When the engine exits, the scan stops: any scan process still running is killed, by stopping the pipeline, or by `Dispose` if Task 1 chose the writer.

- [ ] **Step 1: Failing tests.**
  - The fzf member's hook binds `Alt+c` with BriefDescription `DotForge directory-jump (fzf)`.
  - A user's own Alt+C scriptblock handler is kept, with the status note.
  - `Defaults = @{ 'directory-jump' = 'skim' }` binds sk.
  - With a mocked engine that returns the second Shown line, `Enter-DFDirectory` gets that line's Path.
  - When the engine returns nothing, there's no `Enter-DFDirectory` call.
  - `--tiebreak=index` is passed.
  - **Early pick:** a scan stub that blocks after its first line, with an engine that picks at once. The handler returns within 2 s and no stub process is left running.
  - **PSFzf:** importing with DotForge's arguments leaves Alt+C unbound (stub PSFzf module, recording its arguments).
  - **Regression:** no test-session code path calls `z` (`Mock z` is never invoked, with `function global:z {}` stubbed).
- [ ] **Step 2: Run them.**
  `./build/Test-DFFull.ps1 -Path tests/FuzzyKeys.Tests.ps1, tests/FuzzyKeys.Members.Tests.ps1`
  Expected: FAIL.
- [ ] **Step 3: Implement** the changes above. Rebuild the bundle.
- [ ] **Step 4: Run them again.** Expected: PASS.
- [ ] **Step 5: Real check:** in a real pwsh, `Invoke-DFFuzzyKey -Engine fzf -Key Directory` from `$HOME` shows lines within ~0.5 s. Record it in the commit message.
- [ ] **Step 6: Commit.** `feat: Alt+C picks a folder with fzf or skim; PSFzf no longer binds it`

### Task 5: broot record, XDG, seeds and themes

**Files:**
- Modify:
  - `Tools/broot.json`;
  - `build/New-DFCatppuccinThemes.ps1` (add broot);
  - `Private/DFSessionConfig.ps1` (`BrootTheme`).
- Create:
  - `Tools/broot/conf.hjson`, `Tools/broot/verbs.hjson` (from `broot --write-default-conf`, 1.61);
  - `Tools/broot/catppuccin-{latte,frappe,macchiato,mocha}.hjson`, plus the license file, as the other tools have.
- Test: `tests/broot.Tests.ps1` (new), `tests/CatppuccinThemes.Tests.ps1`

**Interfaces:**
- **XDG:** `xdg.method` `env`, `xdg.vars.BROOT_CONFIG_DIR = "${XDG_CONFIG_HOME}/broot"`, `xdg.native` from Task 1's step 1.
- **Seeds:** `${XDG_CONFIG_HOME}/broot/conf.hjson` and `verbs.hjson`.
- **Theme:** `theme: { key: "BrootTheme", default: "catppuccin-mocha", files: "broot" }`.
  - **live:** `conf.hjson` keeps broot's own skin imports, and `br` passes the theme file (Task 6).
  - **seeded:** the seed source for `conf.hjson` is generated per flavor, importing `skins/<theme>.hjson` and seeding that skin too, plus a `setup.notes` entry with `ifFile` on `conf.hjson`: "your broot conf.hjson predates DotForge; to use the catppuccin skin, import skins/<theme>.hjson in it".
- **Skin keys:** the generator maps broot's skin keys from broot's own `catppuccin-mocha.hjson` onto palette names.

- [ ] **Step 1: Failing tests.**
  - `Start-DFSession` with `Tools = @('broot')` sets `$Env:BROOT_CONFIG_DIR`, seeds both files, and resolves `Get-DFToolTheme broot` to the mocha file, or latte with `Theme = 'catppuccin-latte'`.
  - `tests/CatppuccinThemes.Tests.ps1` covers broot's four files: each parses as hjson-ish text with a `skin:` block, and its colors match the palette.
- [ ] **Step 2: Run them.**
  `./build/Test-DFFull.ps1 -Path tests/broot.Tests.ps1, tests/CatppuccinThemes.Tests.ps1, tests/ToolNative.Coverage.Tests.ps1`
  Expected: FAIL.
- [ ] **Step 3: Implement.** Run the generator, rebuild the registry and the bundle, and check `Tools/carapace/specs/broot.yaml` against `broot --help` (1.61).
- [ ] **Step 4: Run them again.** Expected: PASS.
- [ ] **Step 5: Commit.** `feat: broot follows XDG, seeds its config and gets catppuccin skins`

### Task 6: `br`, broot's Alt+C and the outcmd reader

**Files:**
- Create: `Tools/broot.ps1`
- Test: `tests/broot.Tests.ps1`

**Interfaces:**
- Consumes: `Enter-DFDirectory` (Task 3), through a captured `${function:Enter-DFDirectory}`; and `Get-DFToolTheme`.
- Produces:
  - `ConvertFrom-DFBrootOutCmd -Text <string>` returns the cd target, or `$null`.
    - It accepts exactly one non-empty line of the cd form Task 1 recorded, and unquotes it per that format.
    - Anything else returns `$null`: several lines, anything after the closing quote, or a missing quote.
  - `global:br` (with full help) runs broot `--outcmd <New-TemporaryFile> <args>` in the current folder, plus `--conf "<conf>;<skin>"` in the live branch.
    - On exit 0 it reads the file; a target goes to `Enter-DFDirectory`.
    - It always removes the temp file. A non-zero exit writes one error.
  - `Initialize-DFRoleDirectoryJump` binds Alt+C through `Set-DFRoleKeyHandler`. The handler runs the same helper with `--only-folders`, then `[Microsoft.PowerShell.PSConsoleReadLine]::InvokePrompt()`, and keeps the typed line.
  - `br` and the handler share one helper (`Invoke-DFBroot`, sidecar scope, captured for the global closure).

- [ ] **Step 1: Failing tests.**
  - `ConvertFrom-DFBrootOutCmd` returns `C:\a b` and `C:\it's` for Task 1's samples.
  - It returns `$null` for `cd "x"; Remove-Item y`, two cd lines, an empty file, `Start-Process calc` and an unterminated quote.
  - `br` with a mocked broot run (seam: the helper's process call) that writes a sample file calls `Enter-DFDirectory` with the target, and the temp file is gone afterwards.
  - With a hostile file, no command runs: `Mock Invoke-Expression` and `Remove-Item` on the target are never called.
  - The broot winner's hook binds `Alt+c`.
  - `Get-Command br` resolves to the DotForge function. No builtin named `br` exists (`Get-Command br -CommandType Cmdlet,Alias` is empty in a clean pwsh).
- [ ] **Step 2: Run them.** `./build/Test-DFFull.ps1 -Path tests/broot.Tests.ps1`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them again,** plus `tests/Docs.Help.Tests.ps1`. Expected: PASS.
- [ ] **Step 5: Commit.** `feat: br and broot's Alt+C move the shell without running broot's command file`

### Task 7: broot's one-time setup

**Files:**
- Create: `Tools/broot.setup.ps1`
- Test: `tests/broot.Tests.ps1`

- [ ] **Step 1: Failing tests.** On first activation, the setup runs `broot --set-install-state installed` once, through `Invoke-DFBoundedProcess` with a 30 s timeout (mocked). It adds the note "DotForge provides br; broot's own br isn't installed" and completes.
  - On the second load, broot isn't run again.
  - If broot fails, setup still completes, with a note telling you to run `broot --set-install-state installed` yourself.
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement,** modeled on `Tools/television.setup.ps1`.
- [ ] **Step 4: Run them again.** Expected: PASS.
- [ ] **Step 5: Commit.** `feat: broot's setup turns off its br install prompt`

### Task 8: Docs, backlog, full gate

**Files:**
- `docs/guide/tools.md`: Alt+C section; broot section; `DirectoryJumpDepth`.
- `docs/guide/configuration.md`: the new keys.
- `docs/guide/writing-a-tool.md`: the three role-block fields.
- `CLAUDE.md`: the roles bullet gets one line on `directory-jump` and the role-block fields.
- `docs/external-dependencies.md`: broot's outcmd format, its install-state file, `BROOT_CONFIG_DIR`, the `--conf` override if live.
- `CHANGELOG.md` [Unreleased].
- `TODO.md`: delete T-68 (`Closes T-68`); update T-35's note.
- `TODO-Tools.md`: directory-jump done; broot's gap closed; PSFzf no longer owns Alt+C.
- `data/groups.json` stays unchanged (the collections are the user's call).

- [ ] **Step 1: Write the docs.**
  - Mark doc code blocks that need a person `<!-- interactive -->`.
  - Mark blocks that run real tools `<!-- requires: broot -->`.
- [ ] **Step 2: Regenerate** the bundle, the registry, the reference docs, and `data/tool-categories.json` / `data/tool-identities.json` if the full suite asks for them.
- [ ] **Step 3: Full gate.** `./build/Test-DFFull.ps1`. Expected: `Failed 0 … FailedContainers 0 SentinelFiles 0 StrayFolders 0`.
- [ ] **Step 4: Commit.** `docs: directory-jump and broot; Closes T-68`
- [ ] **Step 5: By hand** (the user, after `./build/Publish-DFLocal.ps1 -Install`):
  - Alt+C from `$HOME` shows folders at once;
  - picking one moves there, and zoxide learns it;
  - `br` moves the shell;
  - the broot skin follows `Theme`.
