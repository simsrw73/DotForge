# Pager Tools: moor, ov, less, bat — Design

**Date:** 2026-10-05
**Status:** Draft for review.
**Builds on:** `2026-10-05-roles-v2-design.md` (the `pager` role, `Set-DFRoleEnv` precedence).
**Governed by:** `docs/plugin-architecture.md`, `docs/external-dependencies.md`.

## Purpose

The `pager` role sets `PAGER`, which DotForge's own `pg`/`hm`/`clhp`, bat, delta, gh and others read.
Today its members are less and bat. This adds moor and ov, makes less resolve to the native Windows
build instead of Git for Windows' MSYS one, and takes bat out of the role.

## Verified facts

| Tool | Fact | Source |
|---|---|---|
| less | scoop `less`, choco `less` and winget `jftuga.less` all ship the native Windows build from jftuga/less-Windows (v710 here), compiled from upstream less. It uses the Windows console API, so `TERM` doesn't matter to it. | less-Windows README, scoop manifest |
| less | Git for Windows ships an MSYS `less` (v704 here) in `Git\usr\bin`. MSYS programs depend on `TERM` and terminfo ("WARNING: terminal is not fully functional"). On this machine `Git\usr\bin` precedes scoop's shims on PATH, so a bare `less` is the MSYS build. | `Get-Command less -All`; rtwilson.com |
| less | Native less on Windows reads key bindings from `%XDG_CONFIG_HOME%\lesskey` (lesskey *source* format), or `LESSKEYIN` when set. `LESSKEY` names the pre-582 compiled format. History defaults to `%HOME%\_lesshst`; `LESSHISTFILE` overrides it. | `less.nro` (gwsw/less) |
| bat 0.26 | Pager choice: `--pager`/config, then `BAT_PAGER`, then `PAGER`, then `less`. When `PAGER` names bat itself (or `more`/`most`), bat silently uses `less`. | `src/pager.rs` |
| moor 2.19.2 | Renamed from moar at v2.0.0. Windows-CI tested. Reads extra options from `MOOR`. `-style <name>` picks a highlighting style (`catppuccin-mocha` is one); `-quit-if-one-screen`, `-terminal-fg`, `-no-linenumbers`. scoop `moor` (extras). | README, `moor --help` |
| moor | This user already sets `MOOR="-style catppuccin-mocha -no-linenumbers"` and `PAGER=moor`. | this machine |
| ov 0.55.0 | scoop `ov` (main), winget `noborus.ov`. Config `$XDG_CONFIG_HOME/ov/config.yaml` on every platform (falls back to `~/.config/ov`, `~/.ov.yaml`). Styles live only in that file; no environment variable for options. `-F`/`--quit-if-one-screen`. | README, `main.go`, `ov --help` |
| DotForge | `Invoke-DFPagerExe` splits `PAGER` on whitespace and warns on any quote, so a program path containing spaces doesn't work today. | `Private/Invoke-DFPagerExe.ps1` |

## 1. New generic mechanism: `executableExclude` and `${DF_TOOL_EXE}`

- **`executableExclude`** (optional, tool record): glob patterns matched (case-insensitively)
  against the full path of each `Get-Command <executable> -All -CommandType Application` result.
  `ConvertTo-DFToolRecord` defaults it to `@()`; `Test-DFToolSchema` requires an array of strings.
- **`Resolve-DFToolExecutable -Tool`** (new private): returns the first resolved path not matching any
  pattern, or `$null` when none qualifies. Availability (`Test-DFToolAvailable`) is unchanged: a tool
  whose only copy is excluded still counts as installed.
