# Tools

**Audience:** DotForge users who want to know what it does to each of their tools.  
**Topic:** the 43 tools DotForge configures, the commands they add, and tool-specific behavior.  
**Goal:** know what changes when a tool is registered, and use the commands it adds.

`Register-DFTool` configures a tool only if it's installed. For the exact environment variables, aliases and install ids of each tool, see the generated [tool records](../reference.md#tool-records); this page explains the behavior behind them.

## Groups

Request a group in `Start-DFSession -Config` with its leading `+`; use `Get-DFToolGroup` to inspect it. `+core`: psreadline, PSFzf, fzf, eza, bat, fd, ripgrep, zoxide, carapace, less; `+prompt`: starship; `+git`: delta, gh, lazygit; `+dev-tools`: jq, micro, mise, chezmoi; `+javascript-dev`: fnm, node, npm; `+python-dev`: uv, python, pip, pipx; `+rust-dev`: rustup, cargo; `+admin-tools`: gsudo, procs, fastfetch, curl, wget; `+markdown`: glow; `+package-managers`: scoop, winget.

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
| System | fastfetch, gsudo, procs |
| Network | curl, wget |
| Containers | docker |
| Per-folder environments | ps-dotenv, mise, direnv (one is active; see below) |
| Prompt | oh-my-posh, starship |
| Editor | micro |
| Fuzzy finding and navigation | fzf, zoxide |
| Pager | moor, ov, less (one sets `PAGER`; see below) |
| Package managers | choco, npm, scoop, winget |
| Development | bitwarden, chezmoi, delta, fnm, gh, lazygit, rustup, uv, vcpkg |
| PowerShell modules | posh-git, PSFzf, psreadline, Terminal-Icons |

## Commands each tool adds

| Tool | Commands and keys |
| --- | --- |
| bat | `cat` → `bat -pp` |
| chezmoi | `cz` |
| choco | `cins`, `crm`, `cup` pickers; `Ctrl+G` `C` |
| eza | `ls`, `ll`, `la`, `tree` (when it wins the `listing` role); `ff` file picker |
| fd | `ffd` file picker |
| fnm | `cd` also switches Node versions |
| gsudo | `sudo` → gsudo; `please` re-runs the last command elevated |
| lazygit | `lg` |
| lsd | `ls`, `ll`, `la`, `tree` (when it wins the `listing` role; see [roles](configuration.md#choose-a-tool-for-each-role)) |
| npm | `nls` → `npm list -g --depth=0` |
| oh-my-posh | `fpot` prompt theme picker (when it wins the `prompt` role) |
| posh-git | `fco` (checkout branch), `flog` (show commit), `fga` (stage files), `fstash` (apply stash) |
| procs | `fkill` process picker |
| PSFzf | `Ctrl+T` (insert a path), `Ctrl+R` (history), `Alt+C` (change folder), fuzzy Tab |
| psreadline | `fprl` color theme picker; `Ctrl+P` / `Ctrl+N` history search |
| ripgrep | `frg` search-and-open picker |
| scoop | `sins`, `srm`, `sup` pickers; `Ctrl+G` `S` |
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

- **moor** gets `MOOR=-style <theme> -quit-if-one-screen` from your theme (`MoorTheme` or `Theme`), unless you've set `MOOR` yourself.
- **ov** runs as `ov --quit-if-one-screen`. Its colors come only from `$XDG_CONFIG_HOME\ov\config.yaml`, which DotForge doesn't write; `ov --generate-config` prints a starting file.
- **less**: DotForge points `PAGER` at the native Windows build (scoop, winget `jftuga.less` or choco), not Git for Windows' copy in `Git\usr\bin`, which needs `TERM` set correctly. With only Git's copy installed, `PAGER` is plain `less`. Key bindings come from `$XDG_CONFIG_HOME\less\lesskey` (`LESSKEYIN`) and search history goes to `$XDG_STATE_HOME\less\history`.

bat isn't a pager here: when it pages, it uses the `PAGER` above.

### fnm and zoxide

zoxide replaces `cd` with a smart version: `cd proj` jumps to the most-used folder matching `proj`, and `cdi` picks from a list. fnm wraps the same `cd` to switch Node versions when a folder has a `.nvmrc` or `.node-version`. DotForge chains the two, so `cd` does both.

zoxide hooks the prompt, so it must be set up after your prompt engine; DotForge orders that for you. If you switch oh-my-posh themes with `fpot`, folder tracking stops until you open a new shell.

### glow and fastfetch

Neither tool reads its config location from environment variables on Windows, so DotForge wraps each in a function that passes the path explicitly: `$XDG_CONFIG_HOME\glow\glow.yml` and `$XDG_CONFIG_HOME\fastfetch\config.jsonc`. You use them as normal:

```powershell
Import-Module DotForge
Start-DFSession -Config @{ Tools = @('glow') }
Register-DFTool -Name glow
'# Hello' | Set-Content hello.md
$global:DFGlowStyle = 'notty'
glow hello.md
```

<!-- output: varies -->
```text
  # Hello
```

1. `$global:DFGlowStyle` switches glow's style for the rest of the session.
2. fastfetch's config file is created from DotForge's template the first time, then left for you to edit.

### gsudo

`sudo` runs gsudo. If Windows' own `sudo.exe` would otherwise win, DotForge moves gsudo's folder to the front of `PATH`. `please` runs the previous command again, elevated, in a new process.

### lsd

lsd panics when pointed at a config file that doesn't exist, so DotForge doesn't manage its config and prints a reminder each time lsd is registered. To stop the reminder, exclude lsd (`ExcludeTools = @('lsd')`), or uninstall one of eza and lsd.

### mdcat and mdv

mdcat's theme is set through `MDCAT_THEME`, and its completions are registered. mdv has no theme variable, so its theme is written to `$XDG_CONFIG_HOME\mdv\config.yaml` the first time mdv is registered, and never changed after that.

### oh-my-posh and starship

These are prompt engines; install one. oh-my-posh uses `$Env:POSH_THEME` if you set it, otherwise the single `*.omp.*` file in `$XDG_CONFIG_HOME\oh-my-posh\` (it warns when there are none or several). starship reads `$XDG_CONFIG_HOME\starship\starship.toml`.

`fpot` previews and applies oh-my-posh themes for the current session. It lists the `*.omp.json` files in `POSH_THEMES_PATH`, which DotForge sets to `$XDG_DATA_HOME\oh-my-posh\themes`; copy the themes you want to browse there.

### PSReadLine

DotForge sets Emacs editing keys, history predictions, a 10,000-entry history saved incrementally without duplicates, and a color theme. It moves the history file to `$XDG_STATE_HOME\psreadline\history`; your old history in PowerShell's default location isn't copied there. See [configuration](configuration.md#command-line-editing-keys) to keep Windows keys.

### rustup, vcpkg and other relocated tools

Some tools move their data under the XDG folders: rustup to `$XDG_DATA_HOME\rustup` and `$XDG_DATA_HOME\cargo`, vcpkg to `$XDG_DATA_HOME\vcpkg`. A toolchain or package already installed in the old location isn't found afterwards. Move it, or reinstall. The [safety page](safety.md) lists every relocated tool.

### vivid

vivid generates `LS_COLORS`, which eza, lsd and many other listing tools read. The generated value is cached, so vivid runs only when the theme changes. After upgrading vivid, refresh it with `Invoke-DFApplyLSColorsTheme -Name <theme> -Force`.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `lsd requires manual XDG configuration` on every start | lsd is installed and registered | Skip lsd or ignore the note; nothing is wrong. |
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
