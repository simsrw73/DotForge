# Safety

**Audience:** anyone deciding whether to run DotForge on a machine they care about.  
**Topic:** what DotForge reads, writes, runs and sends over the network, and what it changes outside the current session.  
**Goal:** know every change before you make it, and how to undo it.

## Summary

| | |
| --- | --- |
| **Reads** | `$DFConfig`, environment variables, its own tool records, your installed tools and modules, package managers' local catalog files. |
| **Writes** | Folders and files under your XDG folders (`~\.config`, `~\.local\share`, `~\.local\state`, `~\.cache`, `~\.local\bin`). One line in your global git config (delta, once). Shims, only when you run `New-DFShim`. |
| **Changes for the session only** | Environment variables, `PATH`, aliases, functions, PSReadLine options and key bindings, the prompt. Nothing is written to the registry or to user/machine environment variables. |
| **Runs** | Your installed tools' own setup commands while registering; package managers only when you run `Install-DFTool` or a picker action. |
| **Network** | DotForge itself makes no requests while importing or registering. Only `trifle`/`ftrifle`, `Update-DFPackageCache`, `Update-DFCategoryDb`, `Update-DFToolIdentityGuide`, `Install-DFTool` and the package-manager pickers use it. |
| **Elevation** | Never on its own. `please`, `sudo` and the Chocolatey pickers ask through gsudo's UAC prompt when you use them. |

## Relocated tool data

This is the change most likely to surprise you. For many tools, DotForge sets environment variables that point the tool at XDG folders. A tool that already had files in its old default location **won't see them** afterwards: an installed Rust toolchain, vcpkg packages, zoxide's folder history, and so on.

DotForge never moves or deletes the old files. It also never overrides a variable you've already set, so setting one yourself (for example `$Env:RUSTUP_HOME = "$HOME\.rustup"` before `Register-DFTool`) keeps a tool where it was.

| Tool | Variable | New location |
| --- | --- | --- |
| bat | `BAT_CONFIG_PATH` | `$XDG_CONFIG_HOME\bat\bat.conf` |
| chezmoi | `CHEZMOI_CONFIG_DIR` | `$XDG_CONFIG_HOME\chezmoi` |
| curl | `CURL_HOME` | `$XDG_CONFIG_HOME\curl` |
| docker | `DOCKER_CONFIG` | `$XDG_CONFIG_HOME\docker` |
| fnm | `FNM_DIR` | `$XDG_DATA_HOME\fnm` (installed Node versions) |
| lazygit | `LG_CONFIG_FILE` | `$XDG_CONFIG_HOME\lazygit\config.yml` |
| less | `LESSHISTFILE`, `LESSKEY` | `$XDG_STATE_HOME\less\history`, `$XDG_CONFIG_HOME\less\lesskey` |
| mdv | `MDV_CONFIG_PATH` | `$XDG_CONFIG_HOME\mdv` |
| micro | `MICRO_CONF_DIR` | `$XDG_CONFIG_HOME\micro` |
| npm | `NPM_CONFIG_USERCONFIG`, `NODE_REPL_HISTORY` | `$XDG_CONFIG_HOME\npm\npmrc`, `$XDG_DATA_HOME\node_repl_history` |
| oh-my-posh | `POSH_THEMES_PATH` | `$XDG_DATA_HOME\oh-my-posh\themes` |
| PSReadLine | history file (`HistorySavePath`) | `$XDG_STATE_HOME\psreadline\history` |
| ripgrep | `RIPGREP_CONFIG_PATH` | `$XDG_CONFIG_HOME\ripgrep\ripgreprc` |
| rustup | `RUSTUP_HOME`, `CARGO_HOME` | `$XDG_DATA_HOME\rustup`, `$XDG_DATA_HOME\cargo` (toolchains and installed crates) |
| starship | `STARSHIP_CONFIG`, `STARSHIP_CACHE` | `$XDG_CONFIG_HOME\starship\starship.toml`, `$XDG_CACHE_HOME\starship` |
| uv | `UV_CACHE_DIR`, `UV_DATA_DIR` | `$XDG_CACHE_HOME\uv`, `$XDG_DATA_HOME\uv` |
| vcpkg | `VCPKG_ROOT`, `VCPKG_DOWNLOADS` | `$XDG_DATA_HOME\vcpkg`, `$XDG_CACHE_HOME\vcpkg\downloads` |
| wget | `WGETRC` | `$XDG_CONFIG_HOME\wget\wgetrc` |
| zoxide | `_ZO_DATA_DIR` | `$XDG_DATA_HOME\zoxide` (folder history) |

