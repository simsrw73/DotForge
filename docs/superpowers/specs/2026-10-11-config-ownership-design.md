# Config ownership: never orphan a user's existing config — Design

**Date:** 2026-10-11
**Status:** Approved design; ready for implementation planning.
**Backlog:** T-61 (part of the 1.0 track, T-1).

## Purpose

About 20 tool records point a tool at XDG locations: most set a variable (`BAT_CONFIG_PATH`,
`STARSHIP_CONFIG`, `WGETRC`, `FNM_DIR`, `_ZO_DATA_DIR`, `RUSTUP_HOME`, …), two use a command wrapper
(glow, fastfetch), and some seed a default config (`setup.seed`). DotForge already leaves a variable
alone when the user set it. The gap: a user who never set it but has config or data in the tool's own
default location (`%APPDATA%\bat\config`, `~\.wgetrc`, `~\.cargo`, fnm's Node versions, zoxide's
database). DotForge sets the variable and the tool silently stops seeing it.

**Rule:** DotForge never makes a user's existing config or data stop working, unless the user
explicitly hands that tool over.

1. A tool not in `Tools` is untouched (already true: activation is opt-in).
2. A tool in `Tools` with nothing in its old locations: DotForge owns it from then on.
3. A tool in `Tools` with content in an old location is a **conflict**. DotForge does nothing at all
   for that tool, and warns on every load, until the user takes it out of `Tools` or resolves it
   with `Resolve-DFToolConflict`.
4. Once the user resolves it, ownership is recorded and DotForge owns the tool completely inside
   its sessions; leftovers in old locations are ignored from then on.

Ownership is session-scoped: DotForge never sets user-level (persistent) environment variables.
Programs run outside a DotForge shell keep using the old location; that is accepted.

## Non-goals

- Copying config automatically, or running with two live copies (rejected: mixes things up).
- Warning but relocating anyway (rejected: orphans the config).
- Setting user-level environment variables.
- A "release" command that moves config back out of XDG (later, if wanted).
- Theme variables that outrank a user's own config file (T-37; related, separate).

## Tool data: `xdg.native`

Each relocated path declares the tool's own default locations, keyed like the thing it relocates:
a variable name from `xdg.vars`, or a seed/wrapper target path.

```json
"xdg": {
  "method": "env",
  "vars": { "BAT_CONFIG_PATH": "${XDG_CONFIG_HOME}/bat/bat.conf" },
  "native": {
    "BAT_CONFIG_PATH": ["${APPDATA}/bat/config", "${HOME}/.config/bat/config"]
  }
}
```

An entry is a list of path templates, or an object for a location DotForge must not move itself:

```json
"RUSTUP_HOME": {
  "paths": ["${HOME}/.rustup"],
  "move": false,
  "guide": "rustup keeps absolute paths inside; follow https://rust-lang.github.io/rustup/installation/index.html to move it, then run Resolve-DFToolConflict rustup -Adopt."
}
```

- Templates: `${HOME}`, `${APPDATA}`, `${LOCALAPPDATA}` and `${XDG_*}`, expanded by a new
  `Expand-DFNativePath` and passed through `ConvertTo-DFPath`. `xdg.vars` keeps its `${XDG_*}`-only rule.
- Paths for every OS may be listed; one that doesn't exist on this machine simply isn't found.
- Cache locations (`UV_CACHE_DIR`, `STARSHIP_CACHE`, `VCPKG_DOWNLOADS`, …) declare nothing: losing a
  cache costs nothing. Config, data and state (history files included) must be declared.
- `Test-DFToolSchema` validates the shape; `ConvertTo-DFToolRecord` normalizes `native` to
  `{ key: { paths: [...], move: bool, guide: string|null } }`.
- A test fails when a tool relocates a config, data or state path (an `xdg.vars` entry under
  `XDG_CONFIG_HOME`, `XDG_DATA_HOME` or `XDG_STATE_HOME`, a seed, or a wrapper target) without a
  `native` entry for it. A tool whose default location *is* the XDG one declares `[]` explicitly.

## States

Checked for each requested, installed tool, until it is owned:

