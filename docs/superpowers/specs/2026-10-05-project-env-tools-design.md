# Project-Environment Tools: direnv, ps-dotenv, mise — Design

**Date:** 2026-10-05
**Status:** Draft for review.
**Builds on:** `2026-10-05-roles-v2-design.md` (the `project-env` role and its hook contract).
**Governed by:** `docs/plugin-architecture.md`, `docs/external-dependencies.md`.

## Purpose

`project-env` is an exclusive role: one tool loads per-directory environment variables. Today its
only member is direnv, which is buggy on Windows and needs a Git Bash path DotForge never supplies.
This adds two members and fixes direnv's setup:

- **ps-dotenv** — a PowerShell-native module; the user's intended choice.
- **mise** — a larger tool (runtime versions, tasks, env); also a `version-manager`.
- **direnv** — kept, given its bash path automatically, and flagged while its Windows bug stands.

Each works with no further user configuration once installed.

## Verified facts

| Tool | Fact | Source |
|---|---|---|
| direnv 2.37.1 | Latest release (2025-07-20). On Windows the pwsh hook unloads variables it never set (`ComSpec`, `ProgramFiles`, …) on each `cd` in and out of a project. Open, no fix. | direnv#1488, #1274 |
| direnv | Bash path precedence: `bash_path` in `direnv.toml`, then the `DIRENV_BASH` environment variable, then `bash` on PATH. | `internal/cmd/config.go` |
| direnv | The user's working config: `$XDG_CONFIG_HOME\direnv\direnv.toml` with `bash_path = "C:/Program Files/Git/bin/bash.exe"`. `git` resolves to `C:\Program Files\Git\mingw64\bin\git.exe`. | this machine |
| ps-dotenv 1.1.1 | PowerShell module `Dotenv`; scoop package `ps-dotenv` in the `insomnia` bucket (`https://github.com/insomnimus/scoop-bucket`), installed as a scoop `psmodule`. Maintain-only. | README, bucket manifest |
| ps-dotenv | Disabled until `Enable-Dotenv`. `Update-Dotenv` checks the current folder and its parents; the module keeps its own state, so calling it repeatedly is cheap and correct. Unloading restores the values it replaced. | README |
| ps-dotenv | Default file names: `.env`. Approvals (`Approve-DotenvDir -Path`, `Approve-DotenvFile`, `Add-DotenvPattern`) are held in memory only, so they must be re-applied each session; `Approve-DotenvDir $HOME` adds the pattern `C:\Users\<you>\**`. Configured through the exported `$Dotenv` object. | `documentation.md`, `Dotenv/Daemon.cs`, this machine |
| ps-dotenv (installed, module 1.1.0) | Actual defaults: `Enabled = False`, `SafeMode = True` (the README calls it opt-in, but it ships on), `Async = True` (`Update-Dotenv` loads in a background thread), `Names = .env`. | this machine |
| ps-dotenv (scoop) | The release zip holds a `Dotenv\` folder and scoop links `modules\Dotenv` to the app folder, so the manifest lands at `modules\Dotenv\Dotenv\Dotenv.psd1`. `Get-Module -ListAvailable Dotenv` finds it, but `Import-Module Dotenv` by name fails ("no valid module file"); importing its `.Path` works. | this machine |
| mise 2026.10.3 | Installed via scoop (`mise`); also winget `jdx.mise`, choco `mise`. | this machine, install docs |
| mise | Honors `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_CACHE_HOME`, `XDG_STATE_HOME` natively on Windows (verified by redirecting all four). Shims live in `<XDG_DATA_HOME>\mise\shims`. | `mise doctor` |
| mise | `mise activate pwsh` output embeds the session's current PATH literally (`__MISE_ORIG_PATH`, `PATH`), prepends its shims, wraps `function:prompt`, and chains onto `LocationChangedAction` with `[Delegate]::Combine`. It costs ~73 ms to generate. | this machine |

Consequences: mise's activation **must not be cached** (a cached copy would restore a stale PATH),
and mise, like zoxide, must initialize **after** the prompt engine.

## 1. New declarative field: `scoopBucket`

Some packages live in third-party scoop buckets. A tool declares its bucket:

```jsonc
"packages": { "scoop": "ps-dotenv" },
"scoopBucket": { "name": "insomnia", "url": "https://github.com/insomnimus/scoop-bucket" }
```

- `packages.scoop` stays a plain package id; the catalog and identity-guide code read it as one.
- `Install-DFTool`, when it installs through scoop and the tool declares `scoopBucket`:
  1. If `scoop bucket list` does not include `name`, run `scoop bucket add <name> <url>` and print
     `DotForge: added scoop bucket '<name>' (<url>)`. A failed add stops this manager and the
     usual fallback to the next manager applies.
  2. Install `<name>/<id>` (bucket-qualified, so a same-named package in another bucket can't win).
- `Test-DFToolSchema`: `scoopBucket`, when present, is an object with non-empty string `name` and
  `url`.
- Generic: core reads the field, never a tool name (plugin invariant).

## 2. ps-dotenv (`Tools/ps-dotenv.json`, `Tools/ps-dotenv.ps1`)

```jsonc
{
  "name": "ps-dotenv",
  "type": "module",
  "executable": "Dotenv",
  "description": "Loads .env files as you change folders (PowerShell-native direnv alternative)",
  "tags": ["environment-vars", "shell-enhancement", "dev"],
  "packages": { "scoop": "ps-dotenv" },
  "scoopBucket": { "name": "insomnia", "url": "https://github.com/insomnimus/scoop-bucket" },
  "xdg": { "compliance": "full", "method": "default" },
  "prewarm": false,
  "roles": { "project-env": { "priority": 30 } },
  "aliases": {},
  "picker": null
}
```

Highest `project-env` priority: zero-config, PowerShell-native, and the user's choice.
`prewarm: false`: DotForge's background prewarm imports modules by name, which fails on scoop's
nested layout (Verified facts).

**Hook** `Initialize-DFRoleProjectEnv`, run only when ps-dotenv wins:

1. Import by the discovered path,
   `Import-Module (Get-Module -ListAvailable Dotenv | Select-Object -First 1).Path -Global`, which
   works for scoop's nested layout and a normal install alike; then `Enable-Dotenv`.
2. Safe mode: `$Dotenv.SafeMode = $true` unless `Get-DFConfig DotenvSafeMode -Default $true` is
   `$false`. DotForge sets it explicitly rather than relying on the module's shipped default. It also
   sets `$Dotenv.Async = $false`, so variables are loaded by the time `Set-Location` returns: with the
   module's async default, a script doing `cd project; npm test` could run before the `.env` loads.
   Loading is small and I/O-bound, so blocking costs little.
3. For each path in `@(Get-DFConfig DotenvApprovedDirs)`: `ConvertTo-DFPath` it (so `~` works),
   then `Approve-DotenvDir` it. A path that fails to approve warns and is skipped.
4. Chain `Dotenv\Update-Dotenv` onto `$ExecutionContext.SessionState.InvokeCommand.LocationChangedAction`
   with `[Delegate]::Combine`, keeping any existing handler, and marked so a second registration in
   the same session does not chain it twice.
5. Call `Update-Dotenv` once, for the folder the session starts in.

Trigger: `LocationChangedAction`, not the prompt (README's suggestion). It fires on every
`Set-Location`, including zoxide's `cd`, and needs no prompt wrapping, so there's no ordering against
oh-my-posh, starship or zoxide, and an `fpot` theme switch doesn't break it.

New `$DFConfig` keys (read by the ps-dotenv companion only):

| Key | Type | Default | Meaning |
|---|---|---|---|
| `DotenvSafeMode` | bool | `$true` | `$false` loads every `.env` without approval. |
| `DotenvApprovedDirs` | string[] | none | Folders whose `.env` files (recursively) may load in safe mode. |

With safe mode on and no approved folders, ps-dotenv prints its own "not authorized" message
when it finds a `.env`; the docs explain the setting.

## 3. direnv changes (`Tools/direnv.json`, `Tools/direnv.ps1`)

- `project-env` priority stays **10**, the lowest of the three.
- **Bash path.** In the hook, if `DIRENV_BASH` is unset, find Git for Windows' bash: resolve
  `git.exe` with `Get-Command`, then walk up its parent folders until one contains `bin\bash.exe`
  (`...\Git\mingw64\bin\git.exe` and `...\Git\cmd\git.exe` both reach `...\Git\bin\bash.exe`).
  Found: set `$Env:DIRENV_BASH`. A `bash_path` in the user's `direnv.toml` still wins, per direnv's
  precedence, and DotForge never writes `direnv.toml`. Not found (no git, or no `bin\bash.exe` above
  it): warn `DotForge: direnv needs Git for Windows' bash; set bash_path in direnv.toml or DIRENV_BASH.`
  and still install the hook. Never selects `C:\Windows\System32\bash.exe` (WSL).
