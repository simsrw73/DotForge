# Directory jump: Alt+C and broot (T-68)

Status: draft, 2026-10-17. Follows the fuzzy-finders batch
(`docs/superpowers/specs/2026-10-17-fuzzy-finders-design.md`), whose key-role machinery it reuses.

## Goal

Alt+C is a TUI version of `cd`. You get a fuzzy list of folders (or browse them in broot), pick
one, and the shell moves there. This batch:

1. adds a `directory-jump` role that owns Alt+C;
2. gives it a list that is useful from any folder, even `$HOME`;
3. brings broot through the whole tool contract, as a member of that role;
4. fixes today's Alt+C, which fails with "The term 'z' is not recognized" on every pick.

File managers (yazi, superfile, lf, …) join the role in the next batch (T-35). This design must let
them join without changing the role.

## What the user said

- "The directory-jump role is for tools that allow you to navigate the filesystem and exit leaving
  you in the directory you navigated to. Most tools in that role can do much more than that, but
  that is the role: basically a TUI version of the `cd` command."
- Make it available "for people who do use it with the most popular implementation".
- Today, opening Alt+C in the home folder is bad: "it never completes scanning for files before I
  select anything".
- "Load a complete list of directories with zoxide-graded directories at the top of the list."
  Scan breadth-first, or with a depth limit.
- The scan starts from the **current folder**, to **depth 6**.
- Returning a picked folder's path into the command line is Ctrl+T's job (`path-insert`), not this
  role's.
- Include broot in this batch.

## Why it's broken today

`Tools/zoxide.ps1` runs `zoxide init --cmd cd`, so zoxide defines `cd` and `cdi`; no `z` exists.
`Tools/PSFzf.ps1` sets PSFzf's `-AltCCommand` to a block that calls `z $Location` whenever
`zoxide.exe` is on PATH. Every Alt+C pick throws. PSFzf's own Alt+C also scans the current folder
with fd, so it never finishes in a large tree before you pick.

## The role: `directory-jump` (new, single)

- Defined in `data/roles.json`, keyed by role, with hook `Initialize-DFRoleDirectoryJump`.
- It binds Alt+C only through `Set-DFRoleKeyHandler`, like `history-search` and `path-insert`, so a
  user's own Alt+C binding is kept unless `Defaults` names a tool for the role.
- `Set-DFRoleKeyHandler` and `Register-DFFuzzyKeyHandler` are its reserved code (only in role hooks).

**Members and default order** (my call, from "the most popular implementation"):

| Member | Priority | What Alt+C does |
|---|---|---|
| fzf | 10 | DotForge's folder list, shown in fzf |
| skim | 5 | DotForge's folder list, shown in sk |
| broot | 3 | broot opens in the current folder, folders only; leaving with a cd moves the shell |

