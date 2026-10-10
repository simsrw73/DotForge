# Changelog

All notable changes to DotForge are documented here.

## [Unreleased]

> **Breaking: your profile needs one change.** DotForge now configures only the tools you ask for,
> and never installs anything while it loads. Replace `Initialize-DFEnvironment` and
> `Register-DFTool -All` with one call, and pass your settings to it:
>
> ```powershell
> Import-Module DotForge
> Start-DFSession -Config @{ Tools = @('+core', 'starship'); Defaults = @{ prompt = 'starship' } }
> ```
>
> `SkipTools` is gone: list what you want in `Tools`, and remove members of a `+group` with
> `ExcludeTools`. A global `$DFConfig` is no longer read; pass it with `-Config $DFConfig` if you
> keep one. See `docs/guide/getting-started.md`.

### Added

- **`Get-DFConfig`** is public: read a setting of the current session, e.g. `Get-DFConfig Theme`.
- **`Install-DFTool -Missing` installs everything the session reported missing, in one run.** It
  builds a staged plan, so a manager or runtime installs before the tools that need it (fnm, then
  node, then a tool from the npm registry). It never installs anything you didn't ask for: when a
  tool needs a manager you don't have, it asks which one, showing a default (Enter keeps it);
  `-UseDefaults` takes every default without asking, and `-Confirm:$false` keeps the questions but skips the final confirmation. Third-party feeds (scoop buckets) and admin
  prompts (choco, through an `elevator` such as gsudo; without one, the next source is used) are shown in the plan before you confirm; `-WhatIf` shows only the
  plan. From a script with no one to ask, only decision-free tools install and the rest are
  reported. New tools are configured in the current session right away.
- **Package managers are plugins.** A manager's record declares how it installs (`installs`:
  source, command, batching, elevation, feeds), so adding one is a JSON file. New records: cargo,
  psresource, pnpm, bun, node; npm gains an `installs` block. Pickers and `trifle`'s install hints
  read the same blocks.
- **Choosing where a tool comes from:** `InstallVia` (per tool), the tool record's own preference
  (`install.prefer`, for official or better-maintained packages), `InstallOrder` (ordering only),
  then DotForge's order. `ExcludeSources` forbids a source unless `InstallVia` names it.
  `Install-DFTool -Via <source>` picks one for a single call. Which manager serves a shared registry
  is a role: `Defaults['js-package-manager']`, `rust-package-manager`, `powershell-package-manager`.
- **`Invoke-DFToolSetup -Name <tool>`** re-runs a tool's one-time setup (a deleted seed comes back);
  `-Force` also replaces an edited seed, after a confirm.
- **`Start-DFSession` says how each missing tool would be installed** (`Get-DFToolStatus` detail),
  computed only when something is missing.
