# Declarative tool effects — design

Date: 2026-10-12. Resolves T-21; also closes T-29 and T-28, and the env-override half of T-37.

## Goal

Themes, executable wrappers and environment-variable precedence are hand-written in tool
sidecars today: 9 sidecars repeat the theme chain, 2 hand-build an executable wrapper, and each
env writer picks its own precedence (`xdg.vars` never overwrites, `env` always overwrites, moor
writes only when empty, role env keeps a ledger). Replace that with declarative tool-JSON fields
the core applies with **one set of rules**, the way `setup.seed` already covers config files.

Success:

- bat, mdcat, moor and glow carry no theme or wrapper code (bat's and moor's sidecars are deleted).
- Every DotForge env write follows one precedence rule, and a value DotForge declined to
  overwrite is visible in `Get-DFToolStatus`.
- Code that is genuinely tool-specific (theme-file converters for fzf, psreadline and vivid;
  pickers; completions; delta's bundled theme deploy; fastfetch's banner placeholders) stays in
  sidecars, but calls the shared core helpers instead of re-implementing them.

Non-goals: themes set inside a tool's own config file (bat's config, which `BAT_THEME` outranks)
stay with T-37 as per-tool follow-up. Live switching for code-themed tools keeps their own
`Select-*Theme` commands.

The plugin invariant holds throughout: the new fields are optional extension points the core
reads when present and no-ops when absent; no core code names a tool.

## Phase 1 — One env precedence rule

### `Set-DFEnv`

`Private/Set-DFRoleEnv.ps1` becomes `Private/Set-DFEnv.ps1`. `Get-DFRoleEnvState` becomes
`Get-DFEnvState` (same shape: a session `Written` map, name → value DotForge last wrote).

```powershell
Set-DFEnv -Name <var> -Value <expanded> -Source <tool or role label> [-Explicit] [-Tool <name>]
```

Rule, in order:

1. Current value `-ceq` new value → record it in `Written`, done.
2. Current value empty, or `-ceq Written[Name]` (DotForge wrote it) → write, record.
3. Otherwise the value was **set outside DotForge**:
   - without `-Explicit`: keep it; `Write-Verbose`; return a *kept* outcome (below).
   - with `-Explicit`: overwrite, and warn once per session per variable with both values
     (today's `Defaults` warning, generalized: the user's config contradicts their environment).

`Set-DFEnv` returns `$null` when it wrote or no-op'd, or a `[pscustomobject]@{ Name; Kept; Wanted; Source }`
when it kept an outside value. The caller adds it to the tool's status (see *Status detail*).

Explicit means the user named the choice in DotForge's config:

