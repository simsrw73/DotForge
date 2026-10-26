# Desktop variables (T-78)

Piece 7 of the restore work (`2026-10-24-restore-install-locations-notes.md`, Phase 2, Decision 2).

## Why

Some tools are started outside pwsh: komorebi at sign-in, the Claude desktop app, editors. They only
see variables in the Windows user environment (`HKCU\Environment`), not the ones DotForge sets in each
shell. Today chezmoi's `run_before_05-user-env` script keeps a hand-written list of them, so a tool's
knowledge lives in two places and drifts. The tool's record should say which of its variables desktop
apps need, and DotForge should write them, but only when the user asks, because writing the Windows
environment reaches outside DotForge's sphere.

## Goals

- A record **suggests** desktop variables; nothing is written until the user runs a command.
- One home per variable: the record's existing `xdg.vars` or `env` entry gives the value.
- The user sees in `Get-DFToolStatus` which suggested variables desktop apps don't have yet.
- DotForge removes only what it wrote, and only while the value is still what it wrote.
- komorebi gets a record that uses it; `KOMOREBI_CONFIG_HOME` then leaves chezmoi's script.

## Non-goals

- Nothing is written during a shell load, ever.
- The bootstrap set (XDG folders, `SCOOP`, `GNUPGHOME`) stays in bootstrap and chezmoi: DotForge
  isn't installed yet when they are needed.
- The Claude variables (`CLAUDE_CONFIG_DIR`, `CLAUDE_CODE_GIT_BASH_PATH`) move in piece 9, with the
  Claude Code record. They stay in chezmoi until then.
- No config key: running the command is the opt-in.
- whkd (`WHKD_CONFIG_HOME`) and komorebi's own setup (autostart, bar): not part of this piece.

## Anti-goals

- Overwriting a variable the user (or scoop's `env_set`) set to something else without asking.
- Removing a variable DotForge didn't write, or one the user has since changed.
- Slowing the shell load measurably.
- A link from an XDG folder to the user's whole home folder.

## Decided (the user's)

1. **The opt-in is running the command.** `Set-DFDesktopEnv [-Name <tool>,...]` lists what it will
   write and asks once (`SupportsShouldProcess`, so `-WhatIf` and `-Confirm` work). The restore calls it.
2. **A variable already set to a different value:** in an interactive console, ask per variable (keep
   yours / replace); otherwise keep it, and the command's output says which it left alone and why.
3. **Status note.** A requested tool whose suggested desktop variable is missing from (or differs in)
   the Windows environment gets a note in `Get-DFToolStatus`: e.g. *"KOMOREBI_CONFIG_HOME isn't set
   for desktop apps; Set-DFDesktopEnv komorebi sets it."* No warning at the end of the load.
4. **Scope:** komorebi now; Claude in piece 9.

## Design

### Record declaration

A top-level `desktop` list names variables the record already defines in `xdg.vars` or `env`:

```json
"desktop": ["KOMOREBI_CONFIG_HOME"]
```

The value is that entry's, expanded the same way as in the session (`Expand-DFXdgPath`). A name not
defined in `xdg.vars`/`env` is a schema error (`Test-DFToolSchema`). Normalized to `[]` when absent.
Regenerate the registry and reference.

### `Set-DFDesktopEnv`

- **Which tools:** `-Name` (any record), else the session's requested tools (`Tools`, installed or
  not, so a restore can set them before installing).
- **Per variable:**
  - absent from `HKCU\Environment` → write it;
  - equal to DotForge's value → nothing to write; recorded as DotForge's (my call: the value is the
    same, so DotForge may remove it with the tool later; this is also what happens to the komorebi
    value chezmoi wrote once chezmoi stops managing it);
  - different → decision 2.
- **Writes** go to `HKCU\Environment` with `Set-ItemProperty` (no per-call broadcast), then one
  `WM_SETTINGCHANGE` broadcast (`SendMessageTimeout`, `SMTO_ABORTIFHUNG`, 2 s), only when something
  changed. The registry write and the broadcast sit behind private seams that tests mock: no test
  touches the real user environment.
- **Records** what it wrote in `$XDG_STATE_HOME\dotforge\desktop-env.json`: variable → `{ tool, value,
  since }`.
- **Output:** one result per variable (`Tool`, `Name`, `Value`, `Action`: `Set`, `AlreadySet`, `Kept`
  (yours, left alone), `Replaced`), and a line saying new programs see the change; already running
  ones don't.
- **Non-Windows:** says it's Windows-only and does nothing.
- It is an explicit command, so it lives in an on-demand module (`DotForge.Helpers`).

### Removing

- `Remove-DFTool` removes the tool's desktop variables DotForge recorded, each only if its current
  value still equals the recorded one (otherwise left, and said so), then broadcasts once.
- `Remove-DFDesktopEnv [-Name <tool>,...]` does the same without removing the tool (my call: the way
  back out of the opt-in). Both read and update `desktop-env.json`.

### Status note

At load, for each requested tool with `desktop` entries, compare the expected value with the value in
`HKCU\Environment`. Reading the registry directly (one value per declared variable) is my call: the
process environment can't tell a desktop value from one a parent DotForge shell set. Only records with
`desktop` pay for it; measure with the startup benchmark. A missing or different value adds the note
(decision 3); a value the user keeps on purpose (`Kept`) still shows, worded as *"desktop apps see
KOMOREBI_CONFIG_HOME = <theirs>"*, so the status always says what desktop apps get.

### komorebi record

- `Tools/komorebi.json`: executable `komorebic`, packages scoop (`komorebi`, extras bucket) and winget
  (`LGUG2Z.komorebi`) (ids checked when built), `xdg.method: env`, `KOMOREBI_CONFIG_HOME =
  ${XDG_CONFIG_HOME}/komorebi`, `desktop: ["KOMOREBI_CONFIG_HOME"]`.
- `xdg.native`: komorebi's default config folder is `$HOME` itself. The native paths are therefore
  the files (`${HOME}/komorebi.json`, `${HOME}/applications.json`, `${HOME}/komorebi.bar.json`), never
  `${HOME}`: an XDG folder must never be linked to the home folder. The builder adds a guard in
  `Find-DFToolConflict` so a native path equal to a native root (`$HOME`, `%APPDATA%`, …) is never a
  link target, whatever a record says.
- Your `~\.config\komorebi` is a junction chezmoi made; DotForge leaves it as it is (it is the XDG
  location, and nothing in `$HOME` competes with it).

### The dotfiles side (after a Gallery release)

- Drop `KOMOREBI_CONFIG_HOME` from `run_before_05-user-env` and its list in `tests/Dotfiles.Tests.ps1`.
- Add `komorebi` to the profile's `Tools`, and have the packages script call `Set-DFDesktopEnv
  -Confirm:$false` after DotForge is installed and configured.

The existing `HKCU` value stays when chezmoi stops writing it, so komorebi never goes without it.

## Left to the builder

- Function layout, names of private seams, the exact interactive prompt wording.
- Registry value kind: keep the existing kind when replacing; new values as `REG_SZ`.
- Builtin-safety check for `Set-DFDesktopEnv` / `Remove-DFDesktopEnv` (no aliases planned).
- Docs: `docs/guide/configuration.md` (a "Desktop apps" section), `writing-a-tool.md` (`desktop`),
  `tools.md` (komorebi), CLAUDE.md schema line, CHANGELOG, restore notes, TODO (close T-78).
