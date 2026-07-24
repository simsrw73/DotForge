# Tool Acquisition Specification Audit

**Scope:** Source audit of the current `Tools/*.json` records, sidecars, and
registration infrastructure against `ToolAcquisitionSpec.md`.

**Method:** This document records repository observations and the implementation
specification they imply. It does **not** assert that a third-party tool honors
an XDG variable, config file, flag, theme, or completion path: those claims
require the author-time conformance probes required by the standard.

## Executive conclusion

`ToolAcquisitionSpec.md` is a strong target, but its conformance machinery is
not implemented. Therefore none of the 36 shipped tool integrations can yet be
considered conformant under the standard: there is no conformance harness, no
versioned machine-readable ledger, and no validation tying records or sidecars
to conformance evidence.

The existing registry is a useful baseline:

- 19 records use `xdg.method: env`; 17 use `default`.
- No record uses `config`, `wrapper`, or `manual`.
- Package-manager records already use `packages: {}` and `picker: "custom"`.
- `choco` depends on `gsudo` and routes elevation through the configured `sudo`
  alias, which matches the package-manager convention.
- `psreadline.json` is the only record without an explicit `packages` property.

## Platform-level gaps

### 1. Add conformance infrastructure

Create `build/Test-DFToolConformance.ps1`, `data/tool-conformance.json`, and
their Pester/schema tests. The harness must be author-time only, strict-mode,
isolated from ambient user state, and injectable for tests. It must:

1. run a versioned claim for each integrated behavior;
2. record `pass`, `fail`, or `manual`, with evidence and re-test instructions
   for manual verdicts;
3. generate an upstream-issue-ready report for failures; and
4. find sidecar adapter comments that reference claims changed from `fail` to
   `pass`.

No runtime code may invoke the harness or probe a real external tool.

### 2. Clarify the `xdg` model

The current `xdg` object is used both for XDG storage and for general session
settings. For example, fzf stores colour/layout flags there and delta stores
`GIT_PAGER` and a theme feature there. That conflicts with the standard's
definition of `xdg` as an XDG-conformance declaration.

Add a separate declarative environment/settings channel for non-XDG variables.
Reserve `xdg` for config, data, cache, and state placement plus the mechanism
that makes the tool honor those locations. Move fzf and delta's non-XDG values
to the new channel. Keep the standard's explicit `LESS` exception only if it is
deliberately retained and documented as an exception.

### 3. Add explicit default-tool roles

Do not derive default-tool winners directly from
`data/tool-categories.json`'s `function` field. That field is intentionally
broad and multi-valued: `file-management`, for example, includes eza, broot,
and fd even though only eza is a listing replacement.

Add integration-specific role metadata, such as `listing`, `pager`, and
`markdown-renderer`, and a central role-to-contested-alias definition. Then
make `Register-DFTool` resolve `$DFConfig.Defaults` before registering aliases:

- validate that the chosen tool belongs to the requested role;
- give contested aliases only to the winner;
- skip only genuine role-equivalent losers; and
- preserve non-contested integrations such as fd's picker.

This is a prerequisite for making eza's `ls`, `ll`, `la`, and `tree` aliases
conditional.

### 4. Centralize themes

Add `data/theme-aliases.json` and `Private/Get-DFConfiguredTheme.ps1`. The
resolver must accept a canonical family name, a shared alias, or a tool-native
name, then return the native theme name for the target tool. Sidecars may
validate and apply the result but must not contain their own family-to-dialect
mapping.

Initial candidates requiring a theme decision are bat, delta, fzf, glow,
lazygit, less, micro, oh-my-posh, procs, psreadline, and winfetch. A decision
may be "not configurable"; it still requires a conformance record.

### 5. Resolve alias ownership

The standard requires tool aliases in `DotForge.psd1`, but tool and sidecar
aliases are currently created globally while the manifest's `AliasesToExport`
does not own them. The repository documents this as a known limitation.

Choose one model before enforcing manifest entries:

1. refactor aliases to module-owned definitions and export them; or
2. amend the standard to define global session aliases as registry-owned,
   validated from tool records and sidecars rather than the manifest.

Adding names to the manifest alone would not fix ownership.

## Tool-by-tool disposition

