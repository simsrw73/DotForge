# Legacy Profile Fold-In — Design

**Status:** Draft
**Date:** 2026-07-15
**Source:** `~/OneDrive/Documents/PowerShell/ProfileModules/cli_tools_config.ps1`

## Context

DotForge was extracted from a real-world PowerShell profile whose per-tool configuration lived in
`cli_tools_config.ps1` (1,149 lines, 53 `#region` blocks). The fold-in is **incomplete**, and the
legacy file **is no longer dot-sourced by any profile** — `profile.ps1` loads `Env.ps1`,
`Aliases.ps1`, `Functions.ps1`, `Completers.ps1`, `PSReadline.ps1`, then `Import-Module DotForge`.

The consequence is the important part: **everything not yet folded in is silently inactive today.**
This is not a tidy-up backlog — it is a list of regressions the user is currently living with.

Confirmed live regressions (verified by static search across the whole profile tree — the only hits
are in the dead file):

| Lost | Detail |
|---|---|
| **All native tab completions** | 16 tools. **RESOLVED 2026-07-15 for 11 of 16** by adopting carapace (§2). 5 remain: `broot`, `sfsu`, `nvm`, `uv`, `bw`. |
| ~~**fzf theming + defaults**~~ | **FIXED 2026-07-15** — folded into `Tools/fzf.json` (`xdg.method: env`). |
| ~~**delta as git pager**~~ | **FIXED 2026-07-15** — folded into `Tools/delta.json`. See the caveat in §4. |
| **12 fzf pickers** | See §3. |

`Register-DFTool`'s comment-based help (`Public/Register-DFTool.ps1:11`) claims it "registers
argument completers". It does not. That line is inaccurate and must be fixed regardless of scope.

## Audit method

Region-by-region comparison of the 53 legacy regions against `Tools/*.json`, `Tools/*.ps1`
sidecars, `Public/`, and the loaded profile chain (`Env.ps1`, `Aliases.ps1`, `Functions.ps1`,
`Completers.ps1`, `PSReadline.ps1`, `profile.ps1`). A region counts as folded in only when its
env vars, aliases/functions, completer, and picker all have a live home.

### Picker declaration semantics (discovered during audit)

`Tools/*.json` uses three `picker` shapes, and `Register-DFTool.ps1:167` only acts on the third:

- `"picker": null` — no picker.
- `"picker": "custom"` — implemented by a `Tools/<name>.ps1` sidecar.
- `"picker": { … }` — declarative; built by `Register-DFTool`.

**`"custom"` is unverified.** A tool may declare `"custom"` with no sidecar, or with a sidecar that
defines no picker, and `Register-DFTool` will silently do nothing. Ten tools are in this state today
(§3). `scoop.json` is the clearest case: it declares `"custom"`, and `Tools/scoop.ps1` contains only
the scoop-search hook — no `sins`/`srm`.

## 1. Folded in — legacy regions deleted

`winfetch`, `curl`, `micro`, `less`, `lazygit`, `zoxide`, `gsudo`, `posh-git`, `Terminal-Icons`,
`PSFzf`, `oh-my-posh` (init + `POSH_GIT_ENABLED` + `fpot`), `bat` (env + `cat`), `eza` (aliases +
`ff`), `fd` (`ffd`), `ripgrep` (env + `frg`), `procs` (`fkill`), `npm` (env + `nls`),
`uv`/`chezmoi`/`glow`/`docker` (env vars only), `winget` (`wins`/`wrm`), `scoop` (scoop-search hook).

Note: `zoxide`'s picker was renamed `fcd` → `fzo`, because `DFHelpers.Navigation.ps1:94` already
owns `fcd`.

Deleted with no successor (zero content — `# not yet configured` placeholders): `fx`, `jid`, `duf`,
`dua`, `gdu`, `ntop`, `moor`, `gemini`, `win32yank`, `scoop-completion`, `PSAISuite`,
`PSWindowsUpdate`, `Admin`. Also `cargo` (comments only; `CARGO_HOME` lives in `Env.ps1`) and
`DockerCompletion`/`PowerType` (handled directly in `profile.ps1`).

## 2. Completions — RESOLVED via carapace (2026-07-15)

**Decision: adopt carapace; do not build a DotForge completion engine.**

carapace-bin 1.7.3 (scoop `carapace-bin`, winget `rsteube.Carapace`) is now a first-class DotForge
tool — `Tools/carapace.json` + `Tools/carapace.ps1` — picked up automatically by the existing
`Register-DFTool -All` in `profile.ps1`. **No profile change was required.**

