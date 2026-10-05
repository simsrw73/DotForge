# Pickers and helpers

**Audience:** DotForge users at the prompt every day.  
**Topic:** the commands you get from `Import-Module DotForge` alone (fuzzy pickers, navigation, files, environment, help) and how to build your own picker.  
**Goal:** know which short command does what, and write a picker for your own workflow.

These commands exist as soon as the module is imported; they don't need `Register-DFTool`. Commands that come with a specific tool (`fco` for git branches, `wins` for winget, …) are on the [tools page](tools.md). Every command here has full help: `Get-Help <name> -Full`, or see the [reference](../reference.md).

## Quick start

```powershell
Import-Module DotForge
mkcd demo/src
touch README.md
up 2
which pwsh
```

<!-- output: varies -->
```text
C:\Program Files\PowerShell\7\pwsh.exe
```

1. `mkcd` creates a folder (and any missing parents) and moves into it.
2. `touch` creates an empty file, or updates the time stamp of an existing one.
3. `up 2` moves up two folders.
4. `which` prints the path of the program that runs when you type a name.

## Fuzzy pickers

A picker opens a list in [fzf](https://github.com/junegunn/fzf): type to filter, arrow keys to move, Enter to choose, Esc to cancel. Pickers need fzf on `PATH`.

| Command | Alias | Lists | Enter |
| --- | --- | --- | --- |
| `Select-DFLocation` | `fcd` | folders below the current one (via `fd` when installed) | changes to it |
| `Select-DFHelpTopic` | `fh` | every help topic, with a preview | shows the full help |
| `Select-DFCommand` | `fcmd` | every command, with help in the preview | outputs the name |
| `Select-DFModule` | `fmod` | installed modules | outputs the name |
| `Select-DFVerb` | `fverb` | approved PowerShell verbs | outputs the verb |
| `Select-DFProcess` | `fps` | running processes, highest CPU first | outputs the process objects |
| `Select-DFEnvVar` | `fenv` | environment variables | outputs the value |

Pickers that output something compose with the rest of PowerShell:

<!-- interactive -->

```powershell
Import-Module DotForge
fps -Multi | Stop-Process -WhatIf
Get-Help (fcmd -Module DotForge) -Examples
$token = fenv
```

1. `fps -Multi` lets you mark several processes with Tab; they're passed to `Stop-Process`.
2. `fcmd -Module DotForge` limits the list to one module.
3. `fenv` returns the selected variable's value.

To use [skim](https://github.com/skim-rs/skim) or another fzf-compatible program instead, set `$Env:Picker` to its executable name (`'sk'` for skim).

## Navigation and files

| Command | Alias | What it does |
| --- | --- | --- |
| `Set-DFLocationUp` | `up` | Moves up 1–99 folders (`up 3`). |
| `New-DFDirectoryAndSet` | `mkcd` | Creates a folder and moves into it. |
| `New-DFFile` | `touch` | Creates empty files, or updates their time stamps. |
| `Get-DFWhich` | `which` | Prints the first matching program on `PATH`; `-All` lists every match in `PATH` order. |
| `Open-DFItem` | `open` | Opens files, folders or URLs with their default program. |

Find out which of several copies of a program runs, and which are shadowed:

```powershell
Import-Module DotForge
which pwsh -All
```

<!-- output: varies -->
```text
C:\Program Files\PowerShell\7\pwsh.exe
C:\Users\you\AppData\Local\Microsoft\WindowsApps\pwsh.exe
```

The first line is the one that runs.

## PATH, folders and shims

| Command | What it does |
| --- | --- |
| `Add-DFToPath <dir>` | Adds a folder to `PATH` for this session, without duplicates; `-Prepend` puts it first. |
| `New-DFDirectory <path>` | Creates a folder if it's missing; never errors if it exists. |
| `New-DFShim <exe>` | Writes a `.cmd` file that runs a program that isn't on `PATH`. |
| `Get-DFPath` (`path`) | Lists `PATH` one folder per line. |

`Add-DFToPath` compares folders in a normalized form, so the same folder with a trailing `\` isn't added twice:

```powershell
Import-Module DotForge
$Env:Path = 'C:\Windows\system32;C:\Windows'
Add-DFToPath 'C:\tools\bin'
Add-DFToPath 'C:\tools\bin\'
Add-DFToPath 'C:\Windows' -Prepend
path
```

```text
C:\Windows
C:\Windows\system32
C:\tools\bin
```

1. The second `Add-DFToPath` finds `C:\tools\bin` already present and does nothing.
2. `-Prepend` moves `C:\Windows` to the front instead of adding a second copy.
3. Only the current session changes. Put the calls in your profile to keep them.

A shim makes a program callable by name without adding its whole folder to `PATH`. Shims go to `$HOME\.local\bin`, or `$DFConfig.ShimsPath`:

```powershell
Import-Module DotForge
New-DFShim (which pwsh) -Name ps7
Get-Content (Join-Path $HOME '.local' 'bin' 'ps7.cmd')
```

```text
WARNING: DotForge: '...\.local\bin' is not on PATH - shims won't be invocable until it is added
@echo off
setlocal
"...pwsh.exe" %*
set "_exit=%ERRORLEVEL%"
endlocal & exit /b %_exit%
```

The shim runs the program from your current folder, passes all arguments through and returns its exit code. Add the shims folder to `PATH` once (`Add-DFToPath "$HOME\.local\bin"` in your profile) and the warning goes away. `New-DFShim -Name ripgrep` finds the program through the tool registry instead of a path.

## Environment and profile

| Command | Alias | What it does |
| --- | --- | --- |
| `Get-DFEnv [pattern]` | `env` | Lists environment variables as `NAME=value`, sorted; colored at a terminal. |
| `Get-DFPath` | `path` | Lists `PATH` entries. |
| `Select-DFEnvVar` | `fenv` | Picker; outputs the chosen variable's value. |
| `Edit-DFProfile` | `ep` | Opens `$PROFILE` in `$Env:EDITOR`. |
| `Invoke-DFProfileReload` | `reload` | Runs `$PROFILE` again in the current session. |

```powershell
Import-Module DotForge
$Env:DEMO_COLOR = 'blue'
env DEMO*
```

```text
DEMO_COLOR=blue
```

`reload` applies changes to your profile's functions, aliases and variables without a new shell. It doesn't remove anything you deleted from the profile, and it doesn't re-import a module that's already loaded.

## Help

| Command | Alias | What it does |
| --- | --- | --- |
| `Invoke-DFHelp <name>` | `hm` | Full `Get-Help` with highlighted headings, through `$Env:Pager`. |
| `Show-DFCliHelp <command>` | `clh` | An external program's `--help`, colorized. |
| `Show-DFCliHelpPaged <command>` | `clhp` | The same, through the pager. |

`clh` works out each program's help flag (`--help`, `-help`, `-?`, `help` or `-h`) and remembers it:

```powershell
Import-Module DotForge
(clh git | Out-String) -split "`r?`n" | Select-Object -First 2
```

<!-- output: varies -->
```text
usage: git [-v | --version] [-h | --help] [-C <path>] [-c <name>=<value>]
           [--exec-path[=<path>]] [--html-path] [--man-path] [--info-path]
```

Use `clh <command> -Flag <flag>` when the guess is wrong, and `-Force` to forget a remembered flag.

## Processes, clipboard and utilities

| Command | Alias | What it does |
| --- | --- | --- |
| `Get-DFTopProcess` | `top` | The top 20 processes by CPU (or `-By Memory`), once. |
| `Copy-DFToClipboard` | `yank` | Copies piped text to the clipboard. |
| `Get-DFFromClipboard` | `paste` | Outputs the clipboard text. |
| `New-DFUuid` | `uuidgen` | Prints a new random UUID; `-UpperCase`, `-NoHyphens`, `-Braces` change the format. |
| `Invoke-DFWithPager` | `pg` | Pipes output through `$Env:Pager`, or prints it when unset. |

```powershell
Import-Module DotForge
uuidgen -UpperCase -Braces
```

<!-- output: varies -->
```text
{5A37689B-0A3E-433F-9EA5-DC24EDA4C42B}
```

`yank` and `paste` use the real clipboard:

<!-- system -->

```powershell
Import-Module DotForge
git log --oneline -5 | yank
paste
```

`yank` is named that way because `copy` is PowerShell's built-in alias for `Copy-Item`, and DotForge never replaces built-in commands.

## Build your own picker

`Invoke-DFPicker` runs the list → fzf → action loop the built-in pickers use. Give it a scriptblock that produces lines, and what to do with the choice:

<!-- interactive -->

```powershell
Import-Module DotForge
function Select-Branch {
    Invoke-DFPicker -List { git branch } `
        -Header 'Select branch  [Enter to checkout]' `
        -Parse { $_.TrimStart('*').Trim() } `
        -Action { param($b) git checkout $b }
}
Select-Branch
```

1. `-List` produces the lines fzf shows.
2. `-Parse` turns the chosen line into a value; here it strips the `* ` git puts before the current branch.
3. `-Action` receives that value. Without `-Action`, the picker outputs the value instead.

Carry an id that you don't want to display in a hidden field, and give one item two different actions with `-Expect`:

<!-- interactive -->

```powershell
Import-Module DotForge
$r = Invoke-DFPicker -List { Get-Process | ForEach-Object { "$($_.Name)`t$($_.Id)" } } `
    -Delimiter "`t" -WithNth 1 -Expect 'alt-k' -Parse { ($_ -split "`t")[1] }
if ($r.Key -eq 'alt-k') { Stop-Process -Id $r.Selected -WhatIf } else { Get-Process -Id $r.Selected }
```

1. `-Delimiter` and `-WithNth 1` show only the name; the id rides along in field 2.
2. With `-Expect`, the picker returns `{ Key; Selected }`: `Key` is empty for Enter, or the key you pressed.
3. A `-List` scriptblock that uses your own variables needs `.GetNewClosure()`, for example `{ $items }.GetNewClosure()`; otherwise it sees nothing.

Preview commands (`-Preview 'type {}'`) run in `cmd.exe`, so use commands that work there, or call `pwsh -NoProfile -Command "..."`. See [Invoke-DFPicker](../reference.md#invoke-dfpicker) for every option.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `'fzf' is not on PATH` | fzf isn't installed | `Install-DFTool -Name fzf`, or set `$Env:Picker`. |
| A picker opens with an empty list | the list scriptblock uses local variables without `.GetNewClosure()` | Add `.GetNewClosure()` to the scriptblock. |
| `ep` warns `$Env:EDITOR is not set` | no editor configured | `$Env:EDITOR = 'code'` in your profile. |
| `Quoted arguments in $Env:Pager are not supported` | the pager command contains quotes | Use `--key=value` form: `bat --paging=always`. |
| `touch`, `env` or `paste` runs a different program | Coreutils for Windows intercepts the name | See [Coreutils conflicts](coreutils-conflicts.md). |
| `fh` warns that `XDG_CACHE_HOME` is not set | `Initialize-DFEnvironment` hasn't run | Call it first, or set `$Env:XDG_CACHE_HOME`. |

More on the [troubleshooting page](troubleshooting.md).
