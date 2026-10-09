# Getting started

**Audience:** PowerShell users on Windows 11 who are comfortable editing their profile.  
**Topic:** installing DotForge and configuring your command-line tools with it.  
**Goal:** a profile that sets up only the tools you request on each new shell, plus one new tool installed with DotForge.

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
Start-DFSession -Config @{ Tools = @('+core', '+prompt') }
```

<!-- output: varies -->
```text
DotForge: Environment ready. Package managers: scoop, winget, choco
```

What each line does:

1. `Import-Module DotForge` loads the module and defines the general helpers (`which`, `touch`, `up`, `mkcd`, …). Nothing else changes yet.
2. `Start-DFSession` sets the XDG base-directory variables (`XDG_CONFIG_HOME` and the rest) and exports them, so the tools themselves use the same folders.
3. Its `Tools` list configures only the requested installed tools: environment variables, aliases, pickers, completions, prompt and theme. Missing requested tools are reported with `Install-DFTool -Missing` as the next step.

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
Start-DFSession -Config @{ Tools = @() }
Get-DFEnv XDG*
```

```text
XDG_BIN_HOME=...\.local\bin
XDG_CACHE_HOME=...\.cache
XDG_CONFIG_HOME=...\.config
XDG_DATA_HOME=...\.local\share
XDG_STATE_HOME=...\.local\state
```

The paths are under your home folder unless you set the variables yourself first; DotForge never overrides a value that is already set.

## Step 4: make it permanent

Add the same two lines to your profile so every new shell is configured. Open your profile with `notepad $PROFILE` (or your editor), and add:

```powershell
Import-Module DotForge
Start-DFSession -Config @{ Tools = @('+core', '+prompt') }
```

To customize what DotForge does (tools, themes, and which tool wins `ls`), pass your hashtable to `Start-DFSession -Config`. The [configuration guide](configuration.md) lists every setting:

```powershell
$DFConfig = @{
    Tools     = @('+core', '+prompt')
    Theme     = 'catppuccin-mocha'
    Defaults  = @{ listing = 'eza' }
    ExcludeTools = @('lsd')
}
Import-Module DotForge
Start-DFSession -Config $DFConfig
```

Open a new terminal to check that it loads without errors.

## Step 5: install what's missing

When a requested tool isn't installed, the session lists it and points here. Preview the install first with `-WhatIf`:

```powershell
Import-Module DotForge
Start-DFSession -Config @{ Tools = @('ripgrep') }
Install-DFTool -Missing -WhatIf
```

<!-- output: varies -->
```text
  stage 1  scoop: ripgrep (ripgrep)
```

Then install everything that's missing at once:

<!-- system -->

```powershell
Import-Module DotForge
Start-DFSession -Config $DFConfig
Install-DFTool -Missing
```

1. `Install-DFTool` builds one plan: a source for each tool (scoop, winget, choco, or a registry such as npm or the PowerShell Gallery), in stages, so that a manager or runtime installs before the tools that need it (for example fnm, then node, then a tool from npm).
2. It never installs something you didn't ask for. When a tool needs a manager you don't have (say, a JavaScript package manager), it asks which one, showing a default; Enter keeps it. Third-party feeds (a scoop bucket) and admin prompts (choco) appear in the plan before you confirm.
3. `-UseDefaults` answers every question with the default and doesn't ask for confirmation. From a script with no one to ask, and no `-UseDefaults`, only the tools that need no decision are installed; the rest are reported with the reason.
4. New tools are configured in the current session right away. `Install-DFTool -Name ripgrep` installs one tool by name; add it to `Tools` to load it in future shells.

## Next steps

- [Configuration](configuration.md): every configuration key, themes, and choosing which tool fills each role.
- [Tools](tools.md): the 43 tools DotForge configures, and the commands each one adds.
- [Pickers and helpers](pickers-and-helpers.md): the fuzzy pickers and general commands you get from importing the module.
- [Package catalog](package-catalog.md): `trifle`, which searches every package catalog at once.
- [Reference](../reference.md): every command and parameter.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `Install-PSResource` is not recognized | Windows PowerShell 5.1, or PowerShell 7 older than 7.4 without PSResourceGet | Run `pwsh`, or use `Install-Module DotForge -Scope CurrentUser`. |
| `No supported package managers found` | none of scoop, winget or choco is on `PATH` | Install one; `Register-DFTool` still works without one. |

More symptoms and fixes are on the [troubleshooting page](troubleshooting.md).
