# DotForge

**PowerShell module for registering and configuring CLI tools — XDG paths, completion
caching, fzf pickers, and one-command installation.**

DotForge encodes CLI tool configuration knowledge into a JSON database and applies it
on demand. Stop copy-pasting the same env vars and completers between dotfiles repos.

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

# 4. Refresh completions after upgrading tools
Update-DFCompletions
```

## User Configuration (`$DFConfig`)

Set `$DFConfig` in your profile **before** importing DotForge:

```powershell
$DFConfig = @{
    PackageManagerOrder = @('scoop', 'winget')  # PM preference for Install-DFTool
    SkipTools           = @('lsd')              # excluded from Register-DFTool -All
}
Import-Module DotForge
Register-DFTool -All
```

## Exported Cmdlets

| Cmdlet | Purpose |
|--------|---------|
| `Initialize-DFEnvironment` | Bootstrap XDG dirs; detect package managers |
| `Register-DFTool [-Name] [-All]` | Configure tools in the current session |
| `Install-DFTool -Name <tool>` | Install via scoop / winget / choco / psresource |
| `Update-DFCompletions [-Name]` | Refresh dynamic completion caches |
| `Get-DFTool [-Name] [-Tag]` | Query the tool registry |
| `Find-DFTool -Pattern <str>` | Wildcard search across name / description / tags |
| `Add-DFToPath <dir> [-Prepend]` | Normalized, dedup PATH addition |
| `Ensure-DFDir <path>` | Idempotent directory creation |
| `Invoke-DFPicker` | Generalized fzf picker skeleton |
| `Get-DFCachedCompletion` | Mtime-based completion script caching |

## Tool Records

Each tool is a `Tools/<name>.json` file. Required: `name`, `executable`.

Optional:
- `type` — `"exe"` (default) or `"module"` (PS module; checked via `Get-Module -ListAvailable`)
- `packages` — PM IDs: `scoop`, `winget`, `choco`, `psresource`
- `xdg` — `method` (`default`/`env`/`config`/`wrapper`/`manual`), `vars`, `dirs`
- `completions` — `type` (`static`/`dynamic`), `flags` or `command`
- `aliases` — `{ "alias": { "command": "...", "args": [...] } }`
- `picker` — declarative fzf spec or `"custom"` (companion `.ps1`)

Companion `Tools/<name>.ps1` files are dot-sourced automatically on registration.

## Included Tools (30)

| Group | Tools |
|-------|-------|
| File/dir | bat, eza, fd, ripgrep, broot |
| Text/data | jq, glow |
| System | procs, winfetch |
| Network | curl, wget |
| Container | docker |
| Editors | micro |
| Fuzzy/nav | fzf, zoxide |
| Pagers | less |
| Package managers | scoop, winget, npm |
| Dev | gh, delta, lazygit, rustup, uv, chezmoi |
| PS modules | posh-git, PSFzf, Terminal-Icons, oh-my-posh |

## License

MIT — see [LICENSE](LICENSE).