| Old locations | XDG location | Result |
|---|---|---|
| all empty or absent | empty | owned, recorded |
| all empty or absent | has content | owned, recorded (nothing to orphan; today's DotForge users) |
| any has content | anything | **conflict** |
| (tool already owned) | | not checked |

- "Has content": a file, or a folder with at least one file anywhere below it.
- An old path that resolves to the same canonical path as the target (or lies inside it) is skipped.
- Ownership lives in `$XDG_STATE_HOME/dotforge/ownership.json`:

```json
{ "bat": { "since": "2026-10-11T10:00:00Z", "how": "clean" } }
```

`how` is `clean` (nothing found), `adopt`, or `move`; a move also records `pending` (below).

## Activation

- `Get-DFToolOwnership` reads `ownership.json` once per session (cached; a corrupt file warns once and
  is treated as empty, never overwritten until a write succeeds atomically via `Write-DFFileAtomic`).
- `Find-DFToolConflict -Tool` returns the conflicts (key, old path, target, move, guide), or nothing.
  For an owned tool it returns at once, with no file-system calls.
- `Invoke-DFSessionActivation` (so `Start-DFSession` and `Register-DFTool -Name` alike) calls it for
  each requested, installed tool **before any activation step**. On no conflict it records ownership
  (one write per load at most, batched). On conflict:
  - the tool gets status `Conflict`, the paths in `Detail`, and is skipped entirely: no env, xdg vars,
    seeds, setup, companion, aliases, pickers, role membership;
  - tools that `require` it are blocked as they are for a missing tool;
  - one warning per conflicted tool per load:
    `DotForge: bat isn't active: your existing config at <path> would be hidden. Run Resolve-DFToolConflict bat -Move (or -Adopt), or remove bat from Tools.`
    A `move: false` entry names its guide instead of `-Move`.
- Unfinished removals of owned tools are processed in the same pass (below); none costs nothing.

## `Resolve-DFToolConflict`

On-demand (DotForge.Helpers). `-Name <tool>` and one of `-Move`, `-Adopt`, `-Done`;
`SupportsShouldProcess` (`-WhatIf`, `-Confirm`). Output: a result object (tool, action, moved items,
pending removals, problems). Its steps are private functions; the public function reads as a list.

### `-Adopt`

Records ownership (`how: adopt`). Moves nothing. Works for any conflict, including `move: false`.

### `-Move`

Runs only when every check passes; otherwise changes nothing and reports each problem with what to do.

1. **Checks** (all run, all problems reported together):
   - every conflicting entry allows `move` (else its `guide`);
   - the target is empty (no merging or overwriting; merge by hand, or `-Adopt`);
   - the tool isn't running (`Get-Process` on its executable): "close bat first";
   - no text file under an old location contains that old path, in its spellings: `\` and `/`
     separators, `~`, `%APPDATA%`/`%LOCALAPPDATA%`/`%USERPROFILE%`, `$HOME`/`$env:APPDATA`. Text means
     under 1 MB with no NUL byte in its first 8 KB. Each hit is reported as `file:line`;
   - no user or session environment variable (PATH included) contains an old path.
2. **Copy and verify:** copy each old location to a staging folder beside its target
   (`<target>.dotforge-staging`), verify every file's size and SHA-256 against the source (with
   `Write-Progress`), then rename staging into place. Any failure removes staging and stops; the old
   files are untouched and nothing is recorded.
3. **Record:** ownership `how: move`, with `pending`: the old paths and the moved files' relative
   paths and hashes. Written before removal, so a crash leaves a recoverable record.
4. **Remove the old copy:** each old location goes to the Recycle Bin on Windows
   (`Microsoft.VisualBasic.FileIO.FileSystem` with `SendToRecycleBin`), or is renamed to
   `<name>.dotforge-moved` elsewhere, through one private `Remove-DFItemToBin` (tests mock it).
   Removed locations leave `pending`; locked ones stay.

### Pending removals (next load)

For an owned tool with `pending`: verify the target still holds every recorded file with its hash;
retry each removal; drop what succeeded. Still failing, or a target file missing or changed: one
warning naming each path and what to do, every load, until it succeeds or the user runs
`Resolve-DFToolConflict <tool> -Done` (clears `pending`, keeps ownership).

### Idempotence

A second `-Move` or `-Adopt` on an owned tool says it is already owned and changes nothing.

## Startup cost

One small JSON read per session. Owned tools: zero file-system calls (tested). Unowned tools: a few
`Test-Path`/`Get-ChildItem -File -Recurse | Select -First 1` per declared path, until owned, which is
normally the first load.

## Testing

- All paths under `$TestDrive`. A new `Set-DFTestNativeRoot` / `Restore-DFTestNativeRoot` in
  `tests/TestSupport.ps1` points `HOME`, `APPDATA` and `LOCALAPPDATA` there, alongside `Set-DFTestXdg`.
- Mocked: `Get-Process`, `Remove-DFItemToBin`. No test touches the real Recycle Bin or real processes.
- Cases: every state-table row; same-path and nested-path skip; empty folders; conflict blocks every
  activation step and a requiring tool; one warning per load; `Register-DFTool -Name` path;
  `-Adopt`; `-Move` happy path; each check failing (target not empty, running, path in a file, path
  in PATH, `move: false`), with nothing changed; hash mismatch removes staging; locked removal then
  retry next load; changed target on retry warns; `-Done`; `-WhatIf` changes nothing; repeat runs;
  corrupt `ownership.json`; an owned tool makes no file-system calls; the declaration test.

## Docs

- `docs/guide/configuration.md`: "When DotForge finds your existing config" (states, the warning,
  `-Move`/`-Adopt`/`-Done`, what a move checks, Recycle Bin, outside-PowerShell note).
- Troubleshooting rows in the same page; `Resolve-DFToolConflict` comment-based help; reference
  regenerated; `docs/guide/writing-a-tool.md`: the `xdg.native` field; CHANGELOG; TODO: T-61 removed.

## Work split

- Coordinator: schema and normalization, `Find-DFToolConflict`, activation, ownership state,
  `Resolve-DFToolConflict`, tests, docs.
- Worker (reviewed entry by entry): `xdg.native` for each relocating tool, with a source link per path
  in its report, and `move: false` + guide for rustup/cargo and vcpkg.
