# DotForge (**Experimental**)

<img src="assets/dotforge1.png" align="right" width="180" alt="DotForge logo: a hammer striking a glowing shell-prompt chevron (>) on an anvil, throwing sparks">

**A PowerShell module to manage your command line tools, easily & consistently.**

**[Install from the PowerShell Gallery](https://www.powershellgallery.com/packages/DotForge)** — `Install-PSResource -Name DotForge -Scope CurrentUser`

> [!WARNING]
> **Registering a tool that's already installed can make it lose track of its existing files.**
> DotForge relocates many tools' config/data/cache to XDG-standard paths (e.g. `RUSTUP_HOME`/
> `CARGO_HOME` for `rustup`, `VCPKG_ROOT` for `vcpkg`, PSReadLine's history file). If that tool
> already has files at its old default location — an existing Rust toolchain, installed vcpkg
> packages, prior command history — it won't find them once DotForge points it somewhere else.
> DotForge never moves or deletes them. Move them yourself, reinstall, or set the variable
> yourself first to keep the old location. [Safety](docs/guide/safety.md#relocated-tool-data)
> lists every tool affected.

The goal of this tool is to make it easy to use commonly useful command line tools with a consistent and out-of-the-box useful configuration. For each tool it does its best to enforce XDG style standard directories (yes, on Windows) as I find this makes it easier to manage my configurations (with chezmoi). It also sets sensible, common default options, applies a standard color theme across all output, provides useful pickers with fzf as well as useful aliases. It also wires in shell integrations and hooks trying to ensure that they don't overwrite each other (fzf, zoxide, direnv, carapace, inshellisense, etc.). And it provides command line completions through carapace and inshellisense with occasional manual additions added through carapace's extension mechanism.

This is an experimental project developed out of my own PowerShell profile and generalized to hopefully be useful to others. It's also an experiment with AI development. I have a lifetime of development experience so it's not vibe coded slop. But it is currently the center of my learning experience with AI. I find it amazing at what the various AI tools (Claude, Codex, and Gemini are used here) are capable of. I also find it amazing at the things that they miss and get wrong, at bad design decisions, etc. The code is not yet fully reviewed, but I use this for my profile every day. Optimization is still a huge goal that we've not yet attained.

## What it does

- **Configures 45 command-line tools** (bat, eza, fzf, ripgrep, zoxide, delta, starship, …) with XDG folders, sensible defaults and one shared color theme, from a JSON record per tool.
- **Lets you pick one tool per job**: prompt, pager, editor, `ls` replacement and more. Only the tool you choose (or the best installed one) hooks into the shell; see [roles](docs/guide/configuration.md#choose-a-tool-for-each-role).
- **Adds fuzzy pickers and short commands**: change folders, check out git branches, browse help, install packages, all through fzf.
- **Sets up completion** for hundreds of commands through Carapace, PSFzf and inshellisense, without them fighting over the Tab key.
- **Installs tools** with one command through scoop, winget or Chocolatey, and searches every package catalog at once with `trifle`.

## Requirements

- PowerShell 7.2 or later
- Windows 11 (macOS and Linux are planned)
- scoop, winget or Chocolatey, to install tools
- [fzf](https://github.com/junegunn/fzf), for the pickers (optional but recommended)

## Quick start

Install the module:

<!-- system -->

```powershell
Install-PSResource -Name DotForge -Scope CurrentUser
```

Then add these lines to your profile (`notepad $PROFILE`), and open a new terminal:

```powershell
Import-Module DotForge
Initialize-DFEnvironment
Register-DFTool -All
```

<!-- output: varies -->
```text
DotForge: Environment ready. Package managers: scoop, winget, choco
```

1. `Import-Module DotForge` loads the module and its general commands (`which`, `touch`, `mkcd`, `up`, …).
2. `Initialize-DFEnvironment` sets up the XDG folders and finds your package managers.
3. `Register-DFTool -All` configures every supported tool you have installed. Tools you don't have are skipped.

Install a tool you don't have yet with `Install-DFTool -Name ripgrep`. To run the latest code from GitHub instead of the Gallery, clone the repository and `Import-Module <clone>\DotForge.psd1`.

## Documentation

| Page | Read it to |
| --- | --- |
| [Getting started](docs/guide/getting-started.md) | install DotForge and set up your profile, step by step |
| [Configuration](docs/guide/configuration.md) | change themes, pick between eza and lsd, skip tools, every `$DFConfig` setting |
| [Tools](docs/guide/tools.md) | see the 43 tools and the commands each adds |
| [Pickers and helpers](docs/guide/pickers-and-helpers.md) | use the fuzzy pickers and general commands, and build your own picker |
| [Completion](docs/guide/completion.md) | set up Tab completion with Carapace, PSFzf or inshellisense |
| [Package catalog](docs/guide/package-catalog.md) | search every package catalog at once with `trifle` |
| [Coreutils conflicts](docs/guide/coreutils-conflicts.md) | fix commands that Coreutils for Windows intercepts |
| [Troubleshooting](docs/guide/troubleshooting.md) | look up any warning or error |
| [Safety](docs/guide/safety.md) | see everything DotForge reads, writes, runs and sends |
| [Writing a tool record](docs/guide/writing-a-tool.md) | add or change a tool |
| [Reference](docs/reference.md) | look up any command, parameter or tool record |
| [Examples](examples/README.md) | start from a complete profile |

Every command also has full help in the shell: `Get-Help <command> -Full`.

## Related

DotForge grew out of my own PowerShell profile. These are the projects around it:

- **[dotfiles-windows](https://github.com/simsrw73/dotfiles-windows)**: My whole Windows setup, managed with chezmoi: `~/.config`, the PowerShell profile, apps, keys and secrets. The other projects here are either used by it or published from it.
- **[w11dwm-config](https://github.com/simsrw73/w11dwm-config)**: The keyboard-driven tiling desktop (komorebi, AutoHotkey, yasb, Flow Launcher, wpm), copied out of dotfiles-windows to share and discuss. Its key bindings, app launcher and window switcher are built on Legend.ahk.
- **[Legend.ahk](https://github.com/simsrw73/Legend.ahk)**: An AutoHotkey v2 library: an Alt+/ overlay of the shortcuts for the app you're in, which-key style chord menus, pickers and a window switcher. It runs the keys in w11dwm-config and dotfiles-windows.
- **[starship-p9cat](https://github.com/simsrw73/starship-p9cat)**: A Starship prompt in the powerlevel9k style, in Catppuccin colors. It's the prompt in dotfiles-windows, and a port of the CatPow theme from poshcat.omp.
- **[poshcat.omp](https://github.com/simsrw73/poshcat.omp)**: Catppuccin themes for Oh My Posh, including CatPow, a powerlevel10k-style theme. It was my prompt before Starship; starship-p9cat carries CatPow over.

## License

MIT — see [LICENSE](LICENSE).