| Tools | Required work |
|---|---|
| bat, chezmoi, curl, docker, glow, lazygit, micro, uv, wget, winfetch | Probe the declared environment variable and actual config content; record versioned claims. Ensure parent directories and config creation are explicit. Bat also needs a pager/theme decision. |
| broot | Re-probe whether it is truly XDG-native. `full` plus `env` with no variables is contradictory; it should become `default` or a justified directory-only integration. |
| zoxide | Create the configured data directory, probe `_ZO_DATA_DIR`, and ledger-link the prompt-hook adapter. |
| npm | Probe npmrc and REPL-history behavior; create the data parent for `NODE_REPL_HISTORY`, not only the npm config directory. |
| less | Separate XDG paths from the `LESS` preference unless the documented exception remains; verify pager behavior and assign the pager role. |
| delta, fzf | Move non-XDG session settings out of `xdg.vars`; make default options and theme behavior explicit. |
| oh-my-posh, psreadline | Replace per-tool theme resolution with the shared resolver. Preserve pickers as a UI around the shared setting. Add `packages: {}` to psreadline. |
| eza | Move `ls`, `ll`, `la`, and `tree` behind the `listing` role winner. Retain the picker only with an explicit value justification. |
| fd, broot | Do not let the broad `file-management` category make either tool a loser when eza wins `listing`; give them independent roles. |
| ripgrep | Probe config behavior; make its editor action warn/no-op when `EDITOR` is unset, or provide a verified non-clobbering default. Ledger-link its custom picker. |
| fnm, carapace, scoop, gsudo | Preserve the sidecars, but annotate each workaround with a failed claim ID and add a matching conformance probe. Gsudo needs a PATH-resolution claim for the Windows `sudo` collision. |
| choco, scoop, winget | Their package-manager conventions are already aligned. Reclassify XDG handling after probes: `none/default` is not a valid final rung under the current standard wording. |
| bitwarden, eza, fd, gh, jq, procs, rustup, Terminal-Icons | Establish whether each is XDG-native, configurable with an adapter, or genuinely `manual`; replace unsupported `none/default` declarations. |
| inshellisense, PSFzf, posh-git, psreadline | Record the completion/module integration decision and verify it does not conflict with the shared completion stack. |
| rustup | Reassess Cargo-bin PATH availability. The current tree has no `Tools/rustup.ps1` and no `CARGO_HOME` PATH integration. |
| All tools | Add a completion decision, picker justification, and conformance ledger entry, including when the decision is "nothing to do." |

## Required changes to `Register-DFTool`

`Public/Register-DFTool.ps1` already implements much of the XDG ladder. Extend
it only after the new record fields are defined and tested:

1. apply the new non-XDG environment/settings field separately from XDG;
2. implement role/default resolution before aliases are installed;
3. continue to create config files only when absent and to degrade to warnings
   or no-ops; and
4. keep conformance work completely out of runtime registration.

The existing `config`, `wrapper`, and `manual` branches are useful foundations,
but currently have no shipped records exercising them.

## Completion, picker, and documentation requirements

For every tool record, explicitly record one completion decision:

1. already covered by carapace and inshellisense;
2. tool-provided and non-conflicting; or
3. a DotForge carapace spec is required.

Existing custom pickers for choco, scoop, winget, ripgrep, procs, oh-my-posh,
posh-git, and psreadline must each retain a concise value justification.
Declarative pickers for eza, fd, and zoxide need the same. A null picker is a
valid, intentional decision.

Every adapter depending on external generated code or internal behavior must
also gain a ledger claim reference in the sidecar comment. Continue documenting
the human-facing degradation behavior in `docs/external-dependencies.md`, with
cross-references to ledger claim IDs.

## Specification decisions needed before implementation

1. **`none/default` semantics:** The standard says `default` means
   XDG-native/full, but many records use `none/default`. Require `manual` for a
   non-XDG tool unless a probe demonstrates another ladder rung.
2. **Role source:** Add explicit integration roles rather than overloading the
   taxonomy's `function` data.
3. **Alias ownership:** Select module-owned aliases or registry-owned global
   aliases before requiring manifest exports.
4. **XDG exception boundary:** Decide whether plain non-path settings such as
   `LESS` remain allowed in `xdg.vars`; if so, state why fzf and delta do or do
   not belong there.

## Acceptance criteria

The implementation is complete only when:

- every shipped tool has a versioned ledger record;
- every applied configuration has a `pass` or `manual` verdict;
- every sidecar adapter cites a failing claim ID;
- every contested alias has a role winner;
- all runtime registration remains probe-free and non-terminating; and
- Pester validates the ledger, record schema, role model, theme mapping, and
  shipped-data consistency.
