# Troubleshooting

**Audience:** anyone seeing a DotForge warning, an error, or a command that doesn't behave as expected.  
**Topic:** every message DotForge prints, what causes it, and how to fix it.  
**Goal:** find your symptom, then fix it.

Messages are listed by area. Search this page for the text of the message you see; the parts in `<angle brackets>` vary.

## First checks

Most problems come from one of these. Check them in one go:

```powershell
Import-Module DotForge
Initialize-DFEnvironment
"PowerShell $($PSVersionTable.PSVersion)"
"DotForge $((Get-Module DotForge).Version)"
"fzf: $([bool](Get-Command fzf -ErrorAction Ignore))"
Get-DFEnv XDG_CONFIG_HOME
```

<!-- output: varies -->
```text
DotForge: Environment ready. Package managers: scoop, winget, choco
PowerShell 7.6.6
DotForge 0.6.0
fzf: True
XDG_CONFIG_HOME=C:\Users\you\.config
```

Then see which tools were configured and which were skipped, and why:

```powershell
Import-Module DotForge
Initialize-DFEnvironment
Register-DFTool -All -Verbose 4>&1 | ForEach-Object { "$_" } | Where-Object { $_ -match 'registered|skipping' }
```

<!-- output: varies -->
```text
DotForge: bat registered
DotForge: 'lazygit.exe' not available - skipping lazygit
...
```

## Setup and profile

| Message or symptom | Cause | Fix |
| --- | --- | --- |
| `No supported package managers found (scoop, winget, choco)` | none of them is on `PATH` | Install one. Everything except `Install-DFTool` still works. |
| `Unknown tool '<name>'` | not a DotForge tool name | `Get-DFTool \| Select-Object name` lists valid names. |
| `Could not install '<tool>'. No compatible package manager from: <list>` | no installed manager has a package id for the tool, or every attempt failed | Install another manager, or install the tool yourself. |
| `<tool> one-time setup failed: <error>` | the tool's setup script threw | Fix the cause shown; setup retries on the next `Register-DFTool`. |
| `circular dependency detected in tool dependsOn` | two tool records depend on each other | A bug in the tool records; tools still register, unordered. |
| `<file> schema errors: <errors>` or `Failed to parse <file>` | a tool record is invalid | That tool is skipped. See [writing a tool record](writing-a-tool.md). |
| A tool you installed isn't configured | it isn't on `PATH` in this shell yet, or it's in `SkipTools` | Open a new shell; check `$DFConfig.SkipTools`; run `Register-DFTool -Name <tool> -Verbose`. |
| `reload` didn't remove a function you deleted | reloading runs the profile again; it doesn't undo | Open a new shell. |
| `$PROFILE not found at <path>` | you have no profile yet | `New-Item -ItemType File -Path $PROFILE -Force`. |

## Configuration and themes

