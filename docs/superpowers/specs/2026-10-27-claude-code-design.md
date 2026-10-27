# Claude Code, and script installers (piece 9; T-84)

Piece 9 of the restore work (`2026-10-24-restore-install-locations-notes.md`): onboard Claude Code
as a DotForge tool, so a restore installs it into the XDG locations and sets it up for Windows
PowerShell. Claude Code's native installer is an `irm … | iex` script, so this piece also adds
script installers as a DotForge source (T-84).

## Why

Today Claude Code comes from winget (a portable copy under `WinGet\Packages`), chezmoi sets its
variables (`CLAUDE_CONFIG_DIR`, `CLAUDE_CODE_GIT_BASH_PATH`) as desktop variables, and its
`settings.json` is hand-made and not in the dotfiles, so a restore loses it. You want little Claude
setup: the install locations right, PowerShell preferred, the Windows-friendly settings, and the
theme following DotForge's like the other tools.

## Facts (checked 2026-10-27, Claude Code docs and the installer)

- The native installer (`https://claude.ai/install.ps1` → `bootstrap.ps1`) downloads `claude.exe`
  to `%USERPROFILE%\.claude\downloads`, checks its SHA-256 against the release manifest, runs
  `claude.exe install`, and deletes the download. It reads no `XDG_*` or `CLAUDE_*` variable. The
  result is `~\.local\bin\claude.exe` and `~\.local\share\claude\versions\` (the XDG default
  locations). It updates itself in the background; `claude update` updates on demand. Uninstall:
  delete `~\.local\bin\claude.exe` and `~\.local\share\claude`.
- `CLAUDE_CONFIG_DIR` moves `~\.claude` (settings, history, plugins) and `~\.claude.json`.
- `settings.json` has an `env` block that the CLI, the desktop app and the editor extensions read.
- `defaultShell: "powershell"` runs `!` commands in PowerShell; `CLAUDE_CODE_USE_POWERSHELL_TOOL=1`
  turns the PowerShell tool on. `CLAUDE_CODE_GIT_BASH_PATH` points at Git Bash (Bash and Monitor
  tools) when it isn't found on its own.
- Themes: the `matcra587/claude-themes` marketplace has one plugin per family (catppuccin, dracula,
  gruvbox, nord, …); the `theme` key selects one as `custom:<plugin>:<theme>`, e.g.
  `custom:catppuccin:catppuccin-mocha`, and only works once the marketplace is added and the
  family's plugin installed and enabled. Claude Code reloads `settings.json` on change.
- The CLI does both without the interactive menu: `claude plugin marketplace add <owner/repo>
  --scope user` and `claude plugin install <plugin>@<marketplace> --scope user`, each with `--json`
  for a machine-readable result; `claude plugin list` lists what's installed.
- `cc` is free on this machine: no PowerShell alias or command, nothing on PATH.

## Decided (yours)

1. **settings.json:** DotForge adds only the keys that are missing (creating the file on a fresh
   machine) and never changes a key you set.
2. **Theme:** a DotForge theme change (`Theme`, `Set-DFToolTheme`) changes Claude's theme too,
   rewriting only the `theme` key, and only after the marketplace is added and the theme's plugin
   installed and enabled.
3. **Install source:** the native installer, through a new script-installer source (T-84),
   preferred over winget and npm.
4. **Variables:** `CLAUDE_CODE_GIT_BASH_PATH` and the PowerShell switch go in `settings.json`'s
   `env`. Only `CLAUDE_CONFIG_DIR` is a desktop variable.
5. **Script trust:** only the https URL written in the tool's record is ever run; the install plan
   shows it, and the script source asks once more before running (skipped with `-Confirm:$false`).
6. **Script lifecycle:** the record declares how to update and what to remove; DotForge runs or
   deletes exactly that, confirming first. Installed means the executable at the declared path.
7. **Aliases:** `cc` (launch), `ccc` (`--continue`), `ccr` (`--resume`).

## Goals

- `Install-DFTool claude-code` on a fresh machine: native install into `~\.local`, config in
  `$XDG_CONFIG_HOME\claude`, PowerShell preferred, theme set, `CLAUDE_CONFIG_DIR` offered as a desktop
  variable.
- An existing install and config keep working (winget copy found; old config linked, piece 6).
- Script installers are a general source any record can use, safely.

## Non-goals

- Other AI tools (later pieces), MCP servers, plugins beyond the theme family, sign-in.
- Hash-pinning installer scripts (declined: every upstream change would break installs).
- Moving an existing winget install to the native one (uninstall it the way it was installed, then
  `Install-DFTool claude-code`; the docs say so).

## Anti-goals

- Running any script whose URL isn't in a tool record, or any non-https URL.
- Deleting anything a record doesn't declare, or anything outside the user's home folder.
- Changing a `settings.json` key the user set.
- A test that downloads or runs a real installer.

## Design

### The script-installer source (T-84)

- A manager record (`Tools/script.json`, my call on the name) with `installs.from = "script"`,
  available everywhere (DotForge itself is the manager), and functions in `Tools/script.manage.ps1`
  for install, update, remove and list. Core gains no manager names: it already runs managers through
  `Invoke-DFManagerCommand`.
- A tool's `packages.script` entry carries what a script install needs:

  ```json
  "script": {
    "id": "https://claude.ai/install.ps1",
    "installed": "${HOME}/.local/bin/claude.exe",
    "update": ["claude", "update"],
    "remove": ["${HOME}/.local/bin/claude.exe", "${XDG_DATA_HOME}/claude"]
  }
  ```

  `update` may be `"self"` (the tool updates itself; `Update-DFTool` says so). How these extra fields
  reach the manager functions (`Get-DFPackageRef`, function args) is the builder's call, inside the
  plugin rule. The schema validates the entry: `id` an https URL; `installed` and `remove` path
  templates under `${HOME}` or an `${XDG_*}` root.
- **Install:** the plan shows the URL; the source asks once (`ShouldProcess`, High) naming the URL;
  then it downloads the script with `Invoke-RestMethod` and runs it in a child `pwsh -NoProfile`
  process with the install environment (piece 3) set, so the script can't touch the session.
- **Installed:** the `installed` path exists. `list` reports each script-source tool that is.
- **Update:** runs the declared command, or reports "updates itself".
- **Remove:** deletes exactly the declared paths, after `Remove-DFTool`'s confirmation, refusing any
  path that resolves outside `$HOME`.
- `install.prefer` lets a record rank `script` first (claude-code does).

### The claude-code record

- `Tools/claude-code.json` (my call: the name says what it is; the executable is `claude.exe`).
- `packages`: `script` (above), `winget: Anthropic.ClaudeCode`, `npm: @anthropic-ai/claude-code`;
  `install.prefer: ["script"]`.
- `xdg.vars.CLAUDE_CONFIG_DIR = ${XDG_CONFIG_HOME}/claude`; `xdg.native`: `${HOME}/.claude` for it,
  and `${XDG_CONFIG_HOME}/claude/.claude.json` → `${HOME}/.claude.json`, so existing config is linked,
  never hidden. `desktop: ["CLAUDE_CONFIG_DIR"]`.
- `aliases` (yours):

  | Alias | Runs |
  |---|---|
  | `cc` | `claude` |
  | `ccc` | `claude --continue` (plus your arguments) |
  | `ccr` | `claude --resume` (plus your arguments) |

  Checked against the builtin-safety policy: no PowerShell alias or command named `cc`, `ccc` or
  `ccr`. A `cc` program on PATH (a C compiler) would be hidden by the alias, so each alias is defined
  only when no command of that name exists, and the status says why when one is skipped (my call).
- `theme`: key `ClaudeTheme`, default `catppuccin-mocha`, a `map` from DotForge's theme names to
  `custom:<plugin>:<theme>` ids for the families the marketplace has (builder reads the ids from the
  repository), and an `apply` function. Applying a theme, in this order:
  1. the marketplace is known (`claude plugin marketplace list`), else `claude plugin marketplace add
     matcra587/claude-themes --scope user`;
  2. the family's plugin is installed and enabled (`claude plugin list`), else `claude plugin install
     <family>@claude-themes --scope user` (and `enable` if it's installed but disabled);
  3. only then, `settings.json`'s `theme` key is rewritten.
  If step 1 or 2 fails (offline, Claude Code not installed yet), the theme key is left as it is and the
  status says why; the next load or theme switch tries again. A name with no mapping leaves Claude's
  theme as it is. The `claude` calls go through one private seam so tests never run Claude Code.

### Settings, once (setup script)

`Tools/claude-code.setup.ps1` (one-time) adds these to `$CLAUDE_CONFIG_DIR\settings.json` when missing:

| Key | Value |
|---|---|
| `defaultShell` | `"powershell"` |
| `env.CLAUDE_CODE_USE_POWERSHELL_TOOL` | `"1"` |
| `env.CLAUDE_CODE_GIT_BASH_PATH` | Git Bash found from the installed git (`git --exec-path`, then up to `bin\bash.exe`); left out when there's none |
| `theme` | the session theme's `custom:` id, set through the theme steps above (marketplace and plugin first) |

Merge is per key (nested: per `env` entry, per marketplace, per plugin). The file is written back as
JSON with two-space indentation (my call: it's a JSON file Claude Code also writes, so formatting
isn't preserved byte for byte). A file that isn't valid JSON is left alone, with a setup note.
The marketplace and plugin are added by Claude Code's own CLI (the theme steps), not by writing
`extraKnownMarketplaces`/`enabledPlugins` by hand, so Claude Code records them the way it expects.
The setup runs after the install, so `claude` exists; on a machine where it doesn't yet, setup
waits (it is retried on a later load, as setup scripts are).

### The dotfiles side (after a Gallery release)

Drop `CLAUDE_CONFIG_DIR` and `CLAUDE_CODE_GIT_BASH_PATH` from chezmoi's user-env script, add
`claude-code` to the profile's `Tools`; the restore runs `Install-DFTool` and `Set-DFDesktopEnv`.

## Left to the builder

- How `packages.script` fields reach the manager functions; the script manager's record shape.
- The theme map's entries (from the marketplace's plugin and theme ids).
- Tests with mocked downloads and process runs; a conformance-style check of the real installer
  only by hand, never in the suite.
- Docs: `tools.md` (claude-code, script installers), `writing-a-tool.md` (`packages.script`),
  configuration.md (install sources), CLAUDE.md schema line, CHANGELOG, restore notes, TODO (close
  T-84).