Why it composes rather than conflicts: carapace's init emits `Register-ArgumentCompleter` calls
only — it never binds Tab and never overrides `TabExpansion`. `Tools/PSFzf.ps1:23` owns the Tab key
(`Invoke-FzfTabCompletion`) and routes through `TabExpansion2`, which consults registered
completers. So carapace's results flow into PSFzf's fuzzy Tab UI. Registration order is irrelevant,
hence no `dependsOn`. Argument completers are registered session-wide by the engine regardless of
scope, so dot-sourcing from `Register-DFTool` is safe (verified: `gh pr <Tab>` → 21 matches,
`chezmoi <Tab>` → 47, driven through the real `TabExpansion2`).

carapace registers **519 commands** and covers **11 of the 16** tools that lost completers:
`eza`, `bat`, `fd`, `rg`, `npm`, `gh`, `glow`, `procs`, `rustup`, `chezmoi`, `winget`. Those
completers were deleted from the staging file.

**Trade-off accepted:** carapace ships curated specs that can lag the installed binary. The deleted
`_GetCachedCompletion` completers were generated from the binary itself (cached against its
`LastWriteTime`) and so always matched its version exactly. We traded exactness for zero
maintenance across 11 tools.

**Still uncovered (5):** `broot`, `sfsu`, `nvm`, `uv`, `bw` — static flag/subcommand lists still
parked in the staging file. Prefer a carapace **custom spec**
(`$XDG_CONFIG_HOME/carapace/specs/*.yaml`) over reviving a DotForge completion engine for these.

`CARAPACE_BRIDGES` is deliberately unset: bridging shells out per completion, and of
`zsh,fish,bash,inshellisense` only bash is installed here.

Two items survive this decision regardless:
- `Register-DFTool`'s help still claims it "registers argument completers" (`Register-DFTool.ps1:11`).
  With carapace it is now *indirectly* true via the sidecar, but the wording still misleads — it
  implies a schema-driven feature that does not exist. Fix the wording.
- Extend `Private/Test-DFToolSchema.ps1` to validate `aliases`/`picker`/`packages` shapes
  (`TODO.md:22`) — unrelated to completions but listed here originally.

### Historical: the schema that was NOT built

Retained for context in case carapace is ever dropped. Two kinds existed:

**(a) Static flag/subcommand lists** — a hardcoded array filtered by `$wordToComplete`:
`eza`, `bat`, `broot`, `sfsu`, `nvm`, `npm`, `uv`, `bw`.

**(b) Generated native completions** — shell out to the tool, cache the script, dot-source it. The
legacy `_GetCachedCompletion` (`cli_tools_config.ps1:30-49`) caches to
`$XDG_CACHE_HOME/ps-completions/<key>.ps1`, regenerating only when the cache file is older than the
binary's `LastWriteTime`:
`fd` (`--gen-completions powershell`), `rg` (`--generate complete-powershell`),
`glow` (`completion powershell`), `procs` (`--gen-completion-out powershell`),
`rustup` (`completions powershell`), `gh` (`completion -s powershell`),
`chezmoi` (`completion powershell`).

`winget` is a third kind: a **dynamic** completer that calls `winget complete --word … --commandline
… --position …` per keystroke. It cannot be cached and needs a passthrough escape hatch.

A `completion` schema (`type: static | generate | custom`) plus
`Private/Register-DFCompletion.ps1` and `Private/Get-DFCachedCompletion.ps1` was designed to hold
all three kinds. **It was not built** — carapace covers 11 of 16 with no schema, no cache, and no
maintenance. Revisit only if carapace is dropped or its specs drift badly from the installed
binaries. The deleted implementations are recoverable from
`git show 713f6ff:ProfileModules/cli_tools_config.ps1` in the profile repo.

## 3. Gap: pickers declared but not implemented

Nine tools declare `"picker": "custom"` with **no sidecar**; `scoop` has a sidecar without a picker.
All are silently inert:

| Tool | Lost picker(s) | Legacy source |
|---|---|---|
| `jq` | `fjq` Select-JsonPath | 231-244 |
| `glow` | `fgl` Read-MarkdownFile | 265-275 |
| `docker` | `fdc` / `fdi` | 370-394 |
| `rustup` | `frtc` Select-RustupToolchain | 669-680 |
| `npm` | `fns` Select-NpmScript | 743-756 |
| `gh` | `fpr` / `fgi` | 766-794 |
| `uv` | `fvenv` Select-UvVenv | 840-854 |
| `chezmoi` | `czf` Edit-DotFile | 872-881 |
| `bitwarden` | `fbw` Select-BwItem | 906-926 |
| `scoop` | `sins` / `srm` | 543-570 |

