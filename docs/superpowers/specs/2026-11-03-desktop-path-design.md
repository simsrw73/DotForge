# Desktop Path entries (T-90)

Extends the desktop-variables design (`2026-10-26-desktop-variables-design.md`, T-78). Read that
first: this design reuses its commands, its state file and its seams, and changes one of its rules.

## Why

Desktop apps (Orca, editors, agent launchers) that run `npx`, `npm` or a global npm package (`codex`,
`gemini`) don't start from pwsh, so they never see the `PATH` DotForge builds in each shell. They see
only the Windows user `PATH` (`HKCU\Environment`) after the system `PATH`. On 2026-11-03 the user had to
add fnm's folder to the user `PATH` by hand to get Orca working, and nearly added a per-shell
`fnm_multishells\<pid>` folder, which stops working when its shell closes.

The right folder is `$XDG_DATA_HOME\fnm\aliases\default`: a junction fnm points at the default Node
version (`fnm default`). With fnm, `npm install -g` puts each package's launcher in that same folder,
so this one entry gives desktop apps Node, npm, npx and every global package, and it follows
`fnm default` with no rewrite.

A tool record should be able to say "desktop apps need this folder on the `PATH`", and DotForge should
add it only when the user asks, the same way `desktop` works for variables.

## Goals

- A record declares the folders desktop apps need on the user `PATH` (`desktopPath`).
- `Set-DFDesktopEnv` adds them; `Remove-DFDesktopEnv` and `Remove-DFTool` remove them. Same opt-in,
  same `-WhatIf`/`-Confirm`, same state file, same single broadcast.
- When another copy of a command the folder provides is already on the `PATH`, the user is told and,
  in an interactive console, chooses where the entry goes.
- `Get-DFToolStatus` says when the folder is missing or skipped. (Another copy winning is reported by `Set-DFDesktopEnv` only; see Status note.)
- fnm declares its folder.

## Non-goals

- The system (machine) `PATH`: it needs elevation and changes every account. User `PATH` only.
- Other tools' folders (mise shims, npm's `%APPDATA%\npm` for a non-fnm Node, scoop shims). The field
  is generic and they can declare it later; this piece ships fnm's only.
- Nothing is written during a shell load, ever (unchanged from T-78).
- The session `PATH`: `Add-DFToPath` stays the only way DotForge changes it. This design never
  touches the process `PATH`.
- Unifying DotForge's two prompt styles (`(Enter: x)` vs `[a/b] (Enter = x)` in `Install-DFTool`):
  a separate TODO if wanted.

## Anti-goals

- Moving, changing or removing a `PATH` entry DotForge didn't add, including one already present
  when the command runs.
- Expanding or retyping the user's `PATH`: it is `REG_EXPAND_SZ` and its entries may hold
  unexpanded `%VARIABLES%`. `[Environment]::SetEnvironmentVariable` silently does both; never use it.
- Silently putting a second copy of a command on the `PATH` without saying so.
- Slowing the shell load measurably.

## Decided (the user's)

1. **User `PATH`, for fnm's default folder** (which covers global npm packages).
2. **Opt-in is running the command**, as for variables: `Set-DFDesktopEnv`, never at load. DotForge
   records each entry it adds, removes only those, and never touches entries the user added.
3. **Ownership policy, for variables and `PATH` alike: whatever is already there is the user's.**
   DotForge records only what it actually wrote. It never moves, changes or removes anything else
   without permission. This **changes T-78's rule**: a variable already set to DotForge's value
   (`AlreadySet`) is reported but **no longer recorded** as DotForge's (see Changes to T-78).
4. **Another copy of a command, interactive console:** ask where to put the entry (before / after the
   other copy, or skip). The prompt follows DotForge's existing prompt style (below).
5. **Another copy, no one to ask** (non-interactive host, `-Confirm:$false`): add the entry at the
   **end** of the user `PATH` and say in the output which copy comes first.
6. **Fresh-PC case only.** When the tool's own variable (fnm's `FNM_DIR`) isn't DotForge's value,
   skip the entry and say why; the other starting points belong to T-91.

## Design

### Record declaration

