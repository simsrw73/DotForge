# Your Own Tools (T-2) — Design

**Status:** Approved, 2026-10-11
**Closes:** T-2.

## Context

DotForge reads tool records from one folder, the module's `Tools\`. `-ToolsPath` replaces that folder
instead of adding to it, so a user who wants a tool DotForge doesn't ship, or a shipped tool configured
differently, has to fork the module. T-2 asked for a guide; the user chose to add a real user folder
first, plus a command that starts a record.

## 1. The user tools folder

`$XDG_CONFIG_HOME\dotforge\tools\` (`Get-DFUserToolsPath`, in `Shared/`). It holds the same files as
`Tools\`: `<name>.json`, and optionally `<name>.ps1`, `<name>.setup.ps1`, `<name>.manage.ps1` and a
`<name>\` data folder.

- **Loading.** `Import-DFToolDb` at the default location reads the shipped folder, then the user
  folder; a user record replaces the shipped record of the same name **entirely** (no field merge).
  `-Name` checks the user folder first. `Get-DFToolNames` returns both. An explicit `-ToolsPath` reads
  only that folder, as today (tests rely on it).
- **Where a record's files are.** The loader adds two fields to every record it reads: `folder` (the
  folder its JSON came from) and `source` (`user` for the user folder, else `builtin`). Companions,
  setup scripts, seeds and `.manage.ps1` files are found in `$Tool.folder`, so a user record's files
  come from the user folder, and a user package manager (`installs` + `.manage.ps1`) works too.
  `ConvertTo-DFToolRecord` defaults both to `$null`; consumers fall back to their `ToolsPath` for a
  record built without the loader (tests).
- **The registry.** A user file that is byte-identical to a shipped one still gets the prebuilt record;
  the loader returns a copy of it, so setting `folder` never changes the shared registry object. Other
  user records are validated on every load, like any changed record.
- **Startup.** No user folder: one `Test-Path`. With one: one listing, plus schema checks for its
  records.
- Everything that loads the DB sees user records: `Start-DFSession`, `Register-DFTool`, `Get-DFTool`
  (shows `source`), `Install-DFTool`, `Update-DFTool`, `Remove-DFTool`, `Get-DFCommandConflict`, roles.

## 2. `New-DFTool`

In the on-demand `DotForge.Helpers` module (no startup cost). `SupportsShouldProcess`.

- `New-DFTool -Name <tool> [-Executable <exe>] [-Companion] [-Force]` writes `<name>.json` in the user
  folder: `name`; `executable` (the leaf name of `Get-Command -CommandType Application`, else
  `-Executable`, else `<name>`, with a warning when it isn't on PATH; a PowerShell module found by
  `Get-Module -ListAvailable` instead gets `"type": "module"`); `description` (the exe's
  `FileDescription`, else empty); `tags: []`, `aliases: {}`, `picker: null`. `-Companion` adds a
  `<name>.ps1` skeleton with `$DFCurrentTool`, a commented `Invoke-DFPicker` picker and a commented
  `Register-ArgumentCompleter`.
- `New-DFTool -From <shipped tool> [-Force]` copies the shipped record and its companion, setup and
  manage scripts and data folder, and warns that the copy no longer gets DotForge's fixes (delete it
  to go back).
- Refuses to overwrite an existing file without `-Force`. Validates the written record with
  `Test-DFToolSchema`. Outputs the created files and prints the next step (`Register-DFTool -Name`).

## 3. Guide

`docs/guide/your-own-tools.md`: the folder; `New-DFTool`; overriding a shipped tool and what it
costs; pickers (declared, or written with `Invoke-DFPicker`); completers in a companion; adding the
tool to `Tools`. `writing-a-tool.md` points to it for users; CHANGELOG; T-2 deleted.

## Testing

- Loader: a user record adds a tool; a same-name one replaces the shipped one (default and `-Name`
  paths); `folder`/`source` set; an identical copy doesn't mutate the registry record; explicit
  `-ToolsPath` ignores the user folder; `Get-DFToolNames` union.
- Companion, setup, seed and manage files load from `$Tool.folder`.
- `New-DFTool`: fields filled from a stubbed command; module type; missing exe warns; `-Companion`;
  `-From` copies files and data folder; refuses overwrite; `-WhatIf` writes nothing; result validates.
- All under `Set-DFTestXdg`, so nothing touches the real config folder.
