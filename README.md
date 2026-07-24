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
    CompletionMode      = 'Native'              # Native or Inshellisense completion behavior
    PSReadLineEditMode  = 'Windows'             # Windows or Emacs editing keys
    PSReadLineTheme     = 'catppuccin-mocha'    # PSReadLine color theme (name or path)
    GlowTheme           = 'catppuccin-mocha'    # glow markdown style (name or path)
    ShimsPath           = "$HOME\.local\bin"    # shim output dir for New-DFShim (default: $HOME\.local\bin)
    IgnoreConflicts     = @('cat')              # keep coreutils' version of these; no warning
    SkipConflictCheck   = $false                # $true silences the shadowed-command check
}
Import-Module DotForge
Register-DFTool -All
```

## Completion Stack

DotForge finalizes completion once, after registered tools and PSReadLine's
edit mode have been applied. `CompletionMode = 'Native'` is the default: PSReadLine
provides the editor, Carapace supplies styled argument-completion results, and
PSFzf is optional. In a Carapace-only Native session, Tab uses PSReadLine's
`MenuComplete`; when PSFzf is registered, its fuzzy Tab completion takes
precedence.

When Native mode finds `is` (or `inshellisense`), DotForge augments
`CARAPACE_BRIDGES` with `inshellisense` without discarding user bridge entries.
Because `is` is typically a Node-hosted command, `carapace` declares
`"dependsOn": ["fnm"]` so fnm puts `is` on PATH before the bridge check runs.
Set `CompletionMode = 'Inshellisense'` to start inshellisense directly instead;
direct mode requires the `is` command and starts only after tool registration.
It first checks `is -c`, so an existing session is left alone. If `is` is
unavailable, DotForge warns and falls back to the Native behavior.

Carapace styles its completion results with ANSI colour when attached to a
console. When both Carapace and PSFzf are registered, the resolver adds `--ansi`
to `FZF_DEFAULT_OPTS` so the fuzzy picker renders those colours instead of
printing raw escape sequences; the text inserted at the prompt is unaffected.

Carapace ships no completer for some tools (e.g. `scoop`). DotForge bundles
carapace specs under `Tools/carapace/specs/` and deploys them to
`$XDG_CONFIG_HOME/carapace/specs/`, where carapace auto-loads them. To add your
own, drop a `*.yaml` spec in that directory (see `carapace --schema`).

Do not change PSReadLine's edit mode after `Register-DFTool -All`: a raw
post-registration `Set-PSReadLineOption -EditMode ...` resets Tab. Set
`PSReadLineEditMode` in `$DFConfig` before importing DotForge so the completion
stack can install its final Tab binding afterward.
## Coreutils Conflicts

If you have [Coreutils for Windows](https://github.com/uutils/coreutils) installed, some DotForge
aliases will silently not work — `cat`, `touch`, `env`, and `paste` are the usual ones.

Coreutils installs a `PSConsoleHostReadLine` hook that rewrites matching command names to
`<name>.cmd` **before PowerShell resolves them**. No alias, function, or `-Force` can win, because
the name is gone before resolution begins. The confusing part: `Get-Command cat` still reports
DotForge's version, so the alias inspects as correct while typing `cat` runs coreutils.

`Register-DFTool` detects this and warns once, listing the affected commands. To see them anytime:

```powershell
Get-DFCommandConflict

# Command ShadowedBy WouldResolveTo Ignored DisableWith
# ------- ---------- -------------- ------- -----------
# cat     coreutils  bat            False   cat
# la      coreutils  eza            False   ls
# touch   coreutils  New-DFFile     False   touch
```

Use `DisableWith`, not `Command`, to build the disable list — `la` is not a coreutils
utility and the manager rejects it, so it maps to `ls`.

Resolving it needs elevation and is a policy choice, so DotForge only ever prints the command —
it never elevates or writes to the registry. Pick a side:

```powershell
# Keep DotForge's versions — run once, elevated. Persists across coreutils upgrades:
# the installer regenerates its profile block from this registry list.
coreutils-manager disable cat touch env paste

