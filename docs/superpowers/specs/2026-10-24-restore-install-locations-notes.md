# Restore and install locations: phases, options, audit

**Status:** working notes for a design (not a spec yet). 2026-10-24.
**Question:** on a fresh machine, how do chezmoi and DotForge split the work so that every tool installs
to, and keeps its data in, the XDG folders, without filling the Windows environment with variables
only pwsh needs?

The split you set (2026-10-24): chezmoi installs a small core, then DotForge; DotForge installs the
tools it manages, with their variables set before each install; chezmoi installs the rest.

## Three kinds of variables

The whole problem gets easier once these three are kept apart. Today only the first exists in DotForge.

| Kind | Lives | Who sets it today | Example |
|---|---|---|---|
| **Session** | each pwsh session, from the profile | DotForge (`xdg.vars`, `env`) at load | `RIPGREP_CONFIG_PATH` |
| **Install** | only the process that runs one installer, for that install | nobody (the restore script sets 4 by hand) | `CARGO_HOME` while `cargo install` runs |
| **Desktop** | Windows user environment (`HKCU\Environment`), every new process | chezmoi `run_before_05-user-env`, bootstrap (`SCOOP`), scoop installs (`env_set`) | `XDG_CONFIG_HOME`, `GNUPGHOME` |

Rule of thumb: a variable is a desktop variable only when something outside pwsh needs it (a GUI app, a
sign-in task, another shell). Everything else is session (and install, where an installer reads it).

## The restore in phases

### Phase 0: bare Windows

Windows PowerShell 5.1 and winget are there. Nothing else. Nothing to decide.

### Phase 1: the bootstrap core (chezmoi side, `bootstrap.ps1`)

Installs what DotForge itself can't run without, or what fetches the dotfiles: scoop, git, pwsh 7,
chezmoi, gh, bitwarden-cli, gsudo. It also signs in to gh and Bitwarden.

**Decided:** pwsh 7 comes from winget (a Microsoft tool), not scoop.

**Done (dotfiles `d7b3f91`, 2026-10-25):** the bootstrap sets the XDG folders and `SCOOP` first,
turns on Developer Mode, and installs pwsh from winget; a test keeps its folder list in step with the
user-env script.

**Problem found:** these tools run *before* chezmoi's user-env script, so they use their default
folders. On this machine both `%APPDATA%\GitHub CLI` and `~\.config\gh` exist: `gh auth login` in the
bootstrap wrote to AppData because `XDG_CONFIG_HOME` wasn't set yet.

**Decision 1: where the core's variables come from before anything is installed.**

| Option | For | Against |
|---|---|---|
| A. bootstrap.ps1 sets the desktop variables first (XDG folders, `SCOOP`, …) as its first step | Simple; right from the very first install; bootstrap already does this for `SCOOP` | A second copy of the list (bootstrap + user-env script) unless user-env is dropped |
| B. bootstrap sets them for its own process only; chezmoi's user-env saves them later | Nothing saved before chezmoi runs | Desktop apps started in between (none, in practice) see nothing; two places to keep in step |
| C. Move the logins (gh, bw) after chezmoi apply | Keeps bootstrap minimal | chezmoi init needs gh for the private repo; doesn't fix it |

**Decided: A.** The bootstrap sets the XDG folders and `SCOOP` as its first step. The user-env script then
*checks* the base set rather than writing it, or both read one shared list file (open). The bootstrap
core is never DotForge's job: DotForge isn't installed yet.

### Phase 2: desktop variables (who owns them)

Today: chezmoi's user-env script owns a fixed list (XDG folders, `SCOOP`, `KOMOREBI_CONFIG_HOME`,
`GNUPGHOME`, `CLAUDE_CONFIG_DIR`, `CLAUDE_CODE_GIT_BASH_PATH`). You said this may shift to DotForge.

