# Admin tools: process viewers, disk usage, elevation

Status: draft, 2026-10-17. T-35 batch: bring the administrative tools up to the tool contract.

## Goal

Every tool below gets the whole tool contract (install, XDG, sensible defaults, theme where the
tool has one, completions, a picker where it fits), and is grouped so a user can find and choose
among them. No new behavior beyond the contract.

## What the user said

- "Just want to bring them in to conformance with our tool spec."
- They "don't need be exclusive. They all stand on their own and can co-exist." Grouping is only
  for a default for a user who doesn't want to install them all.
- **No classic names.** The roles' winners don't take `top`, `du` or `df`, since coreutils already
  gives the user `du` and `df`.
- **btop:**
  - There are two builds, both installed as `btop.exe`, so only one is on PATH.
  - `btop` (btop4win) runs without admin rights and shows basic memory and process info.
  - `btop-lhm` bundles LibreHardwareMonitor as a DLL and shows more detail, but needs admin rights.
  - DotForge installs plain `btop` by default ("more sensible default"). btop-lhm is opt-in.
  - btop-lhm can't run without admin rights: its scoop shim asks for elevation itself (UAC). Yes
    runs it, no gives an error. So there is no unelevated fallback.
- **Later, not now:** an "instant replay" for the process viewer, to look back at a CPU or memory
  spike. It becomes a TODO.

## Roles: categories, not single roles (my call, agreed in conversation)

A category groups tools without a winner. It has no aliases and no hooks, so every tool keeps its
own command. That's how `grep` and `fuzzy-finder` work.

| Category | Members |
|---|---|
| `process-viewer` (new) | procs, btop, bottom (`btm`), glances, ntop, pstop |
| `disk-usage` (new) | dust, dua, gdu, duf |
| `elevator` (exists) | gsudo (unchanged) |

- **Windows' own `sudo` gets no record** (my call). In the `elevator` category it would change how
  `Install-DFTool` elevates. `Get-DFElevationMethod` treats every elevator member as the one to use,
  and that would skip its checks that Windows sudo is on and in inline mode. DotForge already handles
  Windows sudo itself, so the guide documents it instead.
- **duf** shows free space per drive rather than folder sizes. It sits in `disk-usage` anyway:
  without a winner, a separate role buys nothing (my call).
- **The default for "just give me one":** the existing `+admin-tools` group (gsudo, procs,
  fastfetch, curl, wget) gains dust (my call). Groups are the install-a-set mechanism, and
  categories are for discovery (`Get-DFRole`).

## Not included

- **ncdu:** not in scoop or winget, and gdu is its Windows-capable port (winget tags gdu "ncdu").
- **htop:** on Windows, winget's pstop installs an `htop` link to pstop itself. pstop's record notes
  it.

## The tools

For each tool, the plan's probe task records the facts, and the record follows them:
- where it reads config on Windows, and whether an env var or flag relocates it;
- its theme or color options;
- its completions (a native generator, carapace's own completer, or a DotForge carapace spec);
- install ids (scoop, winget).

Sensible defaults are seeded only where the tool's own defaults are poor (my call). A theme follows
`Theme` only where the tool has a catppuccin theme or a color config the palette maps onto.

| Tool | Expected work (confirm in probes) |
|---|---|
| procs | has a record; check config (`%APPDATA%\procs\config.toml` or the XDG path); color theme in config; completions (`procs --gen-completion-out powershell`) |
| btop | new record: builds and elevation (below); themes (catppuccin btop themes, MIT); config `btop.conf` (btop4win keeps it beside the exe? probe) |
| bottom | new record, executable `btm`; config `%APPDATA%\bottom\bottom.toml` relocated with `-C`/`--config_location` through a wrapper, or seeded if the probe finds an env var; built-in color themes (`--theme`), catppuccin through a theme file; completions in the release |
| glances | new record (pip, pipx or uv install); config `glances.conf` (`-C`); limited theming; no picker |
| ntop | new record; probe config and options (minimal tool) |
| pstop | new record (winget `pstop`); probe config and themes |
| dust | new record; config `config.toml` (probe the location); colors |
| dua | new record; probe; interactive mode `dua i` |
| gdu | new record; config `.gdu.yaml` (probe XDG support); color style config |
| duf | new record; probe; `--theme` (dark, light, ansi) mapped from Theme |


## btop: two builds and elevation

- **Install:** one `btop` record whose install ids name the plain build (scoop `btop`). A setting
  (`settings.build`, or the record's `packages` with `InstallVia`; the builder picks one existing
  mechanism) lets the user choose `btop-lhm` instead.
- **Telling the builds apart:** at load, the companion detects which build is on PATH. The scoop
  app folder name (`btop-lhm`) or the `LibreHardwareMonitorLib.dll` next to the exe gives it away.
- **When the lhm build is on PATH**, and an `elevator` member is active this session (gsudo, when
  it's in `Tools`; my call, consistent with opt-in): `btop` becomes a global function that runs it
  through that elevator in the same console. gsudo's credential cache saves a UAC prompt per run.
  - The companion finds the elevator through the session's role members, never by naming gsudo.
  - With no active elevator, nothing is wrapped: running btop-lhm shows Windows' own UAC prompt,
    as it does today.
- **When the plain build is on PATH:** nothing wraps it.

## TODO

- **New T-item:** a process-viewer "instant replay", recording CPU and memory history so a spike
  can be looked at afterwards (top processes and top memory users at that moment). This needs a
  background sampler and is its own project.
- `TODO-Tools.md`:
  - process-viewer and disk-usage move to the Done table;
  - Windows `sudo` is documented as handled by DotForge's elevation, not as a member;
  - ncdu goes to "not on Windows";
  - htop becomes "pstop's link".

## Probes (the plan's first task)

For each tool:
- `--help`, to find its config flag and env var;
- where it reads config on Windows, found by running it with a scratch `XDG_CONFIG_HOME` and
  `APPDATA` and looking for files it creates (note the real folders before and after; clean up
  only what the probe created);
- its theme options;
- whether it ships a completion generator;
- its scoop and winget ids.

Never leave a TUI running: run with `--help`/`--version` only, under a timeout, with stdin from
`/dev/null`. Never run btop-lhm (it needs admin).

## Out of scope

- The instant-replay feature.
- Classic-name aliases (`top`, `du`, `df`).
- ncdu and htop.ive
