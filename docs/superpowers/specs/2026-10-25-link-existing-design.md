# Existing tools keep their data; DotForge links to it

**Status:** design, for review. 2026-10-25. Piece 6 of the restore notes (the link fallback);
resolves T-83.
**Context:** `docs/superpowers/specs/2026-10-24-restore-install-locations-notes.md` (Decided: the
link fallback; Decision 5), `docs/superpowers/specs/2026-10-11-config-ownership-design.md` (the
Conflict state this replaces in part).

## Why

When a requested tool already has config or data in its own default place, DotForge leaves it
inactive (Conflict) until the user moves or adopts it. Moving is the wrong default: programs started
outside a DotForge session still use the old place and see it empty, a manager that owns the place
(scoop's persist folder) recreates it and loses track of the data, and an uninstall leaves the moved
copy behind. The user's rules (2026-10-25):

- never fight a package manager, and the session never contradicts the desktop;
- everything findable from the XDG folders;
- for a tool already installed, whatever installed it (scoop, winget, a download): leave its data
  where it is and link the XDG folder to it.

A tool DotForge installs itself gets its variables before the install (piece 3), so its data lands in
the XDG folders natively. Links are for what was there before.

## Goals

- At registration, for each config, data or state location of a requested tool: if the tool's data
  already exists somewhere else and the XDG location is empty, DotForge leaves the data there, does not
  set the variable that would hide it, and links the XDG location to it. The tool is Active at once.
- Locations come from what DotForge already knows, never from detecting which manager installed the
  tool: a variable already set outside DotForge (scoop's `env_set`, the user), or the record's known
  locations (`xdg.native`).
- Only when both places hold content is the tool a Conflict; `Resolve-DFToolConflict -Adopt` then
  keeps the existing data and links to it.
- Every link DotForge makes is recorded, shown in the tool's status, removed with the tool, and
  cleaned up when its target is gone.

## Non-goals

- Reinstalling a tool through DotForge to get a clean layout (dropped by the user: too risky for
  data). The docs say how to do it by hand.
- Detecting which manager installed a tool (not needed: where the data is decides).
- Desktop variables for programs outside DotForge sessions: T-78.
- Warning at first run about a tool installed from a source its record avoids: a new TODO item; it
  could come from the location (a link target under `$SCOOP`), but that's its own small design.

## Anti-goals

- Moving or deleting the user's data. DotForge never moves anything any more.
- Replacing anything at an XDG location. An occupied XDG location is never overwritten.
- A cache location under `~/.cache` pointing into another folder (a cache cleanup could follow it).

## Decided (the user's, 2026-10-25)

1. **Link is the default for pre-existing data**, made automatically at registration.
2. **No manager detection.**
3. **`-Adopt` means "keep the existing data and link to it"; `-Link` is not a separate option.**
4. **`-Move` is dropped**, and with it `-Done` and the retried removals (`Invoke-DFPendingRemoval`).
   `Resolve-DFToolConflict` hasn't been released, so nothing breaks for users.
5. **A single-file location** gets a file symlink when Developer Mode is on (the bootstrap turns it
   on); otherwise the tool's status says where the file is and that Developer Mode lets DotForge link
   it.
6. **Never link caches.**

## Design

### What gets linked

`Get-DFToolRelocation` already lists a tool's relocated config, data and state paths (its `xdg.vars`,
seeds and native target keys). For each one whose XDG template is not under `${XDG_CACHE_HOME}`:

1. **The existing location** is, in order:
   - the variable's current value, when it was set outside DotForge (`Set-DFEnv` keeps it; scoop's
     `env_set` for fnm, uv, bun, bat, rustup, oh-my-posh) and differs from the XDG path;
   - else the first `xdg.native` path for that key that has content (`Test-DFPathHasContent`).
