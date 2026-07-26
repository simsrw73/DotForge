# Builtin Safety Policy

**Status:** Normative policy. Applies to every alias or command name DotForge
creates — general-helper aliases and per-tool aliases alike.

## The rule

> **DotForge never overwrites a builtin PowerShell command or alias without
> explicit, well-thought-out reasoning, documented publicly.** Before shipping
> any new alias — a general-helper alias or a tool's declared alias in
> `Tools/*.json` — check it against `Get-Alias`/`Get-Command` for a builtin
> collision. If one exists, do not silently override it: pick a different name,
> or document the override's reasoning where a user will find it.

## Why: the `copy` incident

`Public/DFHelpers.Clipboard.ps1` originally bound the clipboard-copy helper to
`copy`, colliding with PowerShell's own builtin `copy` alias (→ `Copy-Item`,
`Options=AllScope`). This was done with `-Scope Global -Force -Option AllScope`
— deliberately replicating the builtin's all-scopes visibility, not an
oversight, but never surfaced as a considered, documented trade-off to the
user. It was also a genuine engineering obstacle: an `AllScope` alias cannot be
overridden outside global scope (verified empirically — the override fails with
"The AllScope option cannot be removed from the alias 'copy'" even with
`-Force`, unless `-Scope Global` is also specified), which blocked making the
alias genuinely module-owned (see `docs/plugin-architecture.md` and the
"alias ownership" workstream). The alias was renamed to `yank` — no builtin
collision, no scope workaround needed, and the module-ownership fix applies to
it exactly like every other general-helper alias.

The lesson: silently claiming a builtin's name is a cost paid twice — once by
the user (who loses `Copy-Item`'s shorthand without being told), and once by
the codebase (the override itself becomes an engineering constraint that blocks
other work later). Neither cost was worth paying for a name that had a free,
uncontested alternative.

## Applying it

- **Before adding any alias** (general-helper or per-tool), check
  `Get-Alias <name> -ErrorAction SilentlyContinue` and `Get-Command <name>
  -ErrorAction SilentlyContinue` for an existing binding.
- **No collision:** proceed normally.
- **Collision exists:** prefer a different, uncontested name. Only override a
  builtin when there is a specific, considered reason to — and when you do,
  document that reasoning in a place a user will actually see it (the
  function's help text, the README, or this file), not just a code comment.
- This check belongs in code review for any new tool onboarding (`Tools/*.json`
  aliases) and any new general-helper alias, alongside the existing
  plugin-architecture and conformance checks.

## Related, deferred work

A whitelist/blacklist mechanism giving users explicit control over which
aliases/functions DotForge binds (per-alias or per-tool) would let users decide
their own tolerance for global-namespace changes, rather than DotForge deciding
uniformly for everyone. See `TODO.md` — Priority 3 — for the shelved design
sketch.
