# Install environment: installers see their tools' variables

**Status:** design, for review. 2026-10-25. Resolves T-76 and T-77.
**Context:** `docs/superpowers/specs/2026-10-24-restore-install-locations-notes.md` (Decision 4: A).

## Why

`Install-DFTool` sets a tool's variables only after the install, when `Register-DFTool` activates
it. An installer that reads them writes to its default folder first: rustup puts toolchains under
`~\.rustup` and `~\.cargo` unless `RUSTUP_HOME`/`CARGO_HOME` are set, and `cargo install` writes to
`~\.cargo` unless `CARGO_HOME` is set. On a restore the dotfiles set four of these by hand, and a
2026-10-22 workaround saved all of them as Windows user variables (reverted). DotForge must set them
itself, only while the installer runs, so a restore can rely on DotForge alone.

## Goals

- Every command DotForge runs through a package manager (install, update, remove, and adding a feed)
  sees the location variables of the tools it acts on, of the manager running it, and of the tools
  that manager needs.
- Nothing outlives the command: every variable is put back as it was, even when the command throws.
- No new record fields: the variables come from what records already declare.

## Non-goals

- Desktop (Windows user) variables: T-78.
- Missing variables in records (uv, npm cache, mise, bitwarden): piece 4 of the notes.
- Moving DotForge-managed tools out of `packages.yaml`, and its check: Decision 6, its own piece.
- Creating folders before an install (`xdg.dirs`): installers create their own.

## Anti-goals

- Contradicting the Windows environment: a value set outside DotForge (by the user, or by a manager
  such as scoop's `env_set`) is never overridden, not even for one command (notes, Decision 5).
- Changing the session: after the command the session's variables, and DotForge's record of what it
  wrote (`Get-DFEnvState`), are as before, except for what the manager itself changed.

## Design

### Which variables (`Get-DFInstallEnvironment`)

A new private function in `Private/Invoke-DFManagerCommand.ps1` (or its own file):

`Get-DFInstallEnvironment -Tool <pscustomobject[]> -Manager <pscustomobject> -ToolDb <hashtable>`
returns an ordered dictionary, variable → expanded value, from:

1. each `-Tool`'s `xdg.vars` (the tools being installed, updated or removed);
2. the `-Manager`'s `xdg.vars`;
3. the `xdg.vars` of every tool the manager `requires`, transitively (cargo → rustup gives
   `CARGO_HOME` and `RUSTUP_HOME`; npm → node). References are read with
   `ConvertFrom-DFToolReference`; only tool references are followed, never `role:` ones (a role
   requirement orders, it never names one tool), and a name missing from `-ToolDb` is skipped.

Only `xdg.vars`, never `env`: an installer needs locations, and `env` holds flags and themes
(`FZF_DEFAULT_OPTS`, `LESS`). Only records whose `xdg.method` is `env`, matching
`Set-DFToolXdgConfig`. Values go through `Expand-DFXdgPath`, as at registration.

When two sources name the same variable with different values, the later source in the order above
wins (the manager and its runtimes run the command), and a verbose message names both. No current
record does this. *(My call.)*

### Applying them (`Invoke-DFManagerCommand -Environment`)

`Invoke-DFManagerCommand` stays the only place a manager runs and gains `-Environment
<IDictionary>`. Before the command it sets, in the process, each variable that is

- unset, or
- still holding what DotForge last wrote (`(Get-DFEnvState).Written`),

which is `Set-DFEnv`'s rule for "not set outside DotForge". A variable set outside DotForge is left
as it is, with a verbose message naming it. In a `finally`, every variable it changed goes back to
its previous value (or is removed when it was unset), **unless the command itself changed it**:
scoop's `.ps1` shim runs in this process, and its `env_set` sets the variables it also saves to the
Windows environment. A variable whose value is no longer the one DotForge set keeps the command's
value, so the session agrees with what the manager saved. It never touches `Get-DFEnvState`.

This covers every way a command runs:

| Run as | Variables reach the installer? |
|---|---|
| argv, in this console (scoop's `.ps1` shim runs in-process; exes are child processes) | yes |
| `-Function` (PSResourceGet) | yes, in-process |
| an elevator (gsudo) or Windows' `sudo` inline | to verify: gsudo copies the caller's environment by default; Windows sudo inline needs checking. If either doesn't, the command's output says the variables were not passed |
| `RunAs` (a separate administrator window) | no: an elevated window starts from the user's saved environment. Only choco uses it, and choco installs machine-wide, outside XDG. Documented, not worked around |

### Who passes them

- `Invoke-DFManagerBatch` gains `-Environment` and passes it to each `Invoke-DFManagerCommand`.
- `Invoke-DFInstallPlan`: for each batch, `Get-DFInstallEnvironment` over the batch's tools and its
  manager; the feed `list`/`add` commands get the manager's part only.
- `Invoke-DFManagerOperation` (update, remove): the found tool and its manager. This needs the tool
  record, so it takes `-Tool` (Update-DFTool and Remove-DFTool already have it).

### The restore (dotfiles)

The packages script imports DotForge, runs `Start-DFSession` (it reads
`~/.config/dotforge/config.psd1`) and then `Install-DFTool -Missing -UseDefaults`, so DotForge's
tools install with their variables and every later step runs with the session's variables and PATH.
The hand-set `RUSTUP_HOME`, `CARGO_HOME`, `FNM_DIR` and `PIPX_HOME` in the packages script go away
then. Both need a DotForge release with this change on the PowerShell Gallery (the restore installs
DotForge from there), so this half lands after that release; releases are the user's call.

## Tests (Pester, all with `Invoke-DFManagerCommand`'s process mocked or a stub function)

- `Get-DFInstallEnvironment`: a tool's own vars; the manager's; cargo's chain reaches rustup's; a
  `role:` requirement is not followed; a missing record is skipped; `env` is ignored; a non-`env`
  method contributes nothing; a duplicate with different values takes the later source.
- `Invoke-DFManagerCommand -Environment` (a stub function as `-Function`, and a tiny argv such as
  `pwsh -NoProfile -Command` reading the variable): the command sees an unset variable; it sees a
  variable DotForge wrote updated; a variable set outside DotForge is kept; afterwards every variable
  is back as before, including after the command throws; a variable the command itself changed keeps
  the command's value; `Get-DFEnvState` is unchanged.
- `Invoke-DFInstallPlan`: the batch's command is called with the tools' and manager's variables (mock
  asserts `-Environment`).
- `Update-DFTool`/`Remove-DFTool`: the same through `Invoke-DFManagerOperation`.

## Left to the builder

File placement, names of internal helpers, and the exact verbose texts.
