# Writing a tool record

**Audience:** contributors adding a tool to DotForge, or changing how one is configured.  
**Topic:** the `Tools/<name>.json` record, companion scripts, one-time setup scripts, and the rules every tool follows.  
**Goal:** a new tool that `Register-DFTool` configures, with tests passing.

Read [docs/plugin-architecture.md](../plugin-architecture.md) and [docs/builtin-safety-policy.md](../builtin-safety-policy.md) first. The short version: adding a tool never changes DotForge's core code, and a tool never replaces a built-in PowerShell command without documented reasons.

## Quick start

A tool is one JSON file. Try one out from a scratch folder with `-ToolsPath`, which reads records from that folder instead of the module's `Tools\`:

```powershell
Import-Module DotForge
Initialize-DFEnvironment
$tools = Join-Path $HOME 'scratch-tools'
New-DFDirectory $tools
@'
{
  "name": "whereexe",
  "description": "Windows where.exe, as a demo tool",
  "executable": "where.exe",
  "tags": ["search", "demo"],
  "xdg": { "method": "default" },
  "env": { "WHEREEXE_DEMO": "on" },
  "aliases": { "wh": { "command": "where.exe", "args": [] } }
}
'@ | Set-Content (Join-Path $tools 'whereexe.json')

Register-DFTool -Name whereexe -ToolsPath $tools
"WHEREEXE_DEMO=$Env:WHEREEXE_DEMO"
(Get-Alias wh).Definition
```

```text
...
WHEREEXE_DEMO=on
where.exe
```

1. DotForge finds `where.exe` on `PATH`, so the tool counts as installed.
2. The `env` block sets `WHEREEXE_DEMO` for the session.
3. The `aliases` block defines `wh`. With `"args": []` it's a plain alias; with arguments it becomes a small function that adds them. Always include `args`: a record that leaves it out gets a function, not an alias.

To add the tool to DotForge for real, put the file in the repository's `Tools\` folder and run the tests (see [Check your work](#check-your-work)).

## The record

| Field | Required | Meaning |
| --- | --- | --- |
| `name` | yes | Tool name; the file must be `Tools/<name>.json`. |
| `executable` | yes | What must be on `PATH` (e.g. `bat.exe`); for `"type": "module"`, the module name. |
| `type` | | `exe` (default) or `module`. A module tool is detected with `Get-Module -ListAvailable`. |
| `description` | | One line; shown by `Get-DFTool` and `Find-DFTool`. |
| `tags` | | Words for `Get-DFTool -Tag` and `Find-DFTool`. |
| `packages` | | Install ids per manager: `scoop`, `winget`, `choco`, `psresource`, `cargo`. |
| `xdg` | | How the tool's files move to XDG folders; see below. |
| `env` | | Other environment variables to set every session (flags, themes, `GIT_PAGER`). Values may use `${XDG_*}`. |
| `aliases` | | `{ "<alias>": { "command": "...", "args": [ ... ] } }`; use `"args": []` for none. |
| `picker` | | A declarative fzf picker; see below. |
| `dependsOn` | | Tools that must be registered first, when both are being registered. |
| `role` | | An equivalence group for `$DFConfig.Defaults` (e.g. `listing`). |
| `themeMap` | | Shared theme name → this tool's own spelling, e.g. `{ "catppuccin-mocha": "Catppuccin Mocha" }`. |
| `settings` | | Free-form values for the tool's companion script (`$DFCurrentTool.settings`). |
| `prewarm` | | `false` stops DotForge pre-loading a module tool in the background. |

### `xdg.method`

| Method | What DotForge does |
| --- | --- |
| `default` | Nothing: the tool already follows XDG. |
| `env` | Sets each `xdg.vars` variable that isn't already set (a value you set yourself is kept), and creates each folder in `xdg.dirs`. Values are `${XDG_*}` path templates only. |
| `config` | Writes `xdg.config_content` to `xdg.config_path` if that file doesn't exist; never overwrites it. |
| `wrapper` | Nothing in the record; the companion script wraps the executable (as glow and fastfetch do). |
| `manual` | Warns, with `xdg.instructions`, that the user must configure it. |