| Message or symptom | Cause | Fix |
| --- | --- | --- |
| A `$DFConfig` setting has no effect | set after `Register-DFTool`, or the key is misspelled (no warning) | Set it before `Import-Module`; check the [settings table](configuration.md#all-settings). |
| `$DFConfig.Defaults['<role>'] names an unknown role` | misspelled role name | Run `Get-DFRole` for the list. |
| `$DFConfig.Defaults['<role>'] names '<tool>', which is not a <role> tool` | misspelled tool, or a tool that can't fill that role | Pick one of the tools the warning lists. |
| `$DFConfig.Defaults['<role>']: '<role>' is a category, which has no winner` | `Defaults` names a grouping-only role such as `grep` | Remove that entry; every member of a category is configured. |
| `<tools> can each fill the <role> role; using <tool>` | two tools that would conflict are installed and you haven't chosen | Add the `Defaults` line the warning shows. |
| `<VAR> was '<value>' but $DFConfig.Defaults.<role> is '<tool>'` | you set the variable yourself and also chose a different tool | Remove one of the two settings. |
| `<tool> declares the <role> role but its companion defines no Initialize-DFRole…` | a tool record or companion is incomplete | Report it; the tool works, but not as that role's winner. |
| `CompletionMode '<x>' is invalid; using Native.` | typo | `Native` or `Inshellisense`. |
| `invalid PSReadLineEditMode '<x>'` | typo | `Emacs` or `Windows`. |
| `fzf theme '<name>' not found`, `PSReadLine theme '<name>' not found` | the theme isn't bundled or in your themes folder | Use `catppuccin-mocha`, or add a theme file; see [themes](configuration.md#themes). |
| `mdcat theme '<name>' not recognized`, `mdv theme '<name>' not recognized`, `glow style '<name>' not found` | not a theme that tool has | Pick from the [theme table](configuration.md#theme-names-each-tool-accepts). |
| `vivid theme '<name>' failed` | vivid doesn't have that theme | `vivid themes` lists them. |
| `invalid color '<hex>' for token '<name>'`, `invalid fzf color entry` | a bad value in your theme file | Fix the file; other colors still apply. |
| `unknown PSReadLine setting '<name>'` | a bad key in the psreadline record | A bug in the tool record; please report it. |
| `PSReadLine option 'PredictionSource' not supported in this terminal` | the host has no virtual-terminal support (redirected output, some IDE consoles) | Harmless; predictions are simply off there. |
| Tab stopped completing | `Set-PSReadLineOption -EditMode` after `Register-DFTool` | Use `PSReadLineEditMode` in `$DFConfig`. See [Completion](completion.md). |

## Commands and pickers

| Message or symptom | Cause | Fix |
| --- | --- | --- |
| `'fzf' is not on PATH` | fzf isn't installed, or `$Env:Picker` names a program that isn't | `Install-DFTool -Name fzf`; check `$Env:Picker`. |
| A picker opens with an empty list | your `-List` scriptblock uses local variables without `.GetNewClosure()` | Add `.GetNewClosure()`. |
| `cat`, `ls`, `touch`, `env` or `paste` runs a different program than `Get-Command` says | Coreutils for Windows rewrites the name first | See [Coreutils conflicts](coreutils-conflicts.md). |
| `coreutils shadows <n> DotForge command(s)` | same | Same page. |
| `$Env:EDITOR is not set` | `ep` or `frg` needs an editor | `$Env:EDITOR = 'code'`. |
| `Quoted arguments in $Env:Pager are not supported` | quotes in the pager command | Use `--key=value`: `bat --paging=always`. |
| `Show-DFCliHelp: could not determine a help flag for '<cmd>'` | none of `--help`, `-help`, `-?`, `help`, `-h` produced help | `clh <cmd> -Flag <flag>`. |
| `'<dir>' is not on PATH - shims won't be invocable until it is added` | the shims folder isn't on `PATH` | `Add-DFToPath "$HOME\.local\bin"` in your profile. |
| `Shim '<path>' already exists. Use -Force to overwrite.` | a shim with that name exists | Add `-Force`, or pick another `-Name`. |
| `no command history to elevate` | `please` in a new session | Run the command first. |
| `the 'Microsoft.WinGet.Client' module is required` | `wins`/`wrm`/`wup` without the module | `Install-Module Microsoft.WinGet.Client -Scope CurrentUser`. |
| `the 'Scoop' module is required` | `sins`/`srm`/`sup` without the module | `Install-Module Scoop -Scope CurrentUser`. |
| `choco is not installed` | `cins`/`crm`/`cup` without Chocolatey | Install Chocolatey. |
| `git is not installed — scoop bucket operations will fail` | scoop needs git for buckets | `scoop install git`. |

## Tools

| Message or symptom | Cause | Fix |
| --- | --- | --- |
| `<tool> requires manual XDG configuration` | the tool can't be relocated safely (lsd) | Informational; skip the tool to silence it. |
| `no oh-my-posh config found`, `multiple oh-my-posh configs found` | zero or several `*.omp.*` files in `$XDG_CONFIG_HOME\oh-my-posh\` | Set `$Env:POSH_THEME` to one file. |
| `POSH_THEMES_PATH not set or directory not found` | `fpot` has no themes folder | Put `*.omp.json` themes in `$XDG_DATA_HOME\oh-my-posh\themes`. |
| `direnv requires PowerShell 7.2+` | older PowerShell | Upgrade. |
| A tool can't find data it had before (rustup toolchains, vcpkg packages, PSReadLine history) | DotForge moved the tool's folders to XDG locations | Move the old folders, or reinstall what's missing. See [Safety](safety.md#relocated-tool-data). |
| zoxide stops tracking folders after `fpot` | the theme switch replaced the prompt hook | Open a new shell. |

## Package catalog (trifle)

| Message or symptom | Cause | Fix |
| --- | --- | --- |
| `-Readme/-GitInfo need an exact match — showing the match table instead.` | the query matched several packages | Use a qualified `source:id` query. |
| `No package '<id>' found in <source>` | the qualified id doesn't exist there | Check the `Id` column of `trifle <name> -All`. |
| `unknown -Category value(s)` | not a taxonomy term | `tcats` lists them. |
| `no local catalog data yet` | `ftrifle` with no query before anything was cached | Run a `trifle` query or `Update-DFPackageCache`. |
| `category database unavailable` | the data file is missing or damaged | Reinstall the module, or `Update-DFCategoryDb`. |
| `<catalog> re-warm of '<query>' failed` | a background refresh hit a network error | Harmless; the cached answer is still used. |
| winget results are old | winget refreshes its catalog file only when winget runs | `winget source update`. |

## Still stuck

Run with `-Verbose` to see each step, and include the output, your PowerShell version and `(Get-Module DotForge).Version` when you [open an issue](https://github.com/simsrw73/DotForge/issues).
