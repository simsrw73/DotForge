# Profile-to-DotForge Fold-in Design

## Goal

Move reusable PowerShell and CLI configuration from the user's profile into
DotForge, while keeping personal, host-specific, and security-sensitive
settings in the profile. Remove profile setup that DotForge already owns.

## Scope

### DotForge

- `Initialize-DFEnvironment` adds `XDG_BIN_HOME` to the process PATH through
  `Add-DFToPath`, after it creates the XDG directories.
- Make ordering explicit: `zoxide` depends on `oh-my-posh`; `fnm` continues to
  depend on `zoxide`. `direnv` is independent because its generated PowerShell
  hook uses `LocationChangedAction`, while zoxide wraps `prompt` and owns `cd`.
- Add tool records and companions for `direnv`, `python`, `pipx`, and `gpg`.
- Extend `rustup` to configure `RUSTUP_HOME` and `CARGO_HOME`, and add
  `$CARGO_HOME/bin` to PATH.
- Add a `powershell` companion for interactive suggestion configuration:
  - If the `PSFeedbackProvider` experimental feature exists and is disabled,
    enable it for `CurrentUser` and state that a new session is required.
  - If the feature is absent, treat it as mainstream and make no configuration
    write (PowerShell 7.6+).
  - Import `Microsoft.WinGet.CommandNotFound` only when it is installed.
- Document that DotForge conditionally enables the feedback provider where it
  is still experimental and loads the WinGet command-not-found provider only
  when that module is present.

### Profile cleanup

- Import DotForge and run `Initialize-DFEnvironment` before profile modules
  that need XDG directories or `Add-DFToPath`.
- Remove direct Scoop, direnv, PSReadLine, Carapace, and completion setup that
  DotForge now owns.
- Remove `DockerCompletion`, `PowerType`, the direct feedback-provider block,
  and the WinGet command-not-found import.
- Remove helpers superseded by DotForge: local PATH helper, `touch`,
  environment/PATH display functions, profile reload, and multi-level `cd`
  helpers.
- Remove the obsolete, unloaded `PSReadline.ps1` and `PSReadLine-Theme.ps1`.
- Preserve personal configuration: editor choices, terminal detection, Bun and
  Pulsar locations, Claude settings and unsafe shortcut, module maintenance,
  developer shell, transcripts, and machine-specific integrations.
- Preserve the unloaded `cli_tools_config.ps1` staging/backlog file.

## Behavior and safety

- All registrations remain conditional on the tool or module being available.
- XDG directory and PATH setup is idempotent.
- Experimental-feature activation is current-user only and takes effect in a
  new PowerShell session; it is not attempted when the feature has become
  mainstream.
- DotForge does not install PowerToys, the WinGet command-not-found module, or
  any CLI tool as part of profile registration.

## Verification

- Add Pester coverage for XDG bin PATH setup, tool-record environment and PATH
  behavior, ordering, and all PowerShell feedback-provider branches.
- Validate tool schemas and run the affected Pester suites, then the complete
  suite.
- Start a clean PowerShell session against the revised profile and confirm
  registration completes without duplicate-hook or missing-command errors.
