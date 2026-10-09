# Configuration

**Audience:** DotForge users who want to change its defaults.  
**Topic:** session configuration, themes, choosing which tool fills each role, and the environment variables DotForge reads.
**Goal:** a configuration hashtable in your profile that sets your theme, your package manager and the tools you want.

## Quick start

Pass a configuration hashtable to `Start-DFSession -Config`. Every key is optional except `Tools`:

```powershell
$DFConfig = @{
    Tools               = @('+core')
    Theme               = 'catppuccin-mocha'
    PackageManagerOrder = @('scoop', 'winget')
    Defaults            = @{ listing = 'eza' }
    ExcludeTools        = @('lsd')
}
Import-Module DotForge
Start-DFSession -Config $DFConfig
```

1. `Theme` sets one color theme for every tool that has themes.
2. `PackageManagerOrder` makes `Install-DFTool` try scoop first, then winget.
3. `Defaults` says that eza, not lsd, owns `ls`, `ll`, `la` and `tree`.
4. `ExcludeTools` leaves lsd unconfigured, even when a group requested it.

A key you don't set keeps its default. A misspelled key is ignored without a warning, so compare yours with the table below.

## All settings

| Key | Type | Default | What it does |
| --- | --- | --- | --- |
| `PackageManagerOrder` | string[] | the `package-manager` role's order | Order `Install-DFTool` tries package managers in. Only managers on `PATH` are used. Overrides `Defaults['package-manager']`. |
| `Tools` | string[] | none | Tool names and `+groups` to configure. |
| `ExcludeTools` | string[] | none | Tools and `+groups` removed from `Tools`; exclusions win. |
| `SkipSetup` | string[] | none | Tools whose one-time setup script never runs (`delta`, `mdv`). See [Safety](safety.md). |
| `Defaults` | hashtable | none | Role → tool: which installed tool fills each role (`prompt`, `pager`, `listing`, …). See [Choose a tool for each role](#choose-a-tool-for-each-role). |
| `PSReadLineEditMode` | string | `Emacs` | `Emacs` or `Windows` key bindings for the command line. |
| `Theme` | string | `catppuccin-mocha` | Shared theme for every themed tool. Must be a family name, see [Themes](#themes). |
| `BatTheme`, `DeltaTheme`, `FzfTheme`, `GlowTheme`, `MdcatTheme`, `MdvTheme`, `MoorTheme`, `PSReadLineTheme`, `VividTheme` | string | `Theme` | Theme for one tool, overriding `Theme`. |
| `ShimsPath` | string | `$HOME\.local\bin` | Folder `New-DFShim` writes shims to. |
| `DotenvSafeMode` | bool | `$true` | ps-dotenv loads only `.env` files in approved folders. `$false` loads every one. |
| `DotenvApprovedDirs` | string[] | none | Folders whose `.env` files (recursively) ps-dotenv may load. `~` works. |
| `IgnoreConflicts` | string[] | none | Commands left out of the coreutils warning. See [Coreutils conflicts](coreutils-conflicts.md). |
| `SkipConflictCheck` | bool | `$false` | `$true` turns the coreutils check off. |

DotForge reads the hashtable you pass to `Start-DFSession -Config`, so a change takes effect the next time you call it (or in a new shell).

## Themes

One `Theme` setting colors bat, delta, fzf, glow, mdcat, mdv, PSReadLine and directory listings (through vivid's `LS_COLORS`). DotForge translates the name into each tool's own spelling: `catppuccin-mocha` becomes bat's `Catppuccin Mocha` and mdv's `catppuccin`.

`catppuccin-mocha` is the only theme every one of these tools has. Any other name applies only in the tools that know it; the rest warn and keep their default. Use a per-tool key to fill the gaps.

### Use one theme everywhere

Why: consistent colors across every viewer, prompt and listing.

```powershell
$DFConfig = @{ Theme = 'catppuccin-mocha' }
Import-Module DotForge
Start-DFSession -Config (@{ Tools = @('+core'); Theme = 'catppuccin-mocha' })
```

### Change one tool's theme

Why: a tool has a theme you prefer, or the shared theme isn't available in it.

```powershell
$DFConfig = @{
    Tools      = @('mdcat', 'vivid')
    Theme      = 'catppuccin-mocha'
    MdcatTheme = 'dracula'
    VividTheme = 'nord'
}
Import-Module DotForge
Start-DFSession -Config $DFConfig
"mdcat: $Env:MDCAT_THEME"
```

<!-- output: varies -->
```text
mdcat: dracula
```

1. `Theme` applies to every themed tool.
2. `MdcatTheme` and `VividTheme` override it for mdcat and for directory-listing colors.
3. A per-tool key accepts the shared family name or the tool's own theme names (`MdvTheme = 'nord'`, `BatTheme = 'Monokai Extended'`). The shared `Theme` accepts only family names.

### Theme names each tool accepts

| Tool | Key | Names | Unknown name |
| --- | --- | --- | --- |
| bat | `BatTheme` | any `bat --list-themes` name | bat warns when it runs and uses its default |
| delta | `DeltaTheme` | `catppuccin-mocha`, `catppuccin-macchiato`, `catppuccin-frappe`, `catppuccin-latte` | silently ignored |
| fzf | `FzfTheme` | `catppuccin-mocha`, or `$XDG_CONFIG_HOME\fzf\themes\<name>.json` | warning; no colors set |
| glow | `GlowTheme` | `catppuccin-mocha`, glow's `auto`, `dark`, `light`, `dracula`, `pink`, `notty`, `ascii`, `tokyo-night`, or a path | warning; `auto` |
| mdcat | `MdcatTheme` | `auto`, `dark`, `light`, `catppuccin-mocha`, `catppuccin-latte`, `gruvbox-dark`, `gruvbox-light`, `dracula`, `nord`, `solarized-dark`, `solarized-light` | warning; `auto` |
| mdv | `MdvTheme` | `terminal`, `solarized-dark`, `nord`, `tokyonight`, `kanagawa`, `gruvbox`, `monokai`, `material-ocean`, `catppuccin` | warning; `terminal` |
| moor | `MoorTheme` | any moor `-style` name (`catppuccin-mocha`, `dracula`, `nord`, …); used only when you haven't set `MOOR` | moor uses its default style |
| PSReadLine | `PSReadLineTheme` | `catppuccin-mocha`, `dark`, `light`, or `$XDG_CONFIG_HOME\psreadline\themes\<name>.json` | warning; colors unchanged |
| vivid (`LS_COLORS`) | `VividTheme` | any `vivid themes` name | warning; `LS_COLORS` unchanged |

mdv's theme is written to its config file once, the first time mdv is registered. To change it later, edit `$XDG_CONFIG_HOME\mdv\config.yaml`.

To try themes interactively before you choose, use the theme pickers `fprl` (PSReadLine), `fls` (directory colors) and `fpot` (oh-my-posh prompt). They apply a theme to the current session only; see [Tools](tools.md).

### Add your own fzf or PSReadLine theme

Why: use a palette DotForge doesn't ship.

```powershell
Import-Module DotForge
Start-DFSession -Config @{ Tools = @() }
$dir = Join-Path $Env:XDG_CONFIG_HOME 'psreadline' 'themes'
New-DFDirectory $dir
@{ colors = @{ Command = '#89b4fa'; String = '#a6e3a1'; Comment = '#6c7086' } } |
    ConvertTo-Json | Set-Content (Join-Path $dir 'my-colors.json')
$DFConfig = @{ PSReadLineTheme = 'my-colors' }
Register-DFTool -Name psreadline
```

1. Theme files live in `$XDG_CONFIG_HOME\<tool>\themes\<name>.json`; a file there wins over a bundled theme with the same name.
2. A PSReadLine theme maps [PSReadLine color names](https://learn.microsoft.com/powershell/module/psreadline/set-psreadlineoption) (`Command`, `String`, `Comment`, …) to `#RRGGBB` colors.
3. An fzf theme has the same shape, with fzf's `--color` names (`bg`, `fg`, `hl`, …) as keys.

## Choose a tool for each role

A role is a job several tools can do: drawing the prompt, paging output, listing files. DotForge has two kinds:

- A **single** role has one winner. Only the winner sets the role's variables and aliases and installs its shell hooks. The others are still configured and you can run them by name. Examples: `prompt` (oh-my-posh, starship), `pager` (less, bat), `listing` (eza, lsd), `editor`, `picker`, `diff`, `project-env`, `navigation`, `package-manager`.
- A **category** only groups tools, such as `grep` or `markdown-viewer`. Every member works as usual.

`Get-DFRole` lists the roles, which of your tools can fill each one, and which tool won:

```powershell
Get-DFRole | Format-Table Name, Kind, Winner, Reason, Candidates
```

`Defaults` picks the winner. Here eza gets `ls`, `ll`, `la` and `tree`, and lsd doesn't define them:

```powershell
$DFConfig = @{ Defaults = @{ listing = 'eza' } }
Import-Module DotForge
Start-DFSession -Config @{ Tools = @('eza', 'lsd'); Defaults = @{ listing = 'eza' } }
ls --version | Select-Object -First 1
```

<!-- output: varies -->
```text
eza - A modern, maintained replacement for ls
```

Without a `Defaults` entry, the installed tool with the highest priority wins (eza over lsd, oh-my-posh over starship, less over bat). For `prompt`, `project-env` and `navigation`, where two active tools would break each other, DotForge also warns once, naming its pick and the line that changes it. A tool name that isn't in that role writes a warning, and priority decides.

For per-folder environment variables, `project-env` holds ps-dotenv (the default), mise or direnv; see [Tools](tools.md#per-folder-environments-ps-dotenv-mise-direnv). In your configuration hashtable, name your pick and the folders ps-dotenv may load `.env` files from:

```powershell
$DFConfig = @{
    Tools               = @('ps-dotenv')
    Defaults           = @{ 'project-env' = 'ps-dotenv' }
    DotenvApprovedDirs = @('~\projects')
}
```

### Your own variables win, unless you pick a tool

A role's variables are `PAGER` (pager), `EDITOR` and `VISUAL` (editor), `Picker` (picker) and `GIT_PAGER` (diff). If you set one yourself, say `$Env:PAGER = 'less'` in your profile, DotForge keeps it. The exception is when you also name a different tool in `Defaults`, such as `Defaults = @{ pager = 'bat' }`. Then the `Defaults` choice wins, and DotForge warns at each startup until you remove one of the two settings. `Get-DFRole` shows a kept value of yours under `Overridden`.

`PackageManagerOrder`, when set, overrides the `package-manager` role entirely.

## Skip a tool

Why: you have a tool installed but don't want DotForge to touch it.

```powershell
$DFConfig = @{ Tools = @('+core'); ExcludeTools = @('eza', 'lsd') }
Import-Module DotForge
Start-DFSession -Config $DFConfig
(Get-Command ls).Definition
```

```text
...
Get-ChildItem
```

With both listing tools skipped, `ls` is PowerShell's own alias again.

To keep a tool's configuration but skip its one-time setup script (delta's git-config include, mdv's seeded config), use `SkipSetup` instead:

```powershell
$DFConfig = @{ SkipSetup = @('delta') }
Import-Module DotForge
Start-DFSession -Config @{ Tools = @('delta'); SkipSetup = @('delta') }
```

## Prefer a package manager

```powershell
$DFConfig = @{ PackageManagerOrder = @('winget', 'scoop') }
Import-Module DotForge
Install-DFTool -Name ripgrep -WhatIf
```

<!-- output: varies -->
```text
What if: Performing the operation "Install" on target "ripgrep via winget (BurntSushi.ripgrep.MSVC)".
```

DotForge skips a manager that isn't installed or has no package for the tool, and tries the next one. A tool with a Rust crate also tries `cargo install` last. `-PackageManager` overrides the order for one call.

## Command-line editing keys

DotForge sets PSReadLine to Emacs keys. To keep Windows keys:

```powershell
$DFConfig = @{ PSReadLineEditMode = 'Windows' }
Import-Module DotForge
Start-DFSession -Config @{ Tools = @('psreadline'); PSReadLineEditMode = 'Windows' }
```

Set this in the hashtable passed to `Start-DFSession`, not with `Set-PSReadLineOption -EditMode` afterwards: changing the edit mode afterwards resets the Tab key DotForge set up.

## Environment variables DotForge reads

Set these in your profile, before or after importing DotForge:

| Variable | Used by | Example |
| --- | --- | --- |
| `EDITOR` | `ep` (edit profile), `frg` (open a search result); set by the `editor` role's winner when you haven't set it | `$Env:EDITOR = 'code'` |
| `PAGER` | `pg`, `hm`, `clhp`: output goes through it when set; set by the `pager` role's winner when you haven't set it | `$Env:PAGER = 'less -R'` |
| `Picker` | every picker; the fzf-compatible program to run; set by the `picker` role's winner when you haven't set it | `$Env:Picker = 'sk'` (skim) |
| `NO_COLOR` | `hm`, `clh`, `env`: any value turns colors off | `$Env:NO_COLOR = '1'` |
| `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_STATE_HOME`, `XDG_CACHE_HOME` | everything; set them yourself to move the folders | `$Env:XDG_CONFIG_HOME = 'D:\dotfiles\config'` |

`EDITOR` must be a single command or path; arguments such as `code -w` aren't supported. `PAGER` takes arguments, but not quoted ones: use `bat --paging=always`, not `bat --paging "always"`.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| A setting has no effect | the hashtable was not passed to `Start-DFSession`, or the key is misspelled | Pass it with `-Config`; check the key against [All settings](#all-settings). |
| `fzf theme '<name>' not found` or `PSReadLine theme '<name>' not found` | the shared `Theme` names a theme those tools don't ship | Set `FzfTheme`/`PSReadLineTheme` to `catppuccin-mocha`, or add a theme file. |
| `$DFConfig.Defaults['<role>'] names '<tool>', which is not a <role> tool` | misspelled tool, or a tool that can't fill that role | Pick one of the tools the warning lists. |
| `<tools> can each fill the <role> role; using <tool>` | two tools that would conflict are installed and `Defaults` doesn't choose | Add the `Defaults` line the warning shows. |
| `PAGER was '<value>' but $DFConfig.Defaults.pager is '<tool>'` | you set the variable and also chose a different tool | Remove one of the two settings. |
| Tab completion stopped working after changing keys | `Set-PSReadLineOption -EditMode` ran after session start | Use `PSReadLineEditMode` in the session configuration. |

More on the [troubleshooting page](troubleshooting.md).