- **Python tools install the same way.** New records `python` (the `python-runtime` role), `pymanager`
  (Python's install manager), `pip` and `pipx`; uv joins `python-package-manager`. PyPI packages
  install through uv (`uv tool install`), then pipx, then pip (`Defaults['python-package-manager']`
  changes the order). python installs through pymanager or uv first, so a version manager you have
  owns it; pip comes with python. A manager's `installs` can now be a list of blocks, one per
  source (uv installs both PyPI tools and Python). `trifle`'s PyPI install hint uses uv.
- **`node` and `bun` are the `js-runtime` members.** node installs through your version manager
  (fnm, mise) when you have one; npm comes with node. fnm and mise left `js-runtime`. `after` accepts
  `role:<name>`, so node is checked after any version manager has run.
- **`requires` in tool JSON.** A tool can name tools it can't work without (`"requires": ["fzf"]`)
  or a role (`"requires": ["role:js-runtime"]`). A required tool is requested automatically
  (`Get-DFToolStatus` shows `RequestedBy: requires (<tool>)`) and activated first; if it is missing
  or excluded, the requiring tool reports Missing with the reason. A role requirement orders the
  tool after every requested member of the role. It never picks a member for you (which version
  manager or runtime you use is your choice, made in `Tools`) and never blocks, since the role can
  be filled from outside DotForge; if the tool is missing, its detail names the tools that could
  fill the role. New category role `js-runtime`: fnm and mise.
- **`Start-DFSession -Config`, the single profile entry point.** It configures exactly the tools
  listed in `Tools` (tool names and `+groups`) that are installed, and never looks at the others:
  only the requested tool records are read. It exports the XDG folders, runs each tool's one-time
  setup the first time, activates the tools (one failure never stops the rest), checks for
  coreutils shadowing over the active tools, and ends with a notice. Calling it again adds newly
  requested tools.
- **Tool groups.** `+core`, `+prompt`, `+git`, `+dev-tools`, `+admin-tools`, `+markdown` and
  `+package-managers` request a set of tools at once. `Get-DFToolGroup` lists them.
  `ExcludeTools` removes tools or groups from what `Tools` requests, and always wins.
- **A missing-tools notice at the end of every load.** It names requested tools that aren't
  installed (or gives the count when there are more than five), says which tool is standing in
  for a missing role tool, lists tools that failed to load, and points at
  `Install-DFTool -Missing`. It is silent when everything is installed.
- **`Get-DFToolStatus [-Name] [-Missing] [-Failed]`** shows what the session decided for each
  requested tool: `Active`, `Missing`, `Failed` or `Excluded`, what requested it, the roles it won,
  and why it is missing or failed.
- **Config validation.** An unknown key in `-Config` warns with a suggestion
  (`ExludeTools` → `ExcludeTools`); a removed key (`SkipTools`, `CompletionMode`) says what
  replaced it. A profile that still sets a global `$DFConfig` gets one loud warning that its
  settings, including protective ones like `SkipSetup`, are no longer applied.

- **Tool records are checked as they load.** A record with a malformed field is skipped with a
  warning that names the problem. That covers an object `picker` without `function` and `list`,
  `"false"` in quotes where `true`/`false` belongs, an `aliases` entry without a `command`, and a
  non-array `dependsOn`. A picker `action` or `parse` that isn't valid PowerShell is caught here
  too, instead of when your profile runs. A field name that looks like a misspelling of a known
  one (`dependson`, `themMap`, `preview_windows`) warns "did you mean", and the tool still loads.

- **moor and ov join the `pager` role.** moor (formerly moar) is the default pager and gets
  `MOOR=-style <theme> -quit-if-one-screen` from your theme (`MoorTheme`) unless you set `MOOR`; ov
  runs as `ov --quit-if-one-screen`.
- **less resolves to the native Windows build.** When less is the pager, `PAGER` names the first
  `less.exe` outside Git for Windows' `usr\bin` (whose MSYS build needs `TERM`), via a new
  `executableExclude` tool field and `${DF_TOOL_EXE}` role-env token. less's key bindings now use
  `LESSKEYIN` (the lesskey source file) instead of `LESSKEY`. DotForge's own pager accepts a quoted
  program path.
- **ps-dotenv and mise join the `project-env` role.** ps-dotenv (the default winner) loads `.env`
  files as you change folders, with safe mode on: only folders in `DotenvApprovedDirs` load
  (`DotenvSafeMode = $false` loads all). mise activates when it's the `project-env` tool, and its
  shims stay on PATH either way. Tool records can declare a third-party `scoopBucket`, which
  `Install-DFTool` adds before installing, so `Install-DFTool ps-dotenv` works.
- **direnv works without setup.** When `DIRENV_BASH` is unset, DotForge points it at Git for
  Windows' bash (`direnv.toml`'s `bash_path` still wins), and warns while the installed direnv
  (2.37.1 or older) has the Windows bug that unloads unrelated variables (direnv#1488).
- **Tool roles.** `data/roles.json` defines roles such as `prompt`, `pager`, `editor`, `picker`,
  `diff`, `listing`, `project-env`, `navigation` and `package-manager`, plus grouping-only
  categories (`grep`, `markdown-viewer`, …). Only the winning tool for a role
  (`Defaults`, else the highest-priority installed tool) sets that role's variables and
  aliases and installs its shell hooks; the others stay configured and usable by name. When two
  tools could fill `prompt`, `project-env` or `navigation` and you haven't chosen, DotForge warns
  once and names its pick. New `Get-DFRole` lists roles, candidates and winners; `Find-DFTool -Role`
  filters by role.
- **User documentation, rewritten and tested.** The 785-line README is now a short landing page
  linking to task-based guides in `docs/guide/` (getting started, configuration, tools, pickers
  and helpers, completion, package catalog, coreutils conflicts, troubleshooting, safety, writing
  a tool record). `docs/reference.md` is generated from comment-based help and the tool records by
  `build/Build-DFReferenceDocs.ps1`; `tests/Docs.Reference.Tests.ps1` fails when it is stale.
  `tests/Docs.Examples.Tests.ps1` runs every documentation code block and example profile in a
  sandbox (throwaway home, no XDG or tool variables, private git config) and compares shown
  output; blocks marked `interactive`, `network` or `system` are parse-checked only.
  `tests/Docs.Links.Tests.ps1` checks every relative link and anchor.
- **Complete comment-based help for every companion function** (`fco`, `wins`, `glow`, `fprl`,
  …): `Get-Help <name> -Full` now works for all of them, and `tests/Docs.Help.Tests.ps1` enforces
  complete help for exported and companion functions alike.
- **`starship` prompt tool.** `Tools/starship.json` points `STARSHIP_CONFIG` at
  `$XDG_CONFIG_HOME/starship/starship.toml` and `STARSHIP_CACHE` at `$XDG_CACHE_HOME/starship`.
  `Tools/starship.ps1` initializes the prompt from cached `starship init powershell
  --print-full-init` output, which is regenerated when starship is upgraded. starship's
  `Enable-TransientPrompt`/`Disable-TransientPrompt` are re-imported globally so a profile can
  call them. To switch from oh-my-posh, request starship instead of oh-my-posh in `Tools`.

### Fixed

- **A stuck winget could hang `trifle`:** `winget search` (the fallback when winget's index can't
  be read) and `winget show` ran with no time limit. Both now stop after 30 seconds, and `trifle`
  carries on with its other sources and cached data.
- **Tools only on the npm registry (inshellisense) couldn't be installed:** `Install-DFTool` had
  no npm path. npm, pnpm and bun now install them.
- **One broken tool no longer stops the rest from registering.** A companion that threw, or any
  error while `$ErrorActionPreference = 'Stop'` (common in profiles), aborted `Register-DFTool` and
  skipped every tool after it. Each tool's failure is now caught and reported as `DotForge: <tool>
  failed to register: …`, and registration continues.
- **cargo and PSGallery packages never matched across catalogs.** Tool records and
  `data/tool-identities.json` key packages by package manager (`cargo`, `psresource`), but the
  catalogs are named `crates` and `psgallery`. So mdcat, mdv, posh-git, PSFzf and Terminal-Icons
  never merged their crates.io/PSGallery hits into the tool's row, and the identity build never
  checked those packages. Providers now declare the manager they serve (`-PackageManager`), and every
  identity index translates through it.
- **Cache files could be read half-written.** The cached init scripts (carapace, zoxide, …),
  help-topic list, LS_COLORS, scoop index key, winget index metadata and CLI help-flag cache were
  written in place, with the fingerprint key first. Two shells starting at once could
  `Invoke-Expression` a truncated init script, and a crash between the two writes left a valid key
  over stale content. They now go through `Write-DFFileAtomic`, content before key.
- **npm and inshellisense were reported missing although they were installed.** Node (and the
  npm global folder) is on PATH only after the version manager's companion runs, but nothing
  ordered these tools after it, and DotForge remembered a "not installed" answer for the rest of
  the load. Both now declare `"requires": ["role:js-runtime"]` (see Added), and a missing tool is
  re-checked rather than remembered, so a tool another tool puts on PATH mid-load is found.
- **An empty help-topic scan was cached.** If `Get-Help *` returned nothing once, the help pickers
  stayed empty until a module was installed or updated. The help-topic list, cached tool init
  scripts and LS_COLORS now share one cache (`Get-DFFingerprintCache`) that never stores an empty
  result.
- **`Show-DFCliHelp` ran a tool's help twice on first use.** Detecting the help flag ran the tool
  and threw the text away, then the command ran it again. The detection's output is now reused.
- **Two documented examples failed their output check** because the expected output had a hyphen
  where DotForge prints an em dash.
- **Exclusive-role notice suggests the right alternative.** When two or more tools could fill
  `prompt`, `project-env` or `navigation`, the one-time warning now suggests the runner-up by
  priority (mise, not the alphabetically first direnv).
- **Scoop bucket installs read cleanly and recover.** The "added scoop bucket" message (or its
  warning) prints on its own line before the install progress line, and a failed `bucket add` checks
  the bucket list again before giving up, so an already-added bucket no longer fails the install.
- **Role edge cases.** A role-variable conflict warns once per session, even when `. $PROFILE`
  re-runs your own assignment. DotForge remembers which values it wrote across `Import-Module -Force`,
  and `Get-DFRole` labels a value left by an earlier winner as `DotForge (earlier winner)`. A
  whitespace-only `Defaults` entry is ignored; a `Defaults` winner is reported with the tool's own
  spelling; a `Defaults` entry naming a category warns. An empty `env`/`aliases` role block no
  longer counts as content, a role's hook name must match the role, and a companion or hook that
  reuses a local variable name can no longer stop later hooks or the setup script.
- **`Remove-DFTestGlobal -Alias` removes aliases.** It checked with `Test-Path alias:global:<n>`,
  which is always false, so it never removed anything.
- **`open <url>` failed with "Cannot find drive 'https'".** `Open-DFItem` passed URLs to
  `Invoke-Item`; anything with a `scheme://` now goes through `Start-Process`.
- **`reload` dropped the profile's functions, aliases and variables.** `Invoke-DFProfileReload`
  dot-sourced `$PROFILE` inside the module function, so only environment variables survived; it
  now runs the profile in the caller's session state.
- **`fga` staged the wrong path for unstaged changes and renames.** It split `git status --short`
  lines on whitespace, so ` M file` became `M file`; it now reads the fixed `XY PATH` layout and
  stages the new path of a rename.
- **`which` returned every match on `PATH`, and `-All` did nothing.** It now returns the first
  match (the one that runs) and lists all of them only with `-All`.
- **`examples/02-standard.ps1` reinstalled ripgrep on every shell start**, because it checked for
  `ripgrep.exe` instead of `rg.exe`. (Installing at startup is gone altogether now; see the
  breaking change above.) **`examples/04-vscode-fastpath.ps1`** said its VS Code path skipped oh-my-posh but
  registered it anyway.
- **The `ff` and `ffd` pickers said "Enter to open"** but output the path; the headers now say so.
- **carapace's specs and delta's theme file were rewritten on every shell start.** The "only when
  changed" check compared against a copy `Set-Content` had written with an extra trailing newline,
  so it never matched; the copies are now byte-identical and left alone.
- **A Carapace spec added for a new command never took effect**, because the cached init script was
  keyed only to the carapace executable. `Get-DFCachedCommandOutput` takes an optional `-ExtraKey`,
  and the carapace companion passes its specs folder's file names and times, so adding, removing or
  editing a spec regenerates the cache.
- **A tool alias whose record omitted `"args"` became a wrapper function instead of an alias.**
  A missing `args` now means none.
- **The carapace tests wrote into the real `~\.config\carapace\specs`**; they now use a test folder.
- **Help and documentation errors:** `$Env:Picker = 'skim'` (skim's executable is `sk`),
  `Get-DFCategoryList -Counts:$false` described as a bare list, non-runnable `Invoke-DFPicker`
  examples, `POSH_THEMES_PATH` described as set by the oh-my-posh installer, and registry examples
  naming tools that don't exist.
- **zoxide could register before the prompt engine, which then replaced zoxide's prompt hook and
  silently stopped directory tracking.** The docs said registration was alphabetical, but the tool
  DB is a hashtable, so the order was hash order and varied between processes. `Tools/zoxide.json`
  now declares `"dependsOn": ["oh-my-posh", "starship"]`.
- **Tab completion did nothing for carapace-covered commands (`ls`, `bat`, `eza`, …) on paths
  carapace can't parse, such as `bat ..\<Tab>`.** carapace answers `[]` for a backslash `..\`
  prefix, and its completer then returns `""` to suppress file fallback. pwsh 7.6 throws on that
  empty result, and PSFzf's Tab handler swallows the exception. `Tools/carapace.ps1` now rewrites
  the sentinel to a bare `return`, so PowerShell falls back to filesystem completion; the PSFzf
  `.TrimEnd()` rewrite also drops whitespace-only items that would trim to `""`.
- **Cached tool init output (carapace, zoxide, mdcat, scoop-search) went stale across scoop
  upgrades.** `Get-DFCachedCommandOutput` fingerprinted the scoop shim, which scoop never rewrites;
  it now fingerprints the shim's real target (read from the sibling `.shim` file) and follows
  symlinks. Existing caches regenerate once automatically.
- **A scoped npm package could merge into an unrelated tool's row in `trifle` results.** Identity
  lookup stripped everything before `/` for every catalog, so `@scope/zed` matched the tool `zed`.
  Only scoop's bucket-qualified ids (`main/fd`) are stripped now.
- **Cache and state files could be left half-written.** The catalog caches, seen-query list,
  `setup-state.json` and downloaded release data are all written to a temporary file and renamed
  into place (`Write-DFFileAtomic`).
- **The delta setup test failed whenever the scoop tests ran first.** Test cleanup used
  `Remove-Item function:global:<name>`, which silently removes nothing, so the scoop tests' empty
  `git` stub (and 15 other files' stubs) outlived their tests and swallowed delta's real `git config`
  calls. Cleanup now goes through `Remove-DFTestGlobal` (`tests/TestSupport.ps1`), a test rejects the
  no-op form, and the delta tests fail with a clear message if `git` is shadowed.
- **The docs-example tests intermittently hung on `glow`**, because child processes inherited the
  test run's stdin. They now get a closed stdin.

### Changed

- **`Import-Module DotForge` is about 5x faster** (0.70 s to 0.15 s; startup 2.23 s to 1.71 s with a
  47-tool profile). The startup core loads from one bundled file (`Bundle/DotForge.Core.ps1`, used
  only when it matches the sources; `$Env:DF_NO_BUNDLE = '1'` loads the separate files). The package catalog (`trifle`) and the general helpers are now separate modules inside
  DotForge (`DotForge.Catalog`, `DotForge.Helpers`) that PowerShell loads the first time you use one
  of their commands. Nothing changes in how you call them; every alias is still defined when DotForge
  loads. `Get-Command -Module DotForge` now lists only the core; use
  `Get-Command -Module DotForge, DotForge.Catalog, DotForge.Helpers` for everything.
- **Startup is about a quarter faster** (3.2 s to 2.4 s for a 45-tool profile). Shipped tool
  records are validated once at build time (`data/tool-registry.json`) instead of on every load, and
  "is it installed?" checks look for the file on PATH (or the module's folder) instead of calling
  `Get-Command`/`Get-Module`.
- **Language toolchains have their own groups.** `+dev-tools` is now jq, micro, mise and chezmoi;
  `+javascript-dev` (fnm, node, npm), `+python-dev` (uv, python, pip, pipx) and `+rust-dev` (rustup,
  cargo) are new. A profile that used `+dev-tools` for fnm, uv or rustup adds the matching group.
- **`packages` is keyed by source** (`crates` and `psgallery` instead of `cargo` and `psresource`),
  the same names the package catalog uses, and a value can be `{ id, feed }` for a third-party feed.
- **Install hints show each manager's full command** (winget includes `--silent` and the agreement
  flags).
- **Default config files are seeded once, in the one-time setup step.** A tool declares
  `setup.seed` (destination → a file shipped under `Tools/<name>/`); setup copies each file only if
  it doesn't exist, before the companion runs, and records that it ran. A config you delete on
  purpose is no longer recreated on the next load. fastfetch's themed config moved to
  `Tools/fastfetch/config.jsonc`, and its wrapper passes `--config` only while that file exists.
  `SkipSetup` now skips seeding too.
- **PSFzf requires fzf.** Requesting PSFzf requests fzf too; without fzf, PSFzf reports Missing.
- **`Register-DFTool -Name` adds tools to the current session.** It takes tool names and `+groups`,
  recomputes role winners over the session's tools plus the new ones, reports a missing or
  failed tool in `Get-DFToolStatus`, and re-applies a tool you name even if it is already active.
  Use it to try a tool, or to re-apply one after changing its settings.
- **`Get-DFRole` shows the session's view after `Start-DFSession`:** members, candidates and
  winners among the tools you requested, exactly as decided at load. Outside a session it still
  considers every tool DotForge knows.
- **A role is filled only by a tool you requested.** If the tool `Defaults` names for a role is
  requested but not installed, another requested tool fills the role and the notice says which;
  a `Defaults` entry naming a tool you didn't request warns.
- **The coreutils conflict check covers only the tools the session activated,** so it no longer
  reads every tool record at startup, and its fix text points at `Start-DFSession -Config`.
- **Tab completion is a role.** Which tool owns the Tab key is now the `tab-completion` role:
  PSFzf wins by default, then carapace, and inshellisense only when you choose it. Each tool binds
  Tab in its own companion, so core code no longer names any completion tool. A role block can
  declare `"optIn": true` to be considered only when `Defaults` names it.
  `Get-DFRole tab-completion` shows the winner.
- **bat is no longer a `pager` role member.** As a pager it only ever ran less; its own paging
  follows the role's `PAGER`.
- **One prompt engine, one per-directory env hook.** With both oh-my-posh and starship installed,
  only one now initializes. Prompt, zoxide and direnv init moved into role hooks
  (`Initialize-DFRole<Role>` in each companion).
- **`PAGER`, `EDITOR`/`VISUAL` and `Picker` are set by the pager, editor and picker winners** when
  you haven't set them, so `pg`, `hm` and `ep` work out of the box. A value you set is kept,
  unless `Defaults` names a different tool: then the `Defaults` choice wins and DotForge
  warns until you remove one of the two settings. delta's `GIT_PAGER` is now the `diff` role's.
- **Tool records declare `roles`** (an object: priority, plus the `env`/`aliases` only the winner
  gets) instead of the `role` string, which still loads. eza's and lsd's `ls`/`ll`/`la`/`tree`
  moved into their `listing` role blocks; without `Defaults`, eza wins by priority.
- **`Install-DFTool` orders package managers by the `package-manager` role** (`Defaults` choice
  first, then scoop, winget, choco). `PackageManagerOrder` still overrides it.
- **Replaced the abandoned `winfetch` plugin with `fastfetch`.** `winfetch` is unmaintained
  upstream; `fastfetch` is its actively maintained successor. `Tools/fastfetch.json` uses the
  `wrapper` xdg method (like `glow`) since fastfetch does not honor `$XDG_CONFIG_HOME` on
  Windows — `Tools/fastfetch.ps1` wraps the executable, seeding a catppuccin-mocha themed
  config at `$XDG_CONFIG_HOME/fastfetch/config.jsonc` (only when absent) and passing it via
  an explicit `--config` flag on every invocation. `publicip` is deliberately excluded from
  the seeded module list — it measured a 2.87s cold-path network spike during design.
- **`eza` and `lsd` aliases no longer emit hyperlinks and no longer quote names with spaces.**
  `ls`/`ll`/`la` in `Tools/eza.json` and `Tools/lsd.json` dropped `--hyperlink=auto`. eza's
  `ls`/`ll`/`la`/`tree` and its `ff` picker list command gained `--no-quotes`; lsd's
  `ls`/`ll`/`la`/`tree` gained its equivalent, `--literal`.
- **An unset `XDG_*_HOME` means the XDG default under `$HOME` everywhere** (`Get-DFXdgPath`); the
  "XDG_CACHE_HOME is not set" warnings and disabled caches are gone. `Start-DFSession` exports all
  five variables for the tools themselves.
- **Code-quality pass (`audit.thermonuclear.md`).** No user-visible behavior changes beyond those
  listed here; for contributors:
  - Tool records are normalized once at load (`ConvertTo-DFToolRecord`), so every field exists
    and code reads them directly.
  - Catalogs register themselves (`Register-DFCatalogProvider` in `DFCatalog.Base.ps1`); adding one
    is one new file, and `-Source` validation and completion follow automatically.
  - The category database and identity guide share one loader and updater (`DFReleaseData.ps1`).
  - One cache-first engine (`Invoke-DFCacheFirst`) serves catalog detail and query caches;
    `DFCatalog.ps1` was split into `DFXml.ps1`, `DFCatalog.Records.ps1` and the cache core.
  - A category search takes one installed-package snapshot instead of one per matching tool
    (`Find-DFCatalogFacet`).
  - The winget, scoop and choco pickers run on one engine (`Invoke-DFPackageManagerAction`) from a
    spec per manager.
  - `Register-DFTool` is split into named steps (`Register-DFToolSteps.ps1`).
  - Shared helpers for settings (`Get-DFConfig`), theme files (`Resolve-DFThemeFile`) and
    color (`Test-DFColorOutput`, `Get-DFAnsiPalette`).
  - `tests/ModuleState.Tests.ps1` fails when two module files initialize the same `$script:`
    variable.

### Removed

- **`PackageManagerOrder`**, replaced by `InstallOrder` (ordering only) and `ExcludeSources`; and
  `Install-DFTool -PackageManager`, replaced by `-Via`.
- **`scoopBucket`** in tool records, replaced by a `feed` on the scoop package.
- **`dependsOn` in tool JSON**, replaced by `after` (ordering only, among requested tools) and
  `requires` (also requests the tool). A record that still uses `dependsOn` fails validation.
- **`xdg.method: "config"`** (`xdg.config_path`/`config_content`), replaced by `setup.seed`. No
  shipped tool used it.
- **`Register-DFTool -All` and `SkipTools`.** DotForge no longer configures whatever happens to be
  installed: list the tools you want in `Start-DFSession -Config @{ Tools = ... }`, and remove
  members of a group with `ExcludeTools`.
- **`Initialize-DFEnvironment`.** `Start-DFSession` exports the XDG folders. Package managers are
  no longer detected at startup; only installing needs them.
- **The global `$DFConfig`.** Pass your settings to `Start-DFSession -Config`; keeping them in a
  `$DFConfig` variable of your own still works if you pass it.
- **`CompletionMode`.** To run inshellisense directly, put it in `Tools` and set
  `Defaults['tab-completion'] = 'inshellisense'` in your `-Config` instead.
- **Role v1 alias suppression.** Losers no longer declare role aliases, so there is nothing to
  suppress.

## [0.6.0-preview] - 2026-09-06

### Fixed

- **`eza`'s `ll`/`la` aliases and `fzf`'s match mode/previews had drifted from the reference zsh
  config they were meant to mirror.** Found during a 2026-09-06 zsh-parity comparison against the
  user's `~/.zshrc`. `ll` (`Tools/eza.json`) showed hidden files and had no `--git`/icons/dirs-first
  — now `--long --group-directories-first --icons=auto --color=auto --git` (plus DotForge's own
  `--hyperlink=auto` addition). `la` wasn't even a long listing and used a stray `--group` (group/
  owner column) instead of `--group-directories-first` — now matches `ll` with `--all` added.
  `fzf`'s `FZF_DEFAULT_OPTS` (`Tools/fzf.json`) had `--exact --no-sort` — genuinely non-fuzzy
  substring matching for a *fuzzy* finder — replaced with `--inline-info` to match zsh; also
  dropped `--cycle` and matched the height (`40%`, was `50%`). `fd` calls across
  `FZF_DEFAULT_COMMAND`/`ALT_C_COMMAND`/`CTRL_T_COMMAND` gained `--strip-cwd-prefix` to match zsh,
  and `CTRL_T_COMMAND` is now identical to `FZF_DEFAULT_COMMAND` (zsh sets it that way explicitly).
  Previews: Alt+C now shows an `eza --tree --level=2` tree (was a flat listing); Ctrl+T's `bat`
  preview lost its 500-line cap and gained zsh's `ctrl-/` preview-window toggle bind.
- **`Get-DFCategoryDb.Tests.ps1`/`Get-DFCategoryList.Tests.ps1` silently tested against a real,
  ambient `$Env:XDG_DATA_HOME/dotforge/tool-categories.json` instead of their own small fixture.**
  `Get-DFCategoryDb`'s refreshed-vs-shipped comparison runs unconditionally even when `-Path`
  overrides the "shipped" side (by design, so tests exercise the full resolution algorithm) — a
  real, newer `tool-categories.json` from actual DotForge usage on the dev machine silently
  outranked the fixture in every test that didn't isolate `$Env:XDG_DATA_HOME` itself. Isolated
  it in all three `Get-DFCategoryDb.Tests.ps1` `Describe` blocks and in
  `Get-DFCategoryList.Tests.ps1`'s `BeforeEach`, matching the pattern the file's own
  "refreshed copy" tests already used correctly. No production code changed — test-only.
- **`mdv`'s seeded `config.yaml` was silently reasserted after a deliberate deletion.**
  `Tools/mdv.ps1` checked `Test-Path config.yaml` every session and wrote the file
  whenever absent — indistinguishable from "DotForge has never run here," so a user who
  deleted the seeded file to opt out got it silently rewritten on the very next
  `Register-DFTool` call. Migrated to the new tool-setup-lifecycle primitive: theme
  resolution and seeding now live in `Tools/mdv.setup.ps1`, which runs at most once ever
  (tracked in `$XDG_STATE_HOME/dotforge/setup-state.json`), so a later deletion sticks
  permanently. `Tools/mdv.ps1` retired entirely — directory creation was already handled
  declaratively by `xdg.dirs`, and seeding was its only other job.
- **`Invoke-DFSqliteQuery` built queries by string concatenation, with manual escaping at its one
  call site that embeds free text.** `DFCatalog.Winget.ps1`'s search doubled embedded single
  quotes itself before building the SQL string — correct today, but a discipline that has to be
  re-applied at every future call site forever. Added real `sqlite3_bind_text` parameter binding
  (a new `-Parameters` argument, bound to `?` placeholders); the winget search now binds its search
  term instead of concatenating it, so this class of bug is structurally impossible there going
  forward rather than dependent on remembering to escape.
- **`fzf`'s color theme was hardcoded to catppuccin-mocha, ignoring `$DFConfig['Theme']`/`$DFConfig['FzfTheme']`.**
  `Tools/fzf.json`'s `FZF_DEFAULT_OPTS` embedded a literal `--color=…` string, unlike every
  other themed tool in this codebase, which resolves through `Get-DFConfiguredTheme`/
  `Resolve-DFThemeName`. The color values move to a bundled `Tools/fzf/catppuccin-mocha.json`
  (same shape as `Tools/psreadline/*.json`), resolved by a new `Tools/fzf.ps1` companion and
  appended to `FZF_DEFAULT_OPTS` after `Register-DFTool` sets the non-color flags from
  `fzf.json`'s `env` block — same default appearance as before, now theme-configurable and
  overridable from `$XDG_CONFIG_HOME/fzf/themes/`.
- **`Get-Help Register-DFTool -Full` never rendered its synopsis, description, or examples.**
  A `[Diagnostics.CodeAnalysis.SuppressMessageAttribute(...)]` sat before the comment-based
  help block, and PowerShell only recognizes comment-based help as the very first token in a
  function body. Moved the attribute after the help block — the same fix already applied to
  `Invoke-DFToolCompanion` when the same issue was introduced there during the
  `Register-DFTool` split. This predated that split entirely.
- **`New-DFShim` changed directory before invoking the target.** The generated `.cmd` did
  `cd /d` into the target executable's own install directory before running it, so any
  relative-path argument the user passed resolved against that directory instead of the
  caller's actual working directory. The `cd` is removed — nothing needed it (Windows
  already resolves an executable's own DLL dependencies relative to its own directory
  regardless of `cwd`).
- **`Import-DFToolDb` and `Resolve-DFPackageManager` could return a stale or
  cross-contaminated result.** Both cached their result in a single unkeyed variable
  regardless of whether the caller passed an explicit `-ToolsPath`/`-Priority`, so a
  one-off call with a custom value could read another caller's cached answer, or silently
  overwrite the shared cache for every later default-argument caller in the session. An
  explicit override now always does a fresh, uncached read/write, mirroring the guard
  `Get-DFCategoryDb` already used correctly for its own `-Path` override.

### Added

- **`vcpkg` (`Tools/vcpkg.json`/`.ps1`).** New tool, closing one of the four remaining
  zsh-parity gaps tracked from the 2026-09-06 comparison. `VCPKG_ROOT` relocates under
  `$XDG_DATA_HOME/vcpkg` and `VCPKG_DOWNLOADS` under `$XDG_CACHE_HOME/vcpkg/downloads`
  (matching zsh's `.zshenv` exactly); the sidecar adds `$VCPKG_ROOT` itself to PATH since
  `vcpkg.exe` has no `bin/` subfolder.
- **`direnv` (`Tools/direnv.json`/`.ps1`).** New tool, closing the last of the four
  zsh-parity gaps. direnv is natively XDG-compliant (config at
  `$XDG_CONFIG_HOME/direnv/direnv.toml`, allow-list at `$XDG_DATA_HOME/direnv/allow`) so
  no `xdg.vars` were needed — `xdg.method: "default"`. The sidecar installs direnv's own
  `hook pwsh` output (cached via `Get-DFCachedCommandOutput`, same pattern as
  `Tools/zoxide.ps1`), which attaches to
  `$ExecutionContext.SessionState.InvokeCommand.LocationChangedAction` rather than wrapping
  `function:prompt` — so, unlike zoxide/oh-my-posh, it has no registration-order dependency
  on either. The hook requires PowerShell 7.2+ and throws below that; the sidecar guards
  this and degrades to a warning instead.

### Changed

- **`psreadline`'s default `EditMode` is now `Emacs`, not `Windows`.** Override with
  `$DFConfig['PSReadLineEditMode'] = 'Windows'` to keep the old default. Also folded in three
  settings that previously lived in a personal `profile.ps1` (marked there as a
  `### TODO: Move this to DotForge`): `HistorySearchCursorMovesToEnd` (new `settings` key in
  `Tools/psreadline.json`), and `Ctrl+p`/`Ctrl+n` bound to `HistorySearchBackward`/`-Forward`
  (`Tools/psreadline.ps1`) — history search filtered by what's already typed, cursor landing at
  the end of the recalled line.
- **`psreadline`'s history is now relocated and sized to match zsh** — another of the
  2026-09-06 zsh-parity gaps. `HistorySavePath` moves to `$XDG_STATE_HOME/psreadline/history`
  (was PowerShell's AppData default; the directory is created via a new `xdg.dirs` entry) and
  `MaximumHistoryCount` is raised to `10000` (new `settings` key), matching zsh's explicit
  `HISTSIZE=10000` instead of PSReadLine's own default of 4096.
- **`rustup`'s `RUSTUP_HOME`/`CARGO_HOME` are now relocated under `$XDG_DATA_HOME`** — the
  last of the four zsh-parity gaps (`Tools/rustup.json` gained `xdg.method: "env"`; a new
  `Tools/rustup.ps1` adds `$CARGO_HOME/bin` to PATH, since core's env-var application never
  touches PATH itself). Previously `rustup`/`cargo` used their un-relocated Windows defaults.
- **`Register-DFTool -All` no longer re-probes the same tool's availability more than
  once per session.** A new `Test-DFToolAvailable` (`Private/Test-DFToolAvailable.ps1`)
  memoizes `Get-Command`/`Get-Module` results per `(type, executable)` — previously a
  `$DFConfig.Defaults` role winner was probed twice per `Register-DFTool` call (once
  during role resolution, once in the main loop), and every tool was re-probed from
  scratch on any later `Register-DFTool` call in the same session. Measured ~44%
  reduction in `Register-DFTool -All` wall-clock cost on a representative machine
  (`build/Measure-DFStartup.ps1`). `Install-DFTool` refreshes a tool's cached entry
  immediately after a successful install, so a `Register-DFTool` call right after
  installing a tool picks it up, provided the install landed on the current session's
  PATH already (true for scoop; not guaranteed for winget/choco installs that land
  somewhere the running shell won't see until it restarts).
- **`carapace`, `zoxide`, `mdcat`, and `scoop-search`'s init/completion scripts no longer spawn
  their process every single session.** A startup-perf audit
  (`docs/superpowers/specs/2026-09-05-startup-perf-audit.md`) found these four companions spawn
  a real process every `Register-DFTool` call to produce output that is a pure, byte-identical
  function of the tool's own build — a caching candidate exactly like `vivid`'s existing
  `LS_COLORS` cache, just with no session-input theme name to key on. New
  `Get-DFCachedCommandOutput` (`Private/Get-DFCachedCommandOutput.ps1`) fingerprints the resolved
  executable's own file identity (path + `LastWriteTimeUtc`) instead — a file stat, not a process
  spawn — so a tool upgrade correctly invalidates the cache with no version-check cost on the
  common (cache-hit) path. Falls back to always regenerating, uncached, whenever the resolved
  command has no real file behind it (a function/alias stand-in) so a stubbed or shadowed command
  degrades to "slower but correct," never broken. Measured ~200ms mean reduction in
  `Register-DFTool -All` on a representative machine (`build/Measure-DFStartup.ps1`).
- **`type: module` tools now warm their `Import-Module` cost in the background before
  `Register-DFTool`'s per-tool loop reaches them.** A new `Start-DFModulePrewarm`
  (`Private/Start-DFModulePrewarm.ps1`) fires one background job that pre-imports every
  prewarm-eligible `type: module` tool actually being registered this call (`Terminal-Icons`,
  `PSFzf`, `posh-git`) into a throwaway runspace, purely to warm OS/CLR-level caches
  before the loop reaches that tool's own existing, unchanged `Import-Module` call — the
  later, real import is then measured ~77% faster (282ms → 65ms on a representative
  module, reproduced 3/3, per `docs/superpowers/specs/2026-09-05-startup-perf-audit.md`
  Part 2). Automatic for every prewarm-eligible `type: module` tool actually being
  registered — see `Start-DFModulePrewarm`'s own doc comment for the one assumption this
  relies on (no import-time side effects beyond session-local state). A tool opts out via a
  new `Tools/<name>.json` `"prewarm": false` field; `psreadline` deliberately sets it and is
  excluded — its sidecar (`Tools/psreadline.ps1`) never calls `Import-Module` (PSReadLine is
  always pre-loaded by the PS7 host before any profile runs), so prewarming it has no
  benefit, and it is the module most exposed to the shared-process CLR statics
  `Start-ThreadJob` implies (PSReadLine keeps its key-handler dispatch table on a
  process-global static singleton that PSFzf's import touches).
  Deliberately excludes `oh-my-posh`/`fnm` (neither is a `type: module` tool, and the audit
  found deferring `oh-my-posh`'s init reproduces a documented prompt-hook bug) and
  `inshellisense`'s session check (a separately-tracked, differently-shaped follow-up —
  see `TODO.md`).

### Added

- **Tool setup lifecycle.** A new optional `Tools/<name>.setup.ps1` companion
  runs at most once ever per tool — for setup that makes a persistent,
  user-visible change (e.g. adding an `[include]` line to the user's real git
  config) that must never be silently reasserted after the user edits or
  removes it. Tracked in `$XDG_STATE_HOME/dotforge/setup-state.json`
  (`Private/Get-DFToolSetupState.ps1`); a tool's setup script records its own
  success by calling the new `Complete-DFToolSetup -Name <tool> [-Actions
  <object[]>]`, so a script that throws before reaching that call is retried
  on the next `Register-DFTool` call rather than silently marked done. New
  `$DFConfig['SkipSetup']` opts a tool out, mirroring `SkipTools`. First
  consumer: `delta` (below); `mdv`'s migration closes an already-shipped bug
  (see Fixed).

- **`delta` now actually renders catppuccin instead of silently no-opping.**
  `DELTA_FEATURES=catppuccin-mocha` pointed at a feature that never existed in
  any git config, anywhere — a confirmed no-op. Fixed two ways: `Tools/delta.ps1`
  now bundles and deploys [catppuccin/delta](https://github.com/catppuccin/delta)'s
  `catppuccin.gitconfig` (all four flavours) to
  `$XDG_CONFIG_HOME/delta/catppuccin.gitconfig` every registration, and a new
  `Tools/delta.setup.ps1` — the tool-setup-lifecycle primitive's first
  consumer — adds one `include.path` entry pointing at it to the user's real
  global git config, exactly once ever, printing the exact removal command and
  never re-adding it after an explicit removal. Also fixed a related
  already-shipped bug found along the way: `DELTA_FEATURES` was set bare,
  which *replaces* the user's entire git-config `features` list rather than
  layering on top of it (verified directly) — now prefixed with `+`, additive
  like every other feature DotForge doesn't own. Opt out of the git-config
  edit alone (keeping `DELTA_FEATURES`/`GIT_PAGER`) with
  `$DFConfig['SkipSetup'] = @('delta')`.

- **`vivid` LS_COLORS theming.** New `Tools/vivid.json`/`.ps1` plugin resolves
  the shared theme (default `catppuccin-mocha`) via the existing
  `Get-DFConfiguredTheme`/`Resolve-DFThemeName` chain and applies it as
  `LS_COLORS`, cached under `$XDG_CACHE_HOME/dotforge` and regenerated only on
  a theme change (`vivid generate` costs ~40ms). `eza` (this repo's
  `listing`-role default, per `man eza_colors`) and `lsd` (per its README FAQ)
  both read `LS_COLORS` directly for filetype-extension coloring — confirmed
  documented behavior for both, not an assumption — so their output changes
  once `vivid` is installed; it's a suggested, not required, tool. Ships a
  live picker, `Select-LSColorsTheme` / `fls`, mirroring psreadline's `fprl`,
  with a `vivid preview {}` swatch per theme in the fzf preview pane.
- **`bat` theming via `BAT_THEME`.** `Tools/bat.json` now ships bat's native
  `Catppuccin Mocha` theme as the default (bat already had this theme built
  in — no external config needed, unlike `delta`). A new `Tools/bat.ps1`
  overrides it from `$DFConfig['BatTheme']`/`$DFConfig['Theme']` via the
  standard `Get-DFConfiguredTheme`/`Resolve-DFThemeName` chain, same pattern
  as `mdcat`. bat validates the theme name itself and degrades gracefully on
  an unrecognized one, so no DotForge-side whitelist is needed.
- **`$DFConfig.Defaults`-driven default-tool role resolution.** A tool optionally declares a
  `role` (e.g. `"listing"`); `$DFConfig.Defaults = @{ listing = 'eza' }` names the winner, and
  `Register-DFTool` suppresses only the alias keys a role LOSER shares with the winner — every
  other alias, XDG config, and picker the loser declares still applies. Onboarded `lsd` as a real
  second `listing`-role tool alongside `eza` to prove the mechanism.
- **Author-time tool-conformance harness.** `build/Test-DFToolConformance.ps1`
  probes whether a tool actually honors its configuration (env vars, config
  files, flags) rather than trusting the docs, recording per-claim
  `pass`/`fail`/`manual`/`unknown` verdicts in a versioned ledger
  (`data/tool-conformance.json`) and generating an upstream-ready issue report
  (`reports/tool-conformance-issues.md`). Probe descriptors live in
  `build/conformance/*.jsonc`; sidecar adapters cite the claim they work around
  (`# adapter for <claim-id>`), and the harness flags orphaned or upstream-fixed
  adapters. Piloted on `bat` and `glow`. Author-time only — never loaded or run
  by the module.

### Changed

- **`psreadline` now defaults to `catppuccin-mocha`**, matching `mdcat`/`mdv`/`glow`.
  Previously its built-in default was `dark` — the only themed tool in this
  codebase that didn't ship catppuccin out of the box. `Tools/psreadline/catppuccin-mocha.json`
  already existed; this was a one-line default-value change
  (`Tools/psreadline.ps1`'s `Get-DFConfiguredTheme -Default` argument).
- **The `copy` alias is renamed to `yank`.** It collided with PowerShell's builtin `copy` alias
  (`Copy-Item`, `AllScope`) — the only general-helper alias that did. Anyone using `copy` for
  `Copy-DFToClipboard` needs to switch to `yank`.
- **All 27 general-helper aliases (`pg`, `hm`, `touch`, `yank`, …) are now genuinely module-owned.**
  `(Get-Module DotForge).ExportedAliases` reports them and `Remove-Module DotForge` cleans them up
  correctly — previously the manifest's `AliasesToExport` was decorative. No change to how or when
  they're created relative to a session's existing aliases (import-time collision behavior is
  unchanged; see `docs/superpowers/specs/2026-07-26-alias-ownership-design.md` for why).

### Fixed

- **`$DFConfig = $null` in a profile crashed five code paths.** `Register-DFTool`,
  `Install-DFTool`, `New-DFShim`, and both `$DFConfig` reads in `Tools/psreadline.ps1`
  guarded on the *variable's existence* (`Get-Variable -Name DFConfig`) before indexing
  into it. Assigning `$null` leaves the variable defined, so the index threw
  `Cannot index into a null array`. All five now test the value (`$null -ne $Global:DFConfig`),
  matching the already-safe short-circuit in `Get-DFCommandConflict`. Regression tests
  added for each.

- **glow ignored its DotForge configuration entirely.** `Tools/glow.json` set
  `GLOW_CONFIG_DIR` and created `$XDG_CONFIG_HOME/glow`, but glow honors no XDG
  environment variable: its config path comes from a Win32 known-folder lookup
  (it does not move even when `APPDATA`/`LOCALAPPDATA` are redirected),
  `GLAMOUR_STYLE` is never read at all, and `GLOW_STYLE` is parsed but loses to
  glow's non-TTY downgrade. The result was an empty config directory and a theme
  that never rendered. A new companion `Tools/glow.ps1` now wraps the executable
  and passes `--config` and `-s` as flags — the only knobs that work — so
  `xdg.method` moves from `env` to `wrapper` and the dead `xdg.vars` are gone.

### Added

- **Canonical path handling (`ConvertTo-DFPath`).** All paths DotForge stores, compares, emits, or
  accepts are now absolute, native-separator, free of `.`/`..`, and without a trailing separator, with
  a leading `~` expanded to `$HOME`. This fixes the mixed `\`/`/` separators that XDG-derived env vars
  (`BAT_CONFIG_PATH`, `MDV_CONFIG_PATH`, …) previously carried on Windows, and collapses `..` in
  internal path defaults. Non-path flag strings (`LESS`, `FZF_DEFAULT_OPTS`) are unaffected.
- **Two markdown viewers — `mdcat` and `mdv`:** both catppuccin by default. `mdcat`
  is themed via `MDCAT_THEME` with native `--completions`; `mdv` is themed by a seeded
  `config.yaml` (written only when absent) plus a bundled carapace spec. A shared
  `$DFConfig['Theme']` key now drives `glow`, `mdcat`, `mdv`, and `psreadline`, with
  per-tool keys (`GlowTheme`, `MdcatTheme`, `MdvTheme`, `PSReadLineTheme`) overriding it.
  `Install-DFTool` gained a `cargo` arm (last-resort) so cargo-only tools install.
- **Bundled glow theme + `$DFConfig['GlowTheme']`:** `Tools/glow/catppuccin-mocha.json`
  ships with the module, and `Resolve-DFGlowStyle` resolves a theme name the same
  way PSReadLine themes resolve — rooted path, then
  `$XDG_CONFIG_HOME/glow/themes/<name>.json`, then the bundled copy, then glow's
  own built-in style names (`auto`, `dark`, `light`, `dracula`, `pink`, `notty`,
  `ascii`, `tokyo-night`). An unresolved name warns and falls back to `auto`,
  because a `-s` path glow cannot load makes it exit 1 rather than degrade. The
  resolved value lives in `$global:DFGlowStyle` and is read at call time, so
  assigning to it switches theme for the rest of the session.

### Changed

- **Non-XDG environment variables moved out of `xdg.vars` into a dedicated top-level `env`
  block.** `xdg.vars` is now `${XDG_*}` path-templates only. Affects `fzf`, `delta`, `less`,
  and `mdcat` (fzf/delta/mdcat move to `xdg.method: default`). Behavior is unchanged — the same
  variables are set to the same values, just declared in `env`.

- **Theme family→dialect mapping moved from hardcoded sidecar rules into an optional per-tool
  `themeMap`**, resolved by the new `Private/Resolve-DFThemeName.ps1` from each tool's own
  declaration (no central registry — governed by `docs/plugin-architecture.md`). The bare
  `catppuccin` alias is retired in favor of the canonical `catppuccin-mocha`; the shared
  `$DFConfig.Theme` is now canonical-name-only, while a per-tool `<Tool>Theme` still accepts a
  tool's own native names. All tool defaults remain canonical, so out-of-the-box rendering is
  unchanged. `delta` gains a new companion (`Tools/delta.ps1`) so `DELTA_FEATURES` tracks
  `$DFConfig.Theme`/`DeltaTheme` instead of being a static value.

## [0.5.0-preview] - 2026-07-23

### Added

- **Debounced picker previews:** the winget/scoop/choco preview panes are
  prefixed with a ~1s cmd sleep (`ping -n 2 127.0.0.1 >nul &`). fzf kills the
  running preview when the cursor moves, so scrolling quickly through a list no
  longer spawns `winget show` / `scoop info` / `choco info` for every skipped
  item — the preview only fetches once the cursor rests on an item.
- **Command-line prefill chords for the search pickers:** when PSReadLine is
  available, each companion binds a `Ctrl+G` chord — `Ctrl+G W` (winget),
  `Ctrl+G S` (scoop), `Ctrl+G C` (choco) — that reads the current line as the
  search query, opens the fuzzy picker, and drops the resulting install command
  onto the command line (editable; press Enter to run). Guarded, so it is a no-op
  when PSReadLine is not loaded.
- **scoop fuzzy pickers (`Tools/scoop.ps1`):** `Select-ScoopPackage` / `sins`,
  `Remove-ScoopPackage` / `srm`, `Invoke-ScoopUpdate` / `sup` — same picker set
  and keybindings as winget, with a `scoop info` preview. Search uses
  `scoop-search` when present (fast, matches names and binaries) and falls back
  to the [`Scoop`](https://www.powershellgallery.com/packages/Scoop) module's
  `Find-ScoopApp`; the installed list and install/uninstall/update actions use the
  Scoop module (object output — no `scoop list` table scraping). `scoop.json`
  `picker` is now `"custom"`.
- **choco tool + fuzzy pickers (`Tools/choco.json` + `Tools/choco.ps1`):**
  `Select-ChocoPackage` / `cins`, `Remove-ChocoPackage` / `crm`,
  `Invoke-ChocoUpdate` / `cup`, driven by choco's machine-readable `-r` output
  (pipe-delimited, not table-scraped). Install/uninstall/upgrade run through
  `gsudo` when it is available (elevation); otherwise the search picker's `Enter`
  returns the command to run elevated.
- **winget fuzzy pickers (`Tools/winget.ps1`):** rebuilt on the
  `Microsoft.WinGet.Client` module (object output — no CLI table scraping) with a
  live `winget show` preview pane.
  - `Select-WingetPackage` / `wins [query]` — search → install. `Enter` returns
    the `winget install …` command; `Alt-R` installs now; `Alt-I` installs the
    highlighted package in place while you keep browsing.
  - `Remove-WingetPackage` / `wrm` — browse installed → uninstall (`Alt-C`
    returns the command, `Alt-X` uninstalls in place). `-Source <src>` (e.g.
    `wrm -Source winget`) filters the list to one source, hiding ARP/registry-only
    entries.
  - `Invoke-WingetUpdate` / `wup` — browse upgradable packages, multi-select to
    update (`Tab` marks, `Alt-A` runs `winget upgrade --all`). New picker.
  - The pickers warn and no-op if `Microsoft.WinGet.Client` is not installed.
- **`Invoke-DFPicker` keybinding support:** new `-Expect` (fzf `--expect`
  multi-key mode; returns a `{ Key; Selected }` object so callers branch on the
  pressed key), `-Bind` (one `--bind` per spec, for act-in-place `execute(...)`
  bindings), and `-FzfArgs` (verbatim passthrough). All backward-compatible —
  existing callers and the declarative picker generator are unaffected.

## [0.4.0-preview] - 2026-07-20

### Added

- **fnm tool (`Tools/fnm.json` + `Tools/fnm.ps1`):** configures the Fast Node Manager,
  including its `--use-on-cd` per-directory version switching. fnm's generated hook
  rebinds `cd` to a wrapper that calls plain `Set-Location`, which would clobber
  zoxide's smart `cd`. The companion captures whatever owns `cd` before fnm loads
  (`$global:cdBeforeFnm`) and re-points fnm's `Set-LocationWithFnm` back through it, so
  a single `cd` performs zoxide's jump **and** fnm's Node switch; it forwards `@args`
  (not fnm's single `$path`) so zoxide's multi-keyword queries survive. `fnm.json`
  declares `"dependsOn": ["zoxide"]` so `Register-DFTool` topo-sorts zoxide first; with
  zoxide absent it falls back to `Set-Location` and fnm still works standalone. XDG:
  `FNM_DIR` points at `${XDG_DATA_HOME}/fnm`. The dependency on fnm's and zoxide's
  internals is catalogued in `docs/external-dependencies.md`.
- **`Get-DFCommandConflict`:** reports DotForge commands that Coreutils for Windows
  shadows before PowerShell can resolve them. Coreutils installs a
  `PSConsoleHostReadLine` hook that rewrites matching command names to `<name>.cmd`
  above command resolution, so affected aliases (`cat`, `touch`, `env`, `paste`) never
  run — while `Get-Command` still reports DotForge's version, making the failure
  invisible to normal probing. `Register-DFTool` now emits one consolidated warning
  listing the affected commands and the exact `coreutils-manager disable` line.
  Resolving the conflict needs elevation and is a policy choice, so DotForge only ever
  prints the command; it never elevates or writes to the registry. Suppress per-command
  with `$DFConfig.IgnoreConflicts`, or entirely with `$DFConfig.SkipConflictCheck`.
  The check reads the same set the hook itself consults, so it costs nothing when
  coreutils is absent and correctly reports no conflict in hosts where the hook never
  loads (it is injected into the ConsoleHost profile only, so the VS Code terminal is
  unaffected).
- **`docs/external-dependencies.md`:** catalogues every undocumented internal DotForge
  relies on in the tools it configures — coreutils' `$__COREUTILS__` variable, its
  section-marker GUID and generated code shape, its profile load order and per-host
  injection, its synthesized `la`; PSReadLine's suppression of `Colors` in non-VT
  terminals; zoxide's prompt hooking and re-hook guard — plus documented-but-load-bearing
  assumptions. Each entry records what breaks if it changes and how DotForge degrades.
  Undocumented dependencies degrade silently; they never fail.
- **Coreutils collision tripwire (`tests/Coreutils.Conflicts.Tests.ps1`):** fails the suite
  when a new DotForge alias collides with a coreutils utility, so contributors without
  coreutils installed find out at dev time rather than shipping a command that silently
  cannot run. Accepted collisions are listed with reasons; the fixture records the
  coreutils version it was captured from.
- **`carapace` tool record:** registers native argument completers for ~519 commands,
  including `eza`, `bat`, `fd`, `rg`, `npm`, `gh`, `glow`, `procs`, `rustup`, `chezmoi`,
  and `winget`. Composes with PSFzf, which owns the Tab key and routes through
  `TabExpansion2`.
- **Bundled carapace spec for `scoop`.** Carapace ships no scoop completer, so
  `scoop <TAB>` fell through to filesystem completion (offering `.\` and directory
  names). `Tools/carapace/specs/scoop.yaml` supplies static subcommand and flag
  completion; `Tools/carapace.ps1` deploys bundled specs into
  `$XDG_CONFIG_HOME/carapace/specs/`, which carapace auto-loads. Deployed copies are
  refreshed only when the bundled content changes.
- **Package-universe Phase C (tool merge)** — `build/Build-DFPackageUniverseTools.ps1` flattens Phase B clusters and singletons into a master `tools` table (one row per real-world tool across the whole corpus, lossless via a `tool_packages` child), with per-field priority picks (winget > choco > scoop) and provenance, a license single-answer conflict flag, a `tool_tags` union, and first-pass `tool_categories` from a committed `data/package-universe-categories.jsonc` rule file. Build-only; no public module surface change.

### Fixed

- **`docker <TAB>` emitted raw ANSI escape sequences through the PSFzf picker.**
  Carapace styles completion `ListItemText` with colour escapes whenever it is
  attached to a console (invisible when stdout is redirected, so headless tests never
  saw it). PSFzf ran `fzf` without `--ansi`, so the escapes rendered literally. The
  completion-stack resolver now adds `--ansi` to `FZF_DEFAULT_OPTS` — a documented fzf
  environment variable, not a PSFzf internal — whenever PSFzf and Carapace are both
  registered. The inserted text stays clean because it comes from `CompletionText`,
  which Carapace never styles. The merge is idempotent and preserves existing options.
- **A fuzzy-picked Carapace completion was inserted quoted (`docker "build "`).**
  Carapace appends a trailing space to each `CompletionText`, and PSFzf quotes any
  completion containing a space. When PSFzf owns Tab (Native mode + PSFzf available),
  `Tools/carapace.ps1` now trims that trailing space from Carapace's generated
  completer, so the picked value lands unquoted (`docker build `); PSFzf re-adds the
  single trailing space. The space is preserved when PSFzf is not in play, where
  `MenuComplete` needs it for subcommand chaining. Catalogued in
  `docs/external-dependencies.md`.
- **The inshellisense Carapace bridge never activated.** `Tools/carapace.ps1` checks
  for the `is` executable before merging it into `CARAPACE_BRIDGES`, but Carapace
  sorted ahead of fnm, so `is` was not yet on PATH and the check always failed.
  `Tools/carapace.json` now declares `"dependsOn": ["fnm"]`, so `Register-DFTool`
  configures fnm (which puts the Node-hosted `is` on PATH) before Carapace runs. With
  fnm absent the dependency is skipped and Carapace still registers normally.
- **Eleven tools advertised fzf pickers that did not exist.** `Register-DFTool` only
  builds a picker from a declarative object, so `"picker": "custom"` without a sidecar
  that actually builds one did nothing at all — no error, no warning, no picker.
  `gh`, `jq`, `glow`, `docker`, `rustup`, `npm`, `uv`, `chezmoi`, `bitwarden`, `scoop`
  and `gsudo` were affected; `scoop` had a sidecar holding only the scoop-search hook.
  The field also under-reported: `psreadline` declared `null` while its sidecar builds
  the `fprl` picker. Records now match reality, and
  `tests/Tools.PickerDeclaration.Tests.ps1` fails the suite in both directions. The
  unported pickers are tracked in the fold-in spec.
- **`eza` aliases dropped their path argument.** `--icons` and `--hyperlink` take an
  optional value, and a trailing bare `--hyperlink` consumed the caller's path, so
  `ll .` failed with `invalid value '.' for '--hyperlink [<WHEN>]'`. All four aliases
  now bind values explicitly (`--icons=auto`, `--hyperlink=auto`).
- **`fzf` and `delta` configuration restored** to `Tools/fzf.json` and
  `Tools/delta.json` (`FZF_DEFAULT_OPTS` and friends; `GIT_PAGER`, `DELTA_FEATURES`).

- **`Find-DFPackage` (`trifle`):** fast multi-catalog tool lookup. Given a command
  name or keywords, searches scoop, winget, choco, npm, PyPI, crates.io, and
  PSGallery and renders a merged info card (single confident match) or match
  table (keyword search): description, installed status + owning catalog(s),
  per-catalog availability and latest versions, homepage, license, last-updated,
  and per-source cache age. Piped/redirected output (or `-AsObject`) emits raw
  `DotForge.ToolInfo` objects with no ANSI. Cross-catalog identities unify via
  the `packages` blocks in `Tools/*.json` (e.g. scoop `ripgrep` and winget
  `BurntSushi.ripgrep.MSVC` render as one row), and commands found on PATH but
  unclaimed by any catalog report `InstalledVia PATH`. Results order by match
  quality (exact id → exact name/moniker → keyword; installed tools win ties),
  and long first-run work (index builds, live fetches) reports status via the
  progress stream — never polluting piped output.
- **Speed architecture:** cache-first under `$XDG_CACHE_HOME/dotforge/catalogs/`.
  Scoop buckets are parsed directly from disk into a fingerprinted index (bucket
  git HEADs); the winget catalog is queried directly from the CLI's own SQLite
  `index.db` via a zero-dependency `winsqlite3.dll` P/Invoke (extracted from
  `source.msix`, keyed on its mtime+size, with a cached `winget search` CLI-parse
  fallback when the schema is unreadable); web catalogs use per-query TTL caches
  (24h; 72h for choco). Stale entries are served instantly while a background
  ThreadJob re-warms them. A warm query answers in ~200 ms across all seven
  catalogs.
- **`Update-DFPackageCache`:** refresh-only entry point designed for Task
  Scheduler — rebuilds snapshot indexes, refreshes the unified installed-package
  snapshot, and re-warms recently seen queries plus installed tool names.
  All cache writes are atomic renames, so a scheduled refresh is safe alongside
  an interactive session. Note: winget only refreshes its own `source.msix`
  when winget runs, so the recommended scheduled action prepends
  `winget source update` (documented in README, the example profile, and the
  cmdlet help) — otherwise the winget index ages silently on machines that
  rarely invoke winget.
- **`Select-DFPackage` (`ftrifle`):** fzf browser over every locally cached
  package (scoop + winget indexes, cached web queries, installed snapshot);
  Enter renders the trifle info card.
- **`trifle` detail view:** a confident single match (exact id or exact
  name/moniker) now renders a richer detail card instead of
  the summary card — every catalog (scoop, winget, choco, npm, PyPI,
  crates.io, PSGallery) contributes a `Detail` hook (manifest notes, dist-tags,
  resolved GitHub metadata, etc.). Qualified `source:id` queries (e.g. `trifle
  winget:Zed.Zed`) bypass keyword ranking and always resolve to that one
  package's detail card. `-All` forces the full match table even on an exact
  hit, and its table gains an `Id` column with values usable directly as a
  qualified query. `-Readme` fetches and pages the package's readme (npm
  registry, GitHub, or PyPI long description); `-GitInfo` resolves the GitHub
  repo and adds stars/latest release/activity, using `gh` when installed and
  authenticated and falling back to the anonymous GitHub REST API otherwise.
  `ftrifle <query>` live-searches and pre-renders instant preview cards for
  fzf's preview pane, with Enter re-entering `trifle` via the qualified id for
  the full detail card. `Update-DFPackageCache` now also re-warms every cached
  detail entry (the files under each provider's `details/` cache ARE the
  re-warm list) so detail lookups stay warm alongside search results.
- **trifle discovery (`-Category`/`-WorksWith`):** a curated, offline taxonomy
  (~70 well-known CLI tools, function + works-with facets) ships with the
  module in `data/tool-categories.json`. `trifle -Category <c> [-WorksWith <w>]`
  facet-searches the seed database and resolves every match through the same
  live catalog search-and-merge path as an ordinary query — installed state
  and versions are never a stale snapshot. `Get-DFCategoryList` (`tcats`)
  lists the valid vocabulary with live tool counts. The detail card gains
  `Category`/`Related`/`Alt to` lines for any package in the seed database.
  `ftrifle -Categories` browses the vocabulary interactively. `Update-DFCategoryDb`
  refreshes the database independently of module releases (opt-in only,
  never run implicitly). Built and regenerated via `build/Build-DFCategoryDb.ps1`
  from hand-authored `build/categories/*.jsonc` fragments.

### Fixed

- **trifle cross-catalog identity fix:** `Find-DFPackage`/`ftrifle` no longer
  merge two different catalogs' packages into one row on a bare name match.
  A new shipped, offline-verified tool-identity guide
  (`data/tool-identities.json`, built from `Tools/*.json`'s existing curated
  mappings via automated GitHub-repo and homepage-match verification, see
  `build/Build-DFToolIdentities.ps1`) supplements the existing live
  `Tools/*.json` identity mapping. Two catalog hits merge only when a
  genuine identity link says they're the same tool; anything else renders
  as separate rows — this fixes `trifle zed` wrongly combining the winget
  Zed editor with choco's unrelated `zed` package. `Update-DFToolIdentityGuide`
  refreshes the guide independently of module releases (opt-in only, never
  run implicitly).

## [0.3.0-preview] - 2026-06-20

### Added

- **`New-DFUuid` (`uuidgen`):** generates a version-4 UUID. Default output is lowercase,
  hyphenated, and unbraced (Unix-style, matching the Windows SDK `uuidgen` default). The
  `-UpperCase`, `-NoHyphens`, and `-Braces` switches are independent and combine freely —
  reaching all eight format variants, including the registry/COM form via `-UpperCase
  -Braces` (`{F47AC10B-...}`). `-Sdk` is a named preset (in its own parameter set, so it
  cannot be combined with the formatting switches) for the Windows SDK `uuidgen` default
  format. The `uuidgen` alias is unconditional and deliberately shadows any native
  `uuidgen` so output is identical on every platform.

### Changed

- **`Get-DFEnv` (`env`) colorized output:** KEY=VALUE lines now render with a bold-cyan
  variable name, a bold-yellow `=` divider, and a faint (theme-adaptive) value, gated on
  `$Env:NO_COLOR` / VT support. Color is suppressed automatically when output is piped or
  redirected (`env | Where-Object`, `env > out.txt`) so downstream string matching and
  captured files stay free of ANSI escapes. Backed by new private `Test-DFOutputPiped`
  (a mockable pipe/redirect detection seam using `PipelinePosition`/`PipelineLength` and
  `[Console]::IsOutputRedirected`).

## [0.2.0-preview] - 2026-06-12

### Added

- **`Show-DFCliHelp` (`clh`) + `Show-DFCliHelpPaged` (`clhp`):** colorized help for external
  CLI tools (git, eza, docker, ...). Auto-detects the help flag — tries `--help`, `-help`,
  `-?`, `help`, `-h` (in that order; `-h` last because it collides with real flags), accepts
  the first whose output looks like help and is not an unknown-option error, and caches the
  winner per command in `$XDG_CACHE_HOME/dotforge/cli-help-flags.json` (`-Force` re-detects).
  Colorizes like `hm` — bold-yellow section headers, faint tint on option flags — gated on
  `$Env:NO_COLOR` / VT support. `clhp` routes the result through `Invoke-DFWithPager`. Backed
  by private `Format-DFCliHelpText` (pure colorizer), `Resolve-DFCliHelpFlag` (detection +
  cache), and `Invoke-DFCommandCapture` (mockable command-execution seam).
- `New-DFShim [[-Target] <path>] [-Name] [-ShimsPath] [-Force]` — creates a `.cmd` shim in `$HOME\.local\bin` (or `$DFConfig['ShimsPath']`) that forwards invocations to a target executable, first `cd`-ing to the executable's own directory. `-Target` is positional (`New-DFShim C:\tools\grep\grep.exe`); shim name derived from target basename when `-Name` is omitted. Accepts a DotForge tool name via `-Name` for DB lookup when `-Target` is not given. Warns if the shims directory is not on `$PATH`.
- **General Helpers layer (Phase 5):** 19 functions across 7 helper files
  - **Pager:** `Invoke-DFWithPager` (`pg`) — pipes output through `$Env:Pager`
  - **Help & Discovery:** `Invoke-DFHelp` (`hm`), `Select-DFCommand` (`fcmd`), `Select-DFVerb` (`fverb`), `Select-DFModule` (`fmod`), `Select-DFHelpTopic` (`fh`) — fzf-powered help browsing with ANSI header colorization
  - **Navigation:** `Set-DFLocationUp` (`up`), `New-DFDirectoryAndSet` (`mkcd`), `Select-DFLocation` (`fcd`)
  - **File System:** `New-DFFile` (`touch`), `Get-DFWhich` (`which`), `Open-DFItem` (`open`)
  - **Process:** `Select-DFProcess` (`fps`), `Get-DFTopProcess` (`top`)
  - **Environment & Profile:** `Get-DFPath` (`path`), `Select-DFEnvVar` (`fenv`), `Edit-DFProfile` (`ep`), `Invoke-DFProfileReload` (`reload`)
  - **Clipboard:** `Copy-DFToClipboard` (`copy`), `Get-DFFromClipboard` (`paste`)
- **gsudo tool record:** `sudo` alias (direct gsudo alias) and `please` function — re-runs the last
  history entry in an elevated context via `gsudo ([scriptblock]::Create(...))`, preserving pipes,
  semicolons, and compound expressions
- **psreadline tool record with bundled themes:** Default settings record plus 3 bundled PSReadLine
  themes (dark, light, catppuccin-mocha) for syntax highlighting configuration
- **psreadline companion (`psreadline.ps1`):** Applies settings from tool JSON, registers
  `Invoke-DFApplyPSReadLineTheme` (XDG user dir → bundled theme lookup with VT true-color output),
  `Select-PSReadLineTheme` (`fprl`) fuzzy theme picker, and sets initial theme from
  `$DFConfig['PSReadLineTheme']` (defaults to `dark`). Theme colors stored in
  `$global:DFPSReadLineColors` for testability in non-VT environments.
- **oh-my-posh companion: OMP init moved into `oh-my-posh.ps1`** — conditionally imports posh-git
  and sets `POSH_GIT_ENABLED` before OMP starts; resolves theme config via `$Env:POSH_THEME` then
  XDG auto-discovery of `*.omp.*` in `$XDG_CONFIG_HOME/oh-my-posh/` (warns when multiple found,
  uses first alphabetically; warns and skips when none found). Removes the need for a manual OMP
  init block in `$profile`.

### Fixed

- **zoxide companion:** removed duplicate `zoxide init` call that defaulted to `--hook prompt` and
  conflicted with oh-my-posh's prompt wrapper (the actual conflict source); uses `--hook pwd`
  (calls `zoxide add` only on actual directory changes, not every prompt render). Keeps `--cmd cd`,
  so `cd`/`cdi` route through zoxide — zoxide emits `Set-Alias -Name cd -Option AllScope -Force`,
  replacing the built-in `cd` alias in place (alias-replaces-alias; no function-shadowing). The
  underlying `Set-Location` is untouched, so scripts calling it directly are unaffected.
- **arg-bearing aliases shadowed by built-in aliases:** `Register-DFTool` now removes any colliding
  global alias before defining a wrapper function (e.g. `ls` -> `eza --icons ...`). PowerShell
  resolves `Alias > Function`, so the built-in `ls`/`cd`/`cp`/... aliases previously shadowed the
  generated wrapper. `Remove-Item Alias:\<name> -Force` clears ReadOnly built-ins too.

### Changed

- `Register-DFTool`: respects `dependsOn` in tool JSON — tools are topologically sorted before
  registration so declared dependencies are always configured first (e.g. psreadline before PSFzf)
- `Register-DFTool`: sets `$DFCurrentTool` to the tool's parsed JSON object in the local scope
  before dot-sourcing its companion `.ps1`; cleared with `Remove-Variable` immediately after.
  Companions can read `$DFCurrentTool` directly to access their tool's metadata.
- `Ensure-DFDir` renamed to `New-DFDirectory` — approved PowerShell verb (`Ensure` is not in `Get-Verb`)
- `zoxide` picker alias renamed from `fcd` to `fzo` — `fcd` now cleanly belongs to `Select-DFLocation`
- `Register-DFTool`: `-Name` and `-All` are now mutually exclusive parameter sets
- **Selective registration ordering:** `oh-my-posh` must be registered before `zoxide` — zoxide's
  `--hook pwd` wraps `function:prompt`, so OMP must own the prompt first. `Register-DFTool -All`
  handles this automatically (alphabetical order); selective profiles must register oh-my-posh
  explicitly before zoxide. Example `03-selective.ps1` updated to reflect this.

### Removed

- `Get-DFCachedCompletion` — internal caching absorbed into `Get-DFHelpTopicList`
- `Update-DFCompletions` — removed

## [0.1.0] — 2026-05-07

### Added

- **Core primitives:** `Add-DFToPath` (normalized PATH dedup), `New-DFDirectory` (idempotent
  directory creation), `Invoke-DFPicker` (generalized fzf picker), `Get-DFCachedCompletion`
  (mtime-based completion caching)
- **Tool registry:** `Import-DFToolDb` (JSON DB loader), `Get-DFTool`, `Find-DFTool`
- **Configuration:** `Register-DFTool` — applies XDG env vars, static/dynamic completions,
  aliases, declarative fzf pickers, companion .ps1 dot-sourcing; supports `type = "module"`
- **Installation:** `Install-DFTool` (scoop / winget / choco / psresource),
  `Initialize-DFEnvironment`
- **Completions:** `Update-DFCompletions` — on-demand completion cache refresh
- **Tool records:** 30 JSON records covering file tools, dev tools, pagers, package managers,
  Python, Rust, Node, dotfiles, security, and PowerShell module tools
  (posh-git, PSFzf, Terminal-Icons, oh-my-posh)
- **`$DFConfig`** user configuration hashtable (`SkipTools`, `PackageManagerOrder`)
- **PS module tool type:** `type = "module"` in tool JSON
