# DotForge

<img src="assets/dotforge1.png" align="right" width="180" alt="DotForge logo">

**A PowerShell module that turns CLI tool configuration into a one-time-write,
zero-copy-paste operation — across every machine you set up.**

Every time you install a new tool like `bat`, `delta`, or `ripgrep`, there is a
ritual: locate where it stores its config, set the right environment variables,
maybe define a couple of aliases. Do this for thirty tools and you
have a profile that works — on one machine. DotForge encodes that knowledge into a
JSON database so `Register-DFTool -All` handles all of it in one shot, on every
machine.

## What it does

**XDG path compliance.** Most CLI tools support the [XDG Base Directory
Specification](https://specifications.freedesktop.org/basedir-spec/latest/) — a
standard that routes config to `~/.config`, data to `~/.local/share`, and cache to
`~/.cache` rather than scattering dotfiles across your home directory. DotForge sets
the right environment variable for each tool to opt it in. This is the feature that
inspired the whole module: I use [chezmoi](https://www.chezmoi.io/) to manage my
dotfiles, and keeping everything under `~/.config` means my tool configurations sync
to every new machine automatically — no hunting, no manual re-setup.

**fzf pickers.** Interactive fuzzy-find workflows are built in for common operations:
fuzzy `cd`, process management, help browsing, ripgrep result navigation, and more.
Any tool with a picker entry in its JSON record gets a full `Invoke-DFPicker`-backed
function and alias registered automatically. Set `$Env:Picker = 'skim'` to use an
alternative fuzzy finder.

**One-command install.** `Install-DFTool -Name <tool>` installs via whichever of
scoop, winget, or choco you have available — no need to remember package IDs.

## Requirements

- PowerShell 7.0+
- Windows 11 (v0.1; macOS/Linux planned)
- At least one package manager: [scoop](https://scoop.sh), [winget](https://learn.microsoft.com/windows/package-manager/winget/), or [choco](https://chocolatey.org/)
- [fzf](https://github.com/junegunn/fzf) for picker functions (optional but recommended)

## Installation

### From GitHub (current)

```powershell
git clone https://github.com/simsrw73/DotForge.git
Import-Module C:\path\to\DotForge\DotForge.psd1
```

### From PSGallery (coming soon)

```powershell
Install-PSResource -Name DotForge -Scope CurrentUser
```

## Quick Start

```powershell
# 1. Bootstrap XDG dirs and detect package managers
Initialize-DFEnvironment

# 2. Configure all installed tools in the current session
Register-DFTool -All

# 3. Install a tool you don't have yet
Install-DFTool -Name ripgrep
```

## User Configuration (`$DFConfig`)

Set `$DFConfig` in your profile **before** importing DotForge:

```powershell
$DFConfig = @{
    PackageManagerOrder = @('scoop', 'winget')  # PM preference for Install-DFTool
    SkipTools           = @('lsd')              # excluded from Register-DFTool -All
    PSReadLineTheme     = 'catppuccin-mocha'    # PSReadLine color theme (name or path)
    ShimsPath           = "$HOME\.local\bin"    # shim output dir for New-DFShim (default: $HOME\.local\bin)
}
Import-Module DotForge
Register-DFTool -All
```

## Exported Cmdlets

**Core (Layer 1–3)**

| Cmdlet                          | Alias | Purpose                                          |
| ------------------------------- | ----- | ------------------------------------------------ |
| `Initialize-DFEnvironment`      |       | Bootstrap XDG dirs; detect package managers      |
| `Register-DFTool [-Name\|-All]` |       | Configure tools in the current session           |
| `Install-DFTool -Name <tool>`   |       | Install via scoop / winget / choco / psresource  |
| `New-DFShim [[-Target] <path>] [-Name] [-Force]` |       | Create a `.cmd` shim forwarding invocations to an off-PATH executable |
| `Get-DFTool [-Name] [-Tag]`     |       | Query the tool registry                          |
| `Find-DFTool -Pattern <str>`    |       | Wildcard search across name / description / tags |
| `Add-DFToPath <dir> [-Prepend]` |       | Normalized, dedup PATH addition                  |
| `New-DFDirectory <path>`        |       | Idempotent directory creation                    |
| `Invoke-DFPicker`               |       | Generalized fzf picker skeleton                  |
| `Invoke-DFWithPager`            | `pg`  | Pipe output through `$Env:Pager`                 |

**Help & Discovery**

| Cmdlet                 | Alias   | Purpose                                |
| ---------------------- | ------- | -------------------------------------- |
| `Invoke-DFHelp <name>` | `hm`    | Get-Help with ANSI header colorization |
| `Show-DFCliHelp <cmd>` | `clh`   | Colorized external-CLI help (auto-detects the help flag) |
| `Show-DFCliHelpPaged`  | `clhp`  | Same as `clh`, through the pager       |
| `Select-DFHelpTopic`   | `fh`    | Fuzzy-browse all help topics           |
| `Select-DFCommand`     | `fcmd`  | Fuzzy-browse all commands              |
| `Select-DFVerb`        | `fverb` | Fuzzy-browse approved PS verbs         |
| `Select-DFModule`      | `fmod`  | Fuzzy-browse installed modules         |

```powershell
clh eza            # colorized eza help (flag auto-detected + cached)
clh git -Flag --help   # force a specific flag instead of auto-detecting
clhp docker        # colorized docker help through the pager
```

`clh` runs an external tool's help and colorizes it (bold-yellow headers, faint
flags). The help flag is auto-detected (`--help`, `-help`, `-?`, `help`, `-h`)
and cached per command under `$XDG_CACHE_HOME/dotforge/cli-help-flags.json`; pass
`-Force` to re-detect.

**Navigation**

| Cmdlet                         | Alias  | Purpose                            |
| ------------------------------ | ------ | ---------------------------------- |
| `Set-DFLocationUp [-Levels]`   | `up`   | Navigate up N directory levels     |
| `New-DFDirectoryAndSet <path>` | `mkcd` | Create directory and cd into it    |
| `Select-DFLocation`            | `fcd`  | Fuzzy-browse subdirectories and cd |

**File System**

| Cmdlet               | Alias   | Purpose                               |
| -------------------- | ------- | ------------------------------------- |
| `New-DFFile <path>`  | `touch` | Create file or update its timestamp   |
| `Get-DFWhich <name>` | `which` | Find executable path                  |
| `Open-DFItem <path>` | `open`  | Open file/folder with default handler |

**Process**

| Cmdlet             | Alias | Purpose                               |
| ------------------ | ----- | ------------------------------------- |
| `Select-DFProcess` | `fps` | Fuzzy-browse running processes        |
| `Get-DFTopProcess` | `top` | Show top N processes by CPU or memory |

**Environment & Profile**

| Cmdlet                   | Alias    | Purpose                                      |
| ------------------------ | -------- | -------------------------------------------- |
| `Get-DFEnv [-Pattern]`   | `env`    | List env vars as colorized KEY=VALUE; plain when piped/redirected or `NO_COLOR` |
| `Get-DFPath`             | `path`   | List PATH entries one per line               |
| `Select-DFEnvVar`        | `fenv`   | Fuzzy-browse environment variables           |
| `Edit-DFProfile`         | `ep`     | Open `$PROFILE` in `$Env:EDITOR`             |
| `Invoke-DFProfileReload` | `reload` | Dot-source `$PROFILE` in the current session |

**Clipboard**

| Cmdlet                | Alias   | Purpose                                    |
| --------------------- | ------- | ------------------------------------------ |
| `Copy-DFToClipboard`  | `copy`  | Copy string or pipeline input to clipboard |
| `Get-DFFromClipboard` | `paste` | Get clipboard contents                     |

## Recommended Setup

### Environment variables

DotForge uses these env vars when present. Add them to your PowerShell profile:

```powershell
$Env:EDITOR = 'code'              # editor for ep (Edit-DFProfile) and frg (ripgrep picker)
$Env:VISUAL  = 'code'             # GUI editor fallback (conventional POSIX variable)
$Env:PAGER   = 'less'             # pager for pg (Invoke-DFWithPager); try 'bat --paging=always'
$Env:Picker  = 'fzf'              # fuzzy picker used by all DotForge pickers; 'skim' also works
```

### Scoop

- **git** is required for scoop bucket operations (`scoop bucket add`, `scoop update`):

  ```powershell
  scoop install git
  ```

- **[scoop-search](https://github.com/shilangyu/scoop-search)** makes `scoop search` dramatically faster. DotForge hooks it automatically once installed:
  ```powershell
  scoop install scoop-search
  ```

## Tool Records

Each tool is a `Tools/<name>.json` file. Required: `name`, `executable`.

Optional:

- `type` — `"exe"` (default) or `"module"` (PS module; checked via `Get-Module -ListAvailable`)
- `packages` — PM IDs: `scoop`, `winget`, `choco`, `psresource`
- `xdg` — `method` (`default`/`env`/`config`/`wrapper`/`manual`), `vars`, `dirs`
- `aliases` — `{ "alias": { "command": "...", "args": [...] } }`
- `picker` — declarative fzf spec or `"custom"` (companion `.ps1`)
- `dependsOn` — array of tool names that must be registered first (e.g. `["psreadline"]` for PSFzf)

Companion `Tools/<name>.ps1` files are dot-sourced automatically on registration.
Inside a companion, `$DFCurrentTool` holds the tool's parsed JSON object.

## Included Tools (32)

| Group            | Tools                                              |
| ---------------- | -------------------------------------------------- |
| File/dir         | bat, eza, fd, ripgrep, broot                       |
| Text/data        | jq, glow                                           |
| System           | procs, winfetch, gsudo                             |
| Network          | curl, wget                                         |
| Container        | docker                                             |
| Editors          | micro                                              |
| Fuzzy/nav        | fzf, zoxide                                        |
| Pagers           | less                                               |
| Package managers | scoop, winget, npm                                 |
| Dev              | bitwarden, chezmoi, delta, gh, lazygit, rustup, uv |
| PS modules       | posh-git, psreadline, PSFzf, Terminal-Icons, oh-my-posh |

## Tool-Specific Helpers

Companion `.ps1` files register globals (not module exports) when their tool is registered.

**oh-my-posh** (`Tools/oh-my-posh.ps1`)

| Function / Alias               | Purpose                                    |
| ------------------------------ | ------------------------------------------ |
| `Select-PoshTheme` / `fpot`    | Live fzf theme picker for oh-my-posh       |

**posh-git** (`Tools/posh-git.ps1`)

| Function / Alias               | Purpose                                    |
| ------------------------------ | ------------------------------------------ |
| `Select-GitBranch` / `fco`     | Fuzzy checkout — switch branch             |
| `Select-GitLog` / `flog`       | Fuzzy browse commit log                    |
| `Select-GitFile` / `fga`       | Fuzzy stage files                          |
| `Select-GitStash` / `fstash`   | Fuzzy apply stash entry                    |

**psreadline** (`Tools/psreadline.ps1`)

| Function / Alias                              | Purpose                                          |
| --------------------------------------------- | ------------------------------------------------ |
| `Select-PSReadLineTheme` / `fprl`             | Live fzf theme picker for PSReadLine colors      |
| `Invoke-DFApplyPSReadLineTheme -Name <theme>` | Apply a named or path-based PSReadLine theme     |

## License

MIT — see [LICENSE](LICENSE).