| Writer | `-Explicit` when |
|---|---|
| role block `env` | the winner came from `Defaults` (today's `-Reason Defaults`) |
| `theme.env` | the theme came from the per-tool key (`BatTheme`), not `Theme` or the JSON default |
| `xdg.vars`, `env` | never |

### Callers

- `Set-DFToolXdgConfig` (`xdg.vars`): replaces its own "already set → skip" check. Behavior
  change: a re-registration may now update a path DotForge itself wrote earlier.
- `Invoke-DFToolRegistration` (`env`): replaces the raw `SetEnvironmentVariable`. Behavior
  change: `BAT_THEME`, `MDCAT_THEME`, `LESS`, `FZF_*` set outside DotForge are now kept.
- Role env: `Set-DFRoleEnv` call sites switch to `Set-DFEnv`; `Get-DFRole`'s "source" column reads
  `Get-DFEnvState`.
- Sidecars that write env themselves (fzf's `--color` append, vivid's `LS_COLORS`) call
  `Set-DFEnv` too, so their writes enter the ledger.

fzf's colors: `Invoke-DFApplyFzfTheme` appends `--color=…` to the current `FZF_DEFAULT_OPTS`
whether DotForge or the user owns it (fzf applies the last `--color`), and writes the result
through `Set-DFEnv -Explicit`, because an explicit theme apply is a user action.

No `force` flag: no current env entry needs one, and `-Explicit` covers deliberate overrides.

### Status detail (closes T-28)

A kept value is a fourth producer of `DotForge.ToolStatus.Detail`, so T-28's condition is met:
`Detail` becomes a `string[]` built by appending, rendered once (joined with `; `) by the status
formatter and the banner. `Add-DFRoleOutcomeStatus`, `Get-DFActivationBlocker` and
`Add-DFInstallHint` append instead of joining. The kept-env line reads
`BAT_THEME kept as set outside DotForge ('Dracula'); DotForge wanted 'Catppuccin Mocha'`.

## Phase 2 — Declarative theme

### Schema

```jsonc
"theme": {
  "key":      "MdcatTheme",          // required: per-tool config key (must be in $script:DFConfigKeys)
  "default":  "catppuccin-mocha",    // optional: used when neither key nor Theme is set
  "map":      { "catppuccin-mocha": "Catppuccin Mocha" },   // optional: canonical -> native
  "files":    "glow",                // optional: resolve to a theme file (see below)
  "valid":    ["auto", "dark", "..."],  // optional: native names the tool accepts
  "fallback": "auto",                // optional: used (with a warning) when valid/files reject the name
  "env":      { "MDCAT_THEME": "{theme}" },  // optional: templates; {theme} and ${XDG_*} expand
  "command":  "Select-PSReadLineTheme" // optional: for a theme applied by sidecar code, the command
                                       //   that switches it live (Set-DFToolTheme points there)
}
```

Top-level `themeMap` stays accepted: the loader copies it into `theme.map` when `theme.map` is
absent (a user tool written before this change keeps working). In-repo tools move to `theme.map`;
the schema warns on `themeMap` alongside a `theme` block. `ConvertTo-DFToolRecord` normalizes
`theme` to `$null` or an object with every field present.

### `Get-DFToolTheme` (Private, captured by sidecars like `Resolve-DFThemeFile`)

```powershell
Get-DFToolTheme -Tool <record> [-Name <override>]
# -> [pscustomobject]@{ Name; Native; Value; Explicit }
```

1. **Name**: `-Name` if given (explicit); else `Get-DFConfig <key>` (explicit); else `Get-DFConfig Theme`;
   else `default`. `Explicit` is true for the first two.
2. **Native**: `Resolve-DFThemeName` with `theme.map`.
3. **Value**: when `files` is set, `Resolve-DFThemeFile -Tool <files> -Name <Native>
   -BundledDir Tools/<files>` (an absolute path, then `$XDG_CONFIG_HOME/<files>/themes/`, then
   bundled); a found file is the value. Otherwise, or when no file is found, the native name, if
   `valid` is absent or contains it. Otherwise warn
   `DotForge: <tool> theme '<Native>' not recognized — using '<fallback>'` and use `fallback`
   (or `$null` with no fallback, which skips `theme.env`).

A tool without `theme` returns `$null`. `Get-DFConfiguredTheme` is deleted (its only callers are
the migrated sidecars); `Resolve-DFThemeName` stays as the map step.

### Applying it

`Invoke-DFToolRegistration`, after `env` and before the companion: when `$Tool.theme` is set,
resolve it once, store it in session state (`$script:DFToolThemes[<tool>]`), and write each
`theme.env` entry through `Set-DFEnv -Explicit:$theme.Explicit`, `{theme}` replaced by `Value`.
The companion reads the result with `Get-DFToolTheme` (cached; no second warning).

### `Set-DFToolTheme` (Public, core)

```powershell
Set-DFToolTheme -Name glow -Theme dracula
```

Re-resolves with `-Name`, updates session state, re-applies `theme.env` (explicit) and returns
the resolved object. Wrappers read the session theme on every call, so the change is live. Errors
for a tool that isn't active or has no `theme` block. For a tool whose `theme.command` is set
(fzf, psreadline, vivid: themes applied by sidecar code), it errors naming that command; the
message comes from the record, never a tool-name switch.
Argument completion lists active tools with a `theme` block.

### Tool changes

| Tool | Result |
|---|---|
| bat | `theme { key BatTheme, default catppuccin-mocha, map, env BAT_THEME }`; `env.BAT_THEME` and `Tools/bat.ps1` deleted |
| mdcat | `theme { key MdcatTheme, valid [...], fallback auto, env MDCAT_THEME }`; sidecar keeps completions only |
| moor | `theme { key MoorTheme, default catppuccin-mocha, env { MOOR: "-style {theme} -quit-if-one-screen" } }`; `Tools/moor.ps1` deleted |
| delta | `theme { key DeltaTheme, default catppuccin-mocha, env { DELTA_FEATURES: "+{theme}" } }`; sidecar keeps the bundled-file deploy |
| glow | `theme { key GlowTheme, default catppuccin-mocha, files glow, valid [glow built-ins], fallback auto }` + wrapper (phase 3); `Resolve-DFGlowStyle` and `$global:DFGlowStyle` removed; `fgl` reads `Get-DFToolTheme` |
| fzf, psreadline, vivid | `theme { key, default, command }`; sidecars call `Get-DFToolTheme` instead of the two-call chain |
| mdv (setup script) | `theme { key MdvTheme, map, ... }`; `mdv.setup.ps1` calls `Get-DFToolTheme` |

Every config key above already exists in `$script:DFConfigKeys`; a test asserts each
`theme.key` is listed there.

## Phase 3 — Declarative executable wrapper

### Schema

```jsonc
"wrapper": {
  "args": [
    "-s", "{theme}",                                     // plain strings: always passed
    { "ifFile": "${XDG_CONFIG_HOME}/lsd/config.yaml",    // conditional group: passed when the
      "args": ["--config-file", "{file}"] }              //   expanded path is an existing file
  ]
}
```

Tokens: `{theme}` (the session theme's `Value`, read at call time), `{file}` (the group's
expanded `ifFile`), `{settings.<name>}` (a value from the tool's `settings`), `${XDG_*}`.
`{theme}` in a tool without `theme` is a schema error, and so is `{theme}` with a `theme` that has
`valid` or `files` but no `fallback`, so `{theme}` always has a value. Arguments
the user types follow the declared ones.

A `wrapper` block replaces `xdg.method: "wrapper"`'s meaning of "a companion handles it": the
method stays as the XDG classification, and the schema requires a `wrapper` block (or a
companion) for it.

### `New-DFToolWrapper` (Private, captured by sidecars)

```powershell
New-DFToolWrapper -Tool <record> [-OnOutput <scriptblock>]
```

Defines `function:global:<executable basename>` (`glow` for `glow.exe`) as a simple function:

- builds the declared arguments on each call (`{theme}` from session state, `ifFile` tested then);
- `$MyInvocation.ExpectingInput` → `$input | & <exe> @declared @args` (without it, piped input
  hangs: see glow's sidecar history);
- otherwise `& <exe> @declared @args`, or, with `-OnOutput`, passes the call's output, the
  declared arguments and `$MyInvocation` to the scriptblock and returns what it returns;
- calls the executable by its full name (`glow.exe`) so the wrapper never recurses;
- carries generated comment-based help: synopsis "Runs <name> with DotForge's arguments", the
  declared arguments listed in the description, one example. `tests/Docs.Help.Tests.ps1` checks
  generated wrappers too.

Registration calls `New-DFToolWrapper -Tool $Tool` before the companion when `$Tool.wrapper` is set,
unless `wrapper.custom` is true. `custom: true` means the companion calls
`New-DFToolWrapper -Tool $DFCurrentTool -OnOutput { ... }` itself (fastfetch); the declared `args`
are still the single source of the arguments. The schema rejects `custom` on a tool with no
companion.

Builtin safety: a wrapper's name is the executable basename. A test checks every declared
wrapper's name against a fresh session's cmdlets and aliases, so a wrapper never shadows a builtin
(`docs/builtin-safety-policy.md`).

### Tool changes

| Tool | Result |
|---|---|
| glow | `wrapper { args ["-s", "{theme}"] }`; wrapper code removed from the sidecar (picker stays) |
| fastfetch | `wrapper { custom: true, args [{ ifFile: "{settings.configPath}", args ["--config", "{file}"] }] }`; sidecar calls `New-DFToolWrapper -OnOutput` for the `@DF:` placeholders |
| lsd | `xdg.method` `manual` → `wrapper`; `wrapper { args [{ ifFile "${XDG_CONFIG_HOME}/lsd/config.yaml", args ["--config-file", "{file}"] }] }`; `xdg.native` lists lsd's own config locations. **Verify first** with a real probe (lsd's Windows default location, that `--config-file` on an existing file works); clean up any folder the probe creates |


## Error handling

- Unknown theme with `valid`/`files`: warn once, use `fallback`. With no `fallback` (allowed only
  when no wrapper uses `{theme}`), `Value` is `$null` and `theme.env` is skipped.
- `ifFile` that doesn't exist: group omitted silently (fastfetch, lsd today).
- `Set-DFEnv` never throws; a failed `SetEnvironmentVariable` is a warning.
- Schema errors (unknown `theme`/`wrapper` fields, `{theme}` without `theme`, `custom` without a
  companion) fail `Test-DFToolSchema` like any other field.

## Testing

- `tests/Set-DFEnv.Tests.ps1`: the four rule branches, `-Explicit` warning once, kept outcome
  object; replaces the precedence cases in the role-env tests (which keep their role-level ones).
- `tests/Get-DFToolTheme.Tests.ps1`: chain order and `Explicit`, map, files (user dir, bundled,
  absolute), valid/fallback warning, no `theme` → `$null`.
- `tests/New-DFToolWrapper.Tests.ps1`: declared args order, `ifFile` present/absent, piped input
  (a stub `.exe`-named function stands in), `-OnOutput`, theme read at call time after
  `Set-DFToolTheme`, generated help renders.
- Tool tests (bat, mdcat, moor, delta, glow, fastfetch, lsd) assert the JSON blocks and the
  effect (env value / wrapper args) through registration, replacing sidecar-specific tests.
- Status: `Detail` is an array; formatter output unchanged for the existing three producers.
- `ToolNative.Coverage`, `ToolRegistry`, `CoreBundle`, `Docs.Reference` regenerate as usual.

## Docs

- `docs/guide/writing-a-tool.md`: `theme` and `wrapper` field rows; the "read themes with…"
  guidance becomes "declare `theme`; call `Get-DFToolTheme` only for code-applied themes".
- `docs/guide/tools.md`: glow's live switch becomes `Set-DFToolTheme glow notty`; env precedence
  section (what DotForge leaves alone, where it says so).
- CLAUDE.md tool-schema section: `theme`, `wrapper`, `env` precedence; `themeMap` noted as legacy.
- CHANGELOG: `Resolve-DFGlowStyle` and `$global:DFGlowStyle` removed (use `Set-DFToolTheme`);
  `env`/`xdg.vars` values set outside DotForge are now kept.
- `docs/external-dependencies.md`: lsd entry for `--config-file` panicking on a missing path.

## Phases and commits

1. `Set-DFEnv` + callers + `Detail` as a list (Closes T-28).
2. `theme` block, `Get-DFToolTheme`, `Set-DFToolTheme`, tool migrations (Closes T-29's theme half).
3. `wrapper` block, `New-DFToolWrapper`, glow/fastfetch/lsd (Closes T-21, T-29). T-37 is reworded
   to its remaining config-file half.

Each phase ends green on `build/Test-DFFull.ps1` before the next starts.
