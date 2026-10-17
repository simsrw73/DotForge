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
    InstallOrder        = @('scoop', 'winget')
    Defaults            = @{ listing = 'eza' }
    ExcludeTools        = @('lsd')
}
Import-Module DotForge
Start-DFSession -Config $DFConfig
```

1. `Theme` sets one color theme for every tool that has themes.
2. `InstallOrder` makes `Install-DFTool` prefer scoop, then winget, for tools whose own record doesn't say otherwise.
3. `Defaults` says that eza, not lsd, owns `ls`, `ll`, `la` and `tree`.
4. `ExcludeTools` leaves lsd unconfigured, even when a group requested it.

A key you don't set keeps its default. A misspelled key warns at startup and names the closest known key. To see what the session is using, read a setting back with `Get-DFConfig`, e.g. `Get-DFConfig Theme`.

## All settings

| Key | Type | Default | What it does |
| --- | --- | --- | --- |
| `InstallVia` | hashtable | none | Tool → source to install it from, e.g. `@{ glow = 'scoop' }`. Beats everything, including `ExcludeSources`. |
| `InstallOrder` | string[] | DotForge's order | Sources `Install-DFTool` prefers, in order (`scoop`, `winget`, `choco`, `npm`, `crates`, `psgallery`, …). Ordering only: a source you leave out is still used. A tool's own preference (`install.prefer` in its record) comes first. |
| `ExcludeSources` | string[] | none | Sources `Install-DFTool` never uses, unless `InstallVia` names one for a tool. |
| `Tools` | string[] | none | Tool names and `+groups` to configure. |
| `ExcludeTools` | string[] | none | Tools and `+groups` removed from `Tools`; exclusions win. |
| `SkipSetup` | string[] | none | Tools whose one-time setup script never runs (`delta`, `mdv`). See [Safety](safety.md). |
| `Defaults` | hashtable | none | Role → tool: which installed tool fills each role (`prompt`, `pager`, `listing`, …). See [Choose a tool for each role](#choose-a-tool-for-each-role). |
| `PSReadLineEditMode` | string | `Emacs` | `Emacs` or `Windows` key bindings for the command line. |
| `Theme` | string | `catppuccin-mocha` | Shared theme for every themed tool. Must be a family name, see [Themes](#themes). |
| `BatTheme`, `DeltaTheme`, `EzaTheme`, `FzfTheme`, `GlowTheme`, `GumTheme`, `LsdTheme`, `MdcatTheme`, `MdvTheme`, `MoorTheme`, `OvTheme`, `PecoTheme`, `PSReadLineTheme`, `SkimTheme`, `TelevisionTheme`, `VividTheme` | string | `Theme` | Theme for one tool, overriding `Theme`. |
| `ShimsPath` | string | `$HOME\.local\bin` | Folder `New-DFShim` writes shims to. |
| `DotenvSafeMode` | bool | `$true` | ps-dotenv loads only `.env` files in approved folders. `$false` loads every one. |
| `DotenvApprovedDirs` | string[] | none | Folders whose `.env` files (recursively) ps-dotenv may load. `~` works. |
| `IgnoreConflicts` | string[] | none | Commands left out of the coreutils warning. See [Coreutils conflicts](coreutils-conflicts.md). |
| `SkipConflictCheck` | bool | `$false` | `$true` turns the coreutils check off. |
| `ShowBanner` | bool | `$false` | Show the startup banner. See [Startup banner](#startup-banner). |
| `BannerLineDelay` | int | `8` | Milliseconds between banner lines; `0` prints at once. |
| `BannerWait` | int | `300` | Longest wait, in milliseconds, for an unfinished banner line before its last known value is used. |
| `BannerClear` | bool | `$true` | Clear the screen before the banner; `$false` keeps your scrollback. |

DotForge reads the hashtable you pass to `Start-DFSession -Config`, so a change takes effect the next time you call it (or in a new shell).

## Themes

One `Theme` setting colors bat, delta, fzf, glow, mdcat, mdv, PSReadLine and directory listings: file names through vivid's `LS_COLORS`, and the other columns of eza and lsd (dates, sizes, permissions) through their catppuccin themes. DotForge translates the name into each tool's own spelling: `catppuccin-mocha` becomes bat's `Catppuccin Mocha` and mdv's `catppuccin`.

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
| peco | `PecoTheme` | `catppuccin-mocha`, `catppuccin-macchiato`, `catppuccin-frappe`, `catppuccin-latte`; seeded once into `$XDG_CONFIG_HOME\peco\config.json` | warning; nothing seeded |
| PSReadLine | `PSReadLineTheme` | `catppuccin-mocha`, `dark`, `light`, or `$XDG_CONFIG_HOME\psreadline\themes\<name>.json` | warning; colors unchanged |
| skim | `SkimTheme` | the four catppuccin flavors, or `$XDG_CONFIG_HOME\skim	hemes\<name>.json`; appended to `SKIM_DEFAULT_OPTIONS` as `--color` | warning; skim's own colors |
| television | `TelevisionTheme` | the four catppuccin flavors; seeded once into its `config.toml` (`ui.theme`), so change it there later | warning; nothing seeded |
| gum | `GumTheme` | the four catppuccin flavors, or `$XDG_CONFIG_HOME\gum	hemes\<name>.json`; sets `GUM_*` colors | warning; gum's own colors |
| vivid (`LS_COLORS`) | `VividTheme` | any `vivid themes` name | warning; `LS_COLORS` unchanged |

To switch a tool's theme for the rest of the session, use `Set-DFToolTheme`:

<!-- system -->
```powershell
Set-DFToolTheme bat 'Monokai Extended'
```

It works for tools whose theme DotForge applies itself (bat, mdcat, moor, delta, glow). fzf, PSReadLine
and vivid have their own commands (`Invoke-DFApplyFzfTheme`, `Select-PSReadLineTheme`,
`Select-LSColorsTheme`). To keep a theme, set the tool's key (`BatTheme`, ...) in your config.

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

<!-- requires: eza, lsd -->
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

### Pagers

moor, ov and less page the same way, whichever wins the `pager` role (moor, then ov,
then less): output that fits one screen isn't paged, colors pass through, the output
stays on screen when you quit, and the mouse wheel scrolls. The winner sets `PAGER` and
`BAT_PAGER` (so bat pages the same way); with none of them installed, both are `more`.
ov also follows your theme (`OvTheme`, else `Theme`) unless you have your own
`$XDG_CONFIG_HOME\ov\config.yaml`. `Get-DFRole pager` shows the winner, or the fallback.

### Your own variables win, unless you pick a tool

A role's variables are `PAGER` and `BAT_PAGER` (pager), `EDITOR` and `VISUAL` (editor), `Picker` (picker) and `GIT_PAGER` (diff). If you set one yourself, say `$Env:PAGER = 'less'` in your profile, DotForge keeps it. The exception is when you also name a different tool in `Defaults`, such as `Defaults = @{ pager = 'bat' }`. Then the `Defaults` choice wins, and DotForge warns at each startup until you remove one of the two settings. `Get-DFRole` shows a kept value of yours under `Overridden`.

Ctrl+R and Ctrl+T are roles too, `history-search` and `path-insert`: `Defaults = @{ 'history-search' = 'television' }` gives Ctrl+R to television. A Ctrl+R or Ctrl+T binding you make before DotForge loads is kept unless `Defaults` names a tool for it. See [Ctrl+R and Ctrl+T](tools.md#ctrlr-and-ctrlt-psfzf-television-fzf-skim).

Which manager installs from a shared registry is a role too: `Defaults = @{ 'js-package-manager' = 'pnpm' }` makes pnpm, not npm, install npm-registry packages. The same goes for `python-package-manager` (PyPI: uv, then pipx, then pip), `rust-package-manager` (crates) and `powershell-package-manager` (the PowerShell Gallery).

### Your own environment values win

If you set one of the variables a tool configures (in your profile, or system-wide) before DotForge
loads, DotForge keeps your value and `Get-DFToolStatus <tool>` says so, e.g.
`BAT_THEME kept as set outside DotForge ('Dracula'); DotForge wanted 'Catppuccin Mocha'`.
A choice you make in DotForge's own config overrides it (a `Defaults` role pick, a per-tool theme key
such as `BatTheme`, or a command like `Invoke-DFApplyFzfTheme`), with a one-time warning naming both.

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

## Startup banner

Why: a system summary when a shell opens, printed a line at a time like a boot screen, without slowing startup.

<!-- fragment -->

```powershell
Start-DFSession -Config @{ Tools = @('+core'); ShowBanner = $true }
```

<!-- fragment -->

```text
DotForge  0.7.0 · loading 31 tools…
OS  Windows 11 Pro (26H2) x86_64
...
Local IP (Ethernet)  192.168.99.20/24 (Ethernet)
Public IP  203.0.113.4
Disk (C:\)  C:\ (NTFS): 824.22 GiB / 930.62 GiB (89%)
Disk 990 PRO 2TB   NVMe · 99% life · 46°C · 14,014 h · 28 TB written
Disk WD10EZEX      HDD · no bad sectors · 29°C · 84,115 h
```

1. The screen clears and the first line prints at once (`BannerClear = $false` keeps your scrollback).
2. fastfetch, the drive checks and the public-IP lookup run in the background while your tools load; the rest prints when the load ends, `BannerLineDelay` milliseconds apart.
3. **Drive lines** come from smartmontools' `smartctl`, which reads drive health without admin rights: an SSD's remaining life, a hard drive's bad-sector count, temperature, hours powered on, and data written. A line turns red, with the reason, when a drive's self-check fails, media errors or bad sectors appear, or its life drops under 10%.
4. **Public IP** comes from `api.ipify.org` with a 2-second limit, so a slow network never holds up the shell.
5. A line whose check isn't back within `BannerWait` shows its last known value, marked `(cached)`, or is left out the first time.
6. fastfetch and smartmontools are in `+core`. Without smartmontools there are no drive lines; without fastfetch only the first line prints. The banner shows only in an interactive console, never in scripts or redirected output.

**Moving lines.** Your fastfetch config decides where the extra lines go: `{ "type": "custom", "key": "Public IP", "format": "@DF:publicip@" }` and `{ "type": "custom", "key": "Disk", "format": "@DF:drives@" }`. Move or delete those entries. DotForge's default config has them; a config you already have doesn't, so add them, or delete your config and run `Invoke-DFToolSetup fastfetch -Force` for the new default (which also drops the Packages and physical-disk lines). Running `fastfetch` by hand fills them from the last known values; to do that it captures fastfetch's output, so a config with an image logo or one that fits the terminal width shows as plain text there (the banner itself is unaffected).

**Not wanted?** `ExcludeTools = @('smartmontools')` drops the drive lines and the "isn't installed" notice; `ShowBanner = $false` (the default) turns the banner off.

**Colors** follow your fastfetch config (`display.color.keys`, `display.color.output`, `display.separator`).

**Speed.** The banner prints fastfetch's output only if fastfetch has finished by the time your tools have loaded, plus `BannerWait`. Slow fastfetch modules (`packages`, `publicip`, `weather`) can miss that; you then see a line saying so instead of the banner. Remove them from your fastfetch config (DotForge's default has none), or raise `BannerWait`. A drive that doesn't answer in time shows `no answer yet`; one that hangs is stopped after 4 seconds. The banner skips shells started to run a command or a script (`pwsh -c ...`, `pwsh -File ...`).

## When DotForge finds your existing config

Why: you already use a tool, and its config or data is in the tool's own default place. DotForge points tools at XDG folders (bat's config at `$XDG_CONFIG_HOME\bat\bat.conf`, zoxide's database under `$XDG_DATA_HOME`), so taking over would hide what you have.

DotForge never does that on its own:

1. A tool you don't list in `Tools` is never touched.
2. A tool you list, with nothing in its old location, is DotForge's from then on.
3. A tool you list that still has config or data in its old location is left alone entirely (no variables, aliases, pickers or setup) until you decide. Each load warns:

<!-- fragment -->

```text
WARNING: DotForge: 2 tools are waiting on your existing config: bat, zoxide. See Get-DFToolStatus -Conflict, or run Resolve-DFToolConflict to go through them.
```

`Get-DFToolStatus -Conflict` lists every tool waiting on you, with where its config is and what DotForge advises: `-Move` when the XDG location is empty, `-Adopt` when it already has config (DotForge has been using that copy), or the tool's own instructions when DotForge must not move it (rustup, vcpkg).

`Resolve-DFToolConflict` with no tool name goes through them one at a time: Enter takes the advice; `A`, `M` or `S` adopts, moves or skips. Or decide for each tool yourself:

| You want | Run |
| --- | --- |
| DotForge to move the config for you | `Resolve-DFToolConflict bat -Move` |
| DotForge to take over without moving anything (you moved or merged it yourself, or don't need the old copy) | `Resolve-DFToolConflict bat -Adopt` |
| DotForge to leave the tool alone | Remove it from `Tools` |

Then load it with `Register-DFTool -Name bat`, or open a new shell.

### What `-Move` does

<!-- fragment -->

```powershell
Resolve-DFToolConflict bat -Move -WhatIf   # shows the plan, changes nothing
Resolve-DFToolConflict bat -Move
```

1. **It checks first, and changes nothing if any check fails.** The XDG location must be empty, the tool must not be running, and no text file in the old location and no environment variable (PATH included) may name the old location: a hook script with a hard-coded path would break after the move, so it is listed as `file:line` for you to change.
2. **It copies, then verifies.** Files are copied to a staging folder beside the XDG location, every file's size and SHA-256 hash is compared with the original, and only then is the staging folder renamed into place.
3. **It moves the old copy out of the way, never deleting it.** The old location is renamed to `<name>.dotforge-moved` next to where it was; delete it yourself when you're satisfied. A copy that can't be renamed yet (a file open in an editor or a running shell) stays put: DotForge retries on each later load, checks the new location still matches what it moved, and warns, with the reason, until it's done. `Resolve-DFToolConflict bat -Done` stops the retries once you've dealt with it yourself.

A few locations DotForge never moves, because the tool keeps absolute paths inside them (rustup's `~\.rustup` and `~\.cargo`, vcpkg's root, oh-my-posh's installed themes). The warning names the tool's own instructions instead; follow them, then run `-Adopt`.

DotForge's variables apply inside the PowerShell sessions it starts. A program you run from cmd, Git Bash or Explorer still uses the old location.

## Prefer a package manager

```powershell
Import-Module DotForge
Start-DFSession -Config @{ Tools = @(); InstallOrder = @('winget', 'scoop'); ExcludeSources = @('choco') }
Install-DFTool -Name ripgrep -WhatIf
```

<!-- output: varies -->
```text
  stage 1  winget: ripgrep (BurntSushi.ripgrep.MSVC)