- **Bug warning.** While direnv wins, read its version from `direnv version` through
  `Get-DFCachedCommandOutput` (keyed to the binary, so no process per startup). If it parses and is
  `<= 2.37.1`, warn every session:
  `DotForge: direnv <v> on Windows unloads environment variables it didn't set (direnv#1488). Consider ps-dotenv: $DFConfig.Defaults = @{ 'project-env' = 'ps-dotenv' }`.
  A newer version, or an unparsable one, warns nothing. The threshold is a constant in the
  companion, documented in `docs/external-dependencies.md`.
- The PowerShell 7.2 guard and cached hook stay as they are.

## 4. mise (`Tools/mise.json`, `Tools/mise.ps1`)

```jsonc
{
  "name": "mise",
  "executable": "mise.exe",
  "description": "Dev tool versions, environment variables and tasks per project",
  "tags": ["version-manager", "environment-vars", "dev"],
  "dependsOn": ["oh-my-posh", "starship"],
  "packages": { "scoop": "mise", "winget": "jdx.mise", "choco": "mise" },
  "xdg": { "compliance": "full", "method": "default" },
  "roles": { "project-env": { "priority": 20 }, "version-manager": {} },
  "aliases": {},
  "picker": null
}
```

- **Shims fallback (companion body, runs whether or not mise wins).** Add
  `Join-Path (Get-DFXdgPath Data) 'mise\shims'` to PATH with `Add-DFToPath`, so tools mise installed
  keep working when another tool holds `project-env`. Not a reserved action for the role.
