# Your own tools

**Audience:** DotForge users who want a tool DotForge doesn't ship, or a shipped tool set up differently.  
**Topic:** your tools folder, `New-DFTool`, changing a shipped tool, and adding your own pickers and Tab completion.  
**Goal:** tool records of your own that load in every shell, without changing DotForge itself.

## Quick start

DotForge reads tool records from its own `Tools\` folder and from yours, `$XDG_CONFIG_HOME\dotforge\tools`. `New-DFTool` starts a record there:

```powershell
Import-Module DotForge
Start-DFSession -Config @{ Tools = @() }
$null = New-DFTool -Name pwsh7 -Executable pwsh
Get-Content (Join-Path $Env:XDG_CONFIG_HOME 'dotforge' 'tools' 'pwsh7.json')
```

```text
Edit ...pwsh7.json, then load it with: Register-DFTool -Name pwsh7
To load it in every shell, add 'pwsh7' to Tools in your Start-DFSession config.
{
  "name": "pwsh7",
  "executable": "pwsh...",
  "description": "...",
  "tags": [],
  "aliases": {},
  "picker": null
}
```

1. `New-DFTool` found `pwsh` on `PATH` and filled in the program and its description.
2. `tags`, `aliases` and `picker` start empty for you to fill in.
3. The record does nothing until you load it: `Register-DFTool -Name pwsh7` loads it now, and adding `pwsh7` to `Tools` in your profile's `Start-DFSession` config loads it in every shell.

Fill in an alias and load the tool:

```powershell
Import-Module DotForge
Start-DFSession -Config @{ Tools = @() }
$tools = Join-Path $Env:XDG_CONFIG_HOME 'dotforge' 'tools'
New-DFDirectory $tools
@'
{
  "name": "pwsh7",
  "executable": "pwsh",
  "description": "PowerShell 7, without my profile",
  "tags": ["shell"],
  "aliases": { "pn": { "command": "pwsh", "args": ["-NoProfile"] } }
}
'@ | Set-Content (Join-Path $tools 'pwsh7.json')
Register-DFTool -Name pwsh7
(Get-DFToolStatus -Name pwsh7).State
(Get-DFTool -Name pwsh7).source
```

```text
Active
user
```

`pn` now starts PowerShell without a profile. [Writing a tool record](writing-a-tool.md#the-record) lists every field a record can have.

## Your tools folder

`$XDG_CONFIG_HOME\dotforge\tools` (by default `~\.config\dotforge\tools`) holds the same kinds of files as DotForge's `Tools\` folder:

| File | What it is |
| --- | --- |
| `<name>.json` | The tool record. Name the file after the record's `name`; a record named differently is skipped, with a warning. |
| `<name>.ps1` | A companion script, run each time the tool is activated. |
| `<name>.setup.ps1` | A one-time setup script ([One-time setup](writing-a-tool.md#one-time-setup)). |
| `<name>.manage.ps1` | List and outdated functions, for a tool that is a package manager ([Package managers](writing-a-tool.md#package-managers)). |
| `<name>\` | Files the companion or a `setup.seed` entry reads, such as a theme. |

1. Every DotForge command reads your records along with its own: `Start-DFSession`, `Register-DFTool`, `Get-DFTool`, `Install-DFTool`, `Update-DFTool`, `Remove-DFTool` and `Get-DFCommandConflict`.
2. A tool's companion and other files are read from the folder its record is in. A record in your folder never runs DotForge's companion of the same name.
3. A record with an error is skipped with a warning that names the file and the error; nothing else stops loading.
4. `Get-DFTool | Where-Object source -eq user` lists your records.
5. Your records are checked each time a shell loads them, unlike DotForge's, which are checked when DotForge is built. That takes a few milliseconds per record.

## Start a record with New-DFTool

<!-- fragment -->

```powershell
New-DFTool -Name ripgrep -Executable rg -Companion
```

1. `-Name` is the tool's name and the file name. Without `-Executable`, DotForge looks for a program of that name.
2. `-Executable` names the program when it differs from the tool name.
3. When the name is a PowerShell module rather than a program, the record becomes a module tool (`"type": "module"`).
4. When nothing by that name is installed, you get a warning and the record anyway; DotForge activates the tool once it's installed.
5. `-Companion` also writes `<name>.ps1` with a picker and a Tab completer example, commented out.
6. An existing file is kept unless you add `-Force`; `-WhatIf` shows what would be written.

## Change a shipped tool

A record in your folder replaces DotForge's record of the same name. `New-DFTool -From` copies DotForge's record, its scripts and its data folder into your folder, so you can start from them:

```powershell
Import-Module DotForge
Start-DFSession -Config @{ Tools = @() }
New-DFTool -From fzf 3>$null 6>$null | ForEach-Object Name
```

```text
fzf.json
fzf.ps1
fzf
```

1. Your record replaces DotForge's completely: fields aren't merged, so what's in your file is what runs.
2. Your copy no longer gets DotForge's fixes to that tool, so `New-DFTool` warns. Delete the copied files to go back to DotForge's.
3. To change only an environment variable, a theme or the tool chosen for a role, use your [configuration](configuration.md) instead; it keeps DotForge's record.

## Add a picker

A picker that lists a command's output and acts on the line you pick is a `picker` block in the record:

<!-- fragment -->

```json
"picker": {
  "function": "Select-Todo",
  "alias": "ftd",
  "list": "todo.exe list",
  "header": "Select a task  [Enter to mark it done]",
  "parse": "($_ -split '\\s+')[0]",
  "action": "todo.exe done {}"
}
```

[The picker block](writing-a-tool.md#picker) lists every field. A picker that needs more, such as two steps or a check before listing, goes in the companion: write a `function global:` that calls `Invoke-DFPicker` ([Build your own picker](pickers-and-helpers.md#build-your-own-picker)), and set `"picker": "custom"` in the record.

## Add Tab completion

Register a completer in the companion, so it exists whenever the tool is active:

<!-- fragment -->

```powershell
Register-ArgumentCompleter -Native -CommandName todo, todo.exe -ScriptBlock {
    param($wordToComplete, $commandAst, $cursorPosition)
    'add', 'done', 'list' | Where-Object { $_ -like "$wordToComplete*" } |
        ForEach-Object { [System.Management.Automation.CompletionResult]::new($_) }
}
```

When you use Carapace, a YAML spec gives the same result without code; see [Add a completer for a command Carapace doesn't know](completion.md#add-a-completer-for-a-command-carapace-doesnt-know).

## Rules for your companion

The rules for DotForge's own companions apply ([Companion scripts](writing-a-tool.md#companion-scripts)):

1. Define commands as `function global:Name` and aliases with `-Scope Global`, or they're gone when the companion returns.
2. `$DFCurrentTool` is the tool's record while the companion runs; `$DFCurrentTool.settings` is your record's `settings` object.
3. Check new aliases with `Get-Command <alias>` first, so you don't hide a PowerShell command ([Safety](safety.md)).
4. A companion that throws doesn't stop other tools: the tool is marked failed, and `Get-DFToolStatus` shows the error.

## Troubleshooting

| What you see | Why | What to do |
| --- | --- | --- |
| `DotForge: <name>.json schema errors: …` | The record has a mistake; it's skipped, and DotForge's record of that name (if any) is used. | Fix the field the message names. |
| `DotForge: <file>.json names its tool '<x>', so it is skipped` | The file name and `name` differ. | Rename the file to `<x>.json`. |
| `DotForge: … names unknown tool '<name>'` | The file isn't in your tools folder, or `XDG_CONFIG_HOME` points elsewhere. | Run `Get-DFTool -Name <name>`; check `$Env:XDG_CONFIG_HOME`. |
| A changed companion has no effect | Companions run when the tool is activated. | Open a new shell, or run `Register-DFTool -Name <name>`. |
| A copied tool misses a later DotForge fix | Your copy replaces DotForge's record and files. | Delete your copy, run `New-DFTool -From <name>` again, and redo your changes. |