A new top-level field, a list of entries:

```json
"desktopPath": [
  { "path": "${XDG_DATA_HOME}/fnm/aliases/default", "commands": ["node", "npm", "npx"] }
]
```

- `path` (required): a path template, expanded through `Expand-DFXdgPath` and `ConvertTo-DFPath`,
  the same as `xdg.vars` values. Allowed roots are the ones `Expand-DFXdgPath` already knows.
- `commands` (optional, default `[]`): command names (no extension) the folder provides. They drive
  the other-copy check. Only these are checked, never everything in the folder: the user's `PATH`
  holds `OpenAI.Codex` from winget, and a full scan would flag npm's `codex.cmd` as noise.
- Schema (`Test-DFToolSchema`): `desktopPath` must be a list of objects with a string `path`;
  `commands` a list of strings. `Path` (any case) in the existing `desktop` variable list becomes a
  schema error: the `PATH` is managed only through `desktopPath`.
- Normalized to `[]` when absent (`ConvertTo-DFToolRecord`). Regenerate the registry and reference.
- `Tools/fnm.json` gets the entry above. (`fnm.json` already declares `"desktop": ["FNM_DIR"]`.)

### Reading and writing the user `PATH`

New private helpers in `Shared/DFDesktopEnv.ps1`, through the existing key seam
(`Get-DFDesktopEnvKey`, so tests use the scratch key):

- **Read** the user `Path` value with `DoNotExpandEnvironmentNames`; split on `;`, dropping empty
  segments only for comparison, never when writing back.
- **Write** keeps the value's existing kind (`ExpandString` stays `ExpandString`; a new `Path` value
  is created as `ExpandString`) and every other segment byte-for-byte, including `%VARIABLES%`,
  trailing separators and the user's order. Only the one segment is inserted or removed.
- **Match** a segment to DotForge's folder by expanding it the way desktop apps see it
  (`Expand-DFDesktopEnvValue`), then comparing canonically (`ConvertTo-DFPath`), case-insensitively.
- **Links count as the same folder** (my call, from the builder check). fnm reaches one `node.exe`
  through the `aliases\default` junction, its target `node-versions\<v>\installation`, and each
  shell's `fnm_multishells\<pid>` junction. Both the "already present" match and the other-copy check
  compare the folders' final targets (resolve junctions and symlinks), so a segment that leads to
  DotForge's folder is `AlreadySet`, never "another copy". The cost is one file-system lookup per
  `PATH` segment; if that is too slow at load, the load-time note reports only "missing" (see Status
  note).