Several are expressible declaratively (`fgl`, `frtc`, `czf` are close to `eza`'s `ff` shape);
others need sidecars (`fbw` parses JSON, `fns` reads `package.json`, `fpr` uses `--json`).

**Guard against recurrence:** add a test asserting every `"picker": "custom"` tool has a sidecar
that defines a picker function. That single test would have caught all ten.

## 4. Gap: env/config not folded

| Tool | Missing | Notes |
|---|---|---|
| ~~`fzf`~~ | ~~6 `FZF_*` vars~~ | **DONE 2026-07-15.** `xdg.vars` takes plain strings (the `LESS` precedent in `less.json`), and `Expand-DFXdgPath` only substitutes the four `${XDG_*}` tokens — so `{}`, `#`, `+` and embedded newlines round-trip untouched. No `dependsOn: ["fd"]` was added: `FZF_DEFAULT_COMMAND` needs fd on `PATH` at *use* time, which is not a registration-ordering dependency. |
| ~~`delta`~~ | ~~`GIT_PAGER`, `DELTA_FEATURES`~~ | **DONE 2026-07-15**, with a caveat: **`DELTA_FEATURES=catppuccin-mocha` is currently a no-op.** No `[delta "catppuccin-mocha"]` feature is defined in any git config scope (`git config --list --show-origin` has no delta/pager entries at all), and delta silently ignores unknown features. Ported faithfully rather than inventing a theme. To make it live, define the feature in git config — otherwise delta pages with its default theme. |
| `docker` | `DOCKER_CONFIG` set **unconditionally** in legacy (outside the availability guard) so docker-compose picks it up; DotForge sets it only when docker is present. | Behavior change — confirm intent. |
| `ripgrep` | seeds a default `ripgreprc` (`--smart-case`, `--hidden`) | **Schema limitation:** needs `env` *and* `config` seeding; `xdg.method` is a single value and the `config` branch (`Register-DFTool.ps1:115-127`) does not set env vars. |
| `wget` | creates an empty `WGETRC` file | Same limitation; `env` creates dirs, not files. |
| `bat` | `cat` → `Get-Content` fallback when bat is absent | DotForge registers nothing when a tool is missing, so the fallback has no home. |

The ripgrep/wget cases argue for allowing `xdg.method` to be an array, or adding a `seed` block
independent of `method`.

## 5. Gap: functions/aliases not folded

| Legacy | Definition | Home needed |
|---|---|---|
| `sstat` / `supd` | `scoop update; scoop status` / `scoop update *; scoop cleanup *` | `Tools/scoop.ps1` |
| `wstat` / `wupd` | `winget upgrade` / `winget upgrade --all` | `Tools/winget.ps1` |
| `edit` | Notepad++ if installed else `notepad.exe` | No tool record. Overlaps `$Env:EDITOR` (set in `Env.ps1`) — reconcile rather than port blindly. |
| `glazewm` | `Start-GlazeWM` — passes `--config $XDG_CONFIG_HOME/glazewm/config.yaml` | New `Tools/glazewm.json` + sidecar |
| `mqtt` | `Invoke-MQTT` — `mosquitto -v -c ~/.mosquitto/config` | New `Tools/mosquitto.json`. Note: not XDG (`~/.mosquitto`). |

Note `supd` overlaps the planned `Invoke-DFMaintenance` (`TODO.md`) — fold it in there instead of
porting verbatim.

## 6. Tools with no DotForge record

`nano` (`NANORC`), `sfsu` (completer), `nvm` (`NVM_DIR` + completer + `fnv`), `glazewm`,
`mosquitto`, `notepadplusplus`. Each needs a `Tools/*.json` before its config has anywhere to live.

`nvm` carries a caveat worth preserving: `NVM_DIR` is for Unix nvm; nvm-windows uses
`NVM_HOME`/`NVM_SYMLINK`. The legacy line is likely wrong on this machine — verify before porting.

## Suggested order

1. ~~**Restore the live regressions**: `fzf` env, `delta` env~~ — **DONE 2026-07-15** (§4).
2. ~~**Decide Carapace vs. a DotForge completion engine**~~ — **DONE 2026-07-15**: carapace adopted,
   engine not built (§2). 5 tools remain uncovered.
3. **Add the two anti-recurrence tests**: `"picker": "custom"` implies a real sidecar picker (§3);
   schema validation for `aliases`/`picker` (`TODO.md:22`).  ← next
4. **Port the 12 pickers** (§3), declarative where possible.
5. **Resolve the `env`+`config` schema limitation** (§4), then ripgrep/wget seeding.
6. **Small functions** (§5) and **new tool records** (§6) as needed.
7. **Optional:** carapace custom specs for the 5 uncovered tools (§2).

## Verification

- Regressions: in a new terminal, `$Env:FZF_DEFAULT_OPTS`, `$Env:GIT_PAGER` are set; `git diff`
  pages through delta; fzf shows the Catppuccin palette.
- Pickers: each restored alias resolves and runs.
- Completions: `<tool> <Tab>` completes.
- `Invoke-Pester tests/ -Output Detailed` stays green (baseline: 625 passing, 2026-07-15).

## Reference

The legacy file is tracked in the profile repo (`~/OneDrive/Documents/PowerShell`, clean at
`713f6ff`), so any region deleted during this fold-in is recoverable via
`git show 713f6ff:ProfileModules/cli_tools_config.ps1`.
