# Legacy Pickers and Leftovers (T-3) — Design

**Status:** Approved decisions, 2026-10-11
**Closes:** T-3. Supersedes §3, §5 and §6 of `2026-07-15-legacy-profile-fold-in-design.md`; its §2
(completions) is T-4 and its §4 seeding is T-5.

## Context

The legacy `cli_tools_config.ps1` is no longer loaded, so 11 of its fzf pickers are inactive. All 9
tools are installed on the user's machine. The scoop pickers (`sins`, `srm`, `sup`) were ported
since the July spec. Each remaining picker was reviewed for its behavior, not only ported; the decisions
below are the user's.

## 1. A tool may declare several pickers

docker and gh need two pickers each. `picker` may now be:

- `null`: no picker.
- `"custom"`: the companion `Tools/<tool>.ps1` builds its own (unchanged).
- an object: one declarative picker (unchanged).
- **an array of objects:** several declarative pickers.

Records normalize a declarative picker to **a list** (one element for an object), as `installs`
already does, so every consumer loops instead of branching. Validation reports the element
(`picker[1].list is required`). Consumers updated: `ConvertTo-DFPickerBlock`, `Test-DFToolSchema`
(errors and typo warnings), `New-DFToolPickerFunction`, `Get-DFCommandConflict`,
`build/Build-DFReferenceDocs.ps1` (one line per picker), and the tests that read raw JSON
(`AliasOwnership`, `Coreutils.Conflicts`, `Tools.PickerDeclaration`).

## 2. The pickers

All alias names were checked against `Get-Command`: none is taken. Function names keep the legacy
names.

### Declarative (in the tool's JSON)

| Alias | Function | List | Preview | Enter |
|---|---|---|---|---|
| `frtc` | `Select-RustupToolchain` | `rustup toolchain list` (keeps the `(active, default)` marker) | none | `rustup default <name>` |
| `czf` | `Edit-DotFile` | `chezmoi managed --path-style absolute --include files` | bat | `chezmoi edit <file>` (works from any folder; legacy only from `$HOME`) |
| `fdc` | `Select-DockerContainer` | running containers: ID, name, image, status | last 50 log lines | exec bash if the image has it, else sh |
| `fdi` | `Select-DockerImage` | images: `repo:tag`, ID, size | `docker image history` | outputs `repo:tag` (the ID when untagged) |
| `fpr` | `Select-GHPr` | open PRs: number, title, author | `gh pr view <n>` | `gh pr checkout <n>` |
| `fgi` | `Select-GHIssue` | open issues: number, title | `gh issue view <n>` | opens it in the browser |

### Custom (in a companion `.ps1`)

- **`fjq` `Select-JsonPath [-Path]` (jq.ps1, new):** without -Path, pick a `*.json` file first (fd when
  installed, else `Get-ChildItem`). Then fzf becomes a jq playground: the query is the filter
  (`--disabled`, starting at `.`), the preview runs `jq -C <filter> <file>` as you type, and Enter
  writes `jq <filter> <file>`'s output to the pipeline.
- **`fgl` `Read-MarkdownFile [-Path]` (glow.ps1):** lists `*.md` under -Path (default `.`) with
  `fd -e md` when fd is installed, else `Get-ChildItem`. Preview and render use glow's configured
  style (`Resolve-DFGlowStyle`), not a hardcoded `dark`. Enter opens it in glow's pager.
- **`fvenv` `Select-UvVenv [-Path]` (uv.ps1, new):** finds `pyvenv.cfg` up to 4 levels under -Path
  (default: the current folder; `fvenv ~` searches everywhere). Preview shows `pyvenv.cfg`. Enter
  runs the venv's `Activate.ps1` (`Scripts/` on Windows, `bin/` elsewhere).
- **`fns` `Select-NpmScript` (npm.ps1, new):** finds `package.json` from the current folder upward,
  lists its scripts and previews each command line. Enter runs it with the project's manager: `pnpm`
  for `pnpm-lock.yaml`, `bun` for `bun.lock`/`bun.lockb`, `yarn` for `yarn.lock`, else `npm`. (npm's
  picker naming other managers bends the plugin rule; accepted.)
- **`fbw` `Select-BwItem [-Type login|note|card|identity|all]` (bitwarden.ps1, new):** checks
  `bw status` first and says how to log in or unlock. Filters by Bitwarden's real item type (legacy
  searched for the type's name as text). Lists name and username; secrets never appear in the list
  or a preview. Enter copies the password, and a thread job clears the clipboard after 30 s if it
  still holds that password. An item with no password gets a warning. Windows clipboard history
  (Win+V) may keep a copy; the help says so.

## 3. Leftovers

- **Dropped:** `sstat`/`supd`/`wstat`/`wupd` (Update-DFTool replaces them), `edit` (`$EDITOR`),
  the bat `cat` fallback (DotForge never aliases a missing tool), and the records for nvm,
  mosquitto and Notepad++ (not installed).
- **glazewm, dropped (deviates from the Trim answer):** the config is at the default
  `~/.glzr/glazewm`; the legacy wrapper's `--config $XDG_CONFIG_HOME/glazewm/config.yaml` points at
  a file that doesn't exist, and GlazeWM starts at login, not from the shell.
- **nano, new record:** nano ≥ 2.9 reads `$XDG_CONFIG_HOME/nano/nanorc` itself, and the legacy
  `NANORC` variable is not one nano reads. `xdg.method: default`, compliance full.
- **docker's `DOCKER_CONFIG`:** already set only when docker is installed; unchanged.

## Testing

No test runs a real tool: native commands are stubbed as functions and `Invoke-DFFzf` is mocked.

- Schema: an array validates per element; a bad element names its index; a record normalizes an
  object to a one-element list.
- Every shipped declarative picker builds its function and alias (`Register-DFTool` path).
- Each declarative `parse` against sample lines (frtc's markers, fdi's untagged image, fdc, fpr).
- Each custom picker: the action it runs for a chosen line, and its guards (no package.json; vault
  locked; no venv; jq's filter reaches jq).