- **The written segment** is the expanded canonical folder (my call: variables are written expanded
  too, and a literal path can't be broken by a variable changing).
- **System `PATH`**: read (never written) through its own seam, so tests mock it.
- One `WM_SETTINGCHANGE` for the whole command (`Send-DFEnvironmentChange`), shared with variables.

### Finding another copy

For each name in `commands`, look in every folder of the **system `PATH` then the user `PATH`**
(the order Windows builds a desktop app's `PATH`), excluding DotForge's own folder, for
`<name><ext>` for each extension in the desktop `PATHEXT` (machine/user value; default
`.COM;.EXE;.BAT;.CMD`). Each command reports the first other location found, and whether it is on the
system or the user `PATH`. Folders are expanded as desktop apps see them; a folder that doesn't exist
is skipped. The lookup is a seam tests replace with `$TestDrive` folders.

Placement facts that follow:

- A copy on the **system** `PATH` always wins over anything on the user `PATH`, so "before" isn't
  offered for it.
- "Before" means immediately before the **first** user-`PATH` folder holding another copy.
- If the folder doesn't exist yet (a restore that sets desktop values before installing), it is
  still added (my call: Windows ignores a missing folder, and the restore order then works); the
  other-copy check runs on the commands anyway.

### When the tool's folder isn't DotForge's (the user's decision 6)

This piece covers the fresh-PC case only: the tool lives where DotForge's own variables put it. Every
other starting point (a tool installed before DotForge, a value set outside DotForge, a restore) waits
for the broader design in T-91. Until then, a guard keeps DotForge from adding a folder the tool never
uses:

- An entry **lives under** a variable of the same record when its `path` template starts with that
  variable's `xdg.vars` template (fnm: `${XDG_DATA_HOME}/fnm/aliases/default` lives under
  `FNM_DIR = ${XDG_DATA_HOME}/fnm`). Derived from the record, no new syntax, nothing tool-specific
  in core.
- If that variable's value **in effect** differs from DotForge's, in this shell (a value `Set-DFEnv`
  kept) or for desktop apps (the user `HKCU\Environment` value, including one the user chooses to
  keep in the same run), the entry is not added: `Action` `Skipped`, and a host line says why, e.g.
  `Skipped fnm's Path entry: FNM_DIR is C:\Users\you\.fnm for desktop apps, so fnm's Node isn't under
  C:\Users\you\.local\share\fnm. Add C:\Users\you\.fnm\aliases\default yourself, or let DotForge set
  FNM_DIR.`
- The status note says the same while it holds.
- Variables are planned before `PATH` entries, so a `Kept` answer earlier in the run is seen.

### `Set-DFDesktopEnv`

Same command, same tool selection, same `ShouldProcess` call (`ConfirmImpact = 'High'`); the plan
now holds variables and `PATH` entries, and the `ShouldProcess` text lists both. Per entry:

| Situation | Action | Recorded |
|---|---|---|
| Already on the user `PATH` (anywhere) | `AlreadySet` | **no**: it's the user's |
| Missing, no other copy | `Set` (appended) | yes |
| Missing, other copy, interactive | the user's choice: `Set` before / after, or `Skipped` | if added |
| Missing, other copy, no one to ask | `Set` (appended), and the output names the copy that comes first | yes |

"Interactive" is the existing test (`Test-DFConflictPrompt`, `$ConfirmPreference -ne 'None'`, not
`-WhatIf`). With `-WhatIf` nothing is asked and the plan assumes the end of the `PATH`.

**The prompt**, in the style of `Read-DFDesktopEnvChoice` and `Read-DFConflictChoice` (two leading
spaces, the facts, bracketed key letters, `(Enter: <default>)`, first letter matched
case-insensitively). One line per other copy, then one question:

```
  node is also at C:\Users\you\.local\share\scoop\apps\nodejs-lts\current (user Path).
  Put fnm's folder [B]efore it, [A]fter it or [S]kip (Enter: After)
```

```
  node is also at C:\Program Files\nodejs (system Path), which desktop apps find first whatever the user Path order.
  [A]dd fnm's folder anyway or [S]kip (Enter: Add)
```

Enter gives the same answer as an unattended run (the end of the `PATH`). When several commands
find the same other folder, it is listed once. When both kinds exist, the system-`PATH` wording is
used. The tool name in the question is the record's name.

**Output**: one `DotForge.DesktopEnvResult` per entry, as for variables: `Tool`, `Name` = `Path`,
`Value` (the folder), `Current` (`$null`, or the matching segment as written when `AlreadySet`),
`Action` (`Set`, `AlreadySet`, `Skipped`), plus `Shadowed` (the other locations found, or empty).
For an unattended append that is shadowed, a host line:
`Added C:\...\fnm\aliases\default at the end of the user Path; node at <other> comes first.`

### State file

`desktop-env.json` is keyed by variable name today. `PATH` entries need their own section, and a
variable may itself be named `Path`, so the file becomes:

```json
{ "vars": { "FNM_DIR": { "tool": "fnm", "value": "...", "since": "..." } },
  "path": { "C:\\Users\\you\\.local\\share\\fnm\\aliases\\default": { "tool": "fnm", "since": "..." } } }
```

Reading accepts the old flat form (every top-level key a variable) and the new form; writing always
writes the new form. An unreadable file still stops every write and removal (unchanged). The record
is saved before the registry write (unchanged ordering).

### Removing

`Remove-DFDesktopEnv` and `Remove-DFTool` also remove the tool's recorded `PATH` entries:

- The recorded folder is removed **wherever it now is** in the user `PATH` (the user may have moved
  it; the folder is what DotForge owns, not its position). If it appears more than once, only one
  occurrence is removed (my call: the others were added by someone else).
- Already gone: nothing to do (`Removed`, as variables report today).
- The record is dropped either way; one broadcast if anything changed.
- Output: `DotForge.DesktopEnvResult` with `Name` = `Path`, `Action` `Removed`.

### Status note

`Get-DFDesktopEnvNote` adds, per `desktopPath` entry of a requested tool, on Windows (the second note, "another copy wins", is **`Set-DFDesktopEnv` only**, not load-time; see Measured below):

- missing from the user `PATH`: *"fnm's folder isn't on the desktop Path; Set-DFDesktopEnv fnm adds
  it"*;
- **`Set-DFDesktopEnv` only, not at load:** present, but another copy of a declared command comes first in the desktop `PATH` order:
  *"desktop apps run node from C:\Program Files\nodejs"*;
- present and first: no note.

Cost at load: one read of the user `PATH` per load, only when a requested tool declares `desktopPath`.
The other-copy check probes files in every `PATH` folder, so it runs in `Set-DFDesktopEnv`, not at
load (see Measured).

**Measured (2026-11-05):** `Get-DFDesktopPathNote` for fnm (missing/present checks) averages 3.3 ms over 20
runs; the shadow check (`Find-DFDesktopPathOtherCopy`, probing each system and user `PATH` folder for `node`
and `npm`) averages 167 ms, far over the 5 ms budget. **Choice:** the load-time note covers the guard and
"missing" only; the shadow check is not run at load. It runs in `Set-DFDesktopEnv` only.

### Changes to T-78 (variables)

- `Write-DFDesktopEnvPlan` stops recording `AlreadySet` variables. `Set` and `Replaced` are still
  recorded: DotForge wrote them, `Replaced` with the user's permission.
- `Set-DFDesktopEnv`'s `ShouldProcess` text for the nothing-to-write case changes from "nothing to
  write; record what is already set" to "nothing to write"; when nothing is to be written and
  nothing asked, the command needn't call `ShouldProcess` at all (builder's call).