# ...or keep coreutils' versions and silence the warning:
$DFConfig.IgnoreConflicts = @('cat', 'touch', 'env', 'paste')
```

Disabling `ls` also removes `la` (there is no `la.cmd`; coreutils adds `la` only while `ls` is
enabled). Don't hand-edit the `DO NOT MODIFY -- coreutils` block in your profile — the installer
regenerates it from the registry on every upgrade.

The check is cheap: it reads the same set the hook itself consults, so it costs nothing when
coreutils isn't installed and correctly reports **no** conflict in hosts where the hook never loads
(it's injected into the ConsoleHost profile only, so the VS Code terminal is unaffected).

Detecting this relies on coreutils internals that its authors never promised — see
[External Dependencies](docs/external-dependencies.md) for exactly what, and what happens when it
changes. Short version: the check silently disables itself; nothing else breaks.

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
| `Get-DFCommandConflict [-IncludeIgnored]` |       | Report DotForge commands shadowed by coreutils   |
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

**Utility**

| Cmdlet                                            | Alias     | Purpose                                              |
| ------------------------------------------------- | --------- | --------------------------------------------------- |
| `New-DFUuid [-UpperCase] [-NoHyphens] [-Braces]` / `New-DFUuid -Sdk` | `uuidgen` | Generate a v4 UUID. Default is lowercase, hyphenated, no braces (Unix-style). The casing/hyphen/brace switches combine freely (e.g. `-UpperCase -Braces` → `{F47AC10B-…}` registry/COM form); `-Sdk` is a named preset for the Windows SDK `uuidgen` default. The `uuidgen` alias is unconditional and intentionally shadows any native `uuidgen` for consistent output everywhere. |

**Package Catalog Info (trifle)**

| Cmdlet                                              | Alias     | Purpose                                                        |
| --------------------------------------------------- | --------- | -------------------------------------------------------------- |
| `Find-DFPackage <name-or-keywords> [-Source] [-Fresh] [-AsObject] [-All] [-Readme] [-GitInfo]` / `Find-DFPackage -Category <c> [-WorksWith <w>] [-Source] [-Fresh] [-AsObject] [-Readme] [-GitInfo]` | `trifle`  | Search every installer catalog at once and render a merged info card (or match table): description, installed status + source, per-catalog availability and versions, homepage, license, cache age. The `-Category`/`-WorksWith` form facet-searches the offline taxonomy instead of keyword-ranking a query. |
| `Update-DFPackageCache [-Source] [-Quiet]`           |           | Refresh-only entry point for Task Scheduler: rebuilds snapshot indexes and re-warms cached queries + cached detail entries |
| `Select-DFPackage [-Query] [-Categories] [-Category <c>] [-WorksWith <w>] [-Source] [-Readme] [-GitInfo]` | `ftrifle` | Fuzzy-browse locally cached packages, or live-search with instant preview cards; Enter shows the full detail card. `-Categories` browses the taxonomy vocabulary; `-Category`/`-WorksWith` search a specific facet directly. |
| `Get-DFCategoryList [-Facet function\|worksWith] [-Counts]` | `tcats` | List the valid `-Category`/`-WorksWith` vocabulary, each term annotated with its live tool count |
| `Update-DFCategoryDb [-WhatIf]`                       |           | Opt-in refresh of the category database from the latest published release, independent of module version — never run implicitly |
| `Update-DFToolIdentityGuide [-WhatIf]`                |           | Opt-in refresh of the tool-identity guide from the latest published release, independent of module version — never run implicitly |

```powershell
trifle ripgrep          # info card: installed via scoop? what do winget/choco/npm/crates carry?
trifle rg               # winget monikers work too — resolves to ripgrep
trifle static site generator          # keyword search → match table
trifle bat -Source scoop,winget       # restrict catalogs
trifle rg -Fresh                      # block on live catalog data
$x = trifle rg -AsObject              # raw DotForge.ToolInfo objects for scripting
ftrifle                               # fzf-browse everything cached locally
```

Catalogs: **scoop** (bucket JSONs read straight from disk), **winget** (the CLI's
own SQLite index queried directly via `winsqlite3.dll` — no multi-second
`winget.exe` startup), **choco**, **npm**, **PyPI**, **crates.io**, and
**PSGallery** (web APIs with per-query TTL caches). Answers are cache-first:
stale entries are served instantly while a background thread re-warms them, so
the *next* query is fresh; a typical warm query answers in ~200 ms across all
seven catalogs. Cache ages are shown on the card; `-Fresh` forces live fetches.
Installed-status checking is always live (not cached) — every query re-checks
all seven catalogs' actual installed state in parallel, so it never goes stale.
PyPI has no search API, so it only participates in exact-name lookups.

### Detail view

When a query resolves to one confident match (exact package id or exact
name/moniker), `trifle` renders a **detail card** instead of the match table —
the same info-card fields plus catalog-specific detail fetched from that one
source (e.g. scoop manifest notes, npm dist-tags, a GitHub-resolved description).
If other candidates also matched, the card ends with a "+N more matches" footer
so you know the table is one flag away.

```powershell
trifle zed                            # single confident match → detail card
trifle zed -All                       # force the full match table, with an Id column
trifle winget:Zed.Zed                 # qualified source:id — skip ranking, go straight to one package
trifle winget:Zed.Zed -GitInfo        # + GitHub stars / latest release / activity
trifle npm:left-pad -Readme           # + paged package readme
```

- **`-All`** always renders the match table, even for an otherwise-exact hit.
  Its `Id` column shows values you can copy straight back in as a qualified
  query: `trifle <source>:<id>` (e.g. `trifle winget:Zed.Zed`).
- **Qualified `source:id` queries** (`trifle scoop:zed`, `trifle npm:left-pad`)
  bypass keyword ranking entirely and zero in on that one package in that one
  catalog, always producing a detail card. A qualified query always shows the
  detail card — `-All` has no effect on qualified queries. Unknown prefixes are
  just treated as ordinary keyword text.
- **`-Readme`** fetches and pages the package's readme (npm registry readme,
  GitHub readme, or PyPI long description) after the detail card. It needs the
  detail path (an exact match or a qualified id) — otherwise a warning is
  shown and the match table renders instead.
- **`-GitInfo`** resolves the package's GitHub repository (from source detail
  or its homepage) and adds star count, latest release, and recent activity to
  the card. It shells out to `gh` when gh is installed and authenticated
  (faster, higher rate limits) and falls back to the anonymous GitHub REST API
  otherwise. Same detail-path requirement as `-Readme`.
- **`ftrifle <query>`** live-searches every catalog and pre-renders each hit's
  info card to a temp file, so scrolling through fzf's preview pane is instant
  — no network calls while browsing. Enter re-runs the highlighted result as a
  qualified `source:id` query, producing the full detail card (`-Readme`/
  `-GitInfo` pass through). `ftrifle` with no query still browses everything
  already cached locally.
- Detail entries are cached alongside search results and re-warmed by
  `Update-DFPackageCache`, so a query you've looked up before stays instant.

### Discovery (`-Category` / `-WorksWith`)

A curated, offline taxonomy ships with the module in `data/tool-categories.json`
— function categories (e.g. `search`, `file-management`) and works-with facets
(e.g. `filesystem`, `git`) for a seed set of well-known CLI tools. Every facet
match still resolves through the same live catalog search-and-merge path as an
ordinary query, so installed state and versions are never a stale snapshot —
the database is an index into live catalogs, not a cached answer.

```powershell
tcats                                          # every valid -Category/-WorksWith term, with live counts
tcats -Facet function -Counts:$false           # bare list of function-facet terms only
trifle -Category search                        # facet search: every seed-db tool tagged 'search'
trifle -Category search -WorksWith filesystem   # AND across facets; -Category a,b ORs within one facet
trifle ripgrep                                   # detail card now also shows Category/Related/Alt-to
ftrifle -Categories                              # browse the vocabulary in fzf, drill into a facet
```

- **`trifle -Category <c> [-WorksWith <w>]`** / **`trifle -WorksWith <w>`** always
  renders the match table (never the detail card), with the same `Id` column as
  `-All`. Multiple values passed to one facet (`-Category a,b`) OR together;
  `-Category` and `-WorksWith` combined AND across facets. `-Category`/
  `-WorksWith` are their own parameter set — combining either with `-All` is
  rejected at parameter binding, not just discouraged.
- **`Get-DFCategoryList`** (`tcats`) lists the valid `-Category`/`-WorksWith`
  vocabulary, each term annotated with its live tool count (the same index the
  facet search itself uses, so counts never drift from what a matching search
  would return). `-Facet function` or `-Facet worksWith` narrows to one
  taxonomy; `-Counts:$false` prints a bare term list for scripting.
- Any package found in the seed database gets `Category` / `Related` / `Alt to`
  lines added to its detail card automatically — no flag needed, shown
  whenever a detail card renders.
- **`ftrifle -Categories`** browses the full vocabulary (every function and
  works-with value, with live counts) in fzf; picking one drills into that
  facet with the same live-search-and-preview flow as `ftrifle <query>`.
  **`ftrifle -Category <value>`** / **`ftrifle -WorksWith <value>`** skip the
  vocabulary browse and search that facet directly.
- **`Update-DFCategoryDb`** downloads the latest published category database
  and installs it under `$XDG_DATA_HOME/dotforge/`, taking precedence over the
  module's shipped copy on the next load. Purely opt-in — independent of
  module version, never run implicitly by `trifle`, `ftrifle`, or
  `Update-DFPackageCache`.

The shipped seed database covers ~70 well-known CLI tools. It grows over time
via `build/categories/*.jsonc` content authoring and a
`build/Build-DFCategoryDb.ps1` rebuild — not code changes.

**Cross-catalog identity.** Two catalogs' packages only ever merge into one
row when they're genuinely the same tool — confirmed either by a curated
`Tools/*.json` mapping or by the shipped tool-identity guide
(`data/tool-identities.json`, verified via matching GitHub repos or
homepages, refreshable independently via `Update-DFToolIdentityGuide`).
A shared *name* alone is never enough: `trifle zed` shows the winget Zed
editor and choco's unrelated `zed` package as separate rows, because they
are, in fact, different tools. Coverage grows over time the same way the
category database does — nothing is ever merged on a guess.

### Scheduled cache refresh

Schedule a nightly refresh so interactive queries always hit warm caches. Run
this once in an interactive session (no elevation needed for a per-user task):

```powershell
$action  = New-ScheduledTaskAction -Execute 'pwsh' -Argument (
    '-NoProfile -Command "winget source update; Import-Module DotForge; Update-DFPackageCache -Quiet"'
)
$trigger  = New-ScheduledTaskTrigger -Daily -At 6am
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -RunOnlyIfNetworkAvailable
Register-ScheduledTask -TaskName 'DotForge catalog refresh' `
    -Action $action -Trigger $trigger -Settings $settings
```

To inspect or remove it later:

```powershell
Get-ScheduledTask -TaskName 'DotForge catalog refresh' | Get-ScheduledTaskInfo
Unregister-ScheduledTask -TaskName 'DotForge catalog refresh' -Confirm:$false
```

> **Why `winget source update` is part of the action:** the winget catalog is
> read from the `source.msix` that winget itself downloads, and winget only
> refreshes that file when winget runs. `Update-DFPackageCache` re-extracts
> whatever msix is present — it cannot make winget download a newer one. On a
> machine that rarely invokes winget the index silently ages (the card's
> `Cache` line will show it, e.g. `winget 61d`). Running `winget source update`
> (~5 s) first keeps the winget data as fresh as everything else. If the
> scheduled task runs under a different account or `winget` isn't on the task's
> PATH, the refresh still succeeds — the winget index just stays at whatever
> age the msix has.

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

## Included Tools (35)

| Group            | Tools                                              |
| ---------------- | -------------------------------------------------- |
| Completion       | carapace, inshellisense                            |
| File/dir         | bat, eza, fd, ripgrep, broot                       |
| Text/data        | jq, glow                                           |
| System           | procs, winfetch, gsudo                             |
| Network          | curl, wget                                         |
| Container        | docker                                             |
| Editors          | micro                                              |
| Fuzzy/nav        | fzf, zoxide                                        |
| Pagers           | less                                               |
| Package managers | scoop, winget, choco, npm                          |
| Dev              | bitwarden, chezmoi, delta, fnm, gh, lazygit, rustup, uv |
| PS modules       | posh-git, psreadline, PSFzf, Terminal-Icons, oh-my-posh |

## Tool-Specific Helpers

Companion `.ps1` files register globals (not module exports) when their tool is registered.

**glow** (`Tools/glow.ps1`)

glow honors no XDG environment variable — its config path is a Win32 known-folder
lookup, `GLAMOUR_STYLE` is never read, and `GLOW_STYLE` loses to glow's non-TTY
downgrade. So DotForge wraps the executable in a global `glow` function that passes
`--config` and `-s` explicitly. Piped input (`Get-Content x.md | glow`) is forwarded;
glow's own flags (`-w`, `-p`, `-t`, `-a`) and its subcommands pass through unchanged,
and carapace completion for `glow` still works.

| Function / Variable            | Purpose                                                  |
| ------------------------------ | -------------------------------------------------------- |
| `glow`                         | Wrapper passing `--config $XDG_CONFIG_HOME/glow/glow.yml` and `-s <style>` |
| `Resolve-DFGlowStyle -Name <n>` | Resolves a style: rooted path → `$XDG_CONFIG_HOME/glow/themes/<n>.json` → bundled `Tools/glow/<n>.json` → glow built-in name → warn and fall back to `auto` |
| `$global:DFGlowStyle`          | The active style, read at call time — assign to it to switch theme for the session |

Set the startup theme with `$DFConfig['GlowTheme']`. `catppuccin-mocha` ships with
the module; glow's own `auto`, `dark`, `light`, `dracula`, `pink`, `notty`, `ascii`,
and `tokyo-night` are accepted as bare names.

```powershell
glow README.md                     # rendered with the configured theme
$global:DFGlowStyle = 'dracula'    # switch for this session
```

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

**winget** (`Tools/winget.ps1`)

Fuzzy package pickers with a live `winget show` preview pane. Each item carries
a hidden id field, so filtering matches on name **or** id. Requires the
[`Microsoft.WinGet.Client`](https://learn.microsoft.com/windows/package-manager/winget/)
module (`Install-Module Microsoft.WinGet.Client -Scope CurrentUser`); the
pickers warn and no-op if it is missing.

| Function / Alias                | Purpose                                                        |
| ------------------------------- | -------------------------------------------------------------- |
| `Select-WingetPackage [-Query]` / `wins` | Search (`Find-WinGetPackage`) → install. Prompts for a query when none is given. |
| `Remove-WingetPackage [-Source <src>]` / `wrm` | Browse installed packages → uninstall. `-Source winget` filters the list to that source, hiding ARP/registry-only entries. |
| `Invoke-WingetUpdate` / `wup`   | Browse upgradable packages (multi-select) → update.            |

Each picker binds keys two ways — an `--expect` key that exits fzf and runs the
action back in PowerShell (clean UAC/output), and an in-place `--bind execute`
key that acts on the highlighted item while you keep browsing:

| Picker | `Enter` | Other keys |
| ------ | ------- | ---------- |
| `wins` | **returns** the `winget install …` command string | `Alt-R` install now · `Alt-I` install highlighted in place (keep browsing) |
| `wrm`  | uninstall the selection | `Alt-X` uninstall in place · `Alt-C` return the uninstall command |
| `wup`  | update the marked selection(s) | `Tab` mark · `Alt-A` `winget upgrade --all` |

```powershell
wins ripgrep     # search → Enter prints `winget install --id BurntSushi.ripgrep.MSVC --exact`
wrm              # pick an installed app → uninstall
wup              # Tab to mark several upgrades → Enter updates them
```

`Invoke-DFPicker` gained `-Expect` (multi-key mode; returns a `{ Key; Selected }`
object), `-Bind` (per-spec `--bind`), and `-FzfArgs` (verbatim passthrough) to
support these workflows.

**scoop** (`Tools/scoop.ps1`)

The same picker set for scoop, with a `scoop info` preview. Search uses
[`scoop-search`](https://github.com/shilangyu/scoop-search) when present (fast;
matches names **and** binaries), else the module's `Find-ScoopApp`. Requires the
[`Scoop`](https://www.powershellgallery.com/packages/Scoop) module
(`Install-Module Scoop -Scope CurrentUser`) for the installed list and typed
install/uninstall/update actions.

| Function / Alias                | Purpose                                              |
| ------------------------------- | ---------------------------------------------------- |
| `Select-ScoopPackage [-Query]` / `sins` | Search → install (`Enter` returns the command, `Alt-R` installs, `Alt-I` installs in place) |
| `Remove-ScoopPackage` / `srm`   | Installed apps → uninstall (`Alt-X` in place, `Alt-C` command) |
| `Invoke-ScoopUpdate` / `sup`    | Installed apps, multi-select → update (`Tab` mark, `Alt-A` `scoop update *`) |

**choco** (`Tools/choco.json` + `Tools/choco.ps1`)

The same picker set for Chocolatey, driven by choco's machine-readable `-r`
output (no module exists). `choco info` preview. Install/uninstall/upgrade need
elevation and run through [`gsudo`](https://github.com/gerardog/gsudo) when it is
on PATH; otherwise `Enter` on the search picker returns the command to run in an
elevated shell.

| Function / Alias                | Purpose                                              |
| ------------------------------- | ---------------------------------------------------- |
| `Select-ChocoPackage [-Query]` / `cins` | Search → install (`Enter` returns the command, `Alt-R` installs, `Alt-I` installs in place) |
| `Remove-ChocoPackage` / `crm`   | Installed packages → uninstall (`Alt-X` in place, `Alt-C` command) |
| `Invoke-ChocoUpdate` / `cup`    | Outdated packages, multi-select → upgrade (`Tab` mark, `Alt-A` `choco upgrade all`) |

**Command-line prefill (PSReadLine chords).** When PSReadLine is available, each
search picker is also bound to a `Ctrl+G` chord that lands the install command
directly on the command line, editable, ready to run:

| Chord | Manager |
| ----- | ------- |
| `Ctrl+G` `W` | winget |
| `Ctrl+G` `S` | scoop |
| `Ctrl+G` `C` | choco |

Type a search term, press the chord, pick in fzf — the term is replaced by e.g.
`winget install --id BurntSushi.ripgrep.MSVC --exact` with the cursor at the end.
Edit if you like, then press Enter. (The bindings use the current line as the
query and no-op on an empty line. Pressing `Alt-R` inside the picker installs
immediately instead of prefilling.)

## License

MIT — see [LICENSE](LICENSE).

