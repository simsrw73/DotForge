# Getting started

**Audience:** PowerShell users on Windows 11 who are comfortable editing their profile.  
**Topic:** installing DotForge and configuring your command-line tools with it.  
**Goal:** a profile that sets up every installed tool on each new shell, plus one new tool installed with DotForge.

## Before you start

You need:

- PowerShell 7.2 or later (`pwsh`, not Windows PowerShell 5.1).
- Windows 11.
- At least one package manager: [scoop](https://scoop.sh), [winget](https://learn.microsoft.com/windows/package-manager/winget/) or [Chocolatey](https://chocolatey.org/). DotForge installs tools through it.
- [fzf](https://github.com/junegunn/fzf), for the fuzzy pickers. It's optional, but most of the interactive commands need it.

Check your PowerShell version:

```powershell
$PSVersionTable.PSVersion.ToString()
```

<!-- output: varies -->
```text
7.6.6
```

Read the [safety page](safety.md) before you run DotForge on a machine you care about. Configuring a tool can move where it keeps its files. For example, DotForge points rustup at `~\.local\share\rustup`, and a toolchain installed in the old location is no longer found.

## Step 1: install the module

Install DotForge from the PowerShell Gallery for your user account:

<!-- system -->

```powershell
Install-PSResource -Name DotForge -Scope CurrentUser
```

## Step 2: try it in one session

Configure your tools in the current shell only, to see what DotForge does before you commit to it:

```powershell
Import-Module DotForge
Initialize-DFEnvironment
Register-DFTool -All
```

<!-- output: varies -->
```text
DotForge: Environment ready. Package managers: scoop, winget, choco
```

What each line does:

1. `Import-Module DotForge` loads the module and defines the general helpers (`which`, `touch`, `up`, `mkcd`, …). Nothing else changes yet.
2. `Initialize-DFEnvironment` sets the XDG base-directory variables (`XDG_CONFIG_HOME` and the rest), creates the folders, and reports which package managers it found. Always run it before `Register-DFTool`.
3. `Register-DFTool -All` configures every tool DotForge knows that is installed: environment variables, aliases, pickers, completions, prompt and theme. Tools you don't have are skipped silently.

You may also see a few lines from individual tools, such as a note that delta added a theme include to your git config. The [troubleshooting page](troubleshooting.md) explains each warning.

## Step 3: see what changed

List the tools DotForge knows about and has found on this machine:

```powershell
Import-Module DotForge
Get-DFTool | Where-Object { Get-Command $_.executable -ErrorAction Ignore } |
    Sort-Object name | Select-Object -ExpandProperty name
```

<!-- output: varies -->
```text
bat
carapace
delta
eza
fd
fzf
...
```

Look up one tool's record to see what DotForge will do with it:

```powershell
Import-Module DotForge
Get-DFTool -Name bat | Select-Object name, executable, description
```

```text
name executable description
---- ---------- -----------
bat  bat.exe    Modern cat replacement with syntax highlighting and Git integration
```

Check the XDG folders DotForge set up:

```powershell
Import-Module DotForge
Initialize-DFEnvironment
Get-DFEnv XDG*
```

```text
DotForge: Environment ready. Package managers: ...
XDG_BIN_HOME=...\.local\bin
XDG_CACHE_HOME=...\.cache
XDG_CONFIG_HOME=...\.config
XDG_DATA_HOME=...\.local\share
XDG_STATE_HOME=...\.local\state
```

The paths are under your home folder unless you set the variables yourself first; DotForge never overrides a value that is already set.

## Step 4: make it permanent

Add the same three lines to your profile so every new shell is configured. Open your profile with `notepad $PROFILE` (or your editor), and add:

```powershell
Import-Module DotForge
Initialize-DFEnvironment
Register-DFTool -All
```

To customize what DotForge does (themes, which tool wins `ls`, which tools to skip), set `$DFConfig` above those lines. The [configuration guide](configuration.md) lists every setting:

```powershell
$DFConfig = @{
    Theme     = 'catppuccin-mocha'
    Defaults  = @{ listing = 'eza' }
    SkipTools = @('lsd')
}
Import-Module DotForge
Initialize-DFEnvironment
Register-DFTool -All
```

Open a new terminal to check that it loads without errors.

## Step 5: install a missing tool

Install a tool by its DotForge name; DotForge picks the package id for whichever package manager you have. Preview first with `-WhatIf`:

```powershell
Import-Module DotForge
Install-DFTool -Name ripgrep -WhatIf
```

<!-- output: varies -->
```text
What if: Performing the operation "Install" on target "ripgrep via scoop (ripgrep)".
```

Then install it, and configure it in the current session:

<!-- system -->

```powershell
Import-Module DotForge
Initialize-DFEnvironment
Install-DFTool -Name ripgrep
Register-DFTool -Name ripgrep
```

1. `Install-DFTool` tries your package managers in order (scoop, winget, choco, unless you set `PackageManagerOrder`) and uses the first one that has the tool.
2. `Register-DFTool -Name ripgrep` configures just that tool now. New shells pick it up through `Register-DFTool -All`.

## Next steps

- [Configuration](configuration.md): every `$DFConfig` setting, themes, and choosing between competing tools.
- [Tools](tools.md): the 43 tools DotForge configures, and the commands each one adds.
- [Pickers and helpers](pickers-and-helpers.md): the fuzzy pickers and general commands you get from importing the module.
- [Package catalog](package-catalog.md): `trifle`, which searches every package catalog at once.
- [Reference](../reference.md): every command and parameter.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `Install-PSResource` is not recognized | Windows PowerShell 5.1, or PowerShell 7 older than 7.4 without PSResourceGet | Run `pwsh`, or use `Install-Module DotForge -Scope CurrentUser`. |
| An error from a tool companion when your profile runs | `Register-DFTool` ran before `Initialize-DFEnvironment` | Call `Initialize-DFEnvironment` first, as in step 4. |
| `No supported package managers found` | none of scoop, winget or choco is on `PATH` | Install one; `Register-DFTool` still works without one. |

More symptoms and fixes are on the [troubleshooting page](troubleshooting.md).
