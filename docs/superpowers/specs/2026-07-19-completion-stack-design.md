# Completion Stack Integration Design

## Goal

Add inshellisense as a DotForge tool and make PowerShell completion resolve to
the strongest compatible experience available from PSReadLine, Carapace, PSFzf,
and inshellisense. Configuration must be safe on machines with any subset of
those tools and must not leave conflicting Tab bindings.

## User Configuration

Users configure the stack before importing/registering DotForge:

```powershell
$DFConfig = @{
    CompletionMode     = 'Native' # Native (default) or Inshellisense
    PSReadLineEditMode = 'Windows' # Windows (default) or Emacs
}
```

`Native` is the default. `Inshellisense` is an explicit terminal-session
takeover choice. Invalid values warn and use the documented defaults.

## Native Mode

PSReadLine provides editing and history prediction. When present, Carapace
registers argument completers. If inshellisense is also executable,
DotForge merges `inshellisense` into `CARAPACE_BRIDGES`, preserving existing
bridge entries case-insensitively and without duplicates. Carapace can then
use inshellisense as an additional completion source while retaining native
PowerShell completion flow.

PSFzf is an optional presentation layer. The final Tab binding is resolved
only after tool registration and after `PSReadLineEditMode` is applied:

| Available registered capability | Tab binding |
| --- | --- |
| PSFzf | `Invoke-FzfTabCompletion` |
| Carapace without PSFzf | PSReadLine `MenuComplete` |
| Neither | Do not alter PSReadLine's existing binding |

`MenuComplete` is necessary for styled Carapace results, especially when
PSReadLine uses Emacs mode. Setting an edit mode resets PSReadLine key
bindings, so the finalizer always applies the binding afterward.

## Inshellisense Mode

DotForge configures environment and non-keybinding tools, then starts
inshellisense last. It does not enable PSFzf's Tab handler. A guard prevents
starting an inshellisense session from inside an existing one. If the
inshellisense executable is unavailable, DotForge warns and falls back to
Native mode.

## Implementation Boundaries

Create an `inshellisense` tool record with installation and XDG metadata, plus
a companion for direct-mode startup. Add one focused private completion-stack
resolver, invoked after `Register-DFTool` has processed its tools. Move
PSFzf's direct Tab assignment into this resolver. Update the PSReadLine
companion to honor `PSReadLineEditMode` before the resolver binds Tab.

The resolver is responsible only for detecting the available completion tools,
merging `CARAPACE_BRIDGES`, selecting one Tab handler, and issuing concise
fallback warnings. Tool records and companions remain responsible for their
own installation, XDG, import, and initialization work.

## Tests and Documentation

Pester tests cover all resolver states: native Tab precedence, bridge merging,
case-insensitive de-duplication, missing-tool fallback, both edit modes,
invalid config, and inshellisense re-entry protection. Update README user
configuration and the external-dependencies guide with the compatibility
matrix, manual ordering guidance, and centralized Tab-binding contract.

## Scope

This change does not add an interactive setup prompt, monitor later manual
PSReadLine changes, or enable unverified Carapace bridge types. Users who
change PSReadLine edit mode after DotForge registration must restore the
matching Tab binding, as documented.