- **Hook** `Initialize-DFRoleProjectEnv`, only when mise wins:
  `(& mise activate pwsh) | Out-String | Invoke-Expression`, generated live each session (it embeds
  the current PATH; see Verified facts). Costs ~73 ms, only for users whose winner is mise.
- `dependsOn` the prompt engines, because activation wraps `function:prompt`.

## 5. Error handling

| Condition | Behavior |
|---|---|
| `scoop bucket add` fails | Warn; that manager fails; fallback to the next manager. |
| `Import-Module Dotenv` fails in the hook | Hook throws → registration warns "failed to activate as the project-env tool" (existing). |
| An approved folder is invalid | Warn naming it; continue with the rest. |
| No Git bash for direnv | Warn; hook still installs. |
| `direnv version` unparsable | No bug warning. |
| `mise activate` fails | Hook throws → existing activation warning. |

## 6. Testing

- `Install-DFTool`: with `scoopBucket` and scoop mocked — bucket absent → `bucket add` then install
  `insomnia/ps-dotenv`; bucket present → no add; add fails → warning and fallback.
- `Test-DFToolSchema`: rejects a malformed `scoopBucket`.
- ps-dotenv hook (Dotenv commands stubbed): imports by the discovered path, enables, sets SafeMode
  per config and Async off, approves each listed
  folder through `ConvertTo-DFPath`, chains onto an existing `LocationChangedAction` without
  dropping it, doesn't double-chain on re-registration, calls `Update-Dotenv` once. Every test
  restores `LocationChangedAction`.
- direnv hook: bash lookup from both git layouts, respects a preset `DIRENV_BASH`, never picks a
  `System32` bash, warns when none found; version gate warns at 2.37.1, not at 2.38.0 or on garbage.
- mise: shims path added when mise loses `project-env`; activation runs only when it wins; ordering
  after the prompt engines.
- Real-machine checks: `Register-DFTool -Name ps-dotenv` (already installed); with
  `Defaults['project-env'] = 'mise'`, `cd` into a folder with a `mise.toml` setting an env var.
- The roles contract test covers the new records automatically.

## 7. Docs

- `docs/guide/tools.md`: the three tools, safe mode, the direnv warning.
- `docs/guide/configuration.md`: `DotenvSafeMode`, `DotenvApprovedDirs`; `project-env` example.
- `docs/guide/writing-a-tool.md`: `scoopBucket`.
- `docs/external-dependencies.md`: direnv#1488 threshold; `DIRENV_BASH` precedence; mise activation
  embeds PATH (never cache); ps-dotenv approvals are session-only, its scoop install is nested
  (import by path), and its shipped `SafeMode`/`Async` defaults.
- CHANGELOG `[Unreleased]`; TODO: mark the per-directory-env item done.

## Out of scope

- mise beyond activation and shims (tasks, tool installs, `mise.toml` management).
- Persisting ps-dotenv approvals across sessions beyond the `$DFConfig` list.
- Other scoop bucket consumers (the catalog/trifle search of third-party buckets).
