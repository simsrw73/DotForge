# DotForge Profile Examples

Copy one of these as your `$PROFILE` starting point, or use them as reference
when integrating DotForge into an existing profile.

| File | When to use |
|------|-------------|
| `01-minimal.ps1` | Getting started, CI, shared machines — zero config |
| `02-standard.ps1` | Typical developer setup with $DFConfig and first-run bootstrap |
| `03-selective.ps1` | Lean startup — register tools by group, not all at once |
| `04-vscode-fastpath.ps1` | Full profile with VS Code terminal detection and early return |
| `05-trifle-catalog.ps1` | Package catalog info (`trifle`) usage + scheduled cache refresh |
| `06-winget-pickers.ps1` | winget fuzzy pickers (`wins`/`wrm`/`wup`) with preview + keybindings |
| `07-scoop-choco-pickers.ps1` | scoop (`sins`/`srm`/`sup`) and choco (`cins`/`crm`/`cup`) fuzzy pickers |

## Common patterns

### First-run bootstrap

```powershell
$missing = @('eza', 'bat', 'fzf', 'ripgrep') |
    Where-Object { -not (Get-Command "$_.exe" -ErrorAction Ignore) }
if ($missing) { Install-DFTool -Name $missing }
```

### Pick a winner between competing tools

`eza` and `lsd` both declare `role: 'listing'` and compete for `ls`/`ll`/`la`/`tree`.
`Defaults` names the winner; the loser keeps everything else it declares (XDG
config, other aliases) — only the contested alias keys are suppressed.

```powershell
$DFConfig = @{ Defaults = @{ listing = 'eza' } }
```

### Skip a tool entirely

```powershell
$DFConfig = @{ SkipTools = @('lsd') }  # don't register lsd at all
```

### Query the registry

```powershell
Get-DFTool -Tag pager          # → less, moor, delta
Find-DFTool -Pattern 'rust'    # → rustup, cargo
Get-DFTool -Name ripgrep       # → full record with packages, xdg, completions
```
