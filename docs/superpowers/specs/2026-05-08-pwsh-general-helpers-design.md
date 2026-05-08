# Design: General PowerShell Helpers

**Date:** 2026-05-08
**Status:** Approved

## Overview

A new General Helpers layer for DotForge — 20 module-owned public cmdlets with
short aliases covering pager output, help/discovery, navigation, file system,
process management, environment/profile, and clipboard. Functions use the `DF`
prefix and are exported by the module manifest. Short aliases are set `Global`
in each file, matching the tool-companion pattern.

## Architecture

New layer sits alongside the tool registration system (Layers 1–3). Does not
touch the tool DB or JSON schema.

`Invoke-DFWithPager` is elevated to Layer 1 (Core Primitives) — it is a
reusable output primitive that multiple category files depend on.

### New files

```
Public/DFHelpers.Pager.ps1        ← Layer 1: Invoke-DFWithPager (pg)
Public/DFHelpers.Help.ps1         ← Invoke-DFHelp (hm), Select-DFCommand (fcmd),
                                     Select-DFVerb (fverb), Select-DFModule (fmod)
Public/DFHelpers.Navigation.ps1   ← Set-DFLocationUp (up), New-DFDirectoryAndSet (mkcd),
                                     Select-DFLocation (fcd)
Public/DFHelpers.FileSystem.ps1   ← New-DFFile (touch), Get-DFWhich (which),
                                     Open-DFItem (open)
Public/DFHelpers.Process.ps1      ← Select-DFProcess (fps), Get-DFTopProcess (top)
Public/DFHelpers.Environment.ps1  ← Get-DFPath (path), Select-DFEnvVar (fenv),
                                     Edit-DFProfile (ep), Invoke-DFProfileReload (reload)
Public/DFHelpers.Clipboard.ps1    ← Copy-DFToClipboard (copy), Get-DFFromClipboard (paste)

tests/DFHelpers.Pager.Tests.ps1
tests/DFHelpers.Help.Tests.ps1
tests/DFHelpers.Navigation.Tests.ps1
tests/DFHelpers.FileSystem.Tests.ps1
tests/DFHelpers.Process.Tests.ps1
tests/DFHelpers.Environment.Tests.ps1
tests/DFHelpers.Clipboard.Tests.ps1
```

### Conventions

- All files: `#Requires -Version 7.0`
- All aliases: `Set-Alias -Scope Global -Force` at bottom of each file
- Module manifest (`DotForge.psd1`) updated to export all 20 new function names
- Pickers use `Invoke-DFPicker`; pager output uses `Invoke-DFWithPager`
- Default picker action: output to stdout (composable via pipeline)

## Function Specifications

### `Invoke-DFWithPager` (`pg`) — `DFHelpers.Pager.ps1`

Accepts pipeline input or a scriptblock. Collects all output, then pipes to
`$Env:Pager` if set, otherwise writes to stdout. No fallback to `bat` or
`less` — user controls the pager via `$Env:Pager`.

```
Invoke-DFWithPager [-Command <scriptblock>] [-InputObject <string>]
```

Pager parsing: splits `$Env:Pager` on whitespace to handle values like
`less -R` or `bat --paging=always`. Uses splatting — no `Invoke-Expression`.

Usage:
```powershell
pg { rg --help }
Get-Help Get-Process | pg
```

---

### DFHelpers.Help.ps1

**`Invoke-DFHelp` (`hm`)**
Runs `Get-Help -Full`, colorizes section headers (SYNOPSIS, DESCRIPTION,
PARAMETERS, EXAMPLES, NOTES, RELATED LINKS) with ANSI bold/yellow, pipes
through `Invoke-DFWithPager`. Skips colorization if `$Env:NO_COLOR` is set
or `$Host.UI.SupportsVirtualTerminal` is `$false`.

```powershell
hm Get-Process
```

**`Select-DFCommand` (`fcmd`)**
fzf picker over `Get-Command`. Displays `Name  CommandType  Source`. Preview
shows `Get-Help $_ -ErrorAction Ignore`. Supports `-Module` parameter passed
through to `Get-Command`. Outputs selected command name as string.

```powershell
fcmd
fcmd -Module PSFzf
```

**`Select-DFVerb` (`fverb`)**
fzf picker over `Get-Verb`. Displays `Group  Verb` columns. Outputs the
selected verb name as string.

**`Select-DFModule` (`fmod`)**
fzf picker over `Get-Module -ListAvailable`. Displays `Name  Version
Description`. Outputs selected module name as string.

---

### DFHelpers.Navigation.ps1

**`Set-DFLocationUp` (`up`)**
Moves N directory levels up. Defaults to 1. Builds relative path from N `..`
segments and calls `Set-Location`.

```powershell
up        # cd ..
up 3      # cd ../../..
```

**`New-DFDirectoryAndSet` (`mkcd`)**
Creates a directory via `Ensure-DFDir` then calls `Set-Location` on the new
path.

```powershell
mkcd new-project
mkcd path/to/new/dir
```