**Decided:** the user-env script keeps only what bootstrapping DotForge needs (the XDG folders,
`SCOOP`, `GNUPGHOME` for signed commits); `KOMOREBI_CONFIG_HOME`, `CLAUDE_CONFIG_DIR` and
`CLAUDE_CODE_GIT_BASH_PATH` move to DotForge's opt-in desktop variables (T-78). Timing: drop them from
chezmoi when T-78 ships, so the Claude desktop app and editors never go without them. komorebi and
Claude Code have no DotForge records yet; both need one (komorebi runs at sign-in, outside pwsh).

**Decision 2: who owns per-tool desktop variables.**

| Option | For | Against |
|---|---|---|
| A. chezmoi keeps a hand-kept list (today) | Already works; no DotForge change | A tool's knowledge lives in two places (DotForge knows `CLAUDE_CONFIG_DIR`, chezmoi repeats it); the list drifts |
| B. DotForge records declare which variables are also desktop variables (e.g. `"desktop": ["CLAUDE_CONFIG_DIR"]`); an explicit command (`Set-DFDesktopEnv`, run by the restore and by the user, never at load) writes them | One home per tool; shows in `Get-DFToolStatus`; reversible (DotForge can remove what it wrote) | New core feature; writing `HKCU\Environment` is a durable, outward change; needs DotForge installed first, so the XDG base set still belongs to bootstrap |
| C. B, but DotForge only *reports* which desktop variables are missing; the user or chezmoi writes them | DotForge never writes outside the session | Two steps for the user |

**Done (DotForge, 2026-10-26):** records declare `desktop`; running `Set-DFDesktopEnv` is the opt-in
(no config key); a differing value is asked about in a console, else kept; the status notes missing
ones; komorebi has a record. Spec `2026-10-26-desktop-variables-design.md` (closes T-78). The Claude
variables move with piece 9's Claude Code record; chezmoi drops `KOMOREBI_CONFIG_HOME` after a release.

**Decided: B, as opt-in.** A record *suggests* desktop variables; nothing is written until the user
opts in, either for all tools or tool by tool. Writing the Windows environment reaches outside
DotForge's normal sphere, so it needs the user's permission. The XDG base set and `SCOOP` stay in
bootstrap (Decision 1). Writing is explicit and idempotent, broadcasts once, and removes only what
DotForge wrote (it records what it wrote, like `setup-state.json`). Open: the shape of the opt-in (a
config key such as `DesktopEnv = $true` or a list of tool names) and whether a suggested but not
opted-in variable shows in `Get-DFToolStatus`.

### Phase 3: DotForge installed and configured

The packages script installs DotForge from PSGallery. It then needs the same tool list the profile
uses, which today lives inside `profile.ps1` (`$DFConfig`).

**Decision 3: one tool list for the profile and the restore.**

| Option | For | Against |
|---|---|---|
| A. Move `$DFConfig` to a data file (`~/.config/dotforge/config.psd1`) both read | One list; DotForge could even read it by default | A new file convention (DotForge could own it: `Start-DFSession` with no `-Config` reads it) |
| B. Restore dot-sources the profile's config block | No new file | Couples the restore to the profile's layout |

**Decided: A**, with DotForge owning the file's location (an XDG config path), so it's a DotForge
feature, not a dotfiles trick.

**Done (2026-10-25):** DotForge `f0adc6d`: `Start-DFSession` without `-Config` reads
`~/.config/dotforge/config.psd1`; `-Config` replaces it entirely. Dotfiles `d8b5462`: the settings
live in `linked/dotforge/config.psd1`, `~/.config/dotforge` links there, and the profile passes the
file with `-Config` until a release after 0.7.1 is installed.

**Problem found:** PSResourceGet installs `CurrentUser` modules to `Documents\PowerShell\Modules`,
which is OneDrive-redirected here (`OneDrive\Documents\PowerShell\Modules`). No variable changes that.
DotForge, PSFzf, Terminal-Icons, posh-git, NerdFonts and GoogleFonts all land there. Separate decision
(turn off Documents redirection, or a `Save-PSResource` path plus `PSModulePath`).