**PSFzf is not a member** (my call). PSFzf requires fzf, so fzf is always requested alongside it
and wins; there is no fallback member for the edge case where fzf's hook fails. Its own Alt+C can't put zoxide's folders first, and PSFzf
needs fzf anyway, so fzf's member gives the same picker with the better list. `Tools/PSFzf.ps1`
imports PSFzf with `''` for Alt+C too (it already does for Ctrl+R and Ctrl+T), and drops the
`-AltCCommand` override. A user who wants PSFzf's own Alt+C binds it themselves; DotForge then
keeps that binding. Alt+A (PSFzf's history-arguments picker) stays as it is.

television isn't a member for now: it has no "cd to a folder" binding of its own. It can join later
through the same shared handler.

## The folder list (fzf and skim)

The shared handler (`Private/Register-DFFuzzyKeyHandler.ps1`) gains a third key, `Directory`, next to
`History` and `Path`. `Register-DFFuzzyKeyHandler -Engine <exe> -Key Directory -Tool <name>` binds
Alt+C. On a key press:

1. **zoxide's folders first.** When zoxide wins `navigation` this session, its declared
   `directories` command (`zoxide query --list`; most-used and most recent first). zoxide reads only its database, so these appear at once. If zoxide is missing or
   fails, this part is empty and nothing else changes.
2. **Then the scan streams in.** Breadth-first from the current folder, one depth at a time
   (everything 1 deep, then 2 deep, …), up to depth 6. Folders near you show up within a moment,
   even in `$HOME`, and the deep ones keep arriving while you type.
   - With fd requested: its declared `directoryScan` (`fd --type d --exact-depth N`) for N = 1..6,
     which keeps fd's defaults (hidden folders and what `.gitignore` excludes are skipped).
   - Without fd: the same depths through `Get-ChildItem -Directory`, skipping hidden folders.
3. **No folder twice.** A scanned folder that zoxide already listed is dropped. Folders are compared
   case-insensitively, by their full path.
4. **The order holds.** With an empty query the list shows in input order: zoxide's ranking, then
   nearest first. Once you type, the engine ranks by match, and equal matches keep input order
   (`--tiebreak=index`), so a folder you use often beats an equally good deep one.
5. **How folders are shown** (my call): zoxide's entries as full paths with `$HOME` shown as `~`;
   scanned folders relative to the current folder (`src\lib`). The handler maps each shown line back
   to its real path; it never re-parses what the engine returns as a path of its own.
6. **Moving there.** The picked folder is entered through the navigation winner's declared `enter`
   command (zoxide's `cd`, so the pick counts toward its ranking), else `Set-Location`. The path is
   passed as one argument value, never built into a command string. Then the prompt is
   redrawn. The line you were typing is kept. Cancel (Esc) changes nothing.

**Where the list and the cd come from** (my call: a declarative extension point, so no core
file names zoxide or fd; `docs/plugin-architecture.md`). Two new optional fields in role blocks,
normalized by `ConvertTo-DFToolRecord`, validated by the schema and listed in the role contract:

- In a `navigation` role block:
  - `"directories"`: an argv that prints ranked folders, one per line;
  - `"enter"`: the command that moves the shell to a folder.
  - `Tools/zoxide.json` declares `["zoxide", "query", "--list"]` and `"cd"`. That's the `cd` that
    `--cmd cd` defines.
  - Only the session's `navigation` winner is read. A zoxide that's installed but not requested is
    left alone, as with every other opt-in tool.
- In a `file-search` role block:
  - `"directoryScan"`: an argv with `{depth}`, which lists folders exactly that deep.
  - `Tools/fd.json` declares `["fd", "--type", "d", "--exact-depth", "{depth}"]`.
  - The first requested member that declares it is used.
  - With none, the scan falls back to `Get-ChildItem -Directory`.
- **Leaving the cd unset:** with no `enter`, `Set-Location` moves the shell. A future navigation tool
  joins by declaring these two fields, with no core change.

Streaming matters. The engine must get the first lines before the scan finishes: the list is
produced as a pipeline, not collected first. `Invoke-DFFuzzyEngine`'s UTF-8 handling (from the last
batch) applies to it as well.

**Settings** (my call): `DirectoryJumpDepth` (default 6) in `$script:DFConfigKeys`, read with
`Get-DFConfig`. Nothing else is configurable in this batch.

`fzo` (zoxide's picker, zoxide's list only) and `cdi` (zoxide's own interactive cd) stay as they are.

## broot (`Tools/broot.json`, `Tools/broot.ps1`, `Tools/broot.setup.ps1`)

broot today is a stub: install and a config folder. This batch gives it the whole contract.

- **XDG:** `env` method, `BROOT_CONFIG_DIR = ${XDG_CONFIG_HOME}/broot`. `xdg.native` lists broot's
  own default config folder on Windows (`%APPDATA%\dystroy\broot\config`, to verify), so a user's
  existing config is found and the tool waits for `Resolve-DFToolConflict` as usual.
- **Default config:** seeded once (`setup.seed`) as `conf.hjson` and `verbs.hjson`, taken from
  `broot --write-default-conf` (broot 1.61), with one change: the skin import points at DotForge's
  skin (below). broot's own defaults are kept otherwise.
- **Theme:** catppuccin in four flavors, `Tools/broot/catppuccin-{latte,frappe,macchiato,mocha}.hjson`,
  generated by `build/New-DFCatppuccinThemes.ps1` from `build/catppuccin-palette.psd1`, with the
  license file. broot ships only mocha and macchiato. Key `BrootTheme`, following `Theme`.
  - **Preferred:** `br` passes the theme's skin after the user's config,
    `--conf "<BROOT_CONFIG_DIR>\conf.hjson;<skin>"`, so `Set-DFToolTheme` works live.
  - **Fallback**, if the second file doesn't win over the first file's skin import: seed the skin
    import once (like television) and add a setup note to change it in `conf.hjson`.
  - The probe decides between them (see Probes).
- **`br`** (a global function in `Tools/broot.ps1`, with full comment-based help). It runs
  `broot --outcmd <temp file> <your args>` in the current folder. When broot exits with a cd, `br`
  reads **only** the target folder from that file and enters it, through the same "moving there"
  step as the folder list. It never runs the file's content (broot's stock `br` runs it with
  `Invoke-Expression`). Anything other than a cd in the file is ignored, with a verbose message. The
  temp file is always removed. `br` isn't a PowerShell built-in (check against `Get-Command` before
  shipping, per the builtin safety policy).
- **broot's first-launch prompt:** broot asks to install its `br` on first run. The one-time setup
  script runs `broot --set-install-state installed`, so the prompt never shows, and adds a setup note
  saying that DotForge provides `br`.
