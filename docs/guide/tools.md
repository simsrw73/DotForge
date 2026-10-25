# Tools

**Audience:** DotForge users who want to know what it does to each of their tools.  
**Topic:** the 43 tools DotForge configures, the commands they add, and tool-specific behavior.  
**Goal:** know what changes when a tool is registered, and use the commands it adds.

`Register-DFTool` configures a tool only if it's installed. For the exact environment variables, aliases and install ids of each tool, see the generated [tool records](../reference.md#tool-records); this page explains the behavior behind them.

## Groups

Request a group in `Start-DFSession -Config` with its leading `+`; use `Get-DFToolGroup` to inspect it. `+core`: psreadline, PSFzf, fzf, eza, bat, fd, ripgrep, zoxide, carapace, less, fastfetch, smartmontools; `+prompt`: starship; `+git`: delta, gh, lazygit; `+dev-tools`: jq, micro, mise, chezmoi; `+javascript-dev`: fnm, node, npm; `+python-dev`: uv, python, pip, pipx; `+rust-dev`: rustup, cargo; `+admin-tools`: gsudo, procs, fastfetch, curl, wget; `+markdown`: glow; `+package-managers`: scoop, winget; `+fuzzy`: fzf, skim, television, peco, gum; `+fonts`: NerdFonts, GoogleFonts, fontget, gfcli (see [Fonts and icons](fonts.md)).

## Quick start

Ask the registry what DotForge knows:

```powershell
Import-Module DotForge
Get-DFTool -Tag pager | Sort-Object name | Select-Object -ExpandProperty name
```

```text
bat
delta
less
moor
ov
```

```powershell
Import-Module DotForge
Find-DFTool markdown | Sort-Object name | Select-Object name, description
```

```text
name  description
----  -----------
glow  Render Markdown on the CLI
mdcat cat for markdown — render CommonMark in the terminal
mdv   Terminal markdown viewer with themes and syntax highlighting
```

1. `Get-DFTool -Tag` matches one tag exactly; `Get-DFTool -Name` returns one tool's full record.
2. `Find-DFTool` searches names, descriptions and tags for the text anywhere.
3. Both list every known tool, installed or not. To search what you could install, use [`trifle`](package-catalog.md).

## Included tools

| Group | Tools |
| --- | --- |
| Completion | carapace, inshellisense |
| Files and folders | bat, broot, eza, fd, lsd, ripgrep, vivid |
| Text and data | glow, jq, mdcat, mdv |
| System | fastfetch, gsudo, smartmontools |
| Processes | procs, btop, bottom, glances, ntop, pstop (the `process-viewer` category) |
| Disk usage | dust, dua, gdu, duf (the `disk-usage` category) |
| Network | curl, wget |
| Containers | docker |
| Per-folder environments | ps-dotenv, mise, direnv (one is active; see below) |
| Prompt | oh-my-posh, starship |
| Editor | micro, nano |
| Fuzzy finding and navigation | fzf, skim, television, peco, gum, zoxide |
| Pager | moor, ov, less (one sets `PAGER`; see below) |
| Package managers | choco, npm, scoop, winget |
| Development | bitwarden, chezmoi, delta, fnm, gh, lazygit, rustup, uv, vcpkg |
| PowerShell modules | posh-git, PSFzf, psreadline, Terminal-Icons |

## Commands each tool adds

