# Package-manager preview reorder design

## Goal

The `wins`/`wrm`/`wup` (winget), `sins`/`srm`/`sup` (scoop), and `cins`/`crm`/`cup` (choco) fzf
pickers preview a package by shelling out to that tool's own `show`/`info` CLI command. Each
tool's raw output buries the most useful fields (Description, Publisher, License, Homepage) partway
down a long undocumented text blob. Surface those fields — plus a last-updated date where the tool
exposes one — as a short summary block at the top of the preview, above the tool's full unmodified
output.

## Design

### Preview shell: cmd → pwsh

fzf runs `--preview`/`--bind execute()` commands through a child shell chosen by `--with-shell`
(default on Windows, when unset: `cmd /s/c` — verified against fzf 0.74.3's man page). `Tools/fzf.json`
gains a new `FZF_DEFAULT_OPTS` line:

```
--with-shell='pwsh -NoProfile -Command'
```

This switches every DotForge picker's preview/execute shell to PowerShell 7+, applied globally
(one line in the tool JSON's declarative `env` block — no core code change, no per-tool opt-in).
Verified before adopting:

- `pwsh -NoProfile -Command "<text>"` executes `<text>` as one command when passed as a single
  trailing argv element (confirmed via `ProcessStartInfo`) — matches how fzf constructs the child
  process for any configured shell (`<shell> <flags...> <command-text>`).
- Package identifiers (winget IDs, scoop names, choco IDs) never contain spaces or quote
  characters, so fzf's placeholder substitution (`{1}`, `{2}`, …) needs no shell-specific quoting
  changes to stay correct under the new shell.
- **Fixes a latent bug**: `Tools/oh-my-posh.ps1`'s theme preview embeds its path argument in
  single quotes (`'$themesPath\{}'`). Under `cmd`, single quotes are not a quoting mechanism, so a
  themes path containing a space is silently split into two garbage tokens (reproduced: `cmd /s/c`
  splits `'C:\some path\file.json'` into `['C:\some]` and `[path\file.json']`). Under `pwsh`, the
  same text is one correctly quoted argument (reproduced). No code change needed there — switching
  the shell alone corrects it.
- `Tools/posh-git.ps1` (`git log`/`git show`/`git diff`/`git stash show`) and
  `Tools/ripgrep.ps1` (`bat --color=always --highlight-line {2} {1}`) previews are plain
  external-command strings with no cmd-specific operators (no `>nul`, no `&` chaining) — unaffected
  by the shell change either way.
- `Tools/winget.ps1`/`scoop.ps1`/`choco.ps1`'s existing debounce prefix
  (`ping -n 2 127.0.0.1 >nul &`) is cmd-only redirection/chaining syntax and must be rewritten as
  `Start-Sleep -Milliseconds 1000;` (still ~1s, same purpose: fzf kills the running preview command
  on cursor move, so fast scrolling never runs the real command for skipped items).
- Measured pwsh startup cost: `pwsh -NoProfile -Command "1+1"` averages **~230ms** vs. `cmd /s/c
  "echo hi"` at **~80ms** (5-sample average, this machine). `posh-git.ps1`/`ripgrep.ps1`/
  `oh-my-posh.ps1` previews have no debounce today and re-run on every cursor move; without one,
  switching their shell to pwsh would add that ~150ms delta to every keystroke while scrolling a
  git log or grep result list. Decision: add the same `Start-Sleep -Milliseconds 1000;` debounce
  prefix to those three files' `-Preview` strings too, trading "live" preview-as-you-scroll for
  consistent, lag-free scrolling everywhere.

`-Bind execute(...)` strings (`alt-i:execute(winget install --id {2} --exact)`, etc.) are plain
external-command invocations with no cmd-specific syntax and need no changes.

### Preview content: summary block, not full reorder

`winget show`, `scoop info`, and `choco info` are three different undocumented text formats, and
`choco info` in particular is too irregular to safely restructure as a whole document: every line
carries a uniform one-space indent (no top-level-vs-continuation signal like winget's), some lines
pack two fields on one line (`Title: Git | Published: 2026-08-20`), and some lines contain a colon
incidentally as part of an embedded URL with no real `Key:` prefix at all (`Package url
https://community.chocolatey.org/...` — the first colon in that line is inside `https:`, which a
naive "split on first colon" parser would misread as part of the field name).

Instead of reordering the document, each of three new scripts —
`Tools/winget.preview.ps1`, `Tools/scoop.preview.ps1`, `Tools/choco.preview.ps1` — runs the tool's
real command, pulls out a fixed handful of fields **independently**, each via its own isolated
regex/text scan, and renders whichever fields actually matched as a summary block, followed by a
separator, followed by the tool's complete unmodified output:

| Field | winget (`show`) | scoop (`info`) | choco (`info`) |
|---|---|---|---|
| Name | `Found <name> [id]` header line | `Name :` field | header line `<name> <ver> [status]` |
| Description | `Description:` block (multi-line, 2-space-indented continuation) | `Description :` field | `Description:` field (single line) |
| Version | `Version:` field | `Version :` field | header line (fused with Name) |
| Last Updated | first `Release Date:` found under a nested `Installer:` block (best-effort: only the first installer entry's date, since a package can list several) | `Updated at :` field | `Published:` (extracted from inside the `Title:` line's value) |
| Publisher | `Publisher:` field | *(no equivalent — omitted)* | *(no equivalent — omitted)* |
| License | `License:` field | `License :` field | `Software License:` field |
| Homepage | `Homepage:` field | `Website :` field | `Software Site:` field |

A missing field (regex doesn't match) is simply left out of the summary block — never guessed,
never misparsed as something else. If every field's regex fails to match (the tool changed its
output format upstream), the script falls back to printing the plain, unmodified output — no
summary block, no error — consistent with this project's existing rule that undocumented-internals
dependencies degrade silently (`docs/external-dependencies.md`).

Summary-block field labels are DotForge's own uniform names (`Name`, `Description`, `Version`,
`Last Updated`, `Publisher`, `License`, `Homepage`), not each tool's native field name — scoop's
`Website` renders as `Homepage` in the summary block, for example — since this block is newly
authored content, not a literal passthrough of the tool's own labels. (The full unmodified output
below the separator still shows each tool's real field names, unchanged.)

Because the summary block only *adds* content above the untouched original output, a field appears
twice when it's easy to see anyway (e.g. choco's Name+Version, already visible in its header line,
also appear in the summary). This duplication is an accepted trade-off for not having to safely
reorder choco's irregular format.

### Shared helper

`Private/Format-DFPreviewSummary.ps1` is new, tool-agnostic text-formatting glue (not a package-
manager-specific concern, so it lives in `Private/` rather than being duplicated three times in
`Tools/`): given an ordered label→value map (values may be `$null`/empty) and the original body
lines, it renders only the populated labels as `Label: value`, followed by a separator and the
body — or just the body verbatim if nothing matched.

### Where the preview scripts are invoked from

Each tool's `-Preview` string changes from (winget, representative):

```
'ping -n 2 127.0.0.1 >nul & winget show --id {2}'
```

to:

```
"Start-Sleep -Milliseconds 1000; & '$PSScriptRoot\winget.preview.ps1' {2}"
```

`$PSScriptRoot` resolves to `Tools/` at dot-source time (existing convention, documented in
`CLAUDE.md`'s `$DFCurrentTool` sidecar contract note). Since the outer shell fzf spawns via
`--with-shell` is already a fresh `pwsh -NoProfile` process, `& '<path>'` runs the preview script
in that same process — no second nested pwsh startup.

## Error handling and tests

- `docs/external-dependencies.md` gets a new "Undocumented internals" entry documenting the
  dependency on `winget show`/`scoop info`/`choco info`'s plain-text field layout, and what happens
  when it changes (a field silently drops out of the summary block, or — if every field's regex
  misses — the summary block disappears entirely and the preview falls back to the tool's plain
  output, exactly as it behaves today).
- `tests/XdgSplit.Tests.ps1`'s exact-match `$expectedFzfOpts` fixture (asserts
  `Tools/fzf.json`'s `env.FZF_DEFAULT_OPTS` byte-for-byte) gets the new `--with-shell=...` line
  added in the same position it's added to the JSON.
- New Pester tests for each of the three preview scripts, using the real sampled CLI output
  captured during design (real `winget show --id Git.Git`, `scoop info git`, `choco info git`/
  `nodejs` transcripts) as fixtures — asserting the summary block contains the right fields in the
  right order, that a field absent from the fixture is silently omitted (not a blank/placeholder
  line), and that malformed/empty input degrades to plain passthrough with no error.
- Existing `tests/winget.Tests.ps1`/`scoop.Tests.ps1` mock `Invoke-DFFzf` entirely and never
  inspect `-Preview` string content, so they stay green unmodified; no equivalent `choco.Tests.ps1`
  exists today and creating one is out of scope for this change.
- README, `examples/`, and `CHANGELOG.md` updated per the project's pre-commit checklist (the
  picker preview behavior is user-visible).