- **Role:** `directory-jump` priority 3. When broot wins, its hook binds Alt+C (through
  `Set-DFRoleKeyHandler`) to run broot with `--only-folders`, then redraws the prompt. The line being
  typed is kept, as with fzf and skim.
- **One helper, two callers** (my call). `br` and the Alt+C handler share one helper. It runs broot
  with `--outcmd`, reads the target folder, and enters it through the shared "moving there" step.
  `br` is a `function:global:` and reaches it through a captured scriptblock (CLAUDE.md).
- **Completions:** `Tools/carapace/specs/broot.yaml` exists already; check it against broot 1.61's
  flags.
- **Aliases and pickers:** `br` is the only command. No picker.
- Record the outcmd format and the install-state file in `docs/external-dependencies.md`.

## Testing

- **Shared handler:**
  - zoxide entries come first.
  - The scan runs breadth-first and stops at `DirectoryJumpDepth`.
  - Duplicates are dropped, and comparison ignores case.
  - It works without zoxide and without fd.
  - A pick enters the real path through the navigation `cd`, else `Set-Location`.
  - Cancel changes nothing.
  - Names with spaces, quotes or `$` reach `Set-Location` as one literal path, never parsed as code.
- **Streaming:** the first item reaches the engine before the scan ends. Use a fake scan that blocks
  after its first line, and an engine stub that records when it got that line.
- **Role:**
  - Only the winner binds Alt+C.
  - A user's own Alt+C is kept.
  - `Defaults` overrides it with a warning.
  - PSFzf no longer binds Alt+C at import.
- **broot:**
  - XDG variable, seeds, theme selection.
  - `br` reads a cd from a sample outcmd file and runs nothing else from it, including a hostile file
    such as `cd x; Remove-Item …`.
  - The setup script runs `--set-install-state` once and adds the note.
- **Regression:** Alt+C with zoxide initialized as `--cmd cd` never calls `z`.
- **Real binaries**, by hand before merge: fzf and sk from `$HOME` show folders within ~0.5 s; real
  broot `br` moves the shell; real broot honors the skin.

## Probes (the plan's first task)

My call: they run on this machine at the start of the plan. They don't block the plan. The plan
offers both branches where an answer changes the work (the theme approach). broot writes real
AppData, so each probe lists those folders before and after, and removes only what it created.

1. broot's default config folder on Windows (for `xdg.native`), and where `--set-install-state`
   writes, which may be outside `BROOT_CONFIG_DIR`.
2. The exact outcmd format broot 1.61 writes for a cd on Windows (quoting of spaces and quotes).
3. Whether `--conf "a;b"` lets `b`'s `skin` override a skin that `a` imports. This decides the theme
   approach above.
4. Whether PowerShell streams pipeline output to fzf's stdin line by line, or the handler needs its
   own writer for the first lines to arrive early.

## Probe results (2026-10-17, broot 1.61.0, fzf, pwsh 7)

1. **Folders.**
   - broot's default config folder on Windows is `%APPDATA%\dystroy\broot\config`, which goes in
     `xdg.native`.
   - The install state is a file, `<config>\launcher\installed-v5`. It follows `BROOT_CONFIG_DIR`,
     so nothing is written outside the XDG folder.
   - broot writes `conf.hjson`, `verbs.hjson` and `skins\` into an empty config folder on its first
     run.
2. **outcmd.**
   - The file must exist before broot runs (`New-TemporaryFile` does that); a missing one fails
     with "The system cannot find the file specified".
   - A cd is one line, `cd '<path>'` plus a newline, quoted the POSIX way: a `'` inside the path is
     written `'"'"'` (`cd 'C:\x\it'"'"'s'`). Spaces and `[1]` stay as they are inside the quotes.
   - PowerShell can't parse the `'"'"'` form, so broot's stock `br` (`Invoke-Expression`) breaks on
     such folders. DotForge's reader unquotes it as a POSIX shell would.
3. **Skin.** **Live.** With `--conf "<conf>;<second>"`, the second file's `skin` wins over the skin
   the first one imports. The folder color changed from the skin's to `rgb(255,0,0)`. `br` passes
   the theme's skin file second.
4. **Streaming.** A PowerShell pipeline streams to a native process's stdin line by line: the first
   line arrived 3 ms after the start, while the generator still slept. No extra writer is needed.

## Out of scope

- File managers (yazi, superfile, lf, mc, ranger, vifm): next batch. They join `directory-jump` the
  way broot does: a command that browses, and a cd taken from what it writes when you quit.
- television as a member.
- Inserting a folder's path into the command line (that's Ctrl+T).
- Configurable scan roots or excludes beyond fd's defaults.

## TODO

Closes T-68. Update `TODO-Tools.md` (directory-jump done; broot's gap closed) and the T-35 note.