| Tool | Commands and keys |
| --- | --- |
| bat | `cat` → `bat -pp` |
| bitwarden | `fbw` picks a vault item and copies its password, clearing the clipboard after 30 s |
| chezmoi | `cz`; `czf` picks a managed file and runs `chezmoi edit` on it |
| choco | `cins`, `crm`, `cup` pickers; `Ctrl+G` `C` |
| docker | `fdc` opens a shell in a running container; `fdi` outputs an image's `repo:tag` |
| eza | `ls`, `ll`, `la`, `tree` and the `ff` file picker, when it wins the `listing` role (see lsd) |
| fd | `ffd` file picker |
| fnm | `cd` also switches Node versions |
| gh | `fpr` checks out a pull request; `fgi` opens an issue in the browser (both preview it) |
| glow | `fgl` picks a Markdown file and reads it in glow |
| gsudo | `sudo` → gsudo; `please` re-runs the last command elevated |
| jq | `fjq` live jq playground: type a filter, see its output, Enter runs it |
| lazygit | `lg` |
| lsd | When it wins the `listing` role ([roles](configuration.md#choose-a-tool-for-each-role)), the same commands as eza: `ls` (names, directories first), `ll` (long, with git status), `la` (`ll` plus hidden entries), `tree`, and `ff` (pick a file, outputs its path) |
| npm | `nls` → `npm list -g --depth=0`; `fns` runs a `package.json` script with the project's manager |
| oh-my-posh | `fpot` prompt theme picker (when it wins the `prompt` role) |
| posh-git | `fco` (checkout branch), `flog` (show commit), `fga` (stage files), `fstash` (apply stash) |
| procs | `fkill` process picker |
| btop | `btop` runs btop-lhm through gsudo, when btop-lhm is the build on `PATH` and gsudo is in your `Tools` |
| PSFzf | `Ctrl+T` (insert a path) and `Ctrl+R` (history) when it wins those roles (it does by default), `Alt+A` (pick an argument from history), fuzzy Tab |
| psreadline | `fprl` color theme picker; `Ctrl+P` / `Ctrl+N` history search |
| ripgrep | `frg` search-and-open picker |
| rustup | `frtc` picks the default toolchain |
| scoop | `sins`, `srm`, `sup` pickers; `Ctrl+G` `S` |
| uv | `fvenv` activates a Python venv below the current folder |
| vivid | `fls` directory-color theme picker |
| winget | `wins`, `wrm`, `wup` pickers; `Ctrl+G` `W` |
| zoxide | `cd` jumps to frequent folders, `cdi` picks one; `fzo` folder picker |

Every command has help: `Get-Help fco -Full`, or the [reference](../reference.md#tool-companion-functions). Commands defined by a tool exist only after that tool is registered.

## Package manager pickers

The winget, scoop and Chocolatey pickers work the same way: search and install, uninstall, and update.

| Picker | Enter | Other keys |
| --- | --- | --- |
| `wins`, `sins`, `cins` | returns the install command, without running it | `Alt-R` installs now; `Alt-I` installs the highlighted package and keeps the picker open |
| `wrm`, `srm`, `crm` | uninstalls the selection | `Alt-X` uninstalls in place; `Alt-C` returns the command |
| `wup`, `sup`, `cup` | updates the marked packages | `Tab` marks; `Alt-A` updates everything |

<!-- interactive -->

```powershell
Import-Module DotForge
Start-DFSession -Config @{ Tools = @() }
Register-DFTool -Name winget
wins ripgrep
```

Pick ripgrep and press Enter to get `winget install --id BurntSushi.ripgrep.MSVC --exact`.

To put an install command on the command line instead, type a search term at the prompt, press `Ctrl+G` then `W` (winget), `S` (scoop) or `C` (Chocolatey), and pick. The term is replaced with the install command, ready to edit or run.

Requirements:

- winget pickers need the `Microsoft.WinGet.Client` module: `Install-Module Microsoft.WinGet.Client -Scope CurrentUser`.
- scoop pickers need the `Scoop` module: `Install-Module Scoop -Scope CurrentUser`. Search is much faster with `scoop install scoop-search`, which DotForge also hooks into `scoop search`.
- Chocolatey changes need an elevated shell. With gsudo registered, they run through it and show a UAC prompt.

## Notes on individual tools

### bat

`BAT_THEME` is set to `Catppuccin Mocha`. A theme name bat doesn't know makes bat warn and use its own default.

### delta

delta becomes git's pager (`GIT_PAGER=delta`) when it wins the `diff` role. Its theme comes from `DELTA_FEATURES`, which adds a theme to the `features` in your git config rather than replacing them. The theme definitions are written to `$XDG_CONFIG_HOME\delta\catppuccin.gitconfig` on each registration.

The first time delta is registered on a machine, DotForge adds one line to your **global git config** so git can find that file:

```text
[include]
	path = C:\\Users\\you\\.config\\delta\\catppuccin.gitconfig
```

It prints the command to remove the line, and never adds it again after you remove it. To skip this step, set `$DFConfig.SkipSetup = @('delta')` before delta is first registered.

### Per-folder environments: ps-dotenv, mise, direnv

These fill the `project-env` role, so only one is active: your `Defaults['project-env']` choice, otherwise ps-dotenv, then mise, then direnv.

- **ps-dotenv** loads `.env` files from the current folder and its parents as you change folders. DotForge turns its safe mode on, so only folders you approve load. Add the folders to your `$DFConfig` block:

  ```powershell
  $DFConfig = @{
      DotenvApprovedDirs = @('~\projects')
  }
  ```

  Set `DotenvSafeMode = $false` to load every `.env` without approval. Install it with `Install-DFTool -Name ps-dotenv`, which adds its scoop bucket (shown in the plan) first.
- **mise** activates (`mise activate pwsh`) only when it's the `project-env` tool. Its shims folder is on PATH either way, so tools mise installed keep working under ps-dotenv.
- **direnv** gets Git for Windows' bash through `DIRENV_BASH` unless your `direnv.toml` sets `bash_path`. Up to version 2.37.1 it unloads unrelated variables on Windows ([direnv#1488](https://github.com/direnv/direnv/issues/1488)), so DotForge warns while it's active.

### Pagers: moor, ov, less

These fill the `pager` role, so one of them sets `PAGER`: your `Defaults['pager']` choice, otherwise moor, then ov, then less. A `PAGER` you set yourself is kept unless you name a different tool in `Defaults`.

- **moor** gets `MOOR=-style <theme>` from your theme (`MoorTheme` or `Theme`), unless you've set `MOOR` yourself.
- **ov** gets a catppuccin config that follows your theme (`OvTheme` or `Theme`), passed with `--config` unless you have your own `$XDG_CONFIG_HOME\ov\config.yaml`.
- **less**: DotForge points `PAGER` at the native Windows build (scoop, winget `jftuga.less` or choco), not Git for Windows' copy in `Git\usr\bin`, which needs `TERM` set correctly. With only Git's copy installed, `PAGER` is plain `less`. Key bindings come from `$XDG_CONFIG_HOME\less\lesskey` (`LESSKEYIN`) and search history goes to `$XDG_STATE_HOME\less\history`.

bat isn't a pager here: when it pages, it uses the `PAGER` above.

### Ctrl+R and Ctrl+T: PSFzf, television, fzf, skim

Ctrl+R (search history) and Ctrl+T (insert a path) are two roles, `history-search` and `path-insert`, so a different tool can own each key. Only the winner binds the key: your `Defaults` choice, otherwise PSFzf, then television, then fzf, then skim. For example, `Defaults = @{ 'history-search' = 'television'; 'path-insert' = 'skim' }`. A Ctrl+R or Ctrl+T binding you make yourself before DotForge loads is kept (`Get-DFToolStatus` says so) unless `Defaults` names a tool for that key.

- **skim** (`sk`) takes fzf's options, so it can also run every DotForge picker: `Defaults = @{ picker = 'skim' }`. It gets the same layout as fzf through `SKIM_DEFAULT_OPTIONS`, plus catppuccin colors (`SkimTheme` or `Theme`).
- **television** (`tv`): its one-time setup downloads its channels (`tv update-channels`) and seeds `config.toml` with a catppuccin theme (`TelevisionTheme` or `Theme`). If you already had a `config.toml`, it's kept and setup tells you to set `ui.theme` yourself. To change the theme later, edit `ui.theme` in `$XDG_CONFIG_HOME\television\config.toml`; `Set-DFToolTheme` can't change it. Its Ctrl+R searches history and its Ctrl+T is a smart autocomplete that picks a channel from what you've typed.
- **fzf** and **skim** bind Ctrl+R and Ctrl+T through DotForge's own handler when they win: history is newest first without repeats, and picked paths are quoted when they hold a space.

### Alt+C: change folder (fzf, skim, broot)

Alt+C is the `directory-jump` role: a TUI version of `cd`. Pick a folder and the shell moves there. Only the winner binds it: your `Defaults` choice, otherwise fzf, then skim, then broot. For example, `Defaults = @{ 'directory-jump' = 'broot' }`. An Alt+C binding you make yourself before DotForge loads is kept unless `Defaults` names a tool for it. PSFzf no longer binds Alt+C.

With fzf or skim, the list shows zoxide's folders first, most used and most recent at the top, with no wait. They show as full paths in your theme's accent color: the folders scoring at least `DirectoryJumpMinScore` (3), at most `DirectoryJumpRanked` (10) of them, so folders you visited once don't crowd the list. Then the folders under the current one stream in, one level at a time, down to `DirectoryJumpDepth` levels (6 by default). Nearby folders show up within a moment, even in your home folder, and you can type while the deeper ones arrive. fd does the scan when it's in your `Tools` (it skips hidden folders and what `.gitignore` excludes); without it, DotForge scans by itself. Moving goes through zoxide's `cd`, so the folders you pick count toward its ranking. Without zoxide, the list is just the scan.

### broot

broot browses folders as a tree. `br` runs it in the current folder: leave it on a folder with Ctrl+Enter (or `:cd`) and the shell moves there. broot's own key for this, Alt+Enter, still works where the terminal lets it through; Windows Terminal takes Alt+Enter for fullscreen, so DotForge's seeded `verbs.hjson` adds Ctrl+Enter. A `verbs.hjson` you already had is kept: add `{ key: ctrl-enter, cmd: ":cd" }` to its `verbs` list yourself. Quit any other way and nothing changes. With broot as `directory-jump`, Alt+C runs `br` on folders only.

- Its config lives in `$XDG_CONFIG_HOME\broot` (`BROOT_CONFIG_DIR`). DotForge seeds `conf.hjson` and `verbs.hjson` once, from broot's own defaults.
- Its skin follows `Theme` (`BrootTheme`; the four catppuccin flavors) and is passed after your `conf.hjson` on every `br`, so `Set-DFToolTheme broot catppuccin-latte` takes effect on the next run. For a skin of your own, put it in a folder as `skin.hjson` and set `BrootTheme` to that folder's path.
- broot's one-time setup tells broot that DotForge provides `br`, so broot never offers to install its own. Its installer would add a line to your shell profiles.
- DotForge's `br` reads only the target folder from what broot writes, and never runs it. broot's own `br` does run it, and fails on a folder name with a `'` in it.

### peco and gum

- **peco** gets a catppuccin `$XDG_CONFIG_HOME\peco\config.json` once (`PecoTheme` or `Theme`); after that the file is yours.
- **gum** gets catppuccin colors through its `GUM_*` variables (`GumTheme` or `Theme`); a `GUM_*` color you set yourself is kept. Nothing else changes, since scripts expect gum's stock behavior.

### fnm and zoxide

zoxide replaces `cd` with a smart version: `cd proj` jumps to the most-used folder matching `proj`, and `cdi` picks from a list. fnm wraps the same `cd` to switch Node versions when a folder has a `.nvmrc` or `.node-version`. DotForge chains the two, so `cd` does both.

zoxide hooks the prompt, so it must be set up after your prompt engine; DotForge orders that for you. If you switch oh-my-posh themes with `fpot`, folder tracking stops until you open a new shell.

### glow and fastfetch

glow reads its config from `$XDG_CONFIG_HOME\glow\glow.yml` (DotForge sets `GLOW_CONFIG_HOME`); DotForge wraps it only to pass the session's style with `-s`. fastfetch doesn't read its config location from environment variables on Windows, so DotForge wraps it to pass `$XDG_CONFIG_HOME\fastfetch\config.jsonc` explicitly. You use them as normal:

<!-- system -->
```powershell
Import-Module DotForge
Start-DFSession -Config @{ Tools = @('glow') }
Register-DFTool -Name glow
'# Hello' | Set-Content hello.md
Set-DFToolTheme glow notty | Out-Null
glow hello.md
```

<!-- output: varies -->
```text
  # Hello
```

1. `Set-DFToolTheme glow <style>` switches glow's style for the rest of the session.
2. fastfetch's config file is created from DotForge's template the first time, then left for you to edit.
3. fastfetch and smartmontools make up the [startup banner](configuration.md#startup-banner): `ShowBanner = $true`. smartmontools adds no commands of its own; its `smartctl` reads each drive's health for the banner.

### gsudo

`sudo` runs gsudo. If Windows' own `sudo.exe` would otherwise win, DotForge moves gsudo's folder to the front of `PATH`. `please` runs the previous command again, elevated, in a new process.

Windows' own `sudo` isn't a separate DotForge tool: when DotForge needs admin rights (an install through choco), it uses gsudo if it's in your `Tools`, else Windows' `sudo` when it's turned on in inline mode, else a separate administrator window.

### Process viewers and disk usage

These tools all do their own thing and live side by side; none of them takes a classic name such as `top`, `du` or `df`. `Get-DFRole process-viewer` and `Get-DFRole disk-usage` list them. `+admin-tools` installs a sensible pair: procs and dust.

- **procs**, **bottom** (`btm`) and **duf** follow `Theme` with their own light or dark colors (`ProcsTheme`, `BottomTheme`, `DufTheme`).
- **Config folders:** procs, bottom, glances and gdu read their config from `$XDG_CONFIG_HOME\<tool>\` once you create it there (for example `$XDG_CONFIG_HOME\bottom\bottom.toml`), and dust reads `$XDG_CONFIG_HOME\dust\config.toml` itself. A config you already have in the tool's own location (for example `%APPDATA%\bottom\bottom.toml`) holds the tool back until you run `Resolve-DFToolConflict`.
- **dua** keeps its config in `%APPDATA%\dua-cli` whatever `XDG_CONFIG_HOME` says, and has no flag to change that.
- **btop** comes in two builds, both installed as `btop.exe`. Plain `btop` (the default) runs as you. `btop-lhm` (`scoop install btop-lhm`) adds hardware sensors through LibreHardwareMonitor and needs admin rights; with gsudo in your `Tools`, DotForge runs it through gsudo in the same console. btop keeps `btop.conf` beside its exe, so it can't move under XDG; setup copies catppuccin themes into its themes folder, and you choose one with `color_theme` in `btop.conf` or in btop's options. scoop keeps each build's folder separately, so after switching builds run `Invoke-DFToolSetup btop` to copy the themes again.
- **pstop:** winget's install also adds an `htop` link to pstop. htop itself has no Windows build. ncdu has none either; gdu is its port.

### lsd

lsd crashes when pointed at a config file that doesn't exist (lsd 1.2.0), so DotForge passes `--config-file $XDG_CONFIG_HOME\lsd\config.yaml` only while that file exists; without it, lsd uses its own defaults. If you already have a config in lsd's own locations (`%USERPROFILE%\.config\lsd` or `%APPDATA%\lsd`), lsd stays inactive as a conflict until you run `Resolve-DFToolConflict lsd -Move` or `-Adopt`.

### mdcat and mdv

mdcat's theme is set through `MDCAT_THEME`, and its completions are registered. mdv has no theme variable, so its theme is written to `$XDG_CONFIG_HOME\mdv\config.yaml` the first time mdv is registered, and never changed after that.

### oh-my-posh and starship

These are prompt engines; install one. Both follow `Theme` (or `StarshipTheme`, `OhMyPoshTheme`), and `Set-DFToolTheme` switches them live.

- **oh-my-posh** uses `$Env:POSH_THEME` if you set it, otherwise the single `*.omp.*` file in `$XDG_CONFIG_HOME\oh-my-posh\` (it warns when there are several). With neither, it uses the catppuccin theme that matches `Theme`: a same-named `.omp.json` in `POSH_THEMES_PATH`, else the copy DotForge ships (oh-my-posh's own catppuccin themes). `Set-DFToolTheme oh-my-posh catppuccin-latte` switches to that theme for the rest of the session, even over your own config.
- **starship** reads `$XDG_CONFIG_HOME\starship\starship.toml`, which DotForge never writes. If its top-level `palette` line names a different catppuccin flavor than `Theme`, DotForge writes a copy to `$XDG_CACHE_HOME\dotforge\starship\starship-<palette>.toml` with only that line changed (one per palette, so open shells using different flavors don't affect each other) (adding the flavor's `[palettes.*]` table if your file lacks it), and points `STARSHIP_CONFIG` at the copy. When the palette already matches, starship reads your file, so your edits show at once. While the copy is in use, an edit to your file shows from the next shell (or the next `Set-DFToolTheme starship …`). A `STARSHIP_CONFIG` you set yourself is used the same way: it's the file DotForge copies, and it's never written. A config without a `palette` line keeps its own colors; setup says so once.

`fpot` previews and applies oh-my-posh themes for the current session. It lists the `*.omp.json` files in `POSH_THEMES_PATH`, which DotForge sets to `$XDG_DATA_HOME\oh-my-posh\themes`; copy the themes you want to browse there.

### PSReadLine

DotForge sets Emacs editing keys, history predictions, a 10,000-entry history saved incrementally without duplicates, and a color theme. It moves the history file to `$XDG_STATE_HOME\psreadline\history`; your old history in PowerShell's default location isn't copied there. See [configuration](configuration.md#command-line-editing-keys) to keep Windows keys.

### rustup, uv and other relocated tools

Some tools move their data under the XDG folders: rustup to `$XDG_DATA_HOME\rustup` and `$XDG_DATA_HOME\cargo`, uv's tools and Pythons to `$XDG_DATA_HOME\uv`. A toolchain or package already installed in the old location isn't found afterwards. Move it, or reinstall. `Install-DFTool` and `Update-DFTool` set these variables while the installer runs, so installing rustup, or a crate through cargo, lands in the new folders without setting anything first. The [safety page](safety.md) lists every relocated tool.

bun, pnpm, pipx, pip and python follow too:

- **bun:** global packages and their commands go in `$XDG_DATA_HOME\bun` (its `bin` goes on `PATH`), and its cache in `$XDG_CACHE_HOME\bun`.
- **pnpm:** its global commands go in `$XDG_DATA_HOME\pnpm` (on `PATH`). pnpm reads the `XDG_*` folders itself for its config, store, cache and state.
- **pipx:** its apps' environments go in `$XDG_DATA_HOME\pipx`. Their commands stay in `~\.local\bin`.
- **pip:** its config file is `$XDG_CONFIG_HOME\pip\pip.ini`, and its cache `$XDG_CACHE_HOME\pip`.
- **Python:** the REPL keeps its history in `$XDG_STATE_HOME\python\history` (Python 3.13+).

An old home that holds only installed packages, a cache or history (`~\.bun`, pnpm's `%LOCALAPPDATA%\pnpm`, pipx's `%LOCALAPPDATA%\pipx\pipx`, pip's cache, `~\.python_history`) doesn't hold the tool back. `Get-DFToolStatus` says what's there and how to move it, the first time DotForge finds it. An existing `pip.ini` in `%APPDATA%\pip` is your config, so pip waits for `Resolve-DFToolConflict`, like any other tool.

### vivid

vivid generates `LS_COLORS`, which eza, lsd and many other listing tools read. The generated value is cached, so vivid runs only when the theme changes. After upgrading vivid, refresh it with `Invoke-DFApplyLSColorsTheme -Name <theme> -Force`.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `the 'Microsoft.WinGet.Client' module is required` | winget pickers without their module | `Install-Module Microsoft.WinGet.Client -Scope CurrentUser`. |
| `the 'Scoop' module is required` | scoop pickers without their module | `Install-Module Scoop -Scope CurrentUser`. |
| `no oh-my-posh config found` | no theme file where DotForge looks | Set `$Env:POSH_THEME`, or put one `*.omp.json` in `$XDG_CONFIG_HOME\oh-my-posh\`. |
| `direnv requires PowerShell 7.2+` | older PowerShell | Upgrade PowerShell. |
| `direnv <v> on Windows unloads environment variables it didn't set` | direnv 2.37.1 or older is your `project-env` tool | Switch with `$DFConfig.Defaults = @{ 'project-env' = 'ps-dotenv' }`, or update direnv once a fixed release ships. |
| `direnv needs Git for Windows' bash` | no `bin\bash.exe` above `git.exe` | Install Git for Windows, or set `bash_path` in `direnv.toml`. |
| `dotenv info: <file> is not authorized` | ps-dotenv's safe mode found a `.env` outside your approved folders | Add the folder to `DotenvApprovedDirs`, or set `DotenvSafeMode = $false`. |
| rustup can't find your toolchain | `RUSTUP_HOME` now points under `$XDG_DATA_HOME` | Move `~\.rustup` and `~\.cargo` there, or run `rustup toolchain install stable`. |
| `zoxide` stops learning folders after `fpot` | the theme switch replaced the prompt hook | Open a new shell. |

More on the [troubleshooting page](troubleshooting.md).