```

For each tool, `Install-DFTool` takes the first source that has a package for it and a manager you have (or are installing in the same run):

1. `InstallVia` for that tool;
2. the tool record's own preference (`install.prefer`), used where the curator knows one package is official or better maintained;
3. `InstallOrder`;
4. DotForge's order: scoop, winget, choco, then the registries.

`ExcludeSources` removes a source unless `InstallVia` names it. `-Via` picks the source for one call: `Install-DFTool -Name glow -Via scoop`.

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
| `PAGER` | `pg`, `hm`, `clhp`: output goes through it when set; set by the `pager` role's winner (else `more`) when you haven't set it | `$Env:PAGER = 'less -R'` |
| `Picker` | every picker; the fzf-compatible program to run; set by the `picker` role's winner when you haven't set it | `$Env:Picker = 'sk'` (skim) |
| `NO_COLOR` | `hm`, `clh`, `env`: any value turns colors off | `$Env:NO_COLOR = '1'` |
| `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_STATE_HOME`, `XDG_CACHE_HOME` | everything; set them yourself to move the folders | `$Env:XDG_CONFIG_HOME = 'D:\dotfiles\config'` |

`EDITOR` must be a single command or path; arguments such as `code -w` aren't supported. `PAGER` takes arguments; one holding a space goes in double quotes (`ov --config "C:\My Themes\ov.yaml"`). Single quotes aren't understood.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| A setting has no effect | the hashtable was not passed to `Start-DFSession`, or the key is misspelled | Pass it with `-Config`; check the key against [All settings](#all-settings). |
| `fzf theme '<name>' not found` or `PSReadLine theme '<name>' not found` | the shared `Theme` names a theme those tools don't ship | Set `FzfTheme`/`PSReadLineTheme` to `catppuccin-mocha`, or add a theme file. |
| `$DFConfig.Defaults['<role>'] names '<tool>', which is not a <role> tool` | misspelled tool, or a tool that can't fill that role | Pick one of the tools the warning lists. |
| `<tools> can each fill the <role> role; using <tool>` | two tools that would conflict are installed and `Defaults` doesn't choose | Add the `Defaults` line the warning shows. |
| `PAGER was '<value>' but $DFConfig.Defaults.pager is '<tool>'` | you set the variable and also chose a different tool | Remove one of the two settings. |
| `N tools are waiting on your existing config: ...` | those tools' own config locations have your config, and DotForge hasn't been told it may take over | Run `Resolve-DFToolConflict`; see [When DotForge finds your existing config](#when-dotforge-finds-your-existing-config). |
| `<path> names the old location; change it to <path>` from `Resolve-DFToolConflict -Move` | a config file refers to the folder being moved | Edit that line to the new location, then run `-Move` again. |
| `<path> is still in use; DotForge tries again on the next load` | a moved tool's old copy was open | Close what holds it and open a new shell; or delete it yourself and run `Resolve-DFToolConflict <tool> -Done`. |
| No drive lines in the banner | smartmontools isn't installed, or isn't in `Tools` | `Install-DFTool smartmontools`, and keep `+core` (or `smartmontools`) in `Tools`. |
| `@DF:...` text from fastfetch, or no Public IP line | an older fastfetch config without the placeholders, or one run outside DotForge | Add the placeholder entries shown in [Startup banner](#startup-banner). |
| Tab completion stopped working after changing keys | `Set-PSReadLineOption -EditMode` ran after session start | Use `PSReadLineEditMode` in the session configuration. |

More on the [troubleshooting page](troubleshooting.md).
