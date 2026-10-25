# Writing a tool record

**Audience:** contributors adding a tool to DotForge, or changing how one is configured.  
**Topic:** the `Tools/<name>.json` record, companion scripts, one-time setup scripts, and the rules every tool follows.  
**Goal:** a new tool that `Register-DFTool` configures, with tests passing.

Read [docs/plugin-architecture.md](../plugin-architecture.md) and [docs/builtin-safety-policy.md](../builtin-safety-policy.md) first. The short version: adding a tool never changes DotForge's core code, and a tool never replaces a built-in PowerShell command without documented reasons.

## Quick start

A tool is one JSON file. Try one out from a scratch folder with `-ToolsPath`, which reads records from that folder instead of the module's `Tools\`:

```powershell
Import-Module DotForge
Start-DFSession -Config @{ Tools = @() }
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
  "aliases": { "wh": { "command": "where.exe" } }
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
3. The `aliases` block defines `wh`. Without `args` (or with `"args": []`) it's a plain alias; with arguments it becomes a small function that adds them.

To keep the tool for yourself, put the file in your own tools folder instead: see [Your own tools](your-own-tools.md). To add it to DotForge for everyone, put it in the repository's `Tools\` folder and run the tests (see [Check your work](#check-your-work)).

## The record

| Field | Required | Meaning |
| --- | --- | --- |
| `name` | yes | Tool name; the file must be `Tools/<name>.json`. |
| `executable` | yes | What must be on `PATH` (e.g. `bat.exe`); for `"type": "module"`, the module name. |
| `executableExclude` | | Glob patterns of install locations to skip when a role's `env` uses `${DF_TOOL_EXE}`, e.g. `["*\\Git\\usr\\bin\\*"]`. Detection ignores them. |
| `type` | | `exe` (default) or `module`. A module tool is detected with `Get-Module -ListAvailable`. |
| `description` | | One line; shown by `Get-DFTool` and `Find-DFTool`. |
| `tags` | | Words for `Get-DFTool -Tag` and `Find-DFTool`. |
| `packages` | | Install ids per **source**: a system manager (`scoop`, `winget`, `choco`), a registry (`npm`, `crates`, `psgallery`), or a version manager (`fnm`, `mise`). A value is an id, or `{ "id": "...", "feed": { "name": "...", "url": "..." } }` for a package in a third-party feed such as a scoop bucket; `Install-DFTool` adds the feed (shown in the plan first), then installs `<feed>/<id>`. |
| `install` | | `{ "prefer": ["winget", "scoop"] }`: this tool's preferred sources, for when one package is official or better maintained. `{ "avoid": { "scoop": "<why>" } }`: sources that install this tool where DotForge can't fix it (one sentence each, shown to the user); they go last unless the user names one. Only sources in `packages`, and never one source in both. The user's `-Via` and `InstallVia` still win, and `IncludeSources`/`ExcludeSources` still decide which sources are allowed. |
| `installs` | | Makes the tool a **package manager**; see [Package managers](#package-managers). |
| `xdg` | | How the tool's files move to XDG folders; see below. |
| `env` | | Other environment variables to set every session (flags, themes, `LESS`). Values may use `${XDG_*}`. A role's variables (`PAGER`, `EDITOR`, `GIT_PAGER`, …) go in the role block instead. A value you set outside DotForge is kept (see [Your own environment values win](configuration.md#your-own-environment-values-win)). |
| `aliases` | | `{ "<alias>": { "command": "...", "args": [ ... ] } }`; `args` is optional. A role's aliases (`ls`, `ll`, …) go in the role block instead. |
| `picker` | | A declarative fzf picker, or a list of them; see below. |
| `after` | | Tools (`"zoxide"`) or roles (`"role:version-manager"`) this one is registered after, when both are requested. Ordering only: it requests nothing. |
| `requires` | | Tools (`"fzf"`) or roles (`"role:js-runtime"`) this tool can't work without. A required tool is requested automatically and registered first; if it's missing or excluded, this tool isn't activated. A role requirement orders this tool after the role's requested members; it never picks a member for the user, and never blocks. |
| `roles` | | The roles the tool joins, e.g. `{ "pager": { "priority": 10, "env": { "PAGER": "less" } } }`; see [Joining a role](#joining-a-role). |
| `theme` | | The tool's theme: `{ "key": "BatTheme", "default": "catppuccin-mocha", "map": { … }, "env": { "BAT_THEME": "{theme}" } }`. Optional `files` (theme files in `Tools/<files>/` and `$XDG_CONFIG_HOME\<files>\themes`: `<theme>.json`, or a `<theme>` folder for a tool that reads its theme from a folder; with `files` and no `valid`, a theme with no match is left unset), `valid` + `fallback` (names the tool accepts, and what to use otherwise), `command` (for a theme your companion applies: the command that switches it), `apply` (for a theme your companion applies: a global function taking `-Name <value>`, which `Set-DFToolTheme` calls to switch it live). See [Themes and wrappers](#themes-and-wrappers). |
| `wrapper` | | Runs the executable through a function that adds arguments: `{ "args": ["-s", "{theme}", { "ifFile": "${XDG_CONFIG_HOME}/x/config", "args": ["--config", "{file}"] }] }`. `ifFile` may use `{theme}` (lsd: `{theme}/config.yaml`); it is checked on each call. `custom: true` when your companion builds it with `New-DFToolWrapper -Invoke`. |
| `themeMap` | | Legacy: use `theme.map`. Still read when `theme.map` is absent. |
| `settings` | | Free-form values for the tool's companion script (`$DFCurrentTool.settings`). |
| `prewarm` | | `false` stops DotForge pre-loading a module tool in the background. |
| `setup` | | `{ "seed": { "<destination>": "<file under Tools/>" }, "notes": [ { "text", "ifFile"?, "unlessFile"? } ] }`: default config files copied once, and notes for steps only the user can take, in the one-time setup step (see below). |

### `xdg.method`

| Method | What DotForge does |
| --- | --- |
| `default` | Nothing: the tool already follows XDG. |
| `env` | Sets each `xdg.vars` variable that isn't already set (a value you set yourself is kept), and creates each folder in `xdg.dirs`. Values are `${XDG_*}` path templates only. |
| `wrapper` | Nothing in the record; the companion script wraps the executable (as glow and fastfetch do). |
| `manual` | Warns, with `xdg.instructions`, that the user must configure it. |

Non-path values (flags, theme names) belong in `env`, not `xdg.vars`.

### `xdg.native`

Where the tool keeps its config, data or state when DotForge doesn't relocate it, so DotForge finds a user's existing data and links the XDG location to it instead of hiding it ([When DotForge finds your existing config](configuration.md#when-dotforge-finds-your-existing-config)). One entry per relocated path, keyed by its `xdg.vars` variable, its `setup.seed` target, or (for a path a wrapper or companion sets) the target template itself:

<!-- fragment -->

```json
"xdg": {
  "method": "env",
  "vars": { "BAT_CONFIG_PATH": "${XDG_CONFIG_HOME}/bat/bat.conf" },
  "native": {
    "BAT_CONFIG_PATH": ["${APPDATA}/bat/config", "${HOME}/.config/bat/config"]
  }
}
```

The object form `{ "paths": [...], "guide": "..." }` adds a guide: how to keep the XDG copy instead, shown when both locations hold content (`move` and `block` were retired: DotForge never moves data).

1. List the defaults for Windows, Linux and macOS as `${HOME}`, `${APPDATA}`, `${LOCALAPPDATA}`, `${SCOOP}` (where a manager keeps data beside the program, e.g. `${SCOOP}/persist/bitwarden-cli/bw-data`) or `${XDG_*}` templates; a path that doesn't exist on a machine is skipped.
2. Use `[]` when the tool's own default already is the XDG location.
3. Order matters: the first path with content is the one DotForge links to.
4. When a `settings` field can point the tool somewhere else (fastfetch's `configPath`), add `"setting": "configPath"` to the object form: that value, when set, is the target.
5. Caches need no entry. `tests/ToolNative.Coverage.Tests.ps1` fails when a relocated config, data or state path has none.

### `banner`

Adds lines to the [startup banner](configuration.md#startup-banner): `"banner": { "script": "<tool>.banner.ps1", "body": true, "fills": ["publicip"] }`.

1. `script` is a file next to the record. DotForge dot-sources it and it outputs one object with script blocks: `Style` (optional: `@{ KeyColor; OutputColor; Separator }`), `Work` (background jobs: `@{ Name; ScriptBlock; ArgumentList }`, run in a runspace with only their arguments) and `Complete` (`param($Results, $Context)`: returns `@{ Body = lines or $null; Fills = @{ <name> = items } }`, where an item is `@{ Key; Value; Alert }`).
2. `body: true` makes the part's `Body` the banner (fastfetch does this); a `fills` name fills the body's `@DF:<name>@` placeholder lines.
3. `Complete` gets only the jobs that finished in time. DotForge caches fills and uses the last known values when a job is late. See `Tools/fastfetch.banner.ps1` and `Tools/smartmontools.banner.ps1`.

### `picker`

An object describes one picker; a list of objects (`"picker": [ { … }, { … } ]`) gives the tool several, as docker's `fdc` and `fdi`. A picker that needs more than these fields lives in the companion `.ps1`, calls `Invoke-DFPicker`, and the record says `"picker": "custom"`.

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

## Package managers

A tool whose record has `installs` is a package manager: `Install-DFTool` uses it for every tool with a package in its source. Core code never names a manager, so adding one is only a JSON file.

```json
"installs": {
  "from": "scoop",
  "install": ["scoop", "install", "{id}"],
  "batch": true,
  "feeds": {
    "list": ["scoop", "bucket", "list"],
    "add":  ["scoop", "bucket", "add", "{name}", "{url}"],
    "id":   "{feed}/{id}"
  }
}
```

| Field | What it means |
| --- | --- |
| `from` | The source it installs from: its own name for a system manager (`scoop`), or a registry several managers share (`npm` for npm, pnpm and bun). Which of those does the work is a role (`js-package-manager`): the user's `Defaults` choice, else the highest priority. |
| `install` | The install command as an argv. `{id}` is the package id; with `batch`, it expands to every id in the batch. |
| `function` / `args` | Instead of `install`, a PowerShell command and its parameters (`Install-PSResource` with `Name = "{id}"`). A `true` argument is a switch. |
| `update` / `remove` | How to update or remove a package: an argv like `install`, or `{ "function": ..., "args": { ... } }`. Without one, DotForge says it can't update or remove through this manager. |
| `list` / `outdated` | Names of functions in `Tools/<manager>.manage.ps1` that report what the manager has installed and what has an update. |
| `batch` | It can install several ids in one call. |
| `elevate` | It needs administrator rights (choco). Unless the shell is elevated, DotForge runs it through the `elevator` role's tool (gsudo) when one is installed or being installed in the same run, else through Windows' `sudo` when it is on in inline mode, else in a separate administrator window (which reports only an exit code). With no one to answer an admin prompt, it uses the tool's next source. |
| `reactivate` | Re-run this manager's companion after it installs something, so a new runtime reaches `PATH` in the same shell (fnm, mise). |
| `feeds` | How to list and add third-party feeds (buckets, marketplaces) and how a feed-qualified id is written. |

A manager that installs from more than one source gives `installs` as a list of blocks, one per `from`. uv installs PyPI tools (`uv tool install`) and Python itself (`uv python install --default`).

A tool with no `packages` that `requires` another tool is installed by installing that tool: npm comes with node, and pip comes with python.

### `Tools/<manager>.manage.ps1`

Add this companion when a manager supports `list` or `outdated`. It defines the functions named by those fields. Each function accepts `-Manager` and returns objects with `Id`, `Installed`, and `Available`. `Id` must exactly match the value that the manager's `packages` source writes. Use an empty `Available` value for `list`.

Run the manager only through `Invoke-DFManagerCommand`. Never throw when its output cannot be parsed. Return no rows for output that you cannot parse. DotForge loads these companions on demand, not at startup. Test each parser against recorded manager output in `tests/fixtures/managers/<manager>/`.

## Companion scripts

When JSON isn't enough, add `Tools/<name>.ps1`. `Register-DFTool` dot-sources it after applying the record:

- `$DFCurrentTool` holds the parsed record; read your `settings` from it.
- `$PSScriptRoot` is the `Tools\` folder, for bundled files in `Tools/<name>/`.
- Define user-facing functions as `function global:Name` (or `Set-Item function:global:Name`) and aliases with `-Scope Global`, or they vanish when registration returns.
- Give every global function complete comment-based help (`.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER` for each parameter, `.EXAMPLE`, `.OUTPUTS`). `tests/Docs.Help.Tests.ps1` enforces it.
- Declare your theme in the record's `theme` block. If your companion applies it in code (a theme file
  it converts, an API call), read the resolved theme with `Get-DFToolTheme -Tool $DFCurrentTool`
  (`.Native` is the tool's own name, `.Value` the file or name to use) and set `theme.command`.
- Anything that depends on another tool's undocumented behavior must fail quietly and be listed in [docs/external-dependencies.md](../external-dependencies.md).

### Themes and wrappers

Most tools need no theme code. bat takes its theme from a variable:

```json
"theme": {
  "key": "BatTheme",
  "default": "catppuccin-mocha",
  "map": { "catppuccin-mocha": "Catppuccin Mocha" },
  "env": { "BAT_THEME": "{theme}" }
}
```

glow takes it as an argument, from a style file it ships in `Tools/glow/` or a name it knows:

```json
"theme": {
  "key": "GlowTheme",
  "default": "catppuccin-mocha",
  "files": "glow",
  "valid": ["auto", "dark", "light", "dracula", "pink", "notty", "ascii", "tokyo-night"],
  "fallback": "auto"
},
"wrapper": { "args": ["-s", "{theme}"] }
```

The theme comes from the per-tool key (`BatTheme`), then the shared `Theme`, then `default`. An
explicit per-tool key, or `Set-DFToolTheme <tool> <theme>`, overrides a variable set outside DotForge.

## Joining a role

A role is a job several tools can do, such as `prompt` or `pager`. The roles and what each one reserves are defined in `data/roles.json`; `Get-DFRole` lists them. A tool joins in its own record:

```json
"roles": {
  "pager": {
    "priority": 20,
    "env": { "PAGER": "moor" }
  }
}
```

- `priority` decides the winner when the user hasn't chosen one in `$DFConfig.Defaults`; higher wins.
- `env` and `aliases` in the role block are applied **only when your tool wins** the role. A role's reserved variables and aliases may appear only here, never in the top-level `env`/`aliases`.
- For behavior that needs code, define a plain function with the role's hook name in your companion: `Initialize-DFRolePrompt` for `prompt`, `Initialize-DFRoleProjectEnv` for `project-env`, and so on. DotForge calls it with `-Tool` and `-Role`, only when your tool wins, right after running the companion. Never make it `global:`, and don't set a role's reserved variables in it.
- Code a role reserves (for example `Invoke-Expression` for prompt engines) may run only inside that hook.
- In a role block's `env`, `${DF_TOOL_EXE}` becomes the full path of your tool's executable (forward slashes, quoted if it has a space), skipping `executableExclude` locations; with no other copy, it's the bare name. less uses it so `PAGER` names the native build.
- A *category* role (such as `grep`) takes an empty block: `"grep": {}`.
- A role block can also say what your tool offers Alt+C (`directory-jump`). In a `navigation` block, `directories` is a command that prints ranked folders, one per line, and `enter` is the command that moves the shell to one; `directoriesScored: true` says each line is `<score> <path>` (zoxide: `["zoxide", "query", "--list", "--score"]`, scored, and `"cd"`). In a `file-search` block, `directoryScan` lists folders exactly `{depth}` levels down (fd: `["fd", "--type", "d", "--exact-depth", "{depth}"]`). DotForge reads them from the tools in the session (`Get-DFRoleDeclaration`), so a new tool joins without core changes.

Some roles define their aliases and pickers themselves, in words: `listing` defines
`ls`, `ll`, `la`, `tree` and the `ff` picker. Join one by mapping each of its words to
your tool's flags in a `flags` block; `[]` means your tool does that by default:

```json
"roles": { "listing": { "priority": 5, "flags": {
  "color": ["--color=auto"], "color-always": ["--color=always"],
  "icons": ["--icon=auto"], "icons-always": ["--icon=always"],
  "dirs-first": ["--group-directories-first"], "literal": ["--literal"],
  "long": ["--long"], "all": ["--all"], "git": ["--git"],
  "tree": ["--tree"], "one-per-line": ["-1"]
} } }
```

`data/roles.json` lists each role's words and what they mean. With `flags`, don't write
the role's aliases yourself: they're ignored. If your tool lacks a word, the aliases
that use it are built without it, and `Get-DFToolStatus <tool>` says which. A record
without `flags` (written before the role had words) keeps its own aliases.

A role's words can also build variables: `pager` builds `PAGER` and `BAT_PAGER` as your
executable followed by your flags for its words, so don't set those in your block's
`env`. A flag can be a group passed only while a file exists (`ifFile`, which `{file}`
names in `args`) or doesn't (`unlessFile`); paths may use `{theme}`, `${XDG_*}` and
`{settings.<name>}`. ov's theme word:

```json
"theme": [ { "ifFile": "{theme}/config.yaml", "unlessFile": "${XDG_CONFIG_HOME}/ov/config.yaml", "args": ["--config", "{file}"] } ]
```

A role can also name a `fallback` for when no requested tool fills it; `pager` falls back
to `more`.

The key-binding roles, `history-search` (Ctrl+R) and `path-insert` (Ctrl+T), bind only through
`Set-DFRoleKeyHandler -Role -Chord -Tool -Bind { … }` from the hook; it keeps a binding the user made
themselves. An engine that takes fzf's options and ships no PowerShell bindings calls
`Register-DFFuzzyKeyHandler -Engine <exe> -Key History|Path -Tool $Tool.name` instead (fzf, skim).

starship's companion is a complete example:

<!-- fragment -->

```powershell
function Initialize-DFRolePrompt {
    param([PSCustomObject]$Tool, [string]$Role)
    Invoke-Expression (Get-DFCachedCommandOutput -Name 'starship-init' -Executable 'starship' -Generate {
        starship init powershell --print-full-init | Out-String
    })
}
```

`tests/Roles.Contract.Tests.ps1` checks every rule above for every tool.

## One-time setup

Setup runs at most once per machine, the first time the tool is activated, before its companion script. It has two parts, either or both.

**Seeding a default config file.** Ship the file under `Tools/<name>/` and declare it in `setup.seed`, keyed by its destination:

```json
"setup": { "seed": { "${XDG_CONFIG_HOME}/fastfetch/config.jsonc": "fastfetch/config.jsonc" } }
```

A source may use `{theme}`, the tool's theme this session. With `theme.files` that's the theme's own file or folder, so a tool can seed a themed config: `"${XDG_CONFIG_HOME}/peco/config.json": "{theme}"` or `"…/config.toml": "{theme}/config.toml"`.

A file that already exists is kept. Because seeding is part of setup, a file the user deletes on purpose isn't recreated on the next load. Files DotForge owns and must keep current (carapace's specs, delta's theme) are deployed by the companion on every load instead.

**A setup script.** For a persistent change the user may later undo, such as a line in their global git config, add `Tools/<name>.setup.ps1`. It runs after the seeds:

- It must call `Complete-DFToolSetup -Name <name>` as its last line, and only after its work succeeded. If it throws, nothing is recorded and it runs again next time.
- Once recorded in `$XDG_STATE_HOME\dotforge\setup-state.json`, it never runs again, so a user's edit or removal sticks.
- Print what you changed and how to undo it.
- Without a script, DotForge records the seeds itself.
- Users can opt out of the whole setup step with `SkipSetup = @('<name>')` in their `Start-DFSession` config.
- `Invoke-DFToolSetup -Name <name>` runs setup again (a deleted seed comes back; `-Force` also replaces an edited one).

**Setup notes.** When the user has to do something DotForge can't, say so with a note rather than printing from the script. Declare it in `setup.notes`, optionally with `ifFile`/`unlessFile` (read like a role flag group's). Conditions are checked *before* the seeds are copied, so `ifFile` on a seed's own destination means "the user already had one" (television's note about `ui.theme`). A setup script adds one with `Add-DFToolSetupNote -Name <name> -Text '…'` before `Complete-DFToolSetup`. Notes are printed once, at the end of the load, and stay in `Get-DFToolStatus <name>`.

## Check your work

From the repository root:

<!-- fragment -->

```powershell
Invoke-Pester tests/ -Output Detailed
./build/Build-DFReferenceDocs.ps1
./build/Build-DFToolRegistry.ps1
```

`Build-DFToolRegistry.ps1` stores your validated record in `data/tool-registry.json`, so loading it at startup skips the checks. Until you run it, your tool still loads the slower way, from its JSON.

1. Watch for warnings when DotForge loads your tool.
   - The tool database skips a record, with a warning naming the problem, when:
     - `name` or `executable` is missing;
     - `type` or `xdg.method` has an unknown value;
     - a field has the wrong shape. For example, an object `picker` without `function` and `list`, `"false"` in quotes where `true`/`false` belongs, or an `aliases` entry without a `command`;
     - a picker's `action` or `parse` isn't valid PowerShell.
   - A field name that looks like a misspelling of a known one (`dependson`, `themMap`, `preview_windows`) gets a "did you mean" warning, but the tool still loads. Other extra fields are allowed.
   - The tests check every shipped tool against these rules, and check companion help (`tests/Docs.Help.Tests.ps1`). Add a `tests/<name>.Tests.ps1` for any companion logic. Checking new aliases against `Get-Alias` and `Get-Command` is up to you.
2. The reference generator adds your tool to [the tool records](../reference.md#tool-records); commit the regenerated `docs/reference.md`.
3. Add your tool to the tables in [Tools](tools.md), and a note there if it behaves unusually.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| The tool isn't configured | `executable` isn't on `PATH` (or the module isn't installed) | Run `Register-DFTool -Name <tool> -Verbose` to see why it was skipped. |
| `Unknown tool '<name>'` | the record was skipped as invalid, or you used a different name than its `name` field | Look for a `schema errors` warning; tools are looked up by `name`, not file name. |
| An edit to a record in `Tools\` has no effect | the tool database is read once per session | `Import-Module ./DotForge.psd1 -Force`, or a new shell. |
| A companion's function disappears after registration | defined without `global:` | Use `function global:Name`. |
| `circular dependency detected in tool after/requires` | two tools depend on each other | Remove one direction; DotForge falls back to an unordered registration. |
| An `xdg.vars` value isn't applied | the variable was already set | Expected: user values win. Clear it to test. |

More on the [troubleshooting page](troubleshooting.md).