- **`${DF_TOOL_EXE}`** in a role block's `env` value expands, at registration, to that path with
  forward slashes (`C:/Users/x/.local/share/scoop/shims/less.exe`), wrapped in double quotes only
  when it contains a space. Forward slashes keep `sh -c`-based callers (git's pager handling) from
  eating backslashes; Windows programs accept them. When `Resolve-DFToolExecutable` returns `$null`,
  the token expands to the bare executable name without `.exe` (`less`), i.e. today's behavior.
  Expanded in `Invoke-DFToolRegistration` before `Expand-DFXdgPath` and `Set-DFRoleEnv`.
- **`Invoke-DFPagerExe`**: a leading double-quoted program path is taken as the program; the rest
  splits on whitespace as today. Quotes anywhere else still warn.

Generic: core reads fields and expands a token; no tool name in core.

## 2. The pager role

| Tool | Priority | Role `env` | Other |
|---|---|---|---|
| moor (new) | 30 | `PAGER = moor` | Companion: when `MOOR` is unset, set it to `-style <theme> -quit-if-one-screen`; an existing `MOOR` is left alone. |
| ov (new) | 20 | `PAGER = ov --quit-if-one-screen` | No theming (config file only; DotForge doesn't write it). |
| less | 10 | `PAGER = ${DF_TOOL_EXE}` | `executableExclude: ["*\\Git\\usr\\bin\\*"]`; winget `jftuga.less`; `LESSKEY` → `LESSKEYIN`. |
| bat | — | — | Leaves the pager role. `cat` alias and theme unchanged. |

### moor (`Tools/moor.json`, `Tools/moor.ps1`)

```jsonc
{
  "name": "moor",
  "executable": "moor.exe",
  "description": "Pager that does the right thing without configuration (formerly moar)",
  "tags": ["pager", "viewer"],
  "packages": { "scoop": "moor" },
  "xdg": { "compliance": "none", "method": "default" },
  "roles": { "pager": { "priority": 30, "env": { "PAGER": "moor" } } },
  "aliases": {},
  "picker": null
}
```

Companion body (runs whenever moor registers, winner or not, since `MOOR` isn't role-reserved):
if `$Env:MOOR` is empty, set it to `-style <s> -quit-if-one-screen`, where `<s>` is
`Resolve-DFThemeName` of `Get-DFConfiguredTheme -ToolKey MoorTheme -Default 'catppuccin-mocha'`. No
`themeMap` is needed: moor's style names include the canonical `catppuccin-mocha`. moor
validates styles itself; an unknown one falls back to its default.

### ov (`Tools/ov.json`)

```jsonc
{
  "name": "ov",
  "executable": "ov.exe",
  "description": "Feature-rich terminal pager with headers, columns and sections",
  "tags": ["pager", "viewer"],
  "packages": { "scoop": "ov", "winget": "noborus.ov" },
  "xdg": { "compliance": "full", "method": "default" },
  "roles": { "pager": { "priority": 20, "env": { "PAGER": "ov --quit-if-one-screen" } } },
  "aliases": {},
  "picker": null
}
```

No companion.

### less (`Tools/less.json`)

- `executableExclude: ["*\\Git\\usr\\bin\\*"]`.
- `packages.winget = "jftuga.less"`.
- Role env `PAGER = "${DF_TOOL_EXE}"`, priority 20 → **10**.
- `xdg.vars`: `LESSKEY` → `LESSKEYIN` (same path, `${XDG_CONFIG_HOME}/less/lesskey`); `LESSHISTFILE`
  unchanged; `LESS` env unchanged.

### bat (`Tools/bat.json`)

Remove `roles.pager`. Everything else unchanged.

## 3. Effects for this user

- moor wins by priority. Their `$Env:PAGER = 'moor'` and `MOOR` keep working, and DotForge leaves
  both alone (user values, auto-picked winner). They can delete them, or set `Defaults.pager`.
- If they pick less, `PAGER` becomes the native less's full path.

## 4. Error handling

| Condition | Behavior |
|---|---|
| Only Git's MSYS less installed | `PAGER = less` (today's behavior); no warning. |
| `executableExclude` malformed | Schema error at load (existing invalid-record handling). |
| Unknown moor style | moor's own fallback. |

## 5. Testing

- `Resolve-DFToolExecutable`: skips a path matching an exclude glob; returns `$null` when all are
  excluded; honors case-insensitivity.
- `${DF_TOOL_EXE}`: expands to forward slashes; quotes a path with spaces; falls back to the bare name.
- `Invoke-DFPagerExe`: runs a quoted program path with following args; still warns on quotes elsewhere.
- moor companion: composes `MOOR` from the configured theme when unset; leaves an existing `MOOR`.
- Real records: with moor, ov and less available, moor wins; with `Defaults.pager = 'less'`, `PAGER`
  is the non-Git less path (stub two `less` locations); bat is not a pager member.
- Contract test covers the new records.
- Real machine, read-only: a throwaway session with `PAGER`/`MOOR` cleared shows the resolved values
  for each `Defaults.pager` choice. Interactive paging (`pg`, `git log`, `bat file`) is a manual check
  for the user.

## 6. Docs

`docs/guide/tools.md` (pagers note: which wins, the native-less preference, moor/ov theming),
`docs/guide/configuration.md` (`MoorTheme`), `docs/guide/writing-a-tool.md` (`executableExclude`,
`${DF_TOOL_EXE}`), `docs/external-dependencies.md` (MSYS less vs native; moor's `MOOR`; bat's
`PAGER=bat` fallback), CHANGELOG, TODO (pager line done), README tool count (45 → 47),
`data/tool-categories.json` / `data/tool-identities.json` entries for moor and ov.

## Out of scope

- less color theming (`--use-color`/`-D`); ov `config.yaml`.
- Changing PATH order, or `TERM`.