Non-path values (flags, theme names) belong in `env`, not `xdg.vars`.

### `picker`

| Field | Meaning |
| --- | --- |
| `function`, `alias` | Name of the generated function, and its short alias. |
| `list` | Command whose output lines fill the picker. |
| `list_accepts_path` | `true` adds a `-Path` parameter appended to `list`. |
| `preview`, `preview_window` | fzf preview command (`{}` is the item; runs in `cmd.exe`) and its layout. |
| `ansi` | `true` when `list` prints colors. |
| `header` | Text above the list; say what Enter does. |
| `parse` | Optional PowerShell turning the chosen line into a value. |
| `action` | `output` to return the value, or a command with `{}` for the value (`"Set-Location {}"`). |

Check every alias against `Get-Alias` and `Get-Command` before you ship it; see the [builtin safety policy](../builtin-safety-policy.md).

## Companion scripts

When JSON isn't enough, add `Tools/<name>.ps1`. `Register-DFTool` dot-sources it after applying the record:

- `$DFCurrentTool` holds the parsed record; read your `settings` from it.
- `$PSScriptRoot` is the `Tools\` folder, for bundled files in `Tools/<name>/`.
- Define user-facing functions as `function global:Name` (or `Set-Item function:global:Name`) and aliases with `-Scope Global`, or they vanish when registration returns.
- Give every global function complete comment-based help (`.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER` for each parameter, `.EXAMPLE`, `.OUTPUTS`). `tests/Docs.Help.Tests.ps1` enforces it.
- Read themes with `Get-DFConfiguredTheme -ToolKey '<Tool>Theme'`, then `Resolve-DFThemeName` with your `themeMap`.
- Anything that depends on another tool's undocumented behavior must fail quietly and be listed in [docs/external-dependencies.md](../external-dependencies.md).

## One-time setup scripts

For a persistent change the user may later undo, such as a line in their global git config, add `Tools/<name>.setup.ps1`. It runs at most once per machine:

- It must call `Complete-DFToolSetup -Name <name>` as its last line, and only after its work succeeded. If it throws, nothing is recorded and it runs again next time.
- Once recorded in `$XDG_STATE_HOME\dotforge\setup-state.json`, it never runs again, so a user's edit or removal sticks.
- Print what you changed and how to undo it.
- Users can opt out with `$DFConfig.SkipSetup = @('<name>')`.

## Check your work

From the repository root:

<!-- fragment -->

```powershell
Invoke-Pester tests/ -Output Detailed
./build/Build-DFReferenceDocs.ps1
```

1. The tool database skips, with a warning, any record missing `name` or `executable` or using an unknown `type` or `xdg.method`, so watch for warnings. The tests check companion help (`tests/Docs.Help.Tests.ps1`); add a `tests/<name>.Tests.ps1` for any companion logic. Checking new aliases against `Get-Alias` and `Get-Command` is up to you.
2. The reference generator adds your tool to [the tool records](../reference.md#tool-records); commit the regenerated `docs/reference.md`.
3. Add your tool to the tables in [Tools](tools.md), and a note there if it behaves unusually.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| The tool isn't configured | `executable` isn't on `PATH` (or the module isn't installed) | Run `Register-DFTool -Name <tool> -Verbose` to see why it was skipped. |
| `Unknown tool '<name>'` | the record was skipped as invalid, or you used a different name than its `name` field | Look for a `schema errors` warning; tools are looked up by `name`, not file name. |
| An edit to a record in `Tools\` has no effect | the tool database is read once per session | `Import-Module ./DotForge.psd1 -Force`, or a new shell. |
| A companion's function disappears after registration | defined without `global:` | Use `function global:Name`. |
| `circular dependency detected in tool dependsOn` | two tools depend on each other | Remove one direction; DotForge falls back to an unordered registration. |
| An `xdg.vars` value isn't applied | the variable was already set | Expected: user values win. Clear it to test. |

More on the [troubleshooting page](troubleshooting.md).
