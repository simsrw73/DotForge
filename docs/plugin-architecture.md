# DotForge Plugin Architecture — Core Invariant

**Status:** Normative architecture principle. Applies to every new core feature.

DotForge treats each tool as a **plugin**: the tool *declares* what the core
needs, and the core implements features by consuming that declaration. This
document states the invariant that keeps that boundary clean, so the codebase
stays extensible without turning the core into a growing switch statement.

## The invariant

> **Adding or updating a tool never modifies core logic.** A new core feature is
> an **optional declarative extension point** — a block in the tool's JSON or a
> documented sidecar hook. The core reads it **when present** and **no-ops when
> absent**. A tool that predates the feature keeps working unchanged; it simply
> doesn't participate until it declares the data.

This generalizes the existing house rule "undocumented dependencies must degrade
silently, never fail" (`CLAUDE.md`, `docs/external-dependencies.md`): *every*
core feature degrades to a no-op for a tool that hasn't opted in.

## What "core" and "plugin" mean

- **Core** = `Public/`, `Private/`, `DotForge.psm1`, and the generic registration
  path (`Register-DFTool`, `Import-DFToolDb`, `Initialize-DFEnvironment`). Core
  code is tool-agnostic: it knows about *fields and hooks*, never about specific
  tools.
- **Plugin** = a tool's own files: `Tools/<tool>.json` (declarative data) and the
  optional `Tools/<tool>.ps1` sidecar (behavior). Everything a tool needs the
  core to do is expressed here.

**A field the core interprets is fine; a tool *name* the core branches on is a
leak.** `switch ($tool.name) { 'fzf' { … } }` in core code is the thing this
invariant forbids.

## The three rules

1. **Declarative extension point.** A new feature adds an optional field (e.g.
   the top-level `env` block, or a per-tool `theme` map) that any tool may
   populate. The core applies it generically.
2. **Read-if-present, no-op-if-absent.** The core guards on the field's presence
   (`$tool.PSObject.Properties['x']?.Value`) and does nothing when it's missing.
   No tool is *required* to adopt a new feature.
3. **Cross-cutting queries resolve from data, not reflection.** When a feature
   needs a view across *all* tools (e.g. "which tool wins the `listing` role"),
   resolve it from the already-loaded tool DB, or from a **build-time-generated
   index** (the pattern `data/tool-categories.json` and `data/tool-identities.json`
   already use — a `build/` scanner reads `Tools/*` and emits a precomputed file).
   Never scan/reflect at profile-startup time to discover behavior.

## Why data + generated indexes, not a runtime plugin framework

Profile startup speed is a first-class constraint. The good news is the
architecture and the speed goal align rather than conflict:

- **Per-tool declaration is free** — the tool's JSON is already loaded during its
  own registration, so reading its `theme`/`env`/… block costs nothing extra. It
  is often *faster* than the alternative: a central registry file keyed by tool
  is one more file to load and one more thing to hand-maintain.
- **Cross-tool aggregation is paid once, at build time.** A generated index ships
  precomputed and loads as a single file at runtime — plugin-friendly (regenerate
  when a tool is added) *and* startup-cheap.
- **Runtime discovery/reflection is the thing to avoid.** It buys plugin purity
  at a real startup cost and is unnecessary here.

## The realistic boundary

Zero core-touch is not fully attainable, and chasing it produces worse code:

- **The manifest** (`DotForge.psd1` `FunctionsToExport`/`AliasesToExport`) governs
  `Get-Command` visibility and is a genuine PowerShell constraint. The target is
  to **generate** these from tool declarations at build time, not to pretend they
  don't exist.
- **A few genuinely global concerns** will always need *something* central. Keep
  those explicit and small.

So the honest target is: **adding a tool touches only that tool's files plus
regenerable indexes — never hand-edited core logic.**

## Applying it

- **Going forward:** every new core feature is designed against this invariant.
  Specs and code reviews check for it. A design that requires editing core logic
  (or a hand-maintained central list) to add a tool is a design smell to fix
  before building.
- **Opportunistically, not big-bang:** existing central couplings get migrated
  when we next touch them, not in a churn-for-its-own-sake sweep. Examples in
  flight: workstream C moves theme family→dialect mapping from a central table
  into each tool's own `theme` block; workstream E makes aliases
  registry-owned/generated rather than hand-listed in the manifest.

## Worked examples

- **Good (already shipped):** the top-level `env` block (workstream B). A tool
  declares non-XDG env vars; `Register-DFTool` applies any tool's `env` block
  generically; a tool without one is unaffected. Adding such a tool touches no
  core code.
- **Anti-pattern, avoided:** a central `data/theme-aliases.json` keyed by tool
  name. Adding a themed tool would mean editing a core data file. Replaced by an
  optional per-tool `themeMap` block in each tool's own JSON (workstream C), read
  by `Resolve-DFThemeName` from the *target tool's* declaration — a tool whose
  dialect matches the canonical needs no declaration at all.
- **Forbidden:** any `switch ($tool.name)` / `if ($tool.name -eq …)` branch in
  core code. Encode the difference as a field the tool declares instead.