- Records written under the old rule stay as they are (my call: the file can't tell which ones
  DotForge really wrote).
- Update the 10-26 spec's "equal to DotForge's value" bullet to point here, and the help text of
  `Set-DFDesktopEnv` ("One already set to the same value is left as it is" gains "and stays yours").

### Docs

- `docs/guide/configuration.md`, Desktop apps: the `PATH` entries, the prompt, the ownership rule.
- `docs/guide/tools.md`, fnm section: replace the manual `PATH` step with `Set-DFDesktopEnv fnm`.
- `docs/guide/writing-a-tool.md`: the `desktopPath` field row.
- `CLAUDE.md`, Tool JSON Schema, `desktop` bullet: one sentence on `desktopPath`.
- Help for `Set-DFDesktopEnv` / `Remove-DFDesktopEnv`: `PATH` entries and the new result fields.
- `CHANGELOG.md`: the feature, and the `AlreadySet` change under Changed.
- `TODO.md`: delete T-90 in the commit that ships it (`Closes T-90`).

### Tests

- No test reads or writes the real user or system `PATH`: the user `Path` lives in the scratch key
  (`DFTestDesktopEnvKey`), the system `PATH` and the command lookup are mocked seams, and the prompt
  is mocked (`Read-…` helper).
- Cover: append; already present (not recorded); `%VARIABLE%` segments and `ExpandString` kept;
  empty/missing `Path` value; other copy on user `PATH` with each answer; system-`PATH` copy;
  unattended append with the note; removal after the user moved the entry; duplicate occurrences;
  old-format state file read and rewritten; schema errors; `AlreadySet` variables no longer recorded;
  a junction segment leading to DotForge's folder (real junctions under `$TestDrive`) is `AlreadySet`;
  the guard skips when the session or desktop `FNM_DIR` differs, including a `Kept` answer in the run.

## Left to the builder

- Function names and file split within `Shared/` and `DotForge.Helpers` (keep the readability rules).
- Exact wording of host lines beyond the prompts and notes above.
- Whether the `Shadowed` field is a string list or objects with `Command`, `Path`, `Scope`.