glow and fastfetch get their config paths through wrapper functions instead (`$XDG_CONFIG_HOME\glow\glow.yml`, `$XDG_CONFIG_HOME\fastfetch\config.jsonc`). The [tool records](../reference.md#tool-records) are the authoritative list.

Before registering a tool you already use, either move its old folder to the new location or set the variable yourself to keep it in place.

## Files DotForge writes

| Path | Written by | When |
| --- | --- | --- |
| `$XDG_CONFIG_HOME`, `$XDG_DATA_HOME`, `$XDG_STATE_HOME`, `$XDG_CACHE_HOME`, `$XDG_BIN_HOME` | `Initialize-DFEnvironment` | creates the folders if missing |
| Tool folders listed in each record's `xdg.dirs` | `Register-DFTool` | creates them if missing |
| `$XDG_CONFIG_HOME\carapace\specs\scoop.yaml`, `mdv.yaml` | carapace companion | rewritten when DotForge's copy changes |
| `$XDG_CONFIG_HOME\delta\catppuccin.gitconfig` | delta companion | rewritten when DotForge's copy changes |
| `$XDG_CONFIG_HOME\fastfetch\config.jsonc` | fastfetch companion | only if missing |
| `$XDG_CONFIG_HOME\mdv\config.yaml` | mdv setup | once per machine, only if missing |
| `$XDG_STATE_HOME\dotforge\setup-state.json` | one-time setup scripts | records which setups ran |
| `$XDG_STATE_HOME\psreadline\history` | PSReadLine | your command history from now on |
| `$XDG_CACHE_HOME\dotforge\*` | init-script, help-topic, help-flag and `LS_COLORS` caches; catalog caches in `catalogs\` | as needed; safe to delete |
| `$XDG_DATA_HOME\dotforge\tool-categories.json`, `tool-identities.json` | `Update-DFCategoryDb`, `Update-DFToolIdentityGuide` | only when you run them |
| `$HOME\.local\bin\<name>.cmd` (or `$DFConfig.ShimsPath`) | `New-DFShim` | only when you run it |
| a `dotforge-preview-<pid>` folder in your temp folder | `ftrifle <query>` | removed when the picker closes |

Everything under `$XDG_CACHE_HOME\dotforge` can be deleted at any time; it's rebuilt as needed.

## Your global git config

The first time delta is registered on a machine, DotForge runs `git config --global --add include.path <path>` to include its delta theme file, and prints the command that removes it again:

<!-- system -->

```powershell
git config --global --get-all include.path
git config --global --unset-all include.path "$Env:XDG_CONFIG_HOME\delta\catppuccin.gitconfig"
```

The first line shows your includes; the second removes DotForge's. Once you remove it, DotForge doesn't add it again, because the setup is recorded as done. To stop it from ever being added, set `$DFConfig.SkipSetup = @('delta')` before delta is first registered. Your existing delta settings aren't changed.

## Programs DotForge runs

While registering, for tools you have installed:

- each tool's own shell-setup command: `carapace _carapace powershell`, `zoxide init`, `starship init`, `oh-my-posh init`, `direnv hook pwsh`, `fnm env`, `mdcat --completions`, `scoop-search --hook`, `vivid generate`, `is init` (inshellisense mode). Their output is run in your session with `Invoke-Expression`, the way these tools document. Most of these outputs are cached and reused until the tool is upgraded.
- `git config --global` (delta setup, once).
- a background thread that pre-loads PowerShell modules being registered, to speed up startup. It's removed when registration finishes.

When you use them: package managers (`Install-DFTool`, picker actions), `gsudo` (`please`, `sudo`, Chocolatey pickers), `pipx list` (`trifle`'s installed check), `gh` (`trifle -GitInfo`), and whatever command a picker's preview runs. `trifle` refreshes stale catalog data on background threads in the same PowerShell process.

## Network

| Command | Sends | To |
| --- | --- | --- |
| `trifle`, `ftrifle`, `Update-DFPackageCache` | package names and search words | registry.npmjs.org, pypi.org, crates.io, community.chocolatey.org, www.powershellgallery.com |
| `trifle -GitInfo`, `-Readme` | repository names | api.github.com, through `gh` when signed in |
| `Update-DFCategoryDb`, `Update-DFToolIdentityGuide` | a download request | github.com (DotForge's latest release) |
| `Install-DFTool`, package pickers | whatever the package manager sends | scoop buckets, winget, Chocolatey, PowerShell Gallery, crates.io |

DotForge sends nothing while importing the module or registering tools, and has no telemetry. The tools' own setup commands that registration runs (listed above) behave as those tools document.

## What not to do

- Don't register a tool you already rely on without checking [Relocated tool data](#relocated-tool-data) for it.
- Don't put secrets in `$DFConfig` or in a tool record's `env` block: values become ordinary environment variables, visible to every program you start.
- Don't point `New-DFShim -Target` at a program you don't trust: the shim runs it whenever its name is typed.
- Don't run `coreutils-manager` changes or Chocolatey actions in an elevated shell unless you meant to; DotForge only prints those commands.

## Undo everything

1. Remove the DotForge lines from your profile and open a new shell. Every session-only change is gone.
2. Remove the delta include from your global git config, if it was added (command above).
3. Delete `$XDG_CACHE_HOME\dotforge`, `$XDG_STATE_HOME\dotforge` and `$XDG_DATA_HOME\dotforge`.
4. Move relocated tool data back, or keep using the new locations by setting the variables yourself.
5. `Uninstall-PSResource DotForge`.