**Q (yours): how does it affect us?** It doesn't break anything, and it isn't an XDG question. Its risks
are second-order: modules sync to every machine on the OneDrive account (a module updated on one
machine changes under the other's running shells), and OneDrive's files-on-demand can leave a module
as a cloud-only placeholder that can't load offline. **Dropped** from this design; revisit only if one
of those bites.

### Phase 4: DotForge installs its tools

`Install-DFTool -Missing -UseDefaults`, unattended. This is where install variables matter.

**Decision 4: how DotForge sets install variables.**

| Option | For | Against |
|---|---|---|
| A. Before running a manager, `Invoke-DFManagerCommand` sets, in its own process only, the variables of the tool being installed **and of the manager running it** (and the manager's runtime, through `requires`) | One place (the only place a manager runs); covers the chain: a crate install gets cargo's `CARGO_HOME`, an npm global gets npm's variables; no new record field for most tools | Must restore the previous values afterwards; must also apply to `update`/`remove` |
| B. A separate `install.env` block per record | Explicit; can differ from session variables | Duplicates `xdg.vars` for nearly every tool; drifts |
| C. Run every install inside a session where all requested tools are activated, installed or not | No install-specific code | Activating a missing tool runs its companion; fragile; sets far more than needed |

**Decided: A**, with B only for the rare variable an installer needs but the session doesn't.

**Done (DotForge, 2026-10-25):** `Get-DFInstallEnvironment` and `Invoke-DFManagerCommand
-Environment` (spec `2026-10-25-install-environment-design.md`, T-76/T-77). The dotfiles half (the
packages script runs `Start-DFSession` and `Install-DFTool -Missing -UseDefaults`) waits for a Gallery
release.

**Problem found: scoop's own variables.** These variables belong to the tools, and every tool reads
whatever value it finds. But scoop writes them itself, from a manifest's `env_set` field
(`lib/install.ps1:331`, checked 2026-10-24):

- It writes HKCU\Environment and its own process, **unconditionally**: it never checks for an existing
  value, so one set before the install is overwritten.
- It runs at the end of every install, every `scoop update` (which reinstalls) and every `scoop
  reset`. Removing scoop's values once isn't durable.
- `scoop uninstall` deletes them from HKCU, even ones the user changed since.
- It writes them *after* the installer has run, so during the install the tool sees the value set
  beforehand, unless the manifest forces its own.

What makes scoop's value win in pwsh is DotForge, not scoop: `Set-DFEnv` keeps a value set outside it.

From the manifests, three groups:

| Group | Tool | scoop sets | What it means |
|---|---|---|---|
| **Overridable** (nothing put in place during install) | fnm | `FNM_DIR` → app folder | point it elsewhere; the tool uses the new place |
| | uv | `UV_CACHE_DIR`, `UV_TOOL_DIR`, `UV_TOOL_BIN_DIR`, `UV_PYTHON_INSTALL_DIR`, `UV_PYTHON_BIN_DIR` → persist | same; its install script also adds the two shim folders to PATH (stale entries) |
| | bun | `BUN_INSTALL`, `BUN_INSTALL_BIN`, `BUN_INSTALL_GLOBAL_DIR` → persist | same; also adds `persist\bin` to PATH |
| | bat | `BAT_CONFIG_DIR` → app folder (persists config, syntaxes, themes) | same |
| **Says where the program is** (scoop's value is right) | git | `GIT_INSTALL_ROOT` → app folder | leave it |
| | vcpkg | `VCPKG_ROOT` → app folder | leave it; DotForge's `DATA/vcpkg` is wrong for a scoop install |
| | oh-my-posh | `POSH_THEMES_PATH` → app folder's `themes` | leave it, unless DotForge ships themes elsewhere |
| **Location fixed during install** | rustup | `CARGO_HOME`, `RUSTUP_HOME` → persist | its install script sets both for its own process before `rustup-init`, so toolchains land in scoop's folder whatever was set first |
| | pnpm | `PNPM_HOME` → app folder | its post-install runs `pnpm config set storeDir/cacheDir/stateDir`, saving scoop's paths in pnpm's config file; a variable alone doesn't move them |

On this machine only vcpkg and bat came from scoop; the others came from winget, whose installs don't
set variables.

**Decision 5: what to do about scoop's variables.**

| Option | For | Against |
|---|---|---|
| A. Records prefer another source for these tools (`install.prefer: winget`) | No fight with scoop | winget lacks some; users who prefer scoop lose |
| B. Accept scoop's location: scoop lives under `~/.local/share/scoop`, so its persist folder is inside XDG data anyway; DotForge notes it instead of fighting | Honest; nothing breaks | Two layouts depending on source; DotForge's records must not then claim a different folder |
| C. After a scoop install, DotForge removes scoop's variables and sets its own | One layout | Fights scoop (its uninstall, its persist folders hold the data); fragile |

**Decided:** never fight a package manager over a tool (C is out). A record ranks the managers that
best fit XDG and DotForge's goals for that tool, and the user still chooses:

1. the user's overall preference is always honored;
2. the user's global order applies to every tool, unless the record ranks another manager higher;
3. tool by tool, the user can name the manager to use.

Where a source is especially bad for a tool (rustup and pnpm from scoop), DotForge tells the user once,
at first install or first run. Where a source puts data somewhere else but still works (the
"overridable" and "says where the program is" groups), the record follows that source's layout instead
of claiming a folder the install never used (B).

Today's order (`Shared/DFInstallSource.ps1`): `-Via`, `InstallVia` (per tool, rule 3), the record's
`install.prefer` (the ranking), `InstallOrder` (global, rule 2), then DotForge's order;
`ExcludeSources` removes a manager unless `InstallVia` names it. Rules 2 and 3 exist already.

**Decided (rule 1):** a new global setting, "always use X for every tool" (working name
`InstallAlways = 'scoop'`), that no record's ranking overrides. The new order: `-Via`, `InstallVia`,
`InstallAlways`, `install.prefer`, `InstallOrder`, DotForge's order. My calls, to confirm: a tool with no
package for X falls through to the rest of the order (with the once-only notice, not an error); a
per-tool `InstallVia` still beats it; and where X is especially bad for a tool, the once-only notice
says so but the install still goes through X.

**Done (DotForge, 2026-10-25):** `install.avoid` (ranked last, reason shown when used), and rule 1
as `IncludeSources`: the user reframed `InstallAlways` as an allow-list beside `ExcludeSources`,
applying to every source, registries included; spec `2026-10-25-manager-choice-design.md`. The first-run warning is part of T-83.

**Decided: the session never contradicts the desktop.** When a manager has set a tool's variable in
the Windows environment and rewrites it on every update, DotForge keeps that value in the session (as
`Set-DFEnv` does today) instead of overriding it. It suggests a better-behaved manager where one
exists; otherwise it falls back to links (below).

**Decided: the link fallback, project-wide.** Whenever DotForge can't move where a tool or its manager
keeps things, it links the XDG location to the real one, so the user still finds everything under
`~/.config`. This also settles "per-source xdg values" for every tool that has a variable: the real
location is the variable's current value, so no per-source data is needed. A tool with no variable
uses its `xdg.native` paths as the link target.

**Done (DotForge, 2026-10-25):** existing data is linked, never moved; no manager detection; `-Adopt`
links and `-Move`/`-Done` are gone; spec `2026-10-25-link-existing-design.md` (also closes T-83).

**Decided (2026-10-25):** link config, data and state; never cache.

| Kind | Link? | Why |
|---|---|---|
| config (`~/.config/<tool>`) | yes | your rule: all configuration reachable from `~/.config` |
| data (`~/.local/share/<tool>`) and state (`~/.local/state/<tool>`) | yes | the user's own things (toolchains, history, logins): findable and covered by a backup of the XDG folders |
| cache (`~/.cache/<tool>`) | **no**, only noted in the tool's status | `~/.cache` means "safe to delete". A link there lets a cache cleanup reach into the manager's folder (scoop's persist folder holds data next to cache); some delete tools follow junctions |

How (my calls):
- Directory junctions: they need no admin and no Developer Mode. A tool whose config is a single file
  gets a file symlink when Developer Mode is on (the bootstrap now turns it on; see winget below),
  else a status note.
- Never replace content already at the XDG path: that stays a `Conflict`, and `Resolve-DFToolConflict`
  gains `-Link` beside `-Move` and `-Adopt`.
- DotForge records the links it made (like `setup-state.json`), removes only those, and reports one
  whose target is gone (the tool was uninstalled).
- The link is made at registration, idempotently, so it follows a later update that changes the real
  location (vcpkg's `VCPKG_ROOT` moves with each scoop version through `current`, so it is stable).

### Phase 5: chezmoi installs the rest

**Q (yours): does chezmoi inherit the environment DotForge set up?** No, not as designed. DotForge's
session variables exist only in a pwsh session that ran `Start-DFSession`, and Decision 4's install
variables only while one install runs (restored afterwards). The packages script runs in its own
process, which has only the desktop variables plus what it sets itself.

That's fine for tools DotForge doesn't know: they have no DotForge variables. It matters where a
leftover install goes through a DotForge-managed manager, e.g. an npm global needing fnm's node on
PATH. **Leaning:** the packages script imports DotForge and runs `Start-DFSession` (reading Decision 3's
config file) in its own process before Phase 4, so Phases 4 and 5 both run inside a DotForge session
with the same variables and PATH a shell would have. The rule stays that an install through a
DotForge-managed manager belongs in DotForge, not `packages.yaml`.

`packages.yaml` minus DotForge's tools. **Decision 6:** keep `packages.yaml` hand-edited with a check
that fails `chezmoi apply` when it lists a tool DotForge manages, or have the packages script ask
DotForge (`Get-DFToolGroup`, the shared config) and skip those. **Decided:** the check (simple, visible).

### Phase 6: first shell, and strays

After a restore, some data will still be in default folders (tools that ran early, tools that ignore
XDG). **Decision 7:** DotForge reports them (it already knows each tool's `xdg.native` default
folders) and offers to move them, as `Resolve-DFToolConflict` does for config. Later; not needed for
the first restore. **Decided:** only where it can be done safely, without breaking anything.

## Audit: all 75 tool records

What decides where each tool installs and keeps its data, what an install needs set first, and what's
wrong today. "Here" means what this machine shows.

### Managers and runtimes (install variables matter most)

| Tool | Installs to (decided by) | Install needs set first | Gap / here |
|---|---|---|---|
| scoop | `$SCOOP` | `SCOOP` (bootstrap sets it, desktop) | `SCOOP_CACHE` not set (default `$SCOOP\cache`, inside XDG data: fine) |
| winget | its own (`%LOCALAPPDATA%\Microsoft\WinGet\Packages` for portable apps) | nothing (settings.json only) | out of XDG scope |
| choco | `C:\ProgramData\chocolatey`, machine-wide | admin | out of XDG scope |
| psresource | `Documents\PowerShell\Modules` | nothing changes it | OneDrive-redirected here (Phase 3) |
| rustup / cargo | `RUSTUP_HOME`, `CARGO_HOME` | both, before rustup-init and before every `cargo install` | OK here (restore sets them by hand); from scoop, toolchains land in scoop's folder (Decision 5) |
| fnm / node | `FNM_DIR` | `FNM_DIR` | OK here (set by hand); from scoop, overridable |
| npm | prefix: node's folder under fnm, else `%APPDATA%\npm`; cache: `%LOCALAPPDATA%\npm-cache` | `NPM_CONFIG_USERCONFIG` (declared), **cache not declared** | npm cache is in `%LOCALAPPDATA%\npm-cache` here. Declare `NPM_CONFIG_CACHE` (`CACHE/npm`) |
| pnpm | `PNPM_HOME` | `PNPM_HOME` | not installed here; see Decision 5 for scoop |
| bun | `BUN_INSTALL` | `BUN_INSTALL` (+ cache) | not installed here; see Decision 5 for scoop |
| pip | user site `%APPDATA%\Python`, cache `PIP_CACHE_DIR` | `PIP_CACHE_DIR`, `PIP_CONFIG_FILE` | `PYTHONUSERBASE` not declared (only matters for `pip --user`) |
| pipx | `PIPX_HOME`, bins in `PIPX_BIN_DIR` (default `~/.local/bin`: XDG) | `PIPX_HOME` | OK here |
| uv | tools `UV_TOOL_DIR` (default `%APPDATA%\uv\tools`), pythons `UV_PYTHON_INSTALL_DIR`, cache `UV_CACHE_DIR` | all three, **only the cache is declared** | uv tools are in `%APPDATA%\uv\tools` here, and part of the cache in `%LOCALAPPDATA%\uv\cache`. Declare `UV_TOOL_DIR`, `UV_PYTHON_INSTALL_DIR` (`DATA/uv/...`) |
| mise | `MISE_DATA_DIR` (default `%LOCALAPPDATA%\mise`), cache, state | **none declared** | not used here; declare `MISE_DATA_DIR`, `MISE_CACHE_DIR`, `MISE_STATE_DIR` |
| pymanager / python | `%LOCALAPPDATA%\Python` | unknown: to verify whether its config can move the install root | lives in the default here |
| vcpkg | the install folder itself (`VCPKG_ROOT`) | `VCPKG_DOWNLOADS` | `VCPKG_ROOT` declared as `DATA/vcpkg` is wrong for a scoop install: scoop's value is right (Decision 5) |

### Tools installed through a manager that needs install variables

These need the *manager's* variables at install time, which Decision 4 A covers without new fields.

| Tool | Through | Needs |
|---|---|---|
| mdv, mdcat, skim, television (crates source) | cargo | `CARGO_HOME` |
| inshellisense, gfcli, bun, pnpm (npm source) | npm | npm's variables |
| glances, pipx (pypi source) | pipx or uv | `PIPX_HOME` or uv's variables |
| node (fnm or mise source) | fnm, mise | `FNM_DIR` or mise's |
| python (uv or mise source) | uv, mise | `UV_PYTHON_INSTALL_DIR` or mise's |

### Bootstrap core that has DotForge records

| Tool | Problem before DotForge exists |
|---|---|
| gh | `gh auth login` in bootstrap writes `%APPDATA%\GitHub CLI` unless `XDG_CONFIG_HOME` is already set. Both folders exist here (Decision 1) |
| bitwarden | `BITWARDENCLI_APPDATA_DIR` decides its data folder; from scoop it's scoop's persist folder (fine); from winget, `%APPDATA%\Bitwarden CLI`. Not declared in the record |
| chezmoi | config already at `~/.config/chezmoi` by default; `CHEZMOI_CONFIG_DIR` in the record: to verify that chezmoi reads it at all |
| gsudo | settings in the registry; nothing to do |
| git, pwsh | no DotForge records; git reads `~/.config/git/config` by default |

### Runtime only (the install doesn't care; session variables suffice)

bat, broot, curl, glow, lazygit, less, micro, oh-my-posh (themes), ripgrep, starship, wget, zoxide,
python (history), npm (REPL history), psreadline. A tool started *outside* pwsh before the profile ever
ran would use its default folder; none of these is normally started that way.

Known exceptions that ignore their variables: **docker** (Docker Desktop writes `~/.docker` whatever
`DOCKER_CONFIG` says) and **glow** (writes AppData despite its variable).

### Nothing to set (location decided by the manager, no XDG settings)

btop, bottom, carapace, delta, direnv, dua, duf, dust, eza, fastfetch, fd, fontget, fzf, gdu, gum, jq,
lsd, moor, nano, ntop, ov, peco, procs, pstop, smartmontools, vivid; modules GoogleFonts, NerdFonts,
posh-git, ps-dotenv, PSFzf, Terminal-Icons (Phase 3's OneDrive note applies to the modules).

## Summary of gaps

1. DotForge sets no install variables (T-76; Decision 4).
2. Records missing variables: uv (`UV_TOOL_DIR`, `UV_PYTHON_INSTALL_DIR`), npm (`NPM_CONFIG_CACHE`),
   mise (all three), bitwarden (`BITWARDENCLI_APPDATA_DIR`). To verify: pymanager's install root,
   chezmoi's `CHEZMOI_CONFIG_DIR`.
   **Done (2026-10-25):** uv and npm declared. mise needs nothing: it follows the `XDG_*` variables on
   Windows (checked with `mise doctor`). chezmoi ignores `CHEZMOI_CONFIG_DIR` and follows
   `XDG_CONFIG_HOME` (checked), so its record sets nothing. vcpkg's `VCPKG_ROOT` dropped (the
   installer's). pymanager: config file only (`install_dir`), left for now (T-82). bitwarden depends on
   the manager that installed it (T-83, with piece 6).
3. scoop's `env_set` writes desktop variables that DotForge then defers to (Decision 5): harmless for
   git/vcpkg/oh-my-posh, overridable for fnm/uv/bun/bat, fixed at install for rustup/pnpm. vcpkg's
   record is wrong for a scoop install.
4. The bootstrap core runs before any variable is set (Decision 1): gh already leaked.
5. Desktop variables have no home in DotForge (Decision 2).
6. The tool list lives in the profile (Decision 3).
7. PSGallery modules land in OneDrive (Phase 3; dropped: works, revisit if it bites).
8. Strays already on this machine: `%APPDATA%\GitHub CLI`, `%APPDATA%\uv\tools`,
   `%LOCALAPPDATA%\uv\cache`, `%LOCALAPPDATA%\npm-cache`.

## Environment size

**Done (DotForge, 2026-10-26):** fzf's base options → seeded `fzfrc`, less's `LESS` → seeded
`lesskey` `#env`, vivid → seeded trimmed `filetypes.yml` (`LS_COLORS` 17,889 → 6,499 characters);
theme and role variables stay, documented. Spec `2026-10-26-config-files-design.md` (closes T-79).

**Decided (yours): config file over variable, project-wide.** When a setting can be made in a tool's
config file or by a variable, DotForge puts it in the config file unless something prevents it, and
uses variables only to point at config files and folders. Added as T-79, and to project memory.

Measured 2026-10-25, in a DotForge pwsh session: the process environment is 30,155 characters, but
**`LS_COLORS` alone is 17,888** (vivid's theme, a session variable), and `Path` is 4,952 (74
entries). The Windows user environment (HKCU) is only 5,240. Facts that shape the fix
([Microsoft Learn](https://learn.microsoft.com/windows/win32/procthread/environment-variables)):
since Vista there is no limit on the whole environment, only 32,767 characters per variable; but
cmd.exe ignores any inherited variable over 8,191 characters, so cmd and batch files never see
`LS_COLORS` (harmless) and would lose `Path` if it ever passed 8,191. So the real pressures are
`LS_COLORS` (trim vivid's output, e.g. fewer file types; T-79) and `Path` (winget, below).

## winget without links (yours)

**Confirmed from winget's logs:** on 2026-10-19 every portable install logged `Failed to create
symlink at: ...\WinGet\Links\<tool>.exe` (bw, bws, uvx, rg, tldr, …). Creating a symlink needs admin or
**Developer Mode**; without either, winget falls back to adding each package's own folder to the user
PATH. Here that left 22 `WinGet\Packages\...` entries in the user PATH and an empty `Links` folder.
Developer Mode is on now (`AllowDevelopmentWithoutDevLicense = 1`), so it was turned on after those
installs.

**Leaning:** the bootstrap turns on Developer Mode as one elevated step (gsudo is already in the
core, or the bootstrap starts elevated for just that), before any winget install. That is a single
HKLM value; it also lets DotForge's link fallback use file symlinks. Running winget itself elevated is
the wrong fix: it changes which scope some installers pick. For this machine: reinstalling the 22
portable packages now would move them to links and shrink PATH (ask first: touches installed tools).