**`Select-DFLocation` (`fcd`)**
fzf picker for directories. Uses `fd --type d` if `fd` is on PATH, falls back
to `Get-ChildItem -Recurse -Directory`. Search starts from current directory.
Action is `Set-Location` (exception to stdout default — navigation is the
action). `fd` is a soft dependency: absent means slower enumeration, no
warning.

```powershell
fcd
```

---

### DFHelpers.FileSystem.ps1

**`New-DFFile` (`touch`)**
If path exists, updates `LastWriteTime` to now. If not, creates an empty
file. Accepts multiple paths and pipeline input.

```powershell
touch newfile.txt
touch a.txt b.txt c.txt
```

**`Get-DFWhich` (`which`)**
Resolves commands using `Get-Command -CommandType Application`. PowerShell
handles `$Env:PATHEXT` extension resolution in Windows priority order
automatically (`.COM → .EXE → .BAT → .CMD → ...`), so no extension is
required. `-All` switch returns every match across PATH rather than just the
first. Silent (no error/warning) when not found.

```powershell
which rg
which python -All
```

**`Open-DFItem` (`open`)**
Opens file or folder in its default application via `Invoke-Item`. Accepts
multiple paths and pipeline input. Mirrors macOS `open` convention.

```powershell
open .
open file.pdf
```

---

### DFHelpers.Process.ps1

**`Select-DFProcess` (`fps`)**
fzf picker over `Get-Process`, sorted by CPU descending. Displays
`Name  Id  CPU  WorkingSet(MB)`. Preview shows
`Get-Process -Id {Id} | Format-List *`. Outputs selected `Process` object —
composable with `Stop-Process`, `Format-List`, etc. Supports `-Multi` switch
for multi-select.

```powershell
fps
fps | Stop-Process -Force
fps -Multi | Stop-Process -Force
```

**`Get-DFTopProcess` (`top`)**
One-shot snapshot. Outputs a `Format-Table` (display utility, not pipeline
source). Parameters: `-By` (`CPU` or `Memory`, default `CPU`), `-Count`
(default 20).

```powershell
top
top -By Memory
top -Count 10
```

---

### DFHelpers.Environment.ps1

**`Get-DFPath` (`path`)**
Prints each `$Env:PATH` entry on its own line, split on
`[IO.Path]::PathSeparator`.

```powershell
path
path | Select-String scoop
```

**`Select-DFEnvVar` (`fenv`)**
fzf picker over `Get-ChildItem Env:`. Displays `Name  Value`. Outputs
selected env var's value string.

```powershell
fenv
fenv | pg
```

**`Edit-DFProfile` (`ep`)**
Opens `$PROFILE` in `$Env:EDITOR`. Emits `Write-Warning` if `$Env:EDITOR`
is not set.

```powershell
ep
```

**`Invoke-DFProfileReload` (`reload`)**
Dot-sources `$PROFILE` to reload it in the current session.

```powershell
reload
```

---

### DFHelpers.Clipboard.ps1

**`Copy-DFToClipboard` (`copy`)**
Pipeline-friendly `Set-Clipboard` wrapper. Collects all pipeline input and
sets clipboard once at end (avoids overwriting on each item).

```powershell
copy "some text"
Get-Content file.txt | copy
```

**`Get-DFFromClipboard` (`paste`)**
Thin alias over `Get-Clipboard`. Outputs clipboard as string.

```powershell
paste
paste | pg
```

---

## Testing Strategy

One `tests/DFHelpers.<Category>.Tests.ps1` per category file. Each test file:

- Mocks `$Env:Pager` via `$Env:Pager = $null` / set in `BeforeEach`
- Mocks `Invoke-DFPicker` for picker functions
- Mocks external commands (`fd`, `fzf`, editor) via `Mock`
- Focuses on behavior (correct output, correct delegation) not implementation

`Invoke-DFWithPager` tests verify: scriptblock mode, pipeline mode, pager
invoked when `$Env:Pager` set, raw output when unset, pager arg splitting.

## Function/Alias Summary

| File | Functions | Aliases |
|---|---|---|
| DFHelpers.Pager | `Invoke-DFWithPager` | `pg` |
| DFHelpers.Help | `Invoke-DFHelp`, `Select-DFCommand`, `Select-DFVerb`, `Select-DFModule` | `hm`, `fcmd`, `fverb`, `fmod` |
| DFHelpers.Navigation | `Set-DFLocationUp`, `New-DFDirectoryAndSet`, `Select-DFLocation` | `up`, `mkcd`, `fcd` |
| DFHelpers.FileSystem | `New-DFFile`, `Get-DFWhich`, `Open-DFItem` | `touch`, `which`, `open` |
| DFHelpers.Process | `Select-DFProcess`, `Get-DFTopProcess` | `fps`, `top` |
| DFHelpers.Environment | `Get-DFPath`, `Select-DFEnvVar`, `Edit-DFProfile`, `Invoke-DFProfileReload` | `path`, `fenv`, `ep`, `reload` |
| DFHelpers.Clipboard | `Copy-DFToClipboard`, `Get-DFFromClipboard` | `copy`, `paste` |