2. **The XDG location** is the expanded template.
3. If an existing location was found and the XDG location is empty (missing, or an empty folder):
   link the XDG location to the existing one, don't set that variable (the tool keeps its default, or
   the outside value stays), and don't seed that file. Status: Active, with a detail line per link,
   e.g. `linked ~\.local\share\bitwarden → ~\scoop\persist\bitwarden-cli\bw-data`.
4. If both hold content: Conflict, as today, advising `Resolve-DFToolConflict <tool> -Adopt`.
5. If no existing location was found: today's behavior (set the variable; the tool creates its data
   in the XDG location).

A cache variable is set to the XDG cache as today; an old cache is only noted ("delete it to free the
space"), as the `block: false` notes do now.

### Links

- A folder gets a directory junction (no admin, no Developer Mode). A file gets a file symlink when
  Developer Mode is on, else the status note (decision 5).
- The link's parent folder is created through `New-DFDirectory`.
- Made idempotently at registration: an existing correct link is left alone.
- Recorded in `$XDG_STATE_HOME\dotforge\links.json`: tool → [{ path, target }]. DotForge removes only
  links it recorded.
- `Remove-DFTool` removes the tool's links (the link only, never the target).
- A recorded link whose target is gone (the tool was uninstalled) is removed at registration, with a
  status note; the tool then behaves as a fresh one.
- Removing a junction must never touch its target: use the .NET directory delete on the link itself,
  never a recursive delete.

### Records

- `xdg.native` keeps `paths` and `guide`. `move` and `block` retire (nothing moves; whether a
  location is linked depends only on its kind): the schema rejects them, and records drop them.
- `Get-DFNativeRoot` gains `${SCOOP}` (the `SCOOP` variable; unset → that path is skipped), so a
  record can name a location a manager keeps beside the program.
- **bitwarden** (resolves T-83): `xdg.method: env`, `BITWARDENCLI_APPDATA_DIR = ${XDG_DATA_HOME}/bitwarden`,
  native paths `${SCOOP}/persist/bitwarden-cli/bw-data` and `${APPDATA}/Bitwarden CLI`. A fresh install
  uses the XDG folder; an existing vault from scoop or winget stays where it is, linked.

### `Resolve-DFToolConflict`

Only `-Adopt` remains (and the interactive walk with no name, which now offers Adopt or Skip). For
each location where both places hold content, `-Adopt` renames the XDG copy aside
(`<name>.dotforge-moved`, never deleted; refused with nothing changed if it can't be renamed, e.g. a
file in use), then links as above. Ownership entries already in `ownership.json` (from development
builds) keep meaning "DotForge owns it; use the XDG location".

### Status and docs

`Get-DFToolStatus` shows a tool's links in its detail. The docs (`docs/guide/safety.md` "Relocated
tool data", the config-ownership guide text) explain: existing data is linked, not moved; for
everything natively in the XDG folders, uninstall the tool the way it was installed and install it
with `Install-DFTool` (by hand; DotForge doesn't do it).

## Startup cost

The native-path checks already run (`Find-DFToolConflict`). New per load: reading `links.json` once
and a `Test-Path` per recorded link. Measure with the startup benchmark before and after.

## Tests (with sentinel XDG folders; no real tool runs)

- Existing data at a native path, empty XDG → junction made, variable not set, recorded, Active, status
  detail; a second registration changes nothing.
- A variable set outside DotForge pointing elsewhere → link to its value.
- Both hold content → Conflict; `-Adopt` renames the XDG copy aside and links; a rename that fails
  changes nothing.
- A cache variable never links.
- A single file: symlink with Developer Mode, status note without (mock the Developer Mode check).
- `${SCOOP}` paths expand from the variable and are skipped when it is unset.
- Target gone → link removed and noted; `Remove-DFTool` removes links and leaves targets; removing a
  junction never deletes the target's files.
- Schema rejects `move` and `block`; bitwarden record shape.

## Left to the builder

Helper names; whether links live in `links.json` or `ownership.json`; the exact status texts; how the
Developer Mode check is read.
